const Server = @This();

const std = @import("std");
const assert = std.debug.assert;
const w = std.os.windows;
const wtf16 = std.unicode.wtf8ToWtf16LeStringLiteral;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fairy = @import("fairy.zig");
const network = fairy.network;

sync_dir: DirHandle,
mutex: Io.Mutex, // TODO: Compare with RwLock

allocator: Allocator,
path_arena: std.heap.ArenaAllocator.State,
children_arena: std.heap.ArenaAllocator.State,

next_file_id: ?std.meta.Tag(network.FileId),

db: Database,
host_state: std.atomic.Value(Host.State),
debug: Debug,

pub fn initWindows(sync_dir_path: [:0]const u16, allocator: Allocator) !Server {
    comptime assert(fairy.platform == .windows);
    // TODO: The length of this path must also be factored into path length calculations.
    const sync_dir_path_nt = try Io.Threaded.wToPrefixedFileW(null, sync_dir_path, .{ .allow_relative = false });
    const sync_dir = try fairy.windows.openSyncDir(sync_dir_path_nt.span());
    errdefer comptime unreachable;

    return initCommon(sync_dir, allocator);
}

pub fn initLinux(sync_dir_path: [:0]const u8, io: Io, allocator: Allocator) !Server {
    comptime assert(fairy.platform == .linux);
    // TODO: The length of `sync_dir_path` must also be factored into path length calculations.
    const sync_dir = try Io.Dir.cwd().openDir(io, sync_dir_path, .{ .iterate = true });
    errdefer comptime unreachable;

    return initCommon(sync_dir, allocator);
}

fn initCommon(sync_dir: DirHandle, allocator: Allocator) Server {
    return .{
        .sync_dir = sync_dir,
        .allocator = allocator,
        .mutex = .init,
        .path_arena = .{},
        .children_arena = .{},

        .next_file_id = 0,

        .db = .init,
        .host_state = .init(.{}),
        .debug = .{},
    };
}

pub fn deinitWindows(server: *Server) void {
    comptime assert(fairy.platform == .windows);
    fairy.windows.closeHandle(server.sync_dir);

    server.deinitCommon();
}

pub fn deinitLinux(server: *Server, io: Io) void {
    comptime assert(fairy.platform == .linux);
    server.sync_dir.close(io);

    server.deinitCommon();
}

fn deinitCommon(server: *Server) void {
    var path_arena = server.path_arena.promote(server.allocator);
    path_arena.deinit();

    var children_arena = server.children_arena.promote(server.allocator);
    children_arena.deinit();

    server.db.deinit(server.allocator);
    server.* = undefined;
}

fn lock(server: *Server, io: Io) !Locked {
    try server.mutex.lock(io);
    return .{ .server = server };
}

pub const Path = switch (fairy.platform) {
    .windows => fairy.windows.Path,
    .linux => fairy.linux.Path,
};

pub const PathHashMap = switch (fairy.platform) {
    .windows => fairy.windows.PathHashMap,
    .linux => fairy.linux.PathHashMap,
};

pub const DirHandle = switch (fairy.platform) {
    .windows => w.HANDLE,
    .linux => Io.Dir,
};

