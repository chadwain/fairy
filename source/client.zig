const std = @import("std");
const assert = std.debug.assert;
const w = std.os.windows;
const wtf16 = std.unicode.wtf8ToWtf16LeStringLiteral;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fairy = @import("fairy.zig");
const network = fairy.network;
const print = fairy.print;
const printf = fairy.printf;
const Path = fairy.windows.Path;
const PathHashMap = fairy.windows.PathHashMap;
const PathArrayHashMap = fairy.windows.PathArrayHashMap;

const cpu_endian = @import("builtin").cpu.arch.endian();

// TODO: Stop using std.fs.path.ComponentIterator, because it assumes Win32 paths, but fairy.windows.Path is not necessarily so.

pub const Database = struct {
    sync_dir: w.HANDLE,
    alert: std.atomic.Value(Alert),
    mutex: Io.Mutex, // TODO: Compare with RwLock

    // Begin fields protected by mutex

    allocator: Allocator,
    path_arena: std.heap.ArenaAllocator.State,
    scan_arena: std.heap.ArenaAllocator.State,
    local_fs: LocalFilesystem,
    global_fs: GlobalFilesystem,
    events: Events,

    // End fields protected by mutex

    // Database-Host synchronization fields
    host_state: std.atomic.Value(Host.State),
    out_path: Path,
    out_file_id: network.FileId,
    out_directory: bool,

    debug: Debug,

    pub const Alert = enum(u32) { off, on };

    pub fn init(sync_dir_path: [:0]const u16, allocator: Allocator, debug: Debug) !Database {
        // TODO: The length of this path must also be factored into path length calculations.
        const sync_dir_path_nt = try Io.Threaded.wToPrefixedFileW(null, sync_dir_path, .{ .allow_relative = false });
        const sync_dir = try fairy.windows.openSyncDir(sync_dir_path_nt.span());
        errdefer comptime unreachable;

        return .{
            .sync_dir = sync_dir,
            .alert = .init(.off),
            .mutex = .init,

            .allocator = allocator,
            .path_arena = .{},
            .scan_arena = .{},
            .local_fs = .{},
            .global_fs = .{},
            .events = .{},

            .host_state = .init(.{}),
            .out_path = undefined,
            .out_file_id = undefined,
            .out_directory = undefined,

            .debug = debug,
        };
    }

    pub fn deinit(db: *Database) void {
        fairy.windows.closeHandle(db.sync_dir);

        var path_arena = db.path_arena.promote(db.allocator);
        path_arena.deinit();
        var scan_arena = db.scan_arena.promote(db.allocator);
        scan_arena.deinit();

        db.local_fs.deinit(db.allocator);
        db.global_fs.deinit(db.allocator);
        db.events.deinit(db.allocator);

        db.* = undefined;
    }

    pub fn run(db: *Database, io: Io) !void {
        db.debug.log("running on thread {}", .{std.os.windows.GetCurrentThreadId()});
        var stderr = Io.File.stderr().writer(io, &.{});

        const clock: Io.Clock = .boot;
        const max_wait_time = Io.Clock.Duration{ .raw = .fromSeconds(15), .clock = clock };
        var next_scan_time = Io.Clock.Timestamp.now(io, clock); // First scan happens immediately

        while (true) {
            // If enough time has passed, do a scan
            if (Io.Clock.Timestamp.now(io, clock).compare(.gte, next_scan_time)) {
                const locked = try db.lock(io);
                defer locked.unlock(io);

                try scan.run(locked);
                try stderr.interface.writeAll("Scan complete\n");
                try locked.debug.printFileEvents(&stderr.interface);
                try stderr.interface.flush();
                next_scan_time = Io.Clock.Timestamp.now(io, clock).addDuration(max_wait_time);
                continue;
            }

            if (try db.sendHostEvents(io)) {
                continue;
            }

            db.alert.store(.off, .release);
            try io.futexWaitTimeout(Alert, &db.alert.raw, .off, .{ .deadline = next_scan_time });
        }
    }

    /// Returns true if an event was sent.
    fn sendHostEvents(db: *Database, io: Io) Io.Cancelable!bool {
        const Event = union(enum) {
            local: struct {
                event: Events.Local,
                file_id: ?network.FileId,
            },
            sync: struct {
                file_id: network.FileId,
                path: Path,
            },
        };
        const event: Event = blk: {
            try db.mutex.lock(io);
            defer db.mutex.unlock(io);

            if (db.events.in_progress) return false;

            const local_events = db.events.local.items;
            if (local_events.len > 0) {
                const event = local_events[0];
                const file_id = db.global_fs.path_to_id.get(event.path);
                break :blk .{ .local = .{ .event = event, .file_id = file_id } };
            }

            var sync_events = db.events.file_sync.keyIterator();
            if (sync_events.next()) |file_id| {
                const info = db.global_fs.files.get(file_id.*).?;
                assert(!info.directory);
                break :blk .{ .sync = .{ .file_id = file_id.*, .path = info.path } };
            }

            return false;
        };

        db.acquireHostEvent() orelse return false;
        errdefer comptime unreachable;

        const host_event: Host.State.Event = blk: switch (event) {
            .local => |local| {
                db.debug.log("(local event) action: {s}, path: {f}", .{ @tagName(local.event.action), local.event.path.formatUtf8() });
                switch (local.event.action) {
                    .new_regular => {
                        db.out_path = local.event.path;
                        db.out_directory = false;
                        break :blk .get_global_file_id;
                    },
                    .new_directory => {
                        db.out_path = local.event.path;
                        db.out_directory = true;
                        break :blk .get_global_file_id;
                    },
                    .delete_regular => {
                        db.out_file_id = local.file_id.?;
                        // TODO: It should not be necessary to set the path for this event
                        db.out_path = local.event.path;
                        break :blk .delete_file;
                    },
                    .delete_directory => {
                        std.debug.panic("TODO: Handle the '{s}' local filesystem event", .{@tagName(local.event.action)});
                    },
                }
            },
            .sync => |sync| {
                db.debug.log("(sync event) path: {f}", .{sync.path.formatUtf8()});
                db.out_file_id = sync.file_id;
                // TODO: It should not be necessary to set the path for this event
                db.out_path = sync.path;
                break :blk .sync_file;
            },
        };

        db.events.in_progress = true;
        db.releaseHostEvent(host_event);
        io.futexWake(Host.State, &db.host_state.raw, 1);
        return true;
    }

    fn sendAlert(db: *Database, io: Io) void {
        db.alert.store(.on, .release);
        io.futexWake(Alert, &db.alert.raw, 1);
    }

    fn acquireHostEvent(db: *Database) ?void {
        var host_state = db.host_state.load(.monotonic);
        while (host_state.event == .none) {
            var new_host_state = host_state;
            new_host_state.event = .acquired;
            host_state = db.host_state.cmpxchgWeak(host_state, new_host_state, .acquire, .monotonic) orelse break;
        } else return null;
    }

    fn releaseHostEvent(db: *Database, event: Host.State.Event) void {
        var host_state = db.host_state.load(.monotonic);
        while (true) {
            assert(host_state.event == .acquired);
            var new_host_state = host_state;
            new_host_state.event = event;
            host_state = db.host_state.cmpxchgWeak(host_state, new_host_state, .release, .monotonic) orelse break;
        }
    }

    pub fn lock(db: *Database, io: Io) !LockedDatabase {
        try db.mutex.lock(io);
        return .{ .db = db };
    }

    fn openFileReadOnly(db: *const Database, path: Path) !w.HANDLE {
        return fairy.windows.openFile(db.sync_dir, path, .read);
    }

    fn closeFile(_: *const Database, file: w.HANDLE) void {
        fairy.windows.closeHandle(file);
    }

    pub const Debug = struct {
        name: []const u8 = "<unnamed>",

        fn log(debug: *const Debug, comptime fmt: []const u8, args: anytype) void {
            fairy.log.debug("(db:{s}) " ++ fmt, .{debug.name} ++ args);
        }
    };
};

