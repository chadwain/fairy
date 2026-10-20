const std = @import("std");
const assert = std.debug.assert;
const w = std.os.windows;
const wtf16 = std.unicode.wtf8ToWtf16LeStringLiteral;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fairy = @import("fairy.zig");
const network = fairy.network;
const Path = fairy.windows.Path;
const PathHashMap = fairy.windows.PathHashMap;

pub const Database = struct {
    sync_dir: w.HANDLE,

    mutex: Io.Mutex, // TODO: Compare with RwLock
    allocator: Allocator,
    path_arena: std.heap.ArenaAllocator.State,
    children_arena: std.heap.ArenaAllocator.State,

    next_file_id: ?std.meta.Tag(network.FileId),
    files: std.AutoHashMapUnmanaged(network.FileId, FileInfo),
    regular_file_info: std.AutoHashMapUnmanaged(network.FileId, RegularFileEntry),
    directory_file_info: std.AutoHashMapUnmanaged(network.FileId, DirectoryFileEntry),
    sync_dir_entry: DirectoryFileEntry,

    host_state: std.atomic.Value(Host.State),

    debug: Debug,

    pub const FileInfo = struct {
        directory: bool,
        path: Path,
        component: Path,
        parent: ?network.FileId,
    };

    pub const RegularFileEntry = struct {
        status: Status,
        local_file_id: w.LARGE_INTEGER,
        hash: network.FileHash,
        modified_time: w.LARGE_INTEGER,
        size: w.ULARGE_INTEGER,

        pub const Status = enum { unsynced, synced };
    };

    pub const DirectoryFileEntry = struct {
        // Uses children_arena
        children: std.array_hash_map.Auto(network.FileId, void),
        // Uses children_arena
        children_by_component: ComponentArrayHashMap,

        pub const ComponentArrayHashMap = blk: {
            const Context = struct {
                pub fn hash(_: @This(), component: Path) u32 {
                    // TODO: better hashing
                    var hasher = std.hash.Wyhash.init(0);
                    for (component.slice) |c| std.hash.autoHash(&hasher, c);
                    return @truncate(hasher.final());
                }

                pub fn eql(_: @This(), a: Path, b: Path, _: usize) bool {
                    return std.mem.eql(u16, a.slice, b.slice);
                }
            };
            break :blk std.array_hash_map.Custom(Path, network.FileId, Context, true);
        };
    };

    pub fn init(sync_dir_path: [:0]const u16, allocator: Allocator) !Database {
        // TODO: The length of this path must also be factored into path length calculations.
        const sync_dir_path_nt = try Io.Threaded.wToPrefixedFileW(null, sync_dir_path, .{ .allow_relative = false });
        const sync_dir = try fairy.windows.openSyncDir(sync_dir_path_nt.span());
        errdefer comptime unreachable;

        return .{
            .sync_dir = sync_dir,
            .allocator = allocator,
            .mutex = .init,

            .path_arena = .{},
            .children_arena = .{},
            .next_file_id = 0,
            .files = .empty,
            .regular_file_info = .empty,
            .directory_file_info = .empty,
            .sync_dir_entry = .{
                .children = .empty,
                .children_by_component = .empty,
            },

            .host_state = .init(.{}),

            .debug = .{},
        };
    }

    pub fn deinit(db: *Database) void {
        fairy.windows.closeHandle(db.sync_dir);

        var path_arena = db.path_arena.promote(db.allocator);
        path_arena.deinit();

        var children_arena = db.children_arena.promote(db.allocator);
        children_arena.deinit();

        db.files.deinit(db.allocator);
        db.regular_file_info.deinit(db.allocator);
        db.directory_file_info.deinit(db.allocator);

        db.* = undefined;
    }

    fn newFile(db: *Database, path_unowned: Path, kind: network.FileKind, io: Io) !network.FileId {
        try db.mutex.lock(io);
        defer db.mutex.unlock(io);

        var it = path_unowned.pathIterator();
        var parent_file_id: ?network.FileId = null;
        {
            var component = it.nextComponent().?;
            var parent_dir_entry = &db.sync_dir_entry;
            while (true) {
                const file_id = parent_dir_entry.children_by_component.get(component) orelse {
                    it.setDirection(.backwards);
                    _ = it.previous();
                    it.setDirection(.forwards);
                    break;
                };
                const file_info = db.files.get(file_id).?;
                if (it.nextComponent()) |next| {
                    if (!file_info.directory) return error.ClientOutOfSync;
                    component = next;
                    parent_dir_entry = db.directory_file_info.getPtr(file_id).?;
                    parent_file_id = file_id;
                } else {
                    return error.ClientOutOfSync;
                }
            }
        }

        var path_arena = db.path_arena.promote(db.allocator);
        defer db.path_arena = path_arena.state;
        const path_allocator = path_arena.allocator();
        const path = try path_unowned.dupe(path_allocator);
        errdefer path_allocator.free(path.slice);

        var children_arena = db.children_arena.promote(db.allocator);
        defer db.children_arena = children_arena.state;
        const children_allocator = children_arena.allocator();

        // TODO: Calculate the number of components in `path`
        const num_new_files = fairy.max_path_components;
        const is_directory = switch (kind) {
            .directory => true,
            .regular => false,
        };
        try db.ensureUnusedFileIds(num_new_files);
        try db.files.ensureUnusedCapacity(db.allocator, num_new_files);
        try db.regular_file_info.ensureUnusedCapacity(db.allocator, @intFromBool(!is_directory));
        try db.directory_file_info.ensureUnusedCapacity(db.allocator, num_new_files - @intFromBool(!is_directory));
        errdefer comptime unreachable;

        it.replacePath(path);
        var item = it.nextPathComponent().?;
        var parent_dir_entry = if (parent_file_id) |file_id| db.directory_file_info.getPtr(file_id).? else &db.sync_dir_entry;
        while (true) {
            const file_id = db.nextFileIdAssumeAvailable();
            parent_dir_entry.children.putNoClobber(children_allocator, file_id, {}) catch |err| std.debug.panic("TODO: {s}", .{@errorName(err)});
            parent_dir_entry.children_by_component.putNoClobber(children_allocator, item.component, file_id) catch |err| std.debug.panic("TODO: {s}", .{@errorName(err)});

            if (it.nextPathComponent()) |next| {
                const entry = db.initDirectoryFile(file_id, item.component, item.path, parent_file_id);
                parent_file_id = file_id;
                parent_dir_entry = entry;
                item = next;
            } else {
                switch (kind) {
                    .regular => db.initRegularFile(file_id, item.component, item.path, parent_file_id),
                    .directory => _ = db.initDirectoryFile(file_id, item.component, item.path, parent_file_id),
                }
                return file_id;
            }
        }
    }

    // Database must be locked.
    fn ensureUnusedFileIds(db: *const Database, num: std.meta.Tag(network.FileId)) error{ExhaustedFileIds}!void {
        assert(num > 0);
        const next = db.next_file_id orelse return error.ExhaustedFileIds;
        _ = std.math.add(std.meta.Tag(network.FileId), next, num - 1) catch return error.ExhaustedFileIds;
    }

    // Database must be locked.
    fn nextFileIdAssumeAvailable(db: *Database) network.FileId {
        const next = db.next_file_id.?;
        db.next_file_id = std.math.add(std.meta.Tag(network.FileId), next, 1) catch null;
        return @enumFromInt(next);
    }

    // Database must be locked.
    fn initRegularFile(db: *Database, file_id: network.FileId, component: Path, path: Path, parent_file_id: ?network.FileId) void {
        db.files.putAssumeCapacityNoClobber(file_id, .{
            .directory = false,
            .component = component,
            .path = path,
            .parent = parent_file_id,
        });
        db.regular_file_info.putAssumeCapacityNoClobber(file_id, .{
            .status = .unsynced,
            .local_file_id = undefined,
            .hash = undefined,
            .modified_time = undefined,
            .size = undefined,
        });
    }

    // Database must be locked.
    fn initDirectoryFile(db: *Database, file_id: network.FileId, component: Path, path: Path, parent_file_id: ?network.FileId) *DirectoryFileEntry {
        db.files.putAssumeCapacityNoClobber(file_id, .{
            .directory = true,
            .component = component,
            .path = path,
            .parent = parent_file_id,
        });

        const gop = db.directory_file_info.getOrPutAssumeCapacity(file_id);
        assert(!gop.found_existing);
        gop.value_ptr.* = .{
            .children = .empty,
            .children_by_component = .empty,
        };
        return gop.value_ptr;
    }

    fn getReverseFileIdPath(db: *Database, file_id: network.FileId, buffer: *[fairy.max_path_components]network.FileId, io: Io) ![]network.FileId {
        try db.mutex.lock(io);
        defer db.mutex.unlock(io);

        var file_info = db.files.get(file_id) orelse std.debug.panic("TODO file not found", .{});
        // TODO reuse the list that was generated in `newFile`
        var list: std.ArrayList(network.FileId) = .initBuffer(buffer);

        list.appendBounded(file_id) catch unreachable;
        while (file_info.parent) |parent| : (file_info = db.files.get(parent).?) {
            list.appendBounded(parent) catch unreachable;
        }

        return list.items;
    }

    /// Opens a regular file for writing to. Creates parent directories as necessary.
    fn openRegularFile(db: *Database, io: Io, file_id: network.FileId, file_size: w.LARGE_INTEGER) !w.HANDLE {
        const full_path = blk: {
            try db.mutex.lock(io);
            defer db.mutex.unlock(io);

            const info = db.files.getPtr(file_id) orelse return error.FileDoesNotExist;
            if (info.directory) return error.IsDirectory;
            break :blk info.path;
        };

        var it = full_path.backwardsPathIterator();
        const last_component = it.previousComponent().?;
        const top_level = it.empty();
        var dir_handle = if (top_level) db.sync_dir else blk: {
            while (it.previous()) |path| {
                const handle = fairy.windows.createDir(db.sync_dir, path) catch |err| switch (err) {
                    error.ParentDirNotFound => continue,
                    error.Unexpected => |e| return e,
                };
                break :blk handle;
            } else std.debug.panic("TODO: Could not create a file in the sync directory", .{});
        };
        errdefer std.debug.panic("TODO: Delete intermediate directories and files", .{});

        it.setDirection(.forwards);
        while (it.nextComponent()) |component| {
            if (component.slice.ptr == last_component.slice.ptr) break;
            const child_handle = fairy.windows.createDir(dir_handle, component) catch |err| switch (err) {
                error.ParentDirNotFound => {
                    std.debug.panic("TODO: Directory not found even though we have an open handle to it (?)", .{});
                },
                error.Unexpected => |e| return e,
            };
            errdefer comptime unreachable;
            fairy.windows.closeHandle(dir_handle);
            dir_handle = child_handle;
        }

        const handle = fairy.windows.createFile(dir_handle, last_component, .{ .initial_size = file_size }) catch |err| switch (err) {
            error.ParentDirNotFound => {
                std.debug.panic("TODO: Directory not found even though we have an open handle to it (?)", .{});
            },
            error.Unexpected => |e| return e,
        };
        return handle;
    }

    fn finishReceiveFileContents(
        db: *Database,
        io: Io,
        handle: w.HANDLE,
        file_id: network.FileId,
        hash: *const network.FileHash,
        file_size: w.LARGE_INTEGER,
    ) !void {
        try db.mutex.lock(io);
        defer db.mutex.unlock(io);

        const file_info = db.files.get(file_id) orelse std.debug.panic("TODO file not found", .{});
        if (file_info.directory) std.debug.panic("TODO directory", .{});

        const basic_information = blk: {
            var iosb: w.IO_STATUS_BLOCK = undefined;
            var information: w.FILE.BASIC_INFORMATION = undefined;
            const status = w.ntdll.NtQueryInformationFile(
                handle,
                &iosb,
                &information,
                @sizeOf(@TypeOf(information)),
                .Basic,
            );
            switch (status) {
                .SUCCESS => break :blk information,
                else => return w.unexpectedStatus(status),
            }
        };
        const internal_information = blk: {
            var iosb: w.IO_STATUS_BLOCK = undefined;
            var information: w.FILE.INTERNAL_INFORMATION = undefined;
            const status = w.ntdll.NtQueryInformationFile(
                handle,
                &iosb,
                &information,
                @sizeOf(@TypeOf(information)),
                .Internal,
            );
            switch (status) {
                .SUCCESS => break :blk information,
                else => return w.unexpectedStatus(status),
            }
        };

        db.regular_file_info.getPtr(file_id).?.* = .{
            .status = .synced,
            .local_file_id = internal_information.IndexNumber,
            .hash = hash.*,
            .modified_time = basic_information.ChangeTime,
            .size = @intCast(file_size),
        };
    }

    const DeleteGlobalFileResult = union(enum) {
        success,
        unknown_file,
        delete_file_err,
    };

    fn deleteGlobalFile(db: *Database, file_id: network.FileId, io: Io) !DeleteGlobalFileResult {
        try db.mutex.lock(io);
        defer db.mutex.unlock(io);

        const file_info = db.files.getEntry(file_id) orelse return .unknown_file;
        if (file_info.value_ptr.directory) std.debug.panic("TODO delete folders", .{});
        const regular_info = db.regular_file_info.getEntry(file_id).?;
        switch (regular_info.value_ptr.status) {
            .synced, .unsynced => {},
        }

        // TODO maybe don't perform the delete right away, but just queue it
        if (fairy.windows.deleteFile(db.sync_dir, file_info.value_ptr.path)) |_| {
            const parent_children = if (file_info.value_ptr.parent) |parent_file_id|
                &db.directory_file_info.getPtr(parent_file_id).?.children
            else
                &db.sync_dir_entry.children;
            assert(parent_children.swapRemove(file_id));
            db.files.removeByPtr(file_info.key_ptr);
            db.regular_file_info.removeByPtr(regular_info.key_ptr);
            return .success;
        } else |_| {
            // TODO: set the file entry to some errored state
            // TODO: retry the deletion
            return .delete_file_err;
        }
    }

    fn deleteGlobalDir(db: *Database, file_id: network.FileId, io: Io) (error{ UnknownFile, Unexpected } || Io.Cancelable)!void {
        try db.mutex.lock(io);
        defer db.mutex.unlock(io);

        const Item = struct {
            children: []const network.FileId,
            index: Index,
            state: State,

            const Index = u32; // TODO: Temporary, decide on an index type to use for iterating over children
            const State = enum { iterate, delete };
        };
        var stack: [fairy.max_path_components]Item = undefined;

        const root_info = db.files.getEntry(file_id) orelse return error.UnknownFile;
        assert(root_info.value_ptr.directory);
        const root_dir_entry = db.directory_file_info.getEntry(file_id).?;
        stack[0] = .{ .children = root_dir_entry.value_ptr.children.keys(), .index = 0, .state = .iterate };

        var stack_len: fairy.PathComponentCount = 1;
        while (stack_len > 0) {
            const item = &stack[stack_len - 1];
            if (item.index == item.children.len) {
                item.* = undefined;
                stack_len -= 1;
                continue;
            }

            const child_file_id = item.children[item.index];
            const child_info = db.files.getEntry(child_file_id).?;

            if (child_info.value_ptr.directory and item.state == .iterate) enter_dir: {
                const dir_entry = db.directory_file_info.getPtr(child_file_id).?;
                const children = dir_entry.children.keys();
                if (children.len == 0) break :enter_dir;

                item.state = .delete;
                stack[stack_len] = .{ .children = children, .index = 0, .state = .iterate };
                stack_len += 1;
                continue;
            }

            try fairy.windows.deleteFile(db.sync_dir, child_info.value_ptr.path);

            if (child_info.value_ptr.directory) {
                item.state = .iterate;
                assert(db.directory_file_info.remove(child_file_id));
            } else {
                assert(db.regular_file_info.remove(child_file_id));
            }
            db.files.removeByPtr(child_info.key_ptr);

            item.index += 1;
        }

        try fairy.windows.deleteFile(db.sync_dir, root_info.value_ptr.path);

        const parent_children = if (root_info.value_ptr.parent) |parent_file_id|
            &db.directory_file_info.getPtr(parent_file_id).?.children
        else
            &db.sync_dir_entry.children;
        const parent_children_by_component = if (root_info.value_ptr.parent) |parent_file_id|
            &db.directory_file_info.getPtr(parent_file_id).?.children_by_component
        else
            &db.sync_dir_entry.children_by_component;
        assert(parent_children.swapRemove(file_id));
        assert(parent_children_by_component.swapRemove(root_info.value_ptr.component));
        db.files.removeByPtr(root_info.key_ptr);
        db.directory_file_info.removeByPtr(root_dir_entry.key_ptr);
    }

    pub const Debug = struct {
        pub fn printFileEntries(debug: *Debug, writer: *Io.Writer, io: Io) !void {
            const db: *Database = @alignCast(@fieldParentPtr("debug", debug));
            try db.mutex.lock(io);
            defer db.mutex.unlock(io);

            try writer.writeAll("Tracked files\n");
            var it = db.files.iterator();
            while (it.next()) |entry| {
                try writer.print(
                    "{}: {f}\n",
                    .{ @intFromEnum(entry.key_ptr.*), entry.value_ptr.path.formatUtf8() },
                );
            }
        }
    };
};