pub const Database = struct {
    files: std.AutoHashMapUnmanaged(network.FileId, FileInfo),
    regular_file_info: std.AutoHashMapUnmanaged(network.FileId, RegularFileEntry),
    directory_file_info: std.AutoHashMapUnmanaged(network.FileId, DirectoryFileEntry),
    sync_dir_entry: DirectoryFileEntry,
    history: std.ArrayList(HistoryItem),
    revisions: std.ArrayList(usize),

    pub const FileInfo = struct {
        directory: bool,
        path: Path,
        component: Path,
        parent: ?network.FileId,
    };

    pub const RegularFileEntry = struct {
        // TODO: Store metadata about regular files
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
                    return std.mem.eql(std.meta.Child(@FieldType(Path, "slice")), a.slice, b.slice);
                }
            };
            break :blk std.array_hash_map.Custom(Path, network.FileId, Context, true);
        };
    };

    pub const HistoryItem = union(network.HistoryItemKind) {
        create_file: Create,
        create_dir: Create,
        delete_file: network.FileId,
        delete_dir: network.FileId,
        modify_file: network.FileId,

        pub const Create = struct {
            path: Path,
            file_id: network.FileId,
            parent: ?network.FileId,
        };
    };

    const init: Database = .{
        .files = .empty,
        .regular_file_info = .empty,
        .directory_file_info = .empty,
        .sync_dir_entry = .{
            .children = .empty,
            .children_by_component = .empty,
        },
        .history = .empty,
        .revisions = .empty,
    };

    fn deinit(db: *Database, allocator: Allocator) void {
        db.files.deinit(allocator);
        db.regular_file_info.deinit(allocator);
        db.directory_file_info.deinit(allocator);
        db.history.deinit(allocator);
        db.revisions.deinit(allocator);

        db.* = undefined;
    }
};

/// Opens a regular file for writing to. Creates parent directories as necessary.
fn openRegularFileWindows(server: *Server, full_path: Path, file_size: w.LARGE_INTEGER) !w.HANDLE {
    var it = full_path.backwardsPathIterator();
    const last_component = it.previousComponent().?;
    var is_sync_dir = it.empty();
    var dir_handle = if (is_sync_dir) server.sync_dir else blk: {
        while (it.previous()) |path| {
            const handle = fairy.windows.createDir(server.sync_dir, path) catch |err| switch (err) {
                error.ParentDirNotFound => continue,
                error.Unexpected => |e| return e,
            };
            break :blk handle;
        } else std.debug.panic("TODO: Could not create a file in the sync directory", .{});
    };
    defer if (!is_sync_dir) fairy.windows.closeHandle(dir_handle);
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
        if (!is_sync_dir) fairy.windows.closeHandle(dir_handle);
        dir_handle = child_handle;
        is_sync_dir = false;
    }

    const handle = fairy.windows.createFile(dir_handle, last_component, .{ .initial_size = file_size }) catch |err| switch (err) {
        error.ParentDirNotFound => {
            std.debug.panic("TODO: Directory not found even though we have an open handle to it (?)", .{});
        },
        error.Unexpected => |e| return e,
    };
    return handle;
}

/// Opens a regular file for writing to. Creates parent directories as necessary.
fn openRegularFileLinux(server: *Server, full_path: Path, io: Io) !Io.File {
    var it = full_path.backwardsPathIterator();
    const last_component = it.previousComponent().?;
    const top_level = it.empty();
    const dir_handle = if (top_level)
        server.sync_dir
    else
        try server.sync_dir.createDirPathOpen(
            io,
            it.previous().?.slice,
            .{ .open_options = .{ .follow_symlinks = false } },
        );
    defer if (!top_level) dir_handle.close(io);
    errdefer std.debug.panic("TODO: Delete intermediate directories and files", .{});

    return try dir_handle.createFile(io, last_component.slice, .{});
}

pub const Debug = struct {
    fn log(_: *const Debug, comptime level: std.log.Level, comptime fmt: []const u8, args: anytype) void {
        @field(fairy.log, @tagName(level))("(server) " ++ fmt, args);
    }

    pub fn printFileEntries(debug: *Debug, writer: *Io.Writer, io: Io) !void {
        const server: *Server = @alignCast(@fieldParentPtr("debug", debug));
        try server.mutex.lock(io);
        defer server.mutex.unlock(io);

        try writer.writeAll("Tracked files\n");
        var it = server.db.files.iterator();
        while (it.next()) |entry| {
            try writer.print(
                "{}: {f}\n",
                .{ @backingInt(entry.key_ptr.*), entry.value_ptr.path.formatUtf8() },
            );
        }
    }
};