pub const LocalFilesystem = struct {
    repr: Repr = .{},

    /// A representation of the contents of the sync directory.
    pub const Repr = struct {
        files: PathHashMap(Info) = .empty,
        /// Applies to all files
        parent: PathHashMap(?Path) = .empty,
        /// Applies only to directories
        children: PathHashMap(PathHashMap(void)) = .empty,
        /// The direct children of the sync directory.
        top_level_children: PathHashMap(void) = .empty,
        /// Applies to all files
        meta: PathHashMap(Metadata) = .empty,

        fn deinit(repr: *Repr, allocator: Allocator) void {
            var it = repr.children.valueIterator();
            while (it.next()) |list| list.deinit(allocator);

            repr.files.deinit(allocator);
            repr.parent.deinit(allocator);
            repr.children.deinit(allocator);
            repr.top_level_children.deinit(allocator);
            repr.meta.deinit(allocator);

            repr.* = undefined;
        }

        pub const Info = struct {
            directory: bool,
            status: Status,
        };

        pub const Status = enum {
            /// A file which is being tracked.
            tracked,
            /// A file whose existence is known, but will not be synced to the server for one or more reasons.
            untracked,
        };

        pub const Metadata = struct {
            local_file_id: w.LARGE_INTEGER,
            modified_time: w.LARGE_INTEGER,
            size: w.ULARGE_INTEGER,
        };
    };

    pub fn deinit(local_fs: *LocalFilesystem, allocator: Allocator) void {
        local_fs.repr.deinit(allocator);
    }
};

pub const GlobalFilesystem = struct {
    // An entry in this map implies the existence of a corresponding entry in `path_to_id`.
    files: std.AutoHashMapUnmanaged(network.FileId, FileInfo) = .empty,
    path_to_id: PathHashMap(network.FileId) = .empty,

    pub const FileInfo = struct {
        directory: bool,
        path: Path,
    };

    fn deleteRegularFile(global_fs: *GlobalFilesystem, file_id: network.FileId) void {
        const info = global_fs.files.fetchRemove(file_id).?;
        assert(!info.value.directory);
        assert(global_fs.path_to_id.remove(info.value.path));
    }

    pub fn deinit(global_fs: *GlobalFilesystem, allocator: Allocator) void {
        global_fs.files.deinit(allocator);
        global_fs.path_to_id.deinit(allocator);
    }
};

pub const Events = struct {
    local: std.ArrayList(Local) = .empty,
    file_sync: std.AutoHashMapUnmanaged(network.FileId, void) = .empty,
    in_progress: bool = false,

    pub const Local = struct {
        action: Action,
        path: Path,

        pub const Action = enum {
            new_regular,
            new_directory,
            delete_regular,
            delete_directory,
        };
    };

    pub fn deinit(events: *Events, allocator: Allocator) void {
        events.local.deinit(allocator);
        events.file_sync.deinit(allocator);
        events.* = undefined;
    }

    fn ensureLocalEventCapacity(events: *Events, allocator: Allocator) !void {
        try events.local.ensureUnusedCapacity(allocator, 1);
    }

    fn queueLocalEventAssumeCapacity(events: *Events, action: Local.Action, path: Path) void {
        events.local.appendAssumeCapacity(.{ .action = action, .path = path });
    }

    fn finishLocalEventWithPath(events: *Events, action: Local.Action, path: Path) void {
        assert(events.in_progress);
        const event = events.local.orderedRemove(0);
        assert(event.action == action);
        assert(event.path.eql(path));
        events.in_progress = false;
    }

    // TODO: Maybe this function should not exist
    fn finishLocalEventWithFileId(events: *Events, action: Local.Action, file_id: network.FileId) void {
        const db: *const Database = @alignCast(@fieldParentPtr("events", events));
        const path = db.global_fs.files.get(file_id).?.path;
        events.finishLocalEventWithPath(action, path);
    }

    fn ensureSyncEventCapacity(events: *Events, allocator: Allocator) !void {
        try events.file_sync.ensureUnusedCapacity(allocator, 1);
    }

    fn queueSyncEventAssumeCapacity(events: *Events, file_id: network.FileId) void {
        const db: *const Database = @alignCast(@fieldParentPtr("events", events));
        assert(!db.global_fs.files.get(file_id).?.directory);
        events.file_sync.putAssumeCapacity(file_id, {});
    }

    fn finishSyncEvent(events: *Events, file_id: network.FileId) void {
        assert(events.in_progress);
        const db: *const Database = @alignCast(@fieldParentPtr("events", events));
        assert(!db.global_fs.files.get(file_id).?.directory);
        assert(events.file_sync.remove(file_id));
        events.in_progress = false;
    }
};

pub const LockedDatabase = struct {
    db: *Database,
    debug: Debug = .{},

    pub fn unlock(locked: LockedDatabase, io: Io) void {
        locked.db.mutex.unlock(io);
    }

    pub fn manualScan(locked: LockedDatabase, io: Io) !void {
        // TODO delay the next automatic scan
        try scan.run(locked);
        locked.db.sendAlert(io);
    }

    // called from Host
    fn setNewFileId(locked: LockedDatabase, path: Path, kind: network.FileKind, file_id_list: []const network.FileId) !void {
        assert(file_id_list.len > 0);
        locked.db.events.finishLocalEventWithPath(switch (kind) {
            .directory => .new_directory,
            .regular => .new_regular,
        }, path);

        const component_count: fairy.PathComponentCount = @intCast(file_id_list.len);
        try locked.db.global_fs.files.ensureUnusedCapacity(locked.db.allocator, component_count);
        try locked.db.global_fs.path_to_id.ensureUnusedCapacity(locked.db.allocator, component_count);
        switch (kind) {
            .regular => try locked.db.events.ensureSyncEventCapacity(locked.db.allocator),
            .directory => {},
        }
        errdefer comptime unreachable;

        const Iterator = std.fs.path.ComponentIterator(.windows, u16);
        var it = Iterator.init(path.slice);

        for (file_id_list, 0..) |file_id, index| {
            const component = it.next().?;
            const component_as_path = Path.assumeValidPath(component.path);
            const gop = locked.db.global_fs.files.getOrPutAssumeCapacity(file_id);
            if (gop.found_existing) {
                if (index < file_id_list.len - 1 and !gop.value_ptr.directory) std.debug.panic(
                    "TODO client/server conflict: {f}: client says regular file, server says directory",
                    .{file_id},
                );
                if (!gop.value_ptr.path.eql(component_as_path)) std.debug.panic(
                    "TODO client/server conflict: {f}: client path '{f}', server path '{f}'",
                    .{ file_id, gop.value_ptr.path.formatUtf8(), component_as_path.formatUtf8() },
                );
            } else {
                if (index != file_id_list.len - 1) {
                    // TODO This assumes that new file events are always handled in order from shallow to deep directories.
                    std.debug.panic("TODO", .{});
                }
                gop.value_ptr.* = .{
                    .directory = switch (kind) {
                        .directory => true,
                        .regular => false,
                    },
                    .path = path,
                };
                locked.db.global_fs.path_to_id.putAssumeCapacity(path, file_id);
            }
        }
        assert(it.peekNext() == null);

        switch (kind) {
            .regular => locked.db.events.queueSyncEventAssumeCapacity(file_id_list[file_id_list.len - 1]),
            .directory => {},
        }
    }

    // called from Host
    fn confirmDeleteFile(locked: LockedDatabase, file_id: network.FileId) void {
        locked.db.events.finishLocalEventWithFileId(.delete_regular, file_id);
        locked.db.global_fs.deleteRegularFile(file_id);
    }

    // called from Host
    fn markFileAsSynced(locked: LockedDatabase, file_id: network.FileId) void {
        locked.db.events.finishSyncEvent(file_id);
    }

    // called from Host
    fn acknowledgeCreateDir(locked: LockedDatabase, file_id: network.FileId) void {
        _ = locked;
        _ = file_id;
        std.debug.panic("TODO", .{});
    }

    pub const Debug = struct {
        pub fn printFileEntries(debug: *const Debug, writer: *Io.Writer) !void {
            const locked: *const LockedDatabase = @alignCast(@fieldParentPtr("debug", debug));

            try writer.writeAll("Tracked files\n");
            var it = locked.db.local_fs.repr.files.iterator();
            while (it.next()) |entry| {
                switch (entry.value_ptr.status) {
                    .tracked => {},
                    .untracked => continue,
                }
                const meta = locked.db.local_fs.repr.meta.get(entry.key_ptr.*).?;
                try writer.print(
                    "{f}: modified({}) size({})\n",
                    .{
                        entry.key_ptr.formatUtf8(),
                        meta.modified_time,
                        meta.size,
                    },
                );
            }

            try writer.writeAll("\nUntracked files\n");
            it = locked.db.local_fs.repr.files.iterator();
            while (it.next()) |entry| {
                switch (entry.value_ptr.status) {
                    .tracked => continue,
                    .untracked => {},
                }
                try writer.print("{f}\n", .{entry.key_ptr.formatUtf8()});
            }

            try writer.writeAll("\n");
        }

        pub fn printFileEvents(debug: *const Debug, writer: *Io.Writer) !void {
            const locked: *const LockedDatabase = @alignCast(@fieldParentPtr("debug", debug));

            inline for (&[_]struct { []const Events.Local.Action, []const u8 }{
                .{ &.{ .new_regular, .new_directory }, "Locally new files:\n" },
                .{ &.{ .delete_regular, .delete_directory }, "Locally deleted files:\n" },
            }) |item| {
                const actions, const text = item;
                try writer.writeAll(text);

                for (locked.db.events.local.items) |event| {
                    _ = std.mem.findScalar(Events.Local.Action, actions, event.action) orelse continue;
                    try writer.print("\t{f}\n", .{event.path.formatUtf8()});
                }
            }
        }
    };
};

