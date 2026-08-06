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

const cpu_endian = @import("builtin").cpu.arch.endian();

pub const Database = struct {
    sync_dir: w.HANDLE,

    mutex: Io.Mutex, // TODO: Compare with RwLock
    allocator: Allocator,
    path_arena: std.heap.ArenaAllocator.State,

    path_map: PathHashMap(network.FileId),
    next_file_id: ?std.meta.Tag(network.FileId),
    files: std.AutoHashMapUnmanaged(network.FileId, FileInfo),
    regular_file_info: std.AutoHashMapUnmanaged(network.FileId, RegularFileEntry),

    host_state: std.atomic.Value(Host.State),

    debug: Debug,

    pub const FileInfo = struct {
        directory: bool,
        path: Path,
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
            .path_map = .empty,
            .next_file_id = 1,
            .files = .empty,
            .regular_file_info = .empty,

            .host_state = .init(.{}),

            .debug = .{},
        };
    }

    pub fn deinit(db: *Database) void {
        fairy.windows.closeHandle(db.sync_dir);

        var path_arena = db.path_arena.promote(db.allocator);
        path_arena.deinit();

        db.path_map.deinit(db.allocator);
        db.files.deinit(db.allocator);
        db.regular_file_info.deinit(db.allocator);

        db.* = undefined;
    }

    fn newFile(db: *Database, path: Path, kind: network.FileKind, io: Io) !network.FileId {
        try db.mutex.lock(io);
        defer db.mutex.unlock(io);

        const initial_file_id_tag = db.next_file_id orelse return error.ExhaustedFileIds;
        errdefer {
            var file_id_tag: ?std.meta.Tag(network.FileId) = initial_file_id_tag;
            while (file_id_tag) |tag| : (file_id_tag = std.math.add(std.meta.Tag(network.FileId), tag, 1) catch null) {
                if (tag == db.next_file_id) break;
                const file_id: network.FileId = @enumFromInt(tag);
                const info = db.files.fetchRemove(file_id).?;
                if (!info.value.directory) {
                    assert(db.regular_file_info.remove(file_id));
                }
                assert(db.path_map.remove(info.value.path));
            }
            db.next_file_id = initial_file_id_tag;
        }

        var file_id_buffer: [fairy.max_path_components]network.FileId = undefined;
        var file_id_list: std.ArrayList(network.FileId) = .initBuffer(&file_id_buffer);

        var path_arena = db.path_arena.promote(db.allocator);
        defer db.path_arena = path_arena.state;
        const path_allocator = path_arena.allocator();

        var it = path.componentIterator();
        var is_last = true;
        var parent: ?network.FileId = first_known_directory: while (if (is_last) it.last() else it.previous()) |item| : (is_last = false) {
            const sub_path: Path = .assumeValidPath(item.path);
            const gop = try db.path_map.getOrPut(db.allocator, sub_path);
            if (gop.found_existing) {
                // TODO: This is a server/client conflict.
                const file_info = db.files.getEntry(gop.value_ptr.*).?;
                if (is_last) {
                    switch (kind) {
                        .regular => if (file_info.value_ptr.directory) return error.WrongFileKind,
                        .directory => if (!file_info.value_ptr.directory) return error.WrongFileKind,
                    }
                    return gop.value_ptr.*;
                }
                if (!file_info.value_ptr.directory) return error.InvalidFolder;
                break :first_known_directory gop.value_ptr.*;
            }
            errdefer db.path_map.removeByPtr(gop.key_ptr);

            const list_item_ptr = file_id_list.addOneBounded() catch unreachable;
            const file_id_tag = db.next_file_id orelse return error.ExhaustedFileIds;

            const sub_path_copy = try sub_path.dupe(path_allocator);
            errdefer path_allocator.free(sub_path_copy.slice);

            try db.files.ensureUnusedCapacity(db.allocator, 1);
            const is_regular = switch (kind) {
                .regular => is_last,
                .directory => false,
            };
            if (is_regular) try db.regular_file_info.ensureUnusedCapacity(db.allocator, 1);
            errdefer comptime unreachable;

            const file_id: network.FileId = @enumFromInt(file_id_tag);
            db.next_file_id = std.math.add(std.meta.Tag(network.FileId), file_id_tag, 1) catch null;
            db.files.putAssumeCapacityNoClobber(file_id, .{
                .directory = !is_regular,
                .path = sub_path_copy,
                .parent = undefined,
            });
            if (is_regular) db.regular_file_info.putAssumeCapacityNoClobber(file_id, .{
                .status = .unsynced,
                .local_file_id = undefined,
                .hash = undefined,
                .modified_time = undefined,
                .size = undefined,
            });
            gop.key_ptr.* = sub_path_copy;
            gop.value_ptr.* = file_id;
            list_item_ptr.* = file_id;
        } else break :first_known_directory null;

        const file_id_range = file_id_list.items;

        while (it.previous()) |_| {
            _ = file_id_list.addOneBounded() catch unreachable;
        }

        for (0..file_id_range.len) |i| {
            const file_id = file_id_range[file_id_range.len - 1 - i];
            const file_info = db.files.getPtr(file_id).?;
            file_info.parent = parent;
            parent = file_id;
        }

        return file_id_range[0];
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

    const CanTransferDataResult = union(enum) {
        file_exists: struct {
            path: Path,
        },
        file_doesnt_exist,
        is_a_directory,
    };

    fn canTransferData(
        db: *Database,
        file_id: network.FileId,
        io: Io,
    ) !CanTransferDataResult {
        try db.mutex.lock(io);
        defer db.mutex.unlock(io);

        const info = db.files.getPtr(file_id) orelse return .file_doesnt_exist;
        if (info.directory) return .is_a_directory;
        return .{ .file_exists = .{
            .path = info.path,
        } };
    }

    fn openFileReadOnly(db: *const Database, path: Path) !w.HANDLE {
        return fairy.windows.openFile(db.sync_dir, path, .read);
    }

    const CreateParentDirectoriesError = error{ CreateParentDirFail, Unexpected };

    const CreateParentDirectoriesResult = struct {
        parent: union(enum) {
            handle: w.HANDLE,
            sync_dir,
        },
        name: Path,
    };

    fn createParentDirectories(db: *const Database, path: Path) CreateParentDirectoriesError!CreateParentDirectoriesResult {
        var it = path.componentIterator();
        const first = it.first().?;
        const last = it.last().?;
        if (first.path.len == last.path.len) return .{ .parent = .sync_dir, .name = .assumeValidPath(last.name) };
        var handle = blk: while (it.previous()) |component| {
            const handle = fairy.windows.createDir(db.sync_dir, .assumeValidPath(component.path)) catch |err| switch (err) {
                error.ParentDirNotFound => continue,
                error.Unexpected => |e| return e,
            };
            if (component.path.len != first.path.len) _ = it.next().?;
            break :blk handle;
        } else return error.CreateParentDirFail;
        errdefer fairy.windows.closeHandle(handle);

        // TODO errdefer delete whatever we created
        while (it.next()) |component| {
            if (component.path.len == last.path.len) break;
            const child_handle = fairy.windows.createDir(handle, .assumeValidPath(component.name)) catch |err| switch (err) {
                error.ParentDirNotFound => {
                    // TODO: The directory we just created was deleted.
                    //       Either try to re-create it, or obtain exclusive delete access to it.
                    return error.CreateParentDirFail;
                },
                error.Unexpected => |e| return e,
            };
            errdefer comptime unreachable;
            fairy.windows.closeHandle(handle);
            handle = child_handle;
        }

        return .{ .parent = .{ .handle = handle }, .name = .assumeValidPath(last.name) };
    }

    fn createFile(_: *const Database, parent: w.HANDLE, name: Path, initial_size: w.LARGE_INTEGER) !w.HANDLE {
        return fairy.windows.createFile(parent, name, .{ .initial_size = initial_size });
    }

    fn closeHandle(_: *const Database, file: w.HANDLE) void {
        fairy.windows.closeHandle(file);
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

    fn createDir(db: *Database, file_id: network.FileId, io: Io) !void {
        try db.mutex.lock(io);
        defer db.mutex.unlock(io);

        const file_info = db.files.getPtr(file_id) orelse return error.UnknownFile;
        if (!file_info.directory) return error.NotADirectory;

        const create_result = try db.createParentDirectories(file_info.path);
        defer switch (create_result.parent) {
            .handle => |handle| db.closeHandle(handle),
            .sync_dir => {},
        };

        const parent = switch (create_result.parent) {
            .handle => |handle| handle,
            .sync_dir => db.sync_dir,
        };
        const handle = fairy.windows.createDir(parent, create_result.name) catch |err| switch (err) {
            error.ParentDirNotFound => {
                // TODO: The directory we just created was deleted.
                //       Either try to re-create it, or obtain exclusive delete access to it.
                return error.CreateParentDirFail;
            },
            error.Unexpected => |e| return e,
        };
        db.closeHandle(handle);

        // TODO file_info.status = .synced;
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
        // TODO delete folders
        if (file_info.value_ptr.directory) std.debug.panic("TODO", .{});
        const regular_info = db.regular_file_info.getEntry(file_id).?;
        const path_info_entry = db.path_map.getEntry(file_info.value_ptr.path).?;
        assert(path_info_entry.value_ptr.* == file_id);
        switch (regular_info.value_ptr.status) {
            .synced, .unsynced => {},
        }

        // TODO maybe don't perform the delete right away, but just queue it
        if (fairy.windows.deleteFile(db.sync_dir, file_info.value_ptr.path)) |_| {
            db.files.removeByPtr(file_info.key_ptr);
            db.regular_file_info.removeByPtr(regular_info.key_ptr);
            db.path_map.removeByPtr(path_info_entry.key_ptr);
            return .success;
        } else |_| {
            // TODO: set the file entry to some errored state
            // TODO: retry the deletion
            return .delete_file_err;
        }
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
    tx: Transaction,
    // TODO: Don't store this here, instead make it an argument to `run`
    db: *Database,
    debug: Debug,

    pub const Debug = struct {
        name: ?[]const u8 = null,
    };

    pub const Transaction = struct {
        data: TxData,
        peer_tx_id: network.TransactionId,
    };

    pub const State = packed struct(u32) {
        tx: TxStatus = .init,
        padding: u30 = 0,

        pub const TxStatus = enum(u2) {
            /// The TX is free to use.
            init,
            /// The TX is locked and being initialized.
            acquired,
            /// The TX is locked and owned by the outgoing task.
            outgoing,
            /// The TX is locked and owned by the incoming task.
            incoming,
        };
    };

    pub fn init(db: *Database, debug: Debug) Host {
        return .{
            .tx = .{
                .data = undefined,
                .peer_tx_id = undefined,
            },
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

        try select.concurrent(.send_error, sendOutgoingTxs, .{ host, .init(writer), io });
        try select.concurrent(.recv_error, receiveIncomingTxs, .{ host, .init(reader), io });

        host.debugLog("started", .{});
        ns.addToDiagnostics(diag, try select.await());
    }

    pub const SendError = Io.Writer.Error || Io.Cancelable || fairy.windows.SendFileError;

    fn sendOutgoingTxs(host: *Host, writer: network.Writer, io: Io) SendError!void {
        while (true) {
            while (true) {
                const state = host.db.host_state.load(.monotonic);
                if (state.tx == .outgoing) break;
                try io.futexWait(State, &host.db.host_state.raw, state);
            }

            const tx_id: network.TransactionId = @enumFromInt(0); // TODO hardcoded value
            switch (host.tx.data) {
                .in_new_file => |*in_new_file| {
                    try in_new_file.sendDecision(host, tx_id, host.tx.peer_tx_id, io, writer);
                },
                .in_file_contents => |*in_file_contents| switch (in_file_contents.state) {
                    .send_decision => try in_file_contents.sendDecision(host, tx_id, host.tx.peer_tx_id, io, writer),
                    .send_result => try in_file_contents.sendResult(host, tx_id, host.tx.peer_tx_id, io, writer),
                    .receive_file_contents => unreachable,
                },
                .in_create_dir => |*in_create_dir| {
                    try in_create_dir.sendResponse(host, tx_id, host.tx.peer_tx_id, io, writer);
                },
                .in_delete_file => |*in_delete_file| {
                    try in_delete_file.sendConfirmation(host, tx_id, host.tx.peer_tx_id, io, writer);
                },
            }
        }
    }

    pub const RecvError = error{
        InvalidTxId,
        InvalidPeerTxId,
        WrongTxId,
        WrongPeerTxId,
        InvalidAction,
        InvalidHeader,
    } ||
        network.Reader.ReceiveActionError ||
        network.Reader.ReceivePathEncodingError ||
        network.Reader.ReceiveWindowsPathByteCountError ||
        network.Reader.ReceiveWindowsPathError ||
        network.Reader.ReceiveFileKindError ||
        Io.Cancelable ||
        Allocator.Error ||
        AddOutgoingTxError ||
        fairy.windows.ReceiveFileError ||
        Database.CreateParentDirectoriesError;

    fn receiveIncomingTxs(host: *Host, reader: network.Reader, io: Io) RecvError!void {
        while (true) {
            const header = try reader.receiveMessageHeader();
            if (header.tag == .disconnect) break;
            const action = try reader.receiveAction();
            host.logMessage(.incoming, header.tx_id, action, header.peer_tx_id);

            switch (header.tag) {
                .disconnect => unreachable,
                .new_tx => {
                    if (header.tx_id != .invalid) return error.InvalidTxId;
                    if (header.peer_tx_id == .invalid) return error.InvalidPeerTxId;
                    switch (action) {
                        .resolve_path => {
                            try TxData.InNewFile.newTx(host, header.peer_tx_id, io, reader);
                        },
                        .transfer_file_id => {
                            try TxData.InFileContents.newTx(host, header.peer_tx_id, io, reader);
                        },
                        .create_dir => {
                            try TxData.InCreateDir.newTx(host, header.peer_tx_id, io, reader);
                        },
                        .delete_file => {
                            try TxData.InDeleteFile.newTx(host, header.peer_tx_id, io, reader);
                        },
                        else => return error.InvalidAction,
                    }
                },
                .new_tx_reply => {
                    if (@intFromEnum(header.tx_id) != 0) return error.WrongTxId; // TODO: hardcoded value
                    if (host.db.host_state.load(.monotonic).tx != .incoming) return error.InvalidTxId;
                    if (host.tx.peer_tx_id != .invalid) return error.WrongPeerTxId;

                    switch (host.tx.data) {
                        .in_new_file => unreachable,
                        .in_file_contents => |*in_file_contents| switch (in_file_contents.state) {
                            .receive_file_contents => return error.InvalidHeader,
                            .send_decision, .send_result => unreachable,
                        },
                        .in_create_dir => unreachable,
                        .in_delete_file => unreachable,
                    }
                },
                .existing_tx => {
                    if (@intFromEnum(header.tx_id) != 0) return error.WrongTxId; // TODO: hardcoded value
                    if (host.db.host_state.load(.monotonic).tx != .incoming) return error.InvalidTxId;
                    if (header.peer_tx_id != .invalid) return error.WrongPeerTxId;

                    switch (host.tx.data) {
                        .in_new_file => unreachable,
                        .in_file_contents => |*in_file_contents| switch (in_file_contents.state) {
                            .receive_file_contents => {
                                try in_file_contents.receiveFileContents(host, reader, io, header.tx_id, action);
                            },
                            .send_decision, .send_result => unreachable,
                        },
                        .in_create_dir => unreachable,
                        .in_delete_file => unreachable,
                    }
                },
            }
        }
    }

    const AddOutgoingTxError = error{NoTxSlotsAvailable};

    fn addOutgoingTx(
        host: *Host,
        io: Io,
        data: TxData,
        // TODO Make non-nullable
        peer_tx_id: ?network.TransactionId,
    ) AddOutgoingTxError!void {
        _ = try host.acquireUnusedTx();

        host.tx.data = data;
        host.tx.peer_tx_id = peer_tx_id orelse .invalid;

        host.releaseNewTxStatus(.acquired, .outgoing);
        io.futexWake(State, &host.db.host_state.raw, 1);
    }

    fn flipTransaction(
        host: *Host,
        comptime to: State.TxStatus,
        tx_id: network.TransactionId,
        io: Io,
    ) void {
        assert(@intFromEnum(tx_id) == 0); // TODO: hardcoded value
        switch (to) {
            .init, .acquired => unreachable,
            .outgoing => {
                host.releaseNewTxStatus(.incoming, to);
                io.futexWake(State, &host.db.host_state.raw, 1);
            },
            .incoming => {
                host.releaseNewTxStatus(.outgoing, to);
            },
        }
    }

    fn deleteTransaction(host: *Host, tx_id: network.TransactionId, expected_status: State.TxStatus, io: Io) void {
        assert(@intFromEnum(tx_id) == 0); // TODO hardcoded value
        host.tx.data = undefined;
        host.tx.peer_tx_id = undefined;
        host.releaseNewTxStatus(expected_status, .init);

        switch (expected_status) {
            .init, .acquired => unreachable,
            .outgoing => {},
            .incoming => io.futexWake(State, &host.db.host_state.raw, 1),
        }
    }

    fn acquireUnusedTx(host: *Host) !network.TransactionId {
        // TODO switch to using simple atomic stores/loads
        var old_state = host.db.host_state.load(.monotonic);
        while (old_state.tx == .init) {
            var new_state = old_state;
            new_state.tx = .acquired;
            old_state = host.db.host_state.cmpxchgWeak(old_state, new_state, .acquire, .monotonic) orelse break;
        } else return error.NoTxSlotsAvailable;
        return @enumFromInt(0); // TODO hardcoded value
    }

    fn releaseNewTxStatus(host: *Host, expected: State.TxStatus, new: State.TxStatus) void {
        // TODO switch to using simple atomic stores/loads
        var old_state = host.db.host_state.load(.monotonic);
        while (true) {
            assert(old_state.tx == expected);
            var new_state = old_state;
            new_state.tx = new;
            old_state = host.db.host_state.cmpxchgWeak(old_state, new_state, .release, .monotonic) orelse break;
        }
    }

    fn debugLog(host: *const Host, comptime fmt: []const u8, args: anytype) void {
        if (host.debug.name) |name| {
            fairy.log.debug("(host:{s}) " ++ fmt, .{name} ++ args);
        } else {
            fairy.log.debug(fmt, args);
        }
    }

    fn logMessage(
        host: *const Host,
        tx_status: Host.State.TxStatus,
        tx_id: network.TransactionId,
        action: network.Action,
        peer_tx_id: network.TransactionId,
    ) void {
        switch (tx_status) {
            .init, .acquired => unreachable,
            .outgoing => host.debugLog(
                "{s} tx#{f} {s} -> peer tx#{f}",
                .{ @tagName(tx_status), tx_id, @tagName(action), peer_tx_id },
            ),
            .incoming => host.debugLog(
                "{s} tx#{f} <- peer tx#{f} {s}",
                .{ @tagName(tx_status), tx_id, peer_tx_id, @tagName(action) },
            ),
        }
    }
};

pub const TxData = union(enum) {
    in_new_file: InNewFile,
    in_file_contents: InFileContents,
    in_create_dir: InCreateDir,
    in_delete_file: InDeleteFile,

    pub const InNewFile = struct {
        data: NewFileResult,

        pub const NewFileResult = union(network.ResolvePathResponse) {
            success: network.FileId,
            invalid_path,
            exhausted_file_ids,
            invalid_folder,
            wrong_file_kind,
        };

        fn newTx(
            host: *Host,
            peer_tx_id: network.TransactionId,
            io: Io,
            reader: network.Reader,
        ) !void {
            const kind = try reader.receiveFileKind();
            const encoding = try reader.receivePathEncoding();
            const path_byte_count = try reader.receiveWindowsPathByteCount();

            var file_path_buffer: network.FilePathBuffer align(@alignOf(w.WCHAR)) = undefined;
            const path = reader.receiveWindowsPath(path_byte_count, encoding, &file_path_buffer) catch |err| switch (err) {
                error.InvalidPath => {
                    const data: TxData = .{
                        .in_new_file = .{
                            .data = .invalid_path,
                        },
                    };
                    return try host.addOutgoingTx(io, data, peer_tx_id);
                },
                error.ReadFailed, error.EndOfStream => |e| return e,
            };

            const data: TxData = .{
                .in_new_file = .{
                    .data = if (host.db.newFile(path, kind, io)) |file_id|
                        .{ .success = file_id }
                    else |err| switch (err) {
                        error.ExhaustedFileIds => .exhausted_file_ids,
                        error.InvalidFolder => .invalid_folder,
                        error.WrongFileKind => .wrong_file_kind,
                        error.Canceled, error.OutOfMemory => |e| return e,
                    },
                },
            };
            try host.addOutgoingTx(io, data, peer_tx_id);
        }

        fn sendDecision(
            in_new_file: *const InNewFile,
            host: *Host,
            tx_id: network.TransactionId,
            peer_tx_id: network.TransactionId,
            io: Io,
            writer: network.Writer,
        ) !void {
            assert(peer_tx_id != .invalid);

            const outgoing_tx_id: network.TransactionId = .invalid;

            const action: network.Action = .resolve_path_response;
            host.logMessage(.outgoing, outgoing_tx_id, action, peer_tx_id);

            switch (in_new_file.data) {
                .success => |file_id| {
                    var reverse_file_ids_buffer: [fairy.max_path_components]network.FileId = undefined;
                    const reversed_file_id_path = try host.db.getReverseFileIdPath(file_id, &reverse_file_ids_buffer, io);

                    host.deleteTransaction(tx_id, .outgoing, io);

                    try writer.sendMessageHeaderNewTxReply(outgoing_tx_id, peer_tx_id);
                    try writer.sendAction(action);
                    try writer.sendResolvePathResponse(.success);
                    for (reversed_file_id_path) |sub_file_id| {
                        try writer.sendFileId(sub_file_id);
                    }
                },
                .invalid_path,
                .exhausted_file_ids,
                .invalid_folder,
                .wrong_file_kind,
                => {
                    host.deleteTransaction(tx_id, .outgoing, io);

                    try writer.sendMessageHeaderNewTxReply(outgoing_tx_id, peer_tx_id);
                    try writer.sendAction(action);
                    try writer.sendResolvePathResponse(in_new_file.data);
                },
            }
            try writer.flush();
        }
    };

    pub const InFileContents = struct {
        state: State,
        file_id: network.FileId,
        path: Path,

        pub const State = union(enum) {
            send_decision: SendDecision,
            receive_file_contents,
            send_result: SendResult,

            pub const SendDecision = enum { accept, decline };
            pub const SendResult = enum { success, failure };
        };

        fn newTx(
            host: *Host,
            peer_tx_id: network.TransactionId,
            io: Io,
            reader: network.Reader,
        ) !void {
            const file_id = try reader.receiveFileId();
            const path: Path, const decision: State.SendDecision = switch (try host.db.canTransferData(file_id, io)) {
                .file_exists => |res| .{
                    res.path,
                    .accept,
                },
                .file_doesnt_exist, .is_a_directory => std.debug.panic("TODO", .{}),
            };
            const data: TxData = .{
                .in_file_contents = .{
                    .state = .{ .send_decision = decision },
                    .file_id = file_id,
                    .path = path,
                },
            };
            try host.addOutgoingTx(io, data, peer_tx_id);
        }

        fn sendDecision(
            in_file_contents: *InFileContents,
            host: *Host,
            tx_id: network.TransactionId,
            peer_tx_id: network.TransactionId,
            io: Io,
            writer: network.Writer,
        ) !void {
            assert(in_file_contents.state == .send_decision);
            assert(peer_tx_id != .invalid);

            const actual_tx_id: network.TransactionId, const action: network.Action =
                switch (in_file_contents.state.send_decision) {
                    .accept => .{ tx_id, .transfer_file_accept },
                    .decline => .{ .invalid, .transfer_file_decline },
                };
            host.logMessage(.outgoing, tx_id, action, peer_tx_id);

            switch (in_file_contents.state.send_decision) {
                .accept => {
                    in_file_contents.state = .receive_file_contents;
                    host.flipTransaction(.incoming, tx_id, io);
                },
                .decline => host.deleteTransaction(tx_id, .outgoing, io),
            }

            try writer.sendMessageHeaderNewTxReply(actual_tx_id, peer_tx_id);
            try writer.sendAction(action);
            try writer.flush();
        }

        fn receiveFileContents(
            in_file_contents: *InFileContents,
            host: *Host,
            reader: network.Reader,
            io: Io,
            tx_id: network.TransactionId,
            action: network.Action,
        ) !void {
            assert(in_file_contents.state == .receive_file_contents);
            switch (action) {
                .transfer_file_contents => {
                    const file_size = blk: {
                        const network_size = try reader.receiveFileSize();
                        const windows_size = std.math.cast(w.LARGE_INTEGER, network_size) orelse
                            std.debug.panic(
                                "TODO: File too large to transfer: '{f}' with size {}",
                                .{ in_file_contents.path.formatUtf8(), network_size },
                            );
                        break :blk windows_size;
                    };

                    const create_result = try host.db.createParentDirectories(in_file_contents.path);
                    defer switch (create_result.parent) {
                        .handle => |handle| host.db.closeHandle(handle),
                        .sync_dir => {},
                    };

                    const handle = host.db.createFile(switch (create_result.parent) {
                        .handle => |handle| handle,
                        .sync_dir => host.db.sync_dir,
                    }, create_result.name, file_size) catch |err| switch (err) {
                        error.ParentDirNotFound => {
                            // TODO: The directory we just created was deleted.
                            //       Either try to re-create it, or obtain exclusive delete access to it.
                            // TODO: report failure to the client
                            return error.CreateParentDirFail;
                        },
                        // TODO: report failure to the client
                        error.Unexpected => |e| return e,
                    };
                    defer host.db.closeHandle(handle);

                    try fairy.windows.receiveFile(reader.io, handle, file_size);
                    const file_hash = try reader.receiveFileHash();
                    try host.db.finishReceiveFileContents(
                        io,
                        handle,
                        in_file_contents.file_id,
                        &file_hash, // TODO: verify the hash
                        file_size,
                    );

                    in_file_contents.state = .{ .send_result = .success };
                    host.flipTransaction(.outgoing, tx_id, io);
                },
                else => return error.InvalidAction,
            }
        }

        fn sendResult(
            in_file_contents: *const InFileContents,
            host: *Host,
            tx_id: network.TransactionId,
            peer_tx_id: network.TransactionId,
            io: Io,
            writer: network.Writer,
        ) !void {
            assert(in_file_contents.state == .send_result);
            assert(peer_tx_id != .invalid);

            const action: network.Action = switch (in_file_contents.state.send_result) {
                .success => .transfer_file_success,
                .failure => .transfer_file_failure,
            };
            host.logMessage(.outgoing, tx_id, action, peer_tx_id);
            host.deleteTransaction(tx_id, .outgoing, io);

            try writer.sendMessageHeaderExistingTx(peer_tx_id);
            try writer.sendAction(action);
            try writer.flush();
        }
    };

    pub const InCreateDir = struct {
        response: network.CreateDirResponse,

        fn newTx(
            host: *Host,
            peer_tx_id: network.TransactionId,
            io: Io,
            reader: network.Reader,
        ) !void {
            const file_id = try reader.receiveFileId();
            const data: TxData = .{
                .in_create_dir = .{
                    .response = if (host.db.createDir(file_id, io)) .success else |err| switch (err) {
                        error.NotADirectory => .not_a_directory,
                        error.UnknownFile => .unknown_file,
                        error.Unexpected, error.CreateParentDirFail => .unexpected,
                        error.Canceled => |e| return e,
                    },
                },
            };
            try host.addOutgoingTx(io, data, peer_tx_id);
        }

        fn sendResponse(
            in_create_dir: *const InCreateDir,
            host: *Host,
            tx_id: network.TransactionId,
            peer_tx_id: network.TransactionId,
            io: Io,
            writer: network.Writer,
        ) !void {
            assert(peer_tx_id != .invalid);

            const outgoing_tx_id: network.TransactionId = .invalid;

            const action: network.Action = .create_dir_response;
            host.logMessage(.outgoing, outgoing_tx_id, action, peer_tx_id);

            const response = in_create_dir.response;
            host.deleteTransaction(tx_id, .outgoing, io);

            try writer.sendMessageHeaderNewTxReply(outgoing_tx_id, peer_tx_id);
            try writer.sendAction(action);
            try writer.sendCreateDirResponse(response);
            try writer.flush();
        }
    };

    pub const InDeleteFile = struct {
        fn newTx(
            host: *Host,
            peer_tx_id: network.TransactionId,
            io: Io,
            reader: network.Reader,
        ) !void {
            const file_id = try reader.receiveFileId();
            switch (try host.db.deleteGlobalFile(file_id, io)) {
                .success => {},
                .unknown_file, .delete_file_err => std.debug.panic("TODO", .{}),
            }

            const data: TxData = .{
                .in_delete_file = .{},
            };
            try host.addOutgoingTx(io, data, peer_tx_id);
        }

        fn sendConfirmation(
            _: *InDeleteFile,
            host: *Host,
            tx_id: network.TransactionId,
            peer_tx_id: network.TransactionId,
            io: Io,
            writer: network.Writer,
        ) !void {
            const action: network.Action = .delete_file_confirm;
            host.logMessage(.outgoing, tx_id, action, peer_tx_id);
            host.deleteTransaction(tx_id, .outgoing, io);

            try writer.sendMessageHeaderNewTxReply(.invalid, peer_tx_id);
            try writer.sendAction(action);
            try writer.flush();
        }
    };
};