pub const Host = struct {
    mt: MessageThread,
    // TODO: Don't store this here, instead make it an argument to `run`
    db: *Database,
    debug: Debug,

    pub const Debug = struct {
        name: []const u8 = "<unnamed>",
    };

    pub const State = packed struct(u32) {
        mt: MtStatus = .init,
        padding: u30 = 0,

        pub const MtStatus = enum(u2) {
            /// The message thread is free to use.
            init,
            /// The message thread is locked and being initialized.
            acquired,
            /// The message thread is locked and owned by the outgoing task.
            outgoing,
            /// The message thread is locked and owned by the incoming task.
            incoming,
        };
    };

    pub fn init(db: *Database, debug: Debug) Host {
        return .{
            .mt = undefined,
            .db = db,
            .debug = debug,
        };
    }

    pub fn deinit(host: *Host) void {
        host.* = undefined;
    }

    pub const RunError = Io.ConcurrentError || Io.Cancelable;

    pub const Diagnostics = struct {
        send_error: ?SendError = null,
        recv_error: ?RecvError = null,
    };

    /// Blocks until the `Host` is finished running.
    pub fn run(
        host: *Host,
        diag: ?*Diagnostics,
        io: Io,
        reader: *Io.Reader,
        writer: *Io.Writer,
    ) RunError!void {
        const ns = struct {
            const SelectUnion = union(enum) {
                send_error: SendError!void,
                recv_error: RecvError!void,
            };

            fn addToDiagnostics(d: ?*Diagnostics, u: SelectUnion) void {
                const ptr = d orelse return;
                switch (u) {
                    inline else => |payload, tag| {
                        @field(ptr, @tagName(tag)) = if (payload) |_| null else |err| err;
                    },
                }
            }
        };

        var select_buffer: [2]ns.SelectUnion = undefined;
        var select = Io.Select(ns.SelectUnion).init(io, &select_buffer);
        defer while (select.cancel()) |result| ns.addToDiagnostics(diag, result);

        try select.concurrent(.send_error, sendOutgoingMessages, .{ host, .init(writer), io });
        try select.concurrent(.recv_error, receiveIncomingMessages, .{ host, .init(reader), io });

        host.debugLog("started", .{});
        ns.addToDiagnostics(diag, try select.await());
    }

    pub const SendError = Io.Writer.Error || Io.Cancelable || fairy.windows.SendFileError;

    fn sendOutgoingMessages(host: *Host, writer: network.Writer, io: Io) SendError!void {
        while (true) {
            while (true) {
                const state = host.db.host_state.load(.monotonic);
                if (state.mt == .outgoing) break;
                try io.futexWait(State, &host.db.host_state.raw, state);
            }

            switch (host.mt) {
                .in_new_file => |*in_new_file| {
                    try in_new_file.sendDecision(host, io, writer);
                },
                .in_file_contents => |*in_file_contents| {
                    try in_file_contents.sendResult(host, io, writer);
                },
                .in_delete_file => |*in_delete_file| {
                    try in_delete_file.sendConfirmation(host, io, writer);
                },
                .in_delete_dir => |*in_delete_dir| {
                    try in_delete_dir.sendConfirmation(host, io, writer);
                },
            }
        }
    }

    pub const RecvError = error{
        InvalidAction,
        InvalidHeader,
        InvalidFileSize,
        UnexpectedIncomingMessage,
    } ||
        network.Reader.ReceiveActionError ||
        network.Reader.ReceiveFileKindError ||
        network.Reader.ReceiveMessageHeaderError ||
        network.Reader.ReceivePathEncodingError ||
        network.Reader.ReceiveWindowsPathByteCountError ||
        network.Reader.ReceiveWindowsPathError ||
        Io.Cancelable ||
        Allocator.Error ||
        fairy.windows.ReceiveFileError;

    fn receiveIncomingMessages(host: *Host, reader: network.Reader, io: Io) RecvError!void {
        while (true) {
            const header = try reader.receiveMessageHeader();
            if (header == .disconnect) break;
            const action = try reader.receiveAction();
            host.logMessage(.incoming, action);

            switch (header) {
                .disconnect => unreachable,
                .new_thread => {
                    switch (action) {
                        .resolve_path => {
                            try MessageThread.InNewFile.initMessageThread(host, io, reader);
                        },
                        .transfer_file_contents => {
                            try MessageThread.InFileContents.initMessageThread(host, io, reader);
                        },
                        .delete_file => {
                            try MessageThread.InDeleteFile.initMessageThread(host, io, reader);
                        },
                        .delete_dir => {
                            try MessageThread.InDeleteDir.initMessageThread(host, io, reader);
                        },
                        else => return error.InvalidAction,
                    }
                },
                .thread_reply => {
                    if (host.db.host_state.load(.monotonic).mt != .incoming) return error.UnexpectedIncomingMessage;

                    switch (host.mt) {
                        .in_new_file => unreachable,
                        .in_file_contents => unreachable,
                        .in_delete_file => unreachable,
                        .in_delete_dir => unreachable,
                    }
                },
            }
        }
    }

    fn queueOutgoingMessage(host: *Host, io: Io, data: MessageThread) void {
        host.acquireMessageThread() orelse std.debug.panic("TODO: Message thread could not be acquired", .{});

        host.mt = data;

        host.releaseNewMessageThreadStatus(.acquired, .outgoing);
        io.futexWake(State, &host.db.host_state.raw, 1);
    }

    fn flipMessageThreadOwner(host: *Host, comptime to: State.MtStatus, io: Io) void {
        switch (to) {
            .init, .acquired => comptime unreachable,
            .outgoing => {
                host.releaseNewMessageThreadStatus(.incoming, to);
                io.futexWake(State, &host.db.host_state.raw, 1);
            },
            .incoming => {
                host.releaseNewMessageThreadStatus(.outgoing, to);
            },
        }
    }

    fn deleteMessageThread(host: *Host, expected_status: State.MtStatus, io: Io) void {
        host.mt = undefined;
        host.releaseNewMessageThreadStatus(expected_status, .init);

        switch (expected_status) {
            .init, .acquired => unreachable,
            .outgoing => {},
            .incoming => io.futexWake(State, &host.db.host_state.raw, 1),
        }
    }

    /// Returns null if it could not be acquired.
    fn acquireMessageThread(host: *Host) ?void {
        // TODO switch to using simple atomic stores/loads
        var old_state = host.db.host_state.load(.monotonic);
        while (old_state.mt == .init) {
            var new_state = old_state;
            new_state.mt = .acquired;
            old_state = host.db.host_state.cmpxchgWeak(old_state, new_state, .acquire, .monotonic) orelse break;
        } else return null;
    }

    fn releaseNewMessageThreadStatus(host: *Host, expected: State.MtStatus, new: State.MtStatus) void {
        // TODO switch to using simple atomic stores/loads
        var old_state = host.db.host_state.load(.monotonic);
        while (true) {
            assert(old_state.mt == expected);
            var new_state = old_state;
            new_state.mt = new;
            old_state = host.db.host_state.cmpxchgWeak(old_state, new_state, .release, .monotonic) orelse break;
        }
    }

    fn debugLog(host: *const Host, comptime fmt: []const u8, args: anytype) void {
        fairy.log.debug("(host:{s}) " ++ fmt, .{host.debug.name} ++ args);
    }

    fn logMessage(
        host: *const Host,
        comptime mt_status: Host.State.MtStatus,
        action: network.Action,
    ) void {
        switch (mt_status) {
            .init, .acquired => unreachable,
            .outgoing => host.debugLog("outgoing: {s}", .{@tagName(action)}),
            .incoming => host.debugLog("incoming: {s}", .{@tagName(action)}),
        }
    }
};