const scan = struct {
    const Context = struct {
        local_fs: *LocalFilesystem,
        global_fs: *GlobalFilesystem,
        events: *Events,
        db_allocator: Allocator,
        scan_arena: *std.heap.ArenaAllocator,
        path_arena: *std.heap.ArenaAllocator,

        /// A stack of names of child directories relative to the current directory.
        /// An empty slice means to pop the current directory off the stack.
        pending_dirs: std.ArrayList([]const u16),
        /// A path to the current directory/file.
        current_path: std.ArrayList(u16),
        /// A list of the indeces of all the backslash '\' characters within `current_path`.
        component_delimeters: std.ArrayList(u16),
        /// A stack of open directory handles.
        /// The first element is always a handle to the sync directory.
        open_dir_handles: std.ArrayList(w.HANDLE),
        /// A stack of Database-owned directory paths.
        /// The first element is always `null`.
        parent_paths: std.ArrayList(?Path),
        /// Info about each file that is relevant for scanning.
        file_info: FileInfo,

        const FileInfo = PathHashMap(struct {
            /// Becomes true when the file is seen while scanning.
            already_seen: bool,
            /// Only used in the second phase of scanning, where unseen files are marked as deleted.
            already_scanned_for_deletion: bool,
        });

        fn init(
            locked: LockedDatabase,
            scan_arena: *std.heap.ArenaAllocator,
            path_arena: *std.heap.ArenaAllocator,
        ) !Context {
            var file_info: Context.FileInfo = .empty;
            try file_info.ensureTotalCapacity(scan_arena.allocator(), locked.db.local_fs.repr.files.count());
            var it = locked.db.local_fs.repr.files.iterator();
            while (it.next()) |entry| {
                file_info.putAssumeCapacityNoClobber(entry.key_ptr.*, .{
                    .already_seen = false,
                    .already_scanned_for_deletion = false,
                });
            }

            var parent_paths: std.ArrayList(?Path) = .empty;
            try parent_paths.append(scan_arena.allocator(), null);

            var open_dir_handles: std.ArrayList(w.HANDLE) = .empty;
            try open_dir_handles.append(scan_arena.allocator(), locked.db.sync_dir);

            return .{
                .local_fs = &locked.db.local_fs,
                .global_fs = &locked.db.global_fs,
                .events = &locked.db.events,
                .db_allocator = locked.db.allocator,
                .path_arena = path_arena,
                .scan_arena = scan_arena,

                .pending_dirs = .empty,
                .current_path = .empty,
                .component_delimeters = .empty,
                .open_dir_handles = open_dir_handles,
                .parent_paths = parent_paths,
                .file_info = file_info,
            };
        }

        fn deinit(ctx: *Context) void {
            for (ctx.open_dir_handles.items[1..]) |handle| {
                w.CloseHandle(handle);
            }
            ctx.* = undefined;
        }
    };

    // TODO: 128-bit file IDs also exist
    // https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_id_extd_both_dir_information
    const nt_query_information_class: w.FILE.INFORMATION_CLASS = .IdBothDirectory;

    // Corresponds to FILE_ID_BOTH_DIR_INFORMATION.
    // https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_id_both_dir_information
    const NtQueryInformation = extern struct {
        NextEntryOffset: w.ULONG,
        FileIndex: w.ULONG,
        CreationTime: w.LARGE_INTEGER,
        LastAccessTime: w.LARGE_INTEGER,
        LastWriteTime: w.LARGE_INTEGER,
        ChangeTime: w.LARGE_INTEGER,
        EndOfFile: w.LARGE_INTEGER,
        AllocationSize: w.LARGE_INTEGER,
        FileAttributes: w.FILE.ATTRIBUTE,
        FileNameLength: w.ULONG,
        EaSize: w.ULONG,
        ShortNameLength: CCHAR,
        ShortName: [12]w.WCHAR,
        FileId: w.LARGE_INTEGER,
        FileName: [1]w.WCHAR,

        // https://learn.microsoft.com/en-us/windows/win32/winprog/windows-data-types
        const CCHAR = w.CHAR;
    };

    fn run(locked: LockedDatabase) !void {
        var scan_arena = locked.db.scan_arena.promote(locked.db.allocator);
        defer {
            _ = scan_arena.reset(.retain_capacity);
            locked.db.scan_arena = scan_arena.state;
        }

        var path_arena = locked.db.path_arena.promote(locked.db.allocator);
        defer locked.db.path_arena = path_arena.state;

        var ctx = try Context.init(locked, &scan_arena, &path_arena);
        defer ctx.deinit();

        try scanOneDirectory(&ctx);
        while (ctx.pending_dirs.items.len > 0) {
            const dir_path_ptr = &ctx.pending_dirs.items[ctx.pending_dirs.items.len - 1];
            if (dir_path_ptr.len == 0) {
                _ = ctx.pending_dirs.pop();
                exitDir(&ctx);
                continue;
            }

            const dir_path = dir_path_ptr.*;
            dir_path_ptr.* = &.{};
            try enterDir(&ctx, dir_path);
            try scanOneDirectory(&ctx);
        }

        try deleteUnseenFiles(&ctx);
    }

    fn scanOneDirectory(ctx: *Context) !void {
        const dir = ctx.open_dir_handles.items[ctx.open_dir_handles.items.len - 1];
        var buffer: [64 * 1024]u8 align(@alignOf(NtQueryInformation)) = undefined;
        var io_status_block: w.IO_STATUS_BLOCK = undefined;
        var restart_scan: w.BOOLEAN = .TRUE;

        while (true) {
            const status = w.ntdll.NtQueryDirectoryFile(
                dir,
                null,
                null,
                null,
                &io_status_block,
                &buffer,
                buffer.len,
                nt_query_information_class,
                .FALSE,
                null,
                restart_scan,
            );
            switch (status) {
                .NO_MORE_FILES => break,
                .BUFFER_OVERFLOW => return error.NtBufferOverflow,
                .SUCCESS => if (io_status_block.Information == 0) return error.NtBufferOverflow,
                else => return w.unexpectedStatus(status),
            }
            restart_scan = .FALSE;

            var offset: usize = 0;
            var next_entry_offset: usize = 1; // Any non-zero value
            while (next_entry_offset != 0) : (offset += next_entry_offset) {
                const info: *const NtQueryInformation = @ptrCast(@alignCast(&buffer[offset]));
                next_entry_offset = info.NextEntryOffset;

                const offset_of_file_name = @offsetOf(NtQueryInformation, "FileName");
                const file_name_bytes = buffer[offset + offset_of_file_name ..][0..info.FileNameLength];
                const file_name: []const u16 = @ptrCast(@alignCast(file_name_bytes));

                if (std.mem.eql(u16, file_name, comptime wtf16(".")) or
                    std.mem.eql(u16, file_name, comptime wtf16(".."))) continue;
                // TODO: file_name needs to be normalized

                try processFile(ctx, file_name, info);
            }
        }
    }

    fn processFile(ctx: *Context, name: []const u16, information: *const NtQueryInformation) !void {
        const rejected: w.FILE.ATTRIBUTE = .{
            .HIDDEN = true,
            .SYSTEM = true,
            .TEMPORARY = true,
            .REPARSE_POINT = true,
            .ENCRYPTED = true,
        };
        // TODO: Use @backingInt https://codeberg.org/ziglang/zig/issues/35602
        const set_to_untracked = @as(w.ULONG, @bitCast(rejected)) & @as(w.ULONG, @bitCast(information.FileAttributes)) != 0;

        const allocator = ctx.scan_arena.allocator();
        const component_delimeter_index = ctx.current_path.items.len;
        defer ctx.current_path.shrinkRetainingCapacity(component_delimeter_index);
        try ctx.current_path.appendSlice(allocator, name); // TODO: check that it fits within the file path length limit
        const path: Path = .assumeValidPath(ctx.current_path.items);

        if (information.FileAttributes.DIRECTORY) {
            try processDirectoryFile(ctx, path, information, set_to_untracked);

            const component_count: fairy.PathComponentCount = @intCast(ctx.open_dir_handles.items.len - 1); // Don't count the sync dir itself as a component.
            if (component_count == fairy.max_path_components) return; // TODO: track the folder, but don't track its contents.

            const copied_name = try allocator.dupe(u16, name);
            try ctx.pending_dirs.append(allocator, copied_name);
        } else {
            try processRegularFile(ctx, path, information, set_to_untracked);
        }
    }

    fn enterDir(ctx: *Context, dir_name: []const u16) !void {
        const delimeter = comptime wtf16("\\");
        const allocator = ctx.scan_arena.allocator();
        try ctx.component_delimeters.ensureTotalCapacity(allocator, 1);
        try ctx.current_path.ensureUnusedCapacity(allocator, dir_name.len + delimeter.len);
        try ctx.parent_paths.ensureUnusedCapacity(allocator, 1);
        try ctx.open_dir_handles.ensureUnusedCapacity(allocator, 1);

        ctx.component_delimeters.appendAssumeCapacity(@intCast(ctx.current_path.items.len));
        ctx.current_path.appendSliceAssumeCapacity(dir_name);
        const parent_path_temp = ctx.current_path.items;
        ctx.current_path.appendSliceAssumeCapacity(delimeter);

        const path_allocator = ctx.path_arena.allocator();
        const key = ctx.local_fs.repr.files.getKey(.assumeValidPath(parent_path_temp));
        const parent_path = key orelse Path.assumeValidPath(try path_allocator.dupe(u16, parent_path_temp));
        errdefer if (key == null) path_allocator.free(parent_path.slice);
        ctx.parent_paths.appendAssumeCapacity(parent_path);

        const parent_dir = ctx.open_dir_handles.items[ctx.open_dir_handles.items.len - 1];
        const dir = try fairy.windows.openDir(parent_dir, .assumeValidPath(dir_name));
        errdefer comptime unreachable;
        ctx.open_dir_handles.appendAssumeCapacity(dir);
    }

    fn exitDir(ctx: *Context) void {
        const component_delimeter_index = ctx.component_delimeters.pop().?;
        ctx.current_path.shrinkRetainingCapacity(component_delimeter_index);
        _ = ctx.parent_paths.pop();
        const dir = ctx.open_dir_handles.pop().?;
        w.CloseHandle(dir);
    }

    fn processRegularFile(
        ctx: *Context,
        path: Path,
        information: *const NtQueryInformation,
        set_to_untracked: bool,
    ) !void {
        const size = std.math.cast(w.ULARGE_INTEGER, information.EndOfFile) orelse return error.Unexpected;
        const meta = LocalFilesystem.Repr.Metadata{
            .local_file_id = information.FileId,
            .modified_time = information.ChangeTime,
            .size = size,
        };

        const gop = try ctx.file_info.getOrPut(ctx.scan_arena.allocator(), path);
        if (gop.found_existing) {
            if (gop.value_ptr.already_seen) std.debug.panic("TODO saw file more than once while scanning: {f}", .{path.formatUtf8()});
            gop.value_ptr.already_seen = true;

            // TODO Reuse the result of this lookup
            const info = ctx.local_fs.repr.files.get(path).?;
            if (info.directory) std.debug.panic("TODO a directory was changed to a regular file: {f}", .{path.formatUtf8()});

            switch (info.status) {
                .tracked => {
                    if (set_to_untracked) {
                        try changeTrackedRegularFileToUntracked(ctx.local_fs, ctx.events, ctx.db_allocator, path);
                    } else {
                        try updateTrackedRegularFile(ctx.local_fs, ctx.global_fs, ctx.events, ctx.db_allocator, path, meta);
                    }
                },
                .untracked => {
                    if (set_to_untracked) return;
                    try changeUntrackedRegularFileToNew(ctx.local_fs, ctx.events, ctx.db_allocator, path, meta);
                },
            }
        } else {
            errdefer ctx.file_info.removeByPtr(gop.key_ptr);

            const path_allocator = ctx.path_arena.allocator();
            const path_copy = try path.dupe(path_allocator);
            errdefer path_allocator.free(path_copy.slice);

            gop.key_ptr.* = path_copy;
            gop.value_ptr.* = .{ .already_seen = true, .already_scanned_for_deletion = false };

            const parent = ctx.parent_paths.getLast();
            const status: LocalFilesystem.Repr.Status = if (set_to_untracked) .untracked else .tracked;
            try addFile(ctx.local_fs, ctx.events, ctx.db_allocator, .regular, status, path_copy, parent, meta);
        }
    }

    fn processDirectoryFile(
        ctx: *Context,
        path: Path,
        information: *const NtQueryInformation,
        set_to_untracked: bool,
    ) !void {
        const meta = LocalFilesystem.Repr.Metadata{
            .local_file_id = information.FileId,
            .modified_time = information.ChangeTime,
            .size = 0,
        };

        const gop = try ctx.file_info.getOrPut(ctx.scan_arena.allocator(), path);
        if (gop.found_existing) {
            if (gop.value_ptr.already_seen) std.debug.panic("TODO saw directory more than once while scanning: {f}", .{path.formatUtf8()});
            gop.value_ptr.already_seen = true;

            // TODO Reuse the result of this lookup
            const info = ctx.local_fs.repr.files.get(path).?;
            if (!info.directory) std.debug.panic("TODO a regular file was changed into a directory: {f}", .{path.formatUtf8()});

            switch (info.status) {
                .tracked => {
                    if (set_to_untracked) std.debug.panic("TODO set a tracked directory to untracked: {f}", .{path.formatUtf8()});
                    updateTrackedDirectoryFile(ctx.local_fs, path, meta);
                },
                .untracked => std.debug.panic("TODO handle untracked directory: {f}", .{path.formatUtf8()}),
            }
        } else {
            errdefer ctx.file_info.removeByPtr(gop.key_ptr);

            const path_allocator = ctx.path_arena.allocator();
            const path_copy = try path.dupe(path_allocator);
            errdefer path_allocator.free(path_copy.slice);

            gop.key_ptr.* = path_copy;
            gop.value_ptr.* = .{ .already_seen = true, .already_scanned_for_deletion = false };

            const parent = ctx.parent_paths.getLast();
            if (set_to_untracked) {
                std.debug.panic("TODO handle untracked directory: {f}", .{path.formatUtf8()});
            } else {
                try addFile(ctx.local_fs, ctx.events, ctx.db_allocator, .directory, .tracked, path_copy, parent, meta);
            }
        }
    }

    fn deleteUnseenFiles(ctx: *Context) !void {
        var stack: [fairy.max_path_components]Path = undefined;
        var stack_len: fairy.PathComponentCount = 0;
        while (true) {
            const children = if (stack_len == 0) ctx.local_fs.repr.top_level_children else ctx.local_fs.repr.children.get(stack[stack_len - 1]).?;
            var it = children.keyIterator();
            // TODO: O(N^2) loop
            while (it.next()) |child| {
                const file_info = ctx.file_info.getPtr(child.*).?;
                if (file_info.already_scanned_for_deletion) continue;
                file_info.already_scanned_for_deletion = true;
                const info = ctx.local_fs.repr.files.get(child.*).?;

                if (file_info.already_seen) {
                    if (info.directory and stack_len < fairy.max_path_components) {
                        stack[stack_len] = child.*;
                        stack_len += 1;
                    }
                } else {
                    switch (info.status) {
                        .tracked => switch (info.directory) {
                            false => try deleteTrackedRegularFile(ctx.local_fs, ctx.events, ctx.db_allocator, child.*),
                            // TODO: try deleteTrackedDirectoryFile(ctx, ctx.locked.db.allocator, path),
                            true => std.debug.panic("TODO delete a tracked directory: {f}", .{child.formatUtf8()}),
                        },
                        .untracked => std.debug.panic("TODO delete an untracked file: {f}", .{child.formatUtf8()}),
                    }
                }
                break;
            } else {
                if (stack_len == 0) break;
                stack[stack_len - 1] = undefined;
                stack_len -= 1;
            }
        }
    }

    // ===========================================

    const FileKind = enum { regular, directory };

    fn addFile(
        local_fs: *LocalFilesystem,
        events: *Events,
        allocator: Allocator,
        kind: FileKind,
        status: LocalFilesystem.Repr.Status,
        path: Path,
        parent: ?Path,
        meta: LocalFilesystem.Repr.Metadata,
    ) !void {
        try local_fs.repr.files.ensureUnusedCapacity(allocator, 1);
        try local_fs.repr.parent.ensureUnusedCapacity(allocator, 1);
        try local_fs.repr.meta.ensureUnusedCapacity(allocator, 1);
        switch (kind) {
            .regular => {},
            .directory => try local_fs.repr.children.ensureUnusedCapacity(allocator, 1),
        }
        const parent_children = blk: {
            const ptr = if (parent) |p| local_fs.repr.children.getPtr(p).? else &local_fs.repr.top_level_children;
            try ptr.ensureUnusedCapacity(allocator, 1);
            break :blk ptr;
        };

        switch (status) {
            .tracked => try events.ensureLocalEventCapacity(allocator),
            .untracked => {},
        }
        errdefer comptime unreachable;

        const gop = local_fs.repr.files.getOrPutAssumeCapacity(path);
        if (gop.found_existing) std.debug.panic("TODO addFile file already exists", .{});
        gop.value_ptr.* = .{
            .directory = switch (kind) {
                .regular => false,
                .directory => true,
            },
            .status = status,
        };
        local_fs.repr.parent.putAssumeCapacityNoClobber(path, if (parent) |p| local_fs.repr.files.getKey(p).? else null);
        local_fs.repr.meta.putAssumeCapacityNoClobber(path, meta);
        switch (kind) {
            .regular => {},
            .directory => local_fs.repr.children.putAssumeCapacityNoClobber(path, .empty),
        }
        parent_children.putAssumeCapacityNoClobber(path, {});
        switch (status) {
            .tracked => events.queueLocalEventAssumeCapacity(switch (kind) {
                .regular => .new_regular,
                .directory => .new_directory,
            }, path),
            .untracked => {},
        }
    }

    fn changeUntrackedRegularFileToNew(
        local_fs: *LocalFilesystem,
        events: *Events,
        allocator: Allocator,
        path: Path,
        meta: LocalFilesystem.Repr.Metadata,
    ) !void {
        const info = local_fs.repr.files.getEntry(path).?;

        try events.ensureLocalEventCapacity(allocator);
        errdefer comptime unreachable;

        info.value_ptr.status = .tracked;
        local_fs.repr.meta.getPtr(path).?.* = meta;
        events.queueLocalEventAssumeCapacity(.new_regular, info.key_ptr.*);
    }

    fn updateTrackedRegularFile(
        local_fs: *LocalFilesystem,
        global_fs: *GlobalFilesystem,
        events: *Events,
        allocator: Allocator,
        path: Path,
        meta: LocalFilesystem.Repr.Metadata,
    ) !void {
        const info = local_fs.repr.files.getEntry(path).?;
        assert(!info.value_ptr.directory);
        const meta_ptr = local_fs.repr.meta.getPtr(path).?;

        if (meta_ptr.local_file_id == meta.local_file_id and
            meta_ptr.size == meta.size) return;

        try events.ensureSyncEventCapacity(allocator);
        errdefer comptime unreachable;

        meta_ptr.* = meta;
        const file_id = global_fs.path_to_id.get(path).?;
        events.queueSyncEventAssumeCapacity(file_id);
    }

    fn updateTrackedDirectoryFile(
        local_fs: *LocalFilesystem,
        path: Path,
        meta: LocalFilesystem.Repr.Metadata,
    ) void {
        const info = local_fs.repr.files.getPtr(path).?;
        assert(info.directory);
        local_fs.repr.meta.getPtr(path).?.* = meta;
        // TODO: Send an event?
    }

    fn deleteTrackedRegularFile(
        local_fs: *LocalFilesystem,
        events: *Events,
        allocator: Allocator,
        path: Path,
    ) !void {
        // TODO: Delete/cancel any sync events associated with this file

        try events.ensureLocalEventCapacity(allocator);
        errdefer comptime unreachable;

        const info = local_fs.repr.files.fetchRemove(path).?;
        assert(!info.value.directory);
        assert(local_fs.repr.meta.remove(path));
        const parent = local_fs.repr.parent.fetchRemove(path).?.value;
        const parent_children = if (parent) |p| local_fs.repr.children.getPtr(p).? else &local_fs.repr.top_level_children;
        assert(parent_children.remove(path));
        events.queueLocalEventAssumeCapacity(.delete_regular, info.key);
    }

    fn deleteTrackedDirectoryFile(
        local_fs: *LocalFilesystem,
        events: *Events,
        allocator: Allocator,
        path: Path,
    ) !void {
        // TODO: Delete/cancel any sync events associated with this directory and its children
        try events.ensureLocalEventCapacity(allocator);
        errdefer comptime unreachable;

        const StackItem = struct {
            path: Path,
            children: PathHashMap(void),
            child_iterator: PathHashMap(void).KeyIterator,
        };
        var stack: [fairy.max_path_components]StackItem = undefined;
        stack[0] = .{
            .path = path,
            .children = local_fs.repr.children.fetchRemove(path).?.value,
            .child_iterator = undefined,
        };
        stack[0].child_iterator = stack[0].children.keyIterator();
        var stack_len: fairy.PathComponentCount = 1;

        while (stack_len > 0) {
            const stack_item = &stack[stack_len - 1];
            if (stack_item.child_iterator.next()) |child_path_ptr| {
                const child_path = child_path_ptr.*;
                const info = local_fs.repr.files.fetchRemove(child_path).?;
                assert(local_fs.repr.parent.remove(child_path));
                assert(local_fs.repr.meta.remove(child_path));

                if (info.value.directory) {
                    if (stack_len == fairy.max_path_components) unreachable; // TODO: unsound assumption; the directory could be empty
                    stack[stack_len] = .{
                        .path = child_path,
                        .children = local_fs.repr.children.fetchRemove(child_path).?.value,
                        .child_iterator = undefined,
                    };
                    stack[stack_len].child_iterator = stack[stack_len].children.keyIterator();
                    stack_len += 1;
                }
            } else {
                stack_item.children.deinit(allocator);
                stack_item.* = undefined;
                stack_len -= 1;
            }
        }

        const info = local_fs.repr.files.fetchRemove(path).?;
        assert(info.value.directory);

        const parent_children = if (local_fs.repr.parent.fetchRemove(path).?.value) |parent|
            local_fs.repr.children.getPtr(parent).?
        else
            &local_fs.repr.top_level_children;
        assert(parent_children.remove(path));

        assert(local_fs.repr.meta.remove(path));

        events.queueLocalEventAssumeCapacity(.delete_directory, info.key);
    }

    fn changeTrackedRegularFileToUntracked(
        local_fs: *LocalFilesystem,
        events: *Events,
        allocator: Allocator,
        path: Path,
    ) !void {
        // TODO: Delete/cancel any sync events associated with this file

        try events.ensureLocalEventCapacity(allocator);
        errdefer comptime unreachable;

        const info = local_fs.repr.files.getEntry(path).?;
        assert(!info.value_ptr.directory);
        info.value_ptr.status = .untracked;
        local_fs.repr.meta.getPtr(path).?.* = undefined;
        events.queueLocalEventAssumeCapacity(.delete_regular, info.key_ptr.*);
    }
};