const Locked = struct {
    server: *Server,

    fn unlock(locked: Locked, io: Io) void {
        locked.server.mutex.unlock(io);
    }

    fn ensureUnusedRevision(locked: Locked) (error{ExhaustedRevisionIds} || Allocator.Error)!void {
        if (locked.server.db.revisions.items.len == std.math.maxInt(std.meta.Tag(network.RevisionId))) return error.ExhaustedRevisionIds;
        try locked.server.db.revisions.ensureUnusedCapacity(locked.server.allocator, 1);
    }

    fn createRevisionAssumeAvailable(locked: Locked) network.RevisionId {
        const int: std.meta.Tag(network.RevisionId) = @intCast(locked.server.db.revisions.items.len);
        locked.server.debug.log(.info, "created revision {}", .{int});
        locked.server.db.revisions.appendAssumeCapacity(locked.server.db.history.items.len);
        return @fromBackingInt(int);
    }

    fn newFile(locked: Locked, path_unowned: Path, kind: network.FileKind) !network.FileId {
        const s = locked.server;

        var it = path_unowned.pathIterator();
        var parent_file_id: ?network.FileId = null;
        {
            var component = it.nextComponent().?;
            var parent_dir_entry = &s.db.sync_dir_entry;
            while (true) {
                const file_id = parent_dir_entry.children_by_component.get(component) orelse {
                    it.setDirection(.backwards);
                    _ = it.previous();
                    it.setDirection(.forwards);
                    break;
                };
                const file_info = s.db.files.get(file_id).?;
                if (it.nextComponent()) |next| {
                    if (!file_info.directory) return error.ClientOutOfSync;
                    component = next;
                    parent_dir_entry = s.db.directory_file_info.getPtr(file_id).?;
                    parent_file_id = file_id;
                } else {
                    return error.ClientOutOfSync;
                }
            }
        }

        var path_arena = s.path_arena.promote(s.allocator);
        defer s.path_arena = path_arena.state;
        const path_allocator = path_arena.allocator();
        const path = try path_unowned.dupe(path_allocator);
        errdefer path_allocator.free(path.slice);

        var children_arena = s.children_arena.promote(s.allocator);
        defer s.children_arena = children_arena.state;
        const children_allocator = children_arena.allocator();

        // TODO: Calculate the number of components in `path`
        const num_new_files = fairy.max_path_components;
        const is_directory = switch (kind) {
            .directory => true,
            .regular => false,
        };
        try locked.ensureUnusedRevision();
        try locked.ensureUnusedFileIds(num_new_files);
        try s.db.files.ensureUnusedCapacity(s.allocator, num_new_files);
        try s.db.regular_file_info.ensureUnusedCapacity(s.allocator, @intFromBool(!is_directory));
        try s.db.directory_file_info.ensureUnusedCapacity(s.allocator, num_new_files - @intFromBool(!is_directory));
        try s.db.history.ensureUnusedCapacity(s.allocator, num_new_files);
        errdefer comptime unreachable;

        it.replacePath(path);
        var item = it.nextPathComponent().?;
        var parent_dir_entry = if (parent_file_id) |file_id| s.db.directory_file_info.getPtr(file_id).? else &s.db.sync_dir_entry;
        while (true) {
            const file_id = locked.nextFileIdAssumeAvailable();
            parent_dir_entry.children.putNoClobber(children_allocator, file_id, {}) catch |err| std.debug.panic("TODO: {s}", .{@errorName(err)});
            parent_dir_entry.children_by_component.putNoClobber(children_allocator, item.component, file_id) catch |err| std.debug.panic("TODO: {s}", .{@errorName(err)});

            if (it.nextPathComponent()) |next| {
                const entry = locked.initDirectoryFile(file_id, item.component, item.path, parent_file_id);
                parent_file_id = file_id;
                parent_dir_entry = entry;
                item = next;
            } else {
                switch (kind) {
                    .regular => locked.initRegularFile(file_id, item.component, item.path, parent_file_id),
                    .directory => _ = locked.initDirectoryFile(file_id, item.component, item.path, parent_file_id),
                }
                const revision = locked.createRevisionAssumeAvailable();
                _ = revision; // TODO
                return file_id;
            }
        }
    }

    fn ensureUnusedFileIds(locked: Locked, num: std.meta.Tag(network.FileId)) error{ExhaustedFileIds}!void {
        assert(num > 0);
        const next = locked.server.next_file_id orelse return error.ExhaustedFileIds;
        _ = std.math.add(std.meta.Tag(network.FileId), next, num - 1) catch return error.ExhaustedFileIds;
    }

    fn nextFileIdAssumeAvailable(locked: Locked) network.FileId {
        const next = locked.server.next_file_id.?;
        locked.server.next_file_id = std.math.add(std.meta.Tag(network.FileId), next, 1) catch null;
        return @fromBackingInt(next);
    }

    fn initRegularFile(
        locked: Locked,
        file_id: network.FileId,
        component: Path,
        path: Path,
        parent_file_id: ?network.FileId,
    ) void {
        const db = &locked.server.db;
        db.history.appendAssumeCapacity(.{
            .create_file = .{
                .path = path,
                .file_id = file_id,
                .parent = parent_file_id,
            },
        });
        db.files.putAssumeCapacityNoClobber(file_id, .{
            .directory = false,
            .component = component,
            .path = path,
            .parent = parent_file_id,
        });
        db.regular_file_info.putAssumeCapacityNoClobber(file_id, .{});
    }

    fn initDirectoryFile(
        locked: Locked,
        file_id: network.FileId,
        component: Path,
        path: Path,
        parent_file_id: ?network.FileId,
    ) *Database.DirectoryFileEntry {
        const db = &locked.server.db;

        db.history.appendAssumeCapacity(.{
            .create_dir = .{
                .path = path,
                .file_id = file_id,
                .parent = parent_file_id,
            },
        });

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

    fn getReverseFileIdPath(
        locked: Locked,
        file_id: network.FileId,
        buffer: *[fairy.max_path_components]network.FileId,
    ) ![]network.FileId {
        const s = locked.server;

        var file_info = s.db.files.get(file_id) orelse std.debug.panic("TODO file not found", .{});
        // TODO reuse the list that was generated in `newFile`
        var list: std.ArrayList(network.FileId) = .initBuffer(buffer);

        list.appendBounded(file_id) catch unreachable;
        while (file_info.parent) |parent| : (file_info = s.db.files.get(parent).?) {
            list.appendBounded(parent) catch unreachable;
        }

        return list.items;
    }

    fn getPath(locked: Locked, file_id: network.FileId) error{ FileDoesNotExist, IsDirectory }!Path {
        const info = locked.server.db.files.getPtr(file_id) orelse return error.FileDoesNotExist;
        if (info.directory) return error.IsDirectory;
        return info.path;
    }

    fn deleteGlobalFile(
        locked: Locked,
        file_id: network.FileId,
    ) (error{ UnknownFile, NotARegularFile, ExhaustedRevisionIds } || Allocator.Error)!Path {
        const s = locked.server;

        const file_info = blk: {
            const file_info = s.db.files.getEntry(file_id) orelse return error.UnknownFile;
            if (file_info.value_ptr.directory) return error.NotARegularFile;

            try locked.ensureUnusedRevision();
            try s.db.history.ensureUnusedCapacity(s.allocator, 1);

            defer s.db.files.removeByPtr(file_info.key_ptr);
            break :blk file_info.value_ptr.*;
        };
        errdefer comptime unreachable;

        assert(s.db.regular_file_info.remove(file_id));
        const parent_children = if (file_info.parent) |parent_file_id|
            &s.db.directory_file_info.getPtr(parent_file_id).?.children
        else
            &s.db.sync_dir_entry.children;
        assert(parent_children.swapRemove(file_id));

        s.db.history.appendAssumeCapacity(.{ .delete_file = file_id });
        const revision = locked.createRevisionAssumeAvailable();
        _ = revision; // TODO

        return file_info.path;
    }

    const DeleteGlobalDirError = error{
        UnknownFile,
        NotADirectory,
        ExhaustedRevisionIds,
    } ||
        Allocator.Error ||
        Io.Cancelable ||
        switch (fairy.platform) {
            .windows => error{Unexpected},
            .linux => Io.Dir.DeleteFileError || Io.Dir.DeleteDirError,
        };

    fn deleteGlobalDir(locked: Locked, file_id: network.FileId, io: Io) DeleteGlobalDirError!void {
        const s = locked.server;

        const Item = struct {
            children: []const network.FileId,
            index: Index,
            state: State,

            const Index = u32; // TODO: Temporary, decide on an index type to use for iterating over children
            const State = enum { iterate, delete };
        };
        var stack: [fairy.max_path_components]Item = undefined;

        const root_info = s.db.files.getEntry(file_id) orelse return error.UnknownFile;
        if (!root_info.value_ptr.directory) return error.NotADirectory;

        try locked.ensureUnusedRevision();
        try s.db.history.ensureUnusedCapacity(s.allocator, 1);

        const root_dir_entry = s.db.directory_file_info.getEntry(file_id).?;
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
            const child_info = s.db.files.getEntry(child_file_id).?;

            if (child_info.value_ptr.directory and item.state == .iterate) enter_dir: {
                const dir_entry = s.db.directory_file_info.getPtr(child_file_id).?;
                const children = dir_entry.children.keys();
                if (children.len == 0) break :enter_dir;

                item.state = .delete;
                stack[stack_len] = .{ .children = children, .index = 0, .state = .iterate };
                stack_len += 1;
                continue;
            }

            switch (fairy.platform) {
                .windows => try fairy.windows.deleteFile(s.sync_dir, child_info.value_ptr.path),
                .linux => try s.sync_dir.deleteFile(io, child_info.value_ptr.path.slice),
            }

            if (child_info.value_ptr.directory) {
                item.state = .iterate;
                assert(s.db.directory_file_info.remove(child_file_id));
            } else {
                assert(s.db.regular_file_info.remove(child_file_id));
            }
            s.db.files.removeByPtr(child_info.key_ptr);

            item.index += 1;
        }

        switch (fairy.platform) {
            .windows => try fairy.windows.deleteFile(s.sync_dir, root_info.value_ptr.path),
            .linux => try s.sync_dir.deleteDir(io, root_info.value_ptr.path.slice),
        }

        const parent_children = if (root_info.value_ptr.parent) |parent_file_id|
            &s.db.directory_file_info.getPtr(parent_file_id).?.children
        else
            &s.db.sync_dir_entry.children;
        const parent_children_by_component = if (root_info.value_ptr.parent) |parent_file_id|
            &s.db.directory_file_info.getPtr(parent_file_id).?.children_by_component
        else
            &s.db.sync_dir_entry.children_by_component;
        assert(parent_children.swapRemove(file_id));
        assert(parent_children_by_component.swapRemove(root_info.value_ptr.component));
        s.db.files.removeByPtr(root_info.key_ptr);
        s.db.directory_file_info.removeByPtr(root_dir_entry.key_ptr);

        s.db.history.appendAssumeCapacity(.{ .delete_dir = file_id });
        const revision = locked.createRevisionAssumeAvailable();
        _ = revision; // TODO
    }
};