pub const MessageThread = union(enum) {
    in_new_file: InNewFile,
    in_file_contents: InFileContents,
    in_delete_file: InDeleteFile,
    in_delete_dir: InDeleteDir,

    pub const InNewFile = struct {
        data: NewFileResult,

        pub const NewFileResult = union(network.ResolvePathResponse) {
            success: network.FileId,
            invalid_path,
            exhausted_file_ids,
            client_out_of_sync,
        };

        fn initMessageThread(
            host: *Host,
            io: Io,
            reader: network.Reader,
        ) !void {
            const kind = try reader.receiveFileKind();
            const encoding = try reader.receivePathEncoding();
            const path_byte_count = try reader.receiveWindowsPathByteCount();

            var file_path_buffer: network.FilePathBuffer align(@alignOf(w.WCHAR)) = undefined;
            const path = reader.receiveWindowsPath(path_byte_count, encoding, &file_path_buffer) catch |err| switch (err) {
                error.InvalidPath => {
                    const data: MessageThread = .{
                        .in_new_file = .{
                            .data = .invalid_path,
                        },
                    };
                    return host.queueOutgoingMessage(io, data);
                },
                error.ReadFailed, error.EndOfStream => |e| return e,
            };

            const data: MessageThread = .{
                .in_new_file = .{
                    .data = if (host.db.newFile(path, kind, io)) |file_id|
                        .{ .success = file_id }
                    else |err| switch (err) {
                        error.ExhaustedFileIds => .exhausted_file_ids,
                        error.ClientOutOfSync => .client_out_of_sync,
                        error.Canceled, error.OutOfMemory => |e| return e,
                    },
                },
            };
            host.queueOutgoingMessage(io, data);
        }

        fn sendDecision(
            in_new_file: *const InNewFile,
            host: *Host,
            io: Io,
            writer: network.Writer,
        ) !void {
            const action: network.Action = .resolve_path_response;
            host.logMessage(.outgoing, action);

            switch (in_new_file.data) {
                .success => |file_id| {
                    var reverse_file_ids_buffer: [fairy.max_path_components]network.FileId = undefined;
                    const reversed_file_id_path = try host.db.getReverseFileIdPath(file_id, &reverse_file_ids_buffer, io);

                    host.deleteMessageThread(.outgoing, io);

                    try writer.sendMessageHeader(.thread_reply);
                    try writer.sendAction(action);
                    try writer.sendResolvePathResponse(.success);
                    for (0..reversed_file_id_path.len) |index| {
                        try writer.sendFileId(reversed_file_id_path[reversed_file_id_path.len - 1 - index]);
                    }
                },
                .invalid_path,
                .exhausted_file_ids,
                .client_out_of_sync,
                => {
                    host.deleteMessageThread(.outgoing, io);

                    try writer.sendMessageHeader(.thread_reply);
                    try writer.sendAction(action);
                    try writer.sendResolvePathResponse(in_new_file.data);
                },
            }
            try writer.flush();
        }
    };

    pub const InFileContents = struct {
        result: SendResult,

        pub const SendResult = enum { success, failure };

        fn initMessageThread(
            host: *Host,
            io: Io,
            reader: network.Reader,
        ) !void {
            const file_id = try reader.receiveFileId();
            const file_size = blk: {
                const network_size = try reader.receiveFileSize();
                const windows_size = std.math.cast(w.LARGE_INTEGER, network_size) orelse return error.InvalidFileSize;
                break :blk windows_size;
            };

            // TODO: Open a temporary file instead
            const handle = host.db.openRegularFile(io, file_id, file_size) catch |err| switch (err) {
                error.FileDoesNotExist, error.IsDirectory => std.debug.panic("TODO: Client out of sync", .{}),
                error.Unexpected, error.Canceled => |e| return e,
            };
            defer fairy.windows.closeHandle(handle);

            try fairy.windows.receiveFile(reader.io, handle, file_size);
            const file_hash = try reader.receiveFileHash();
            try host.db.finishReceiveFileContents(
                io,
                handle,
                file_id,
                &file_hash, // TODO: verify the hash
                file_size,
            );

            const data: MessageThread = .{
                .in_file_contents = .{
                    .result = .success,
                },
            };
            host.queueOutgoingMessage(io, data);
        }

        fn sendResult(
            in_file_contents: *const InFileContents,
            host: *Host,
            io: Io,
            writer: network.Writer,
        ) !void {
            const action: network.Action = switch (in_file_contents.result) {
                .success => .transfer_file_success,
                .failure => .transfer_file_failure,
            };
            host.logMessage(.outgoing, action);
            host.deleteMessageThread(.outgoing, io);

            try writer.sendMessageHeader(.thread_reply);
            try writer.sendAction(action);
            try writer.flush();
        }
    };

    pub const InDeleteFile = struct {
        fn initMessageThread(
            host: *Host,
            io: Io,
            reader: network.Reader,
        ) !void {
            const file_id = try reader.receiveFileId();
            switch (try host.db.deleteGlobalFile(file_id, io)) {
                .success => {},
                .unknown_file, .delete_file_err => std.debug.panic("TODO", .{}),
            }

            const data: MessageThread = .{
                .in_delete_file = .{},
            };
            host.queueOutgoingMessage(io, data);
        }

        fn sendConfirmation(
            _: *InDeleteFile,
            host: *Host,
            io: Io,
            writer: network.Writer,
        ) !void {
            const action: network.Action = .delete_file_confirm;
            host.logMessage(.outgoing, action);
            host.deleteMessageThread(.outgoing, io);

            try writer.sendMessageHeader(.thread_reply);
            try writer.sendAction(action);
            try writer.flush();
        }
    };

    pub const InDeleteDir = struct {
        fn initMessageThread(
            host: *Host,
            io: Io,
            reader: network.Reader,
        ) !void {
            const file_id = try reader.receiveFileId();
            host.db.deleteGlobalDir(file_id, io) catch |err| switch (err) {
                error.UnknownFile, error.Unexpected => std.debug.panic("TODO", .{}),
                error.Canceled => |e| return e,
            };

            const data: MessageThread = .{
                .in_delete_dir = .{},
            };
            host.queueOutgoingMessage(io, data);
        }

        fn sendConfirmation(
            _: *InDeleteDir,
            host: *Host,
            io: Io,
            writer: network.Writer,
        ) !void {
            const action: network.Action = .delete_dir_confirm;
            host.logMessage(.outgoing, action);
            host.deleteMessageThread(.outgoing, io);

            try writer.sendMessageHeader(.thread_reply);
            try writer.sendAction(action);
            try writer.flush();
        }
    };
};