fn getFileSize(file: w.HANDLE) !w.LARGE_INTEGER {
    const Information = w.FILE.STANDARD_INFORMATION;
    var information: Information = undefined;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    const status = w.ntdll.NtQueryInformationFile(file, &iosb, &information, @sizeOf(Information), .Standard);
    switch (status) {
        .SUCCESS => {},
        else => return w.unexpectedStatus(status),
    }
    return information.EndOfFile;
}

fn computeFileHash(file: w.HANDLE, file_size: w.LARGE_INTEGER) !network.FileHash {
    var iosb: w.IO_STATUS_BLOCK = undefined;
    var buffer: [64 * 1024]u8 = undefined;
    var written: w.LARGE_INTEGER = 0;
    var hash: std.crypto.hash.Blake3 = .init(.{});

    while (written < file_size) {
        const status = w.ntdll.NtReadFile(file, null, null, null, &iosb, &buffer, buffer.len, &written, null);
        switch (status) {
            .SUCCESS => {
                hash.update((&buffer)[0..iosb.Information]);
                written += @intCast(iosb.Information);
            },
            else => return w.unexpectedStatus(status),
        }
    }
    // TODO: the file could have been modified by another thread, making this assertion false; consider locking
    assert(written == file_size);

    var result: network.FileHash = undefined;
    hash.final(&result.blake3);
    return result;
}

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
        event: Event = .none,
        padding: u27 = 0,

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

        pub const Event = enum(u3) {
            none,
            acquired,
            get_global_file_id,
            sync_file,
            create_dir,
            delete_file,
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
        send_error: ?SendMessagesError = null,
        recv_error: ?ReceiveMessagesError = null,
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
                send_error: SendMessagesError!void,
                recv_error: ReceiveMessagesError!void,
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

        try select.concurrent(.send_error, sendMessages, .{ host, .init(writer), io });
        try select.concurrent(.recv_error, receiveMessages, .{ host, .init(reader), io });

        host.debugLog("started", .{});
        ns.addToDiagnostics(diag, try select.await());
    }

    pub const SendMessagesError = Io.Writer.Error || Io.Cancelable || fairy.windows.SendFileError;

    fn sendMessages(host: *Host, writer: network.Writer, io: Io) SendMessagesError!void {
        host.debugLog("sending on thread {}", .{std.os.windows.GetCurrentThreadId()});
        // TODO: Send an initial message containing protocol version, etc.
        // TODO: Send a nonce value with each transaction
        while (true) {
            while (true) {
                const state = host.db.host_state.load(.monotonic);
                if (state.tx == .outgoing) break;
                host.handleEvents(state, io) orelse
                    try io.futexWait(State, &host.db.host_state.raw, state);
            }

            const tx_id: network.TransactionId = @enumFromInt(0); // TODO hardcoded value
            switch (host.tx.data) {
                .out_new_file => |*out_new_file| switch (out_new_file.state) {
                    .send_path => try out_new_file.sendPath(host, tx_id, host.tx.peer_tx_id, io, writer),
                    .receive_decision => unreachable,
                },
                .out_file_contents => |*out_file_contents| switch (out_file_contents.state) {
                    .send_file_id => try out_file_contents.sendFileId(host, tx_id, host.tx.peer_tx_id, io, writer),
                    .send_file_contents => try out_file_contents.sendFileContents(host, tx_id, host.tx.peer_tx_id, io, writer),
                    .receive_decision, .receive_result => unreachable,
                },
                .out_create_dir => |*out_create_dir| switch (out_create_dir.state) {
                    .send_id => try out_create_dir.sendId(host, tx_id, host.tx.peer_tx_id, io, writer),
                    .receive_confirmation => unreachable,
                },
                .out_delete_file => |*out_delete_file| switch (out_delete_file.state) {
                    .send_file_id => try out_delete_file.sendFileId(host, tx_id, host.tx.peer_tx_id, io, writer),
                    .receive_confirmation => unreachable,
                },
            }
        }
    }

    /// Returns null if no event was handled.
    fn handleEvents(host: *Host, state: State, io: Io) ?void {
        switch (state.event) {
            .none, .acquired => return null,
            .get_global_file_id => {
                const tx_id = host.acquireUnusedTx() catch |err| switch (err) {
                    error.NoTxSlotsAvailable => return null,
                };
                assert(@intFromEnum(tx_id) == 0); // TODO hardcoded value
                host.debugLog("getting global file id for new file: {f}", .{host.db.out_path.formatUtf8()});

                host.tx.data = .{
                    .out_new_file = .{
                        .state = .send_path,
                        .path = host.db.out_path,
                        .kind = if (host.db.out_directory) .directory else .regular,
                    },
                };
                host.tx.peer_tx_id = .invalid;

                host.db.out_path = undefined;
                host.db.out_directory = undefined;
            },
            .sync_file => {
                const tx_id = host.acquireUnusedTx() catch |err| switch (err) {
                    error.NoTxSlotsAvailable => return null,
                };
                assert(@intFromEnum(tx_id) == 0); // TODO hardcoded value
                host.debugLog("syncing file: {f}", .{host.db.out_path.formatUtf8()});

                host.tx.data = .{
                    .out_file_contents = .{
                        .state = .send_file_id,
                        .file_id = host.db.out_file_id,
                        .path = host.db.out_path,
                    },
                };
                host.tx.peer_tx_id = .invalid;

                host.db.out_file_id = undefined;
                host.db.out_path = undefined;
            },
            .create_dir => {
                const tx_id = host.acquireUnusedTx() catch |err| switch (err) {
                    error.NoTxSlotsAvailable => return null,
                };
                assert(@intFromEnum(tx_id) == 0); // TODO hardcoded value
                host.debugLog("creating dir: {f}", .{host.db.out_path.formatUtf8()});

                host.tx.data = .{
                    .out_create_dir = .{
                        .state = .send_id,
                        .file_id = host.db.out_file_id,
                        .path = host.db.out_path,
                    },
                };
                host.tx.peer_tx_id = .invalid;

                host.db.out_file_id = undefined;
                host.db.out_path = undefined;
            },
            .delete_file => {
                const tx_id = host.acquireUnusedTx() catch |err| switch (err) {
                    error.NoTxSlotsAvailable => return null,
                };
                assert(@intFromEnum(tx_id) == 0); // TODO hardcoded value
                host.debugLog("deleting file: {f}", .{host.db.out_path.formatUtf8()});

                host.tx.data = .{
                    .out_delete_file = .{
                        .state = .send_file_id,
                        .file_id = host.db.out_file_id,
                        .path = host.db.out_path,
                    },
                };
                host.tx.peer_tx_id = .invalid;

                host.db.out_file_id = undefined;
                host.db.out_path = undefined;
            },
        }

        var old_state = state;
        while (true) {
            var new_state = state;
            new_state.tx = .outgoing;
            new_state.event = .none;
            old_state = host.db.host_state.cmpxchgWeak(old_state, new_state, .release, .monotonic) orelse break;
        }
        host.db.sendAlert(io);
    }

    pub const ReceiveMessagesError = error{
        InvalidTxId,
        InvalidPeerTxId,
        WrongTxId,
        WrongPeerTxId,
        InvalidAction,
        InvalidHeader,
    } ||
        network.Reader.ReceiveActionError ||
        network.Reader.ReceiveResolvePathResponseError ||
        network.Reader.ReceiveCreateDirResponseError ||
        Io.Cancelable ||
        Allocator.Error ||
        AddOutgoingTxError ||
        fairy.windows.ReceiveFileError;

    fn receiveMessages(host: *Host, reader: network.Reader, io: Io) ReceiveMessagesError!void {
        host.debugLog("receiving on thread {}", .{std.os.windows.GetCurrentThreadId()});
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
                    return error.InvalidAction;
                },
                .new_tx_reply => {
                    if (@intFromEnum(header.tx_id) != 0) return error.WrongTxId; // TODO: hardcoded value
                    if (host.db.host_state.load(.monotonic).tx != .incoming) return error.InvalidTxId;
                    if (host.tx.peer_tx_id != .invalid) return error.WrongPeerTxId;

                    switch (host.tx.data) {
                        .out_new_file => |*out_new_file| switch (out_new_file.state) {
                            .receive_decision => {
                                try out_new_file.receiveDecision(
                                    host,
                                    reader,
                                    io,
                                    header.tx_id,
                                    header.peer_tx_id,
                                    action,
                                );
                            },
                            .send_path => unreachable,
                        },
                        .out_file_contents => |*out_file_contents| switch (out_file_contents.state) {
                            .receive_decision => {
                                try out_file_contents.receiveDecision(
                                    host,
                                    reader,
                                    io,
                                    header.tx_id,
                                    header.peer_tx_id,
                                    action,
                                );
                            },
                            .receive_result => return error.InvalidHeader,
                            .send_file_id, .send_file_contents => unreachable,
                        },
                        .out_create_dir => |*out_create_dir| switch (out_create_dir.state) {
                            .receive_confirmation => try out_create_dir.receiveConfirmation(
                                host,
                                reader,
                                io,
                                header.tx_id,
                                header.peer_tx_id,
                                action,
                            ),
                            .send_id => unreachable,
                        },
                        .out_delete_file => |*out_delete_file| switch (out_delete_file.state) {
                            .send_file_id => unreachable,
                            .receive_confirmation => try out_delete_file.receiveConfirmation(
                                host,
                                reader,
                                io,
                                header.tx_id,
                                header.peer_tx_id,
                                action,
                            ),
                        },
                    }
                },
                .existing_tx => {
                    if (@intFromEnum(header.tx_id) != 0) return error.WrongTxId; // TODO: hardcoded value
                    if (host.db.host_state.load(.monotonic).tx != .incoming) return error.InvalidTxId;
                    if (header.peer_tx_id != .invalid) return error.WrongPeerTxId;

                    switch (host.tx.data) {
                        .out_new_file => |*out_new_file| switch (out_new_file.state) {
                            .receive_decision => return error.InvalidHeader,
                            .send_path => unreachable,
                        },
                        .out_file_contents => |*out_file_contents| switch (out_file_contents.state) {
                            .receive_decision => return error.InvalidHeader,
                            .receive_result => {
                                try out_file_contents.receiveResult(host, reader, io, header.tx_id, action);
                            },
                            .send_file_id, .send_file_contents => unreachable,
                        },
                        .out_create_dir => |*out_create_dir| switch (out_create_dir.state) {
                            .receive_confirmation => return error.InvalidHeader,
                            .send_id => unreachable,
                        },
                        .out_delete_file => |*out_delete_file| switch (out_delete_file.state) {
                            .send_file_id => unreachable,
                            .receive_confirmation => return error.InvalidHeader,
                        },
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
        // TODO: This function might need to be `acq_rel` instead of `release`
        assert(@intFromEnum(tx_id) == 0); // TODO: hardcoded value
        switch (to) {
            .init, .acquired => comptime unreachable,
            .outgoing => {
                host.releaseNewTxStatus(.incoming, to);
                io.futexWake(State, &host.db.host_state.raw, 1);
            },
            .incoming => {
                host.releaseNewTxStatus(.outgoing, to);
            },
        }
    }

    fn deleteTransaction(host: *Host, tx_id: network.TransactionId, comptime expected_status: State.TxStatus, io: Io) void {
        assert(@intFromEnum(tx_id) == 0); // TODO hardcoded value
        host.tx.data = undefined;
        host.tx.peer_tx_id = undefined;
        host.releaseNewTxStatus(expected_status, .init);

        switch (expected_status) {
            .init, .acquired => comptime unreachable,
            .outgoing => comptime unreachable,
            .incoming => {
                host.db.sendAlert(io);
                io.futexWake(State, &host.db.host_state.raw, 1);
            },
        }
    }

    fn acquireUnusedTx(host: *Host) !network.TransactionId {
        var old_state = host.db.host_state.load(.monotonic);
        while (old_state.tx == .init) {
            var new_state = old_state;
            new_state.tx = .acquired;
            old_state = host.db.host_state.cmpxchgWeak(old_state, new_state, .acquire, .monotonic) orelse break;
        } else return error.NoTxSlotsAvailable;
        return @enumFromInt(0); // TODO hardcoded value
    }

    fn releaseNewTxStatus(host: *Host, expected: State.TxStatus, new: State.TxStatus) void {
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
    out_new_file: OutNewFile,
    out_file_contents: OutFileContents,
    out_create_dir: OutCreateDir,
    out_delete_file: OutDeleteFile,

    pub const OutNewFile = struct {
        state: State,
        path: Path,
        kind: network.FileKind,

        pub const State = enum {
            send_path,
            receive_decision,
        };

        fn sendPath(
            out_new_file: *OutNewFile,
            host: *Host,
            tx_id: network.TransactionId,
            peer_tx_id: network.TransactionId,
            io: Io,
            writer: network.Writer,
        ) !void {
            assert(out_new_file.state == .send_path);
            assert(peer_tx_id == .invalid);

            const action: network.Action = .resolve_path;
            host.logMessage(.outgoing, tx_id, action, peer_tx_id);

            out_new_file.state = .receive_decision;
            host.flipTransaction(.incoming, tx_id, io);

            try writer.sendMessageHeaderNewTx(tx_id);
            try writer.sendAction(action);
            try writer.sendFileKind(out_new_file.kind);
            try writer.sendPathEncoding(.wtf16le);
            try writer.sendWindowsPathByteCount(out_new_file.path.byteCount());
            try writer.sendWindowsPath(out_new_file.path);
            try writer.flush();
        }

        fn receiveDecision(
            out_new_file: *const OutNewFile,
            host: *Host,
            reader: network.Reader,
            io: Io,
            tx_id: network.TransactionId,
            peer_tx_id: network.TransactionId,
            action: network.Action,
        ) !void {
            assert(out_new_file.state == .receive_decision);
            if (peer_tx_id != .invalid) return error.InvalidPeerTxId;
            if (action != .resolve_path_response) return error.InvalidAction;

            const response = try reader.receiveResolvePathResponse();
            switch (response) {
                .success => {
                    // TODO Store this in Database somewhere instead
                    var file_id_buffer: [fairy.max_path_components]network.FileId = undefined;
                    var file_id_list: std.ArrayList(network.FileId) = .initBuffer(&file_id_buffer);
                    const Iterator = std.fs.path.ComponentIterator(.windows, u16);
                    var it = Iterator.init(out_new_file.path.slice);
                    while (it.next()) |_| {
                        const ptr = file_id_list.addOneBounded() catch unreachable;
                        ptr.* = try reader.receiveFileId();
                    }

                    {
                        const locked = try host.db.lock(io);
                        defer locked.unlock(io);
                        try locked.setNewFileId(out_new_file.path, out_new_file.kind, file_id_list.items);
                    }

                    host.debugLog("received {f} for file {f}\n", .{ file_id_list.items[file_id_list.items.len - 1], out_new_file.path.formatUtf8() });
                    host.deleteTransaction(tx_id, .incoming, io);
                },
                .invalid_path,
                .exhausted_file_ids,
                .invalid_folder,
                .wrong_file_kind,
                => {
                    host.debugLog("error '{s}' while resolving path {f}\n", .{ @tagName(response), out_new_file.path.formatUtf8() });
                    host.deleteTransaction(tx_id, .incoming, io);
                },
            }
        }
    };

    pub const OutFileContents = struct {
        state: State,
        file_id: network.FileId,
        path: Path, // TODO: this field shouldn't be needed

        pub const State = enum {
            send_file_id,
            receive_decision,
            send_file_contents,
            receive_result,
        };

        fn sendFileId(
            out_file_contents: *OutFileContents,
            host: *Host,
            tx_id: network.TransactionId,
            peer_tx_id: network.TransactionId,
            io: Io,
            writer: network.Writer,
        ) !void {
            assert(out_file_contents.state == .send_file_id);
            assert(peer_tx_id == .invalid);

            const action: network.Action = .transfer_file_id;
            host.logMessage(.outgoing, tx_id, action, peer_tx_id);

            out_file_contents.state = .receive_decision;
            host.flipTransaction(.incoming, tx_id, io);

            try writer.sendMessageHeaderNewTx(tx_id);
            try writer.sendAction(action);
            try writer.sendFileId(out_file_contents.file_id);
            try writer.flush();
        }

        fn receiveDecision(
            out_file_contents: *OutFileContents,
            host: *Host,
            _: network.Reader,
            io: Io,
            tx_id: network.TransactionId,
            peer_tx_id: network.TransactionId,
            action: network.Action,
        ) !void {
            assert(out_file_contents.state == .receive_decision);

            switch (action) {
                .transfer_file_accept => {
                    if (peer_tx_id == .invalid) return error.WrongPeerTxId;
                    out_file_contents.state = .send_file_contents;
                    host.tx.peer_tx_id = peer_tx_id;
                    host.flipTransaction(.outgoing, tx_id, io);
                },
                .transfer_file_decline => {
                    if (peer_tx_id != .invalid) return error.WrongPeerTxId;
                    host.deleteTransaction(tx_id, .incoming, io);
                },
                else => return error.InvalidAction,
            }
        }

        fn sendFileContents(
            out_file_contents: *OutFileContents,
            host: *Host,
            tx_id: network.TransactionId,
            peer_tx_id: network.TransactionId,
            io: Io,
            writer: network.Writer,
        ) !void {
            assert(out_file_contents.state == .send_file_contents);

            const action: network.Action = .transfer_file_contents;
            host.logMessage(.outgoing, tx_id, action, peer_tx_id);

            const file = try host.db.openFileReadOnly(out_file_contents.path);
            defer host.db.closeFile(file);
            // TODO update the database with this new size information
            const file_size = blk: {
                const windows_size = try getFileSize(file);
                const casted_size = std.math.cast(network.FileSize, windows_size) orelse
                    std.debug.panic(
                        "TODO: File too large to transfer: '{f}' with size {}",
                        .{ out_file_contents.path.formatUtf8(), windows_size },
                    );
                break :blk casted_size;
            };

            const file_hash = network.FileHash{ .blake3 = @splat(0) }; // TODO: compute the hash while sending data

            out_file_contents.state = .receive_result;
            host.flipTransaction(.incoming, tx_id, io);

            try writer.sendMessageHeaderExistingTx(peer_tx_id);
            try writer.sendAction(action);
            try writer.sendFileSize(file_size);
            try fairy.windows.sendFile(writer.io, file, file_size);
            try writer.sendFileHash(&file_hash);
            try writer.flush();
        }

        fn receiveResult(
            out_file_contents: *const OutFileContents,
            host: *Host,
            _: network.Reader,
            io: Io,
            tx_id: network.TransactionId,
            action: network.Action,
        ) !void {
            switch (action) {
                .transfer_file_success => {
                    {
                        const locked = try host.db.lock(io);
                        defer locked.unlock(io);
                        locked.markFileAsSynced(out_file_contents.file_id);
                    }
                    host.debugLog("successfully synced file: {f}\n", .{out_file_contents.path.formatUtf8()});
                },
                .transfer_file_failure => {
                    // TODO mark file as failed to sync
                    {
                        const locked = try host.db.lock(io);
                        defer locked.unlock(io);
                        locked.markFileAsSynced(out_file_contents.file_id);
                    }
                    host.debugLog("failed to sync file: {f}\n", .{out_file_contents.path.formatUtf8()});
                },
                else => return error.InvalidAction,
            }
            host.deleteTransaction(tx_id, .incoming, io);
        }
    };

    pub const OutCreateDir = struct {
        state: State,
        file_id: network.FileId,
        path: Path,

        pub const State = enum {
            send_id,
            receive_confirmation,
        };

        fn sendId(
            out_create_dir: *OutCreateDir,
            host: *Host,
            tx_id: network.TransactionId,
            peer_tx_id: network.TransactionId,
            io: Io,
            writer: network.Writer,
        ) !void {
            assert(out_create_dir.state == .send_id);
            assert(peer_tx_id == .invalid);

            const action: network.Action = .create_dir;
            host.logMessage(.outgoing, tx_id, action, peer_tx_id);

            out_create_dir.state = .receive_confirmation;
            host.flipTransaction(.incoming, tx_id, io);

            try writer.sendMessageHeaderNewTx(tx_id);
            try writer.sendAction(action);
            try writer.sendFileId(out_create_dir.file_id);
            try writer.flush();
        }

        fn receiveConfirmation(
            out_create_dir: *const OutCreateDir,
            host: *Host,
            reader: network.Reader,
            io: Io,
            tx_id: network.TransactionId,
            peer_tx_id: network.TransactionId,
            action: network.Action,
        ) !void {
            assert(out_create_dir.state == .receive_confirmation);
            if (peer_tx_id != .invalid) return error.InvalidPeerTxId;
            if (action != .create_dir_response) return error.InvalidAction;

            const response = try reader.receiveCreateDirResponse();
            switch (response) {
                .success => {
                    {
                        const locked = try host.db.lock(io);
                        defer locked.unlock(io);
                        locked.acknowledgeCreateDir(out_create_dir.file_id);
                    }
                    host.debugLog(
                        "create dir with id {} name {f}\n",
                        .{ @intFromEnum(out_create_dir.file_id), out_create_dir.path.formatUtf8() },
                    );
                    host.deleteTransaction(tx_id, .incoming, io);
                },
                .not_a_directory, .unknown_file, .unexpected => {
                    // TODO handle this error
                    {
                        const locked = try host.db.lock(io);
                        defer locked.unlock(io);
                        locked.acknowledgeCreateDir(out_create_dir.file_id);
                    }
                    host.debugLog(
                        "error '{s}' while creating dir {} {f}\n",
                        .{ @tagName(response), @intFromEnum(out_create_dir.file_id), out_create_dir.path.formatUtf8() },
                    );
                    host.deleteTransaction(tx_id, .incoming, io);
                },
            }
        }
    };

    pub const OutDeleteFile = struct {
        state: enum { send_file_id, receive_confirmation },
        file_id: network.FileId,
        path: Path,

        fn sendFileId(
            out_delete_file: *OutDeleteFile,
            host: *Host,
            tx_id: network.TransactionId,
            peer_tx_id: network.TransactionId,
            io: Io,
            writer: network.Writer,
        ) !void {
            assert(out_delete_file.state == .send_file_id);
            assert(peer_tx_id == .invalid);

            const action: network.Action = .delete_file;
            host.logMessage(.outgoing, tx_id, action, peer_tx_id);

            out_delete_file.state = .receive_confirmation;
            host.flipTransaction(.incoming, tx_id, io);

            try writer.sendMessageHeaderNewTx(tx_id);
            try writer.sendAction(action);
            try writer.sendFileId(out_delete_file.file_id);
            try writer.flush();
        }

        fn receiveConfirmation(
            out_delete_file: *OutDeleteFile,
            host: *Host,
            _: network.Reader,
            io: Io,
            tx_id: network.TransactionId,
            peer_tx_id: network.TransactionId,
            action: network.Action,
        ) !void {
            assert(out_delete_file.state == .receive_confirmation);
            if (peer_tx_id != .invalid) return error.WrongPeerTxId;

            switch (action) {
                .delete_file_confirm => {
                    {
                        const locked = try host.db.lock(io);
                        defer locked.unlock(io);
                        locked.confirmDeleteFile(out_delete_file.file_id);
                    }
                    host.deleteTransaction(tx_id, .incoming, io);
                },
                else => return error.InvalidAction,
            }
        }
    };
};