pub const Host = struct {
    setup: std.atomic.Value(Setup),
    mt: MessageThread,
    // TODO: Don't store this here, instead make it an argument to `run`
    server: *Server,
    debug: Host.Debug,

    pub const Debug = struct {
        name: []const u8 = "<unnamed>",
    };

    pub const Setup = enum(u32) {
        send_platform,
        recv_ack,
        end,
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

    pub fn init(server: *Server, debug: Host.Debug) Host {
        return .{
            .setup = .init(.send_platform),
            .mt = undefined,
            .server = server,
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
        {
            try writer.sendPlatform(switch (fairy.platform) {
                .windows => .windows,
                .linux => .linux,
            });
            try writer.flush();
            host.setup.store(.recv_ack, .release);
            io.futexWake(Setup, &host.setup.raw, 1);

            while (true) : (try io.futexWait(Setup, &host.setup.raw, .recv_ack)) {
                switch (host.setup.load(.acquire)) {
                    .send_platform => unreachable,
                    .recv_ack => continue,
                    .end => break,
                }
            }
        }

        while (true) {
            while (true) {
                const state = host.server.host_state.load(.monotonic);
                if (state.mt == .outgoing) break;
                try io.futexWait(State, &host.server.host_state.raw, state);
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
        network.Reader.ReceiveAckError ||
        network.Reader.ReceiveActionError ||
        network.Reader.ReceiveFileKindError ||
        network.Reader.ReceiveMessageHeaderError ||
        Io.Cancelable ||
        Allocator.Error ||
        switch (fairy.platform) {
            .windows => fairy.windows.ReceiveFileError ||
                network.Reader.ReceiveWindowsPathByteCountError ||
                network.Reader.ReceiveWindowsPathError,
            .linux => Io.Dir.CreateDirPathOpenError ||
                Io.File.OpenError ||
                Io.Dir.DeleteFileError ||
                Io.File.Writer.Error,
        };

    fn receiveIncomingMessages(host: *Host, reader: network.Reader, io: Io) RecvError!void {
        {
            while (true) : (try io.futexWait(Setup, &host.setup.raw, .send_platform)) {
                switch (host.setup.load(.acquire)) {
                    .send_platform => continue,
                    .recv_ack => break,
                    .end => unreachable,
                }
            }

            try reader.receiveAck();
            host.setup.store(.end, .release);
            io.futexWake(Setup, &host.setup.raw, 1);
        }

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
                    if (host.server.host_state.load(.monotonic).mt != .incoming) return error.UnexpectedIncomingMessage;

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
        io.futexWake(State, &host.server.host_state.raw, 1);
    }

    fn flipMessageThreadOwner(host: *Host, comptime to: State.MtStatus, io: Io) void {
        switch (to) {
            .init, .acquired => comptime unreachable,
            .outgoing => {
                host.releaseNewMessageThreadStatus(.incoming, to);
                io.futexWake(State, &host.server.host_state.raw, 1);
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
            .incoming => io.futexWake(State, &host.server.host_state.raw, 1),
        }
    }

    /// Returns null if it could not be acquired.
    fn acquireMessageThread(host: *Host) ?void {
        // TODO switch to using simple atomic stores/loads
        var old_state = host.server.host_state.load(.monotonic);
        while (old_state.mt == .init) {
            var new_state = old_state;
            new_state.mt = .acquired;
            old_state = host.server.host_state.cmpxchgWeak(old_state, new_state, .acquire, .monotonic) orelse break;
        } else return null;
    }

    fn releaseNewMessageThreadStatus(host: *Host, expected: State.MtStatus, new: State.MtStatus) void {
        // TODO switch to using simple atomic stores/loads
        var old_state = host.server.host_state.load(.monotonic);
        while (true) {
            assert(old_state.mt == expected);
            var new_state = old_state;
            new_state.mt = new;
            old_state = host.server.host_state.cmpxchgWeak(old_state, new_state, .release, .monotonic) orelse break;
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
            const path_byte_count = switch (fairy.platform) {
                .windows => try reader.receiveWindowsPathByteCount(),
                .linux => try reader.receiveLinuxPathByteCount(),
            };

            var file_path_buffer: network.FilePathBuffer align(@alignOf(w.WCHAR)) = undefined;
            const path = switch (fairy.platform) {
                .windows => reader.receiveWindowsPath(path_byte_count, &file_path_buffer),
                .linux => reader.receiveLinuxPath(path_byte_count, &file_path_buffer),
            } catch |err| switch (err) {
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
                    .data = blk: {
                        const locked = try host.server.lock(io);
                        defer locked.unlock(io);

                        break :blk if (locked.newFile(path, kind)) |file_id|
                            .{ .success = file_id }
                        else |err| switch (err) {
                            error.ExhaustedRevisionIds => std.debug.panic("TODO", .{}),
                            error.ExhaustedFileIds => .exhausted_file_ids,
                            error.ClientOutOfSync => .client_out_of_sync,
                            error.OutOfMemory => |e| return e,
                        };
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
                    const reversed_file_id_path = blk: {
                        const locked = try host.server.lock(io);
                        defer locked.unlock(io);
                        break :blk try locked.getReverseFileIdPath(file_id, &reverse_file_ids_buffer);
                    };

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

            // TODO: Open a temporary file instead
            switch (fairy.platform) {
                .windows => {
                    const file_size = blk: {
                        const file_size = try reader.receiveFileSize();
                        const windows_size = std.math.cast(w.LARGE_INTEGER, file_size) orelse return error.InvalidFileSize;
                        break :blk windows_size;
                    };
                    const path = blk: {
                        const locked = try host.server.lock(io);
                        defer locked.unlock(io);
                        break :blk locked.getPath(file_id) catch |err| switch (err) {
                            error.FileDoesNotExist, error.IsDirectory => std.debug.panic("TODO: Client out of sync", .{}),
                        };
                    };
                    const handle = host.server.openRegularFileWindows(path, file_size) catch |err| switch (err) {
                        error.Unexpected => |e| return e,
                    };
                    defer fairy.windows.closeHandle(handle);
                    try fairy.windows.receiveFile(reader.io, handle, file_size);
                },
                .linux => {
                    const file_size = try reader.receiveFileSize();
                    const path = blk: {
                        const locked = try host.server.lock(io);
                        defer locked.unlock(io);
                        break :blk locked.getPath(file_id) catch |err| switch (err) {
                            error.FileDoesNotExist, error.IsDirectory => std.debug.panic("TODO: Client out of sync", .{}),
                        };
                    };
                    const file = host.server.openRegularFileLinux(path, io) catch |err| switch (err) {
                        else => |e| return e,
                    };
                    defer file.close(io);
                    var file_write_buffer: [512]u8 = undefined;
                    var file_writer = file.writer(io, &file_write_buffer);
                    reader.io.streamExact(&file_writer.interface, file_size) catch |err| switch (err) {
                        error.WriteFailed => return file_writer.err.?,
                        error.ReadFailed, error.EndOfStream => |e| return e,
                    };
                    file_writer.interface.flush() catch return file_writer.err.?;
                },
            }
            const file_hash = try reader.receiveFileHash();
            _ = file_hash; // TODO

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
            const path = blk: {
                const locked = try host.server.lock(io);
                defer locked.unlock(io);
                break :blk locked.deleteGlobalFile(file_id) catch |err| switch (err) {
                    error.UnknownFile, error.NotARegularFile => std.debug.panic("TODO: Client out of sync", .{}),
                    error.OutOfMemory, error.ExhaustedRevisionIds => std.debug.panic("TODO: {s}", .{@errorName(err)}),
                };
            };
            switch (fairy.platform) {
                .windows => try fairy.windows.deleteFile(host.server.sync_dir, path),
                .linux => try host.server.sync_dir.deleteFile(io, path.slice),
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
            {
                const locked = try host.server.lock(io);
                defer locked.unlock(io);
                locked.deleteGlobalDir(file_id, io) catch |err| switch (err) {
                    error.UnknownFile => std.debug.panic("TODO: Client out of sync", .{}),
                    error.Canceled => |e| return e,
                    else => |e| std.debug.panic("TODO: {s}", .{@errorName(e)}),
                };
            }

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
