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

pub const Database = struct {
    sync_dir: w.HANDLE,

    mutex: Io.Mutex, // TODO: Compare with RwLock

    // Begin fields protected by mutex

    allocator: Allocator,
    path_arena: std.heap.ArenaAllocator.State,
    scan_arena: std.heap.ArenaAllocator.State,
    tree: Tree,
    file_id_map: std.AutoHashMapUnmanaged(network.FileId, Path),
    /// The database periodically checks this map for new events and tries to move them to "in progress".
    queued_events: Event.Map,
    in_progress_events: Event.Map,

    // End fields protected by mutex

    // Database-Host synchronization fields
    alert: std.atomic.Value(Alert),
    host_state: std.atomic.Value(Host.State),
    out_path: Path,
    out_file_id: network.FileId,
    out_directory: bool,
    out_metadata: struct {
        size: w.ULARGE_INTEGER,
        hash: network.FileHash,
    },

    pub const Alert = enum(u32) { off, on };

    /// A re-representation of the contents of the sync directory.
    pub const Tree = struct {
        files: PathHashMap(Info),
        /// Applies to all files
        parent: PathHashMap(?Path),
        /// Applies only to directories
        children: PathHashMap(PathHashMap(void)),
        /// Applies only to regular files
        meta: PathHashMap(Metadata),
        /// Applies only to regular files
        // TODO: Make the hash nullable, do not compute it until the file is being synced
        hash: PathHashMap(network.FileHash),

        fn deinit(tree: *Tree, allocator: Allocator) void {
            var it = tree.children.valueIterator();
            while (it.next()) |list| list.deinit(allocator);

            tree.files.deinit(allocator);
            tree.parent.deinit(allocator);
            tree.children.deinit(allocator);
            tree.meta.deinit(allocator);
            tree.hash.deinit(allocator);

            tree.* = undefined;
        }

        pub const Info = struct {
            directory: bool,
            status: Status,
            local_file_id: w.LARGE_INTEGER,
            global_file_id: network.FileId,
        };

        pub const Status = enum {
            /// A file which was previously untracked and is now known to exist.
            ///
            /// global_file_id may be `.unknown`
            /// hash is undefined
            new,
            /// A file which is being tracked.
            tracked,
            /// A file whose existence is known, but will not be synced to the server for one or more reasons.
            ///
            /// global_file_id is `.unknown`
            /// meta is undefined
            /// hash is undefined
            untracked,
        };

        pub const Metadata = struct {
            modified_time: w.LARGE_INTEGER,
            size: w.ULARGE_INTEGER,
        };
    };

    pub const Event = enum {
        new,
        modified,
        create_dir,
        deleted,

        pub const Map = struct {
            map: std.ArrayHashMapUnmanaged(Key, Event, Context, true),

            pub const Key = union(enum) {
                path: Path,
                file_id: network.FileId,
            };

            pub const Context = struct {
                pub fn hash(_: @This(), key: Key) u32 {
                    switch (key) {
                        .path => |path| return path.hash(),
                        .file_id => |file_id| return std.hash.int(@intFromEnum(file_id)),
                    }
                }

                pub fn eql(_: @This(), a: Key, b: Key, _: usize) bool {
                    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
                    switch (a) {
                        .path => return Path.eql(a.path, b.path),
                        .file_id => return a.file_id == b.file_id,
                    }
                }
            };
        };
    };

    pub fn init(sync_dir_path: [:0]const u16, allocator: Allocator) !Database {
        const sync_dir_path_nt = try Io.Threaded.wToPrefixedFileW(null, sync_dir_path, .{ .allow_relative = false });
        const sync_dir = try fairy.windows.openSyncDir(sync_dir_path_nt.span());
        errdefer comptime unreachable;

        return .{
            .sync_dir = sync_dir,

            .mutex = .init,
            .allocator = allocator,
            .path_arena = .{},
            .scan_arena = .{},
            .tree = .{
                .files = .empty,
                .parent = .empty,
                .children = .empty,
                .meta = .empty,
                .hash = .empty,
            },
            .file_id_map = .empty,
            .queued_events = .{ .map = .empty },
            .in_progress_events = .{ .map = .empty },

            .alert = .init(.off),
            .host_state = .init(.{}),
            .out_path = undefined,
            .out_file_id = undefined,
            .out_directory = undefined,
            .out_metadata = undefined,
        };
    }

    pub fn deinit(db: *Database) void {
        fairy.windows.closeHandle(db.sync_dir);

        var path_arena = db.path_arena.promote(db.allocator);
        path_arena.deinit();
        var scan_arena = db.scan_arena.promote(db.allocator);
        scan_arena.deinit();

        db.tree.deinit(db.allocator);
        db.file_id_map.deinit(db.allocator);
        db.queued_events.map.deinit(db.allocator);
        db.in_progress_events.map.deinit(db.allocator);

        db.* = undefined;
    }

    pub fn run(db: *Database, io: Io) !void {
        std.debug.print("client db running on thread {}\n", .{std.os.windows.GetCurrentThreadId()});
        var stderr = Io.File.stderr().writer(io, &.{});

        const clock: Io.Clock = .boot;
        const max_wait_time = Io.Clock.Duration{ .raw = .fromSeconds(8), .clock = clock };
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
    fn sendHostEvents(db: *Database, io: Io) (Allocator.Error || Io.Cancelable)!bool {
        const host_event: Host.State.Event = blk: {
            try db.mutex.lock(io);
            defer db.mutex.unlock(io);

            if (db.queued_events.map.count() == 0) return false;
            try db.in_progress_events.map.ensureUnusedCapacity(db.allocator, 1);
            db.acquireHostEvent() orelse return false;
            errdefer comptime unreachable;

            const kv = db.queued_events.map.pop().?;
            const gop = db.in_progress_events.map.getOrPutAssumeCapacity(kv.key);
            if (gop.found_existing) std.debug.panic("TODO: event already in progress for {any}", .{kv.key});
            gop.value_ptr.* = kv.value;

            switch (kv.value) {
                .new => {
                    const path = switch (kv.key) {
                        .file_id => unreachable,
                        .path => |path| path,
                    };
                    const info = db.tree.files.get(path).?;
                    switch (info.status) {
                        .new => {},
                        .tracked, .untracked => unreachable,
                    }
                    db.out_path = path;
                    db.out_directory = info.directory;
                    break :blk .get_global_file_id;
                },
                .modified => {
                    const file_id = switch (kv.key) {
                        .file_id => |file_id| file_id,
                        .path => unreachable,
                    };
                    const path = db.file_id_map.get(file_id).?;
                    const info = db.tree.files.get(path).?;
                    switch (info.status) {
                        .tracked => {},
                        .new, .untracked => unreachable,
                    }
                    db.out_file_id = info.global_file_id;
                    db.out_path = path;
                    db.out_metadata = .{
                        .size = db.tree.meta.get(path).?.size,
                        .hash = db.tree.hash.get(path).?,
                    };
                    break :blk .sync_file;
                },
                .create_dir => {
                    const file_id = switch (kv.key) {
                        .file_id => |file_id| file_id,
                        .path => unreachable,
                    };
                    const path = db.file_id_map.get(file_id).?;
                    const info = db.tree.files.get(path).?;
                    switch (info.status) {
                        .tracked => {},
                        .new, .untracked => unreachable,
                    }
                    db.out_file_id = info.global_file_id;
                    db.out_path = path;
                    break :blk .create_dir;
                },
                .deleted => {
                    const file_id = switch (kv.key) {
                        .file_id => |file_id| file_id,
                        .path => unreachable,
                    };
                    const path = db.file_id_map.get(file_id).?;
                    db.out_file_id = file_id;
                    db.out_path = path;
                    break :blk .delete_file;
                },
            }
        };

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
};

pub const LockedDatabase = struct {
    db: *Database,
    debug: Debug = .{},

    pub fn unlock(locked: LockedDatabase, io: Io) void {
        locked.db.mutex.unlock(io);
    }

    pub fn manualScan(locked: LockedDatabase, io: Io) !void {
        try scan.run(locked);
        locked.db.sendAlert(io);
    }

    fn queueEventAssumeCapacity(
        locked: LockedDatabase,
        key: Database.Event.Map.Key,
        event: Database.Event,
    ) void {
        const gop = locked.db.queued_events.map.getOrPutAssumeCapacity(key);
        if (gop.found_existing) std.debug.panic("TODO: event already queued for {any}", .{key});
        gop.value_ptr.* = event;
    }

    fn addFile(
        locked: LockedDatabase,
        directory: bool,
        comptime status: Database.Tree.Status,
        path: Path,
        parent: ?Path,
        local_file_id: w.LARGE_INTEGER,
        meta: switch (status) {
            .new => Database.Tree.Metadata,
            .untracked => void,
            .tracked => unreachable,
        },
    ) !void {
        try locked.db.tree.files.ensureUnusedCapacity(locked.db.allocator, 1);
        try locked.db.tree.parent.ensureUnusedCapacity(locked.db.allocator, 1);
        try locked.db.tree.meta.ensureUnusedCapacity(locked.db.allocator, 1);
        switch (directory) {
            false => try locked.db.tree.hash.ensureUnusedCapacity(locked.db.allocator, 1),
            true => try locked.db.tree.children.ensureUnusedCapacity(locked.db.allocator, 1),
        }
        const parent_children = if (parent) |p| blk: {
            const ptr = locked.db.tree.children.getPtr(p).?;
            try ptr.ensureUnusedCapacity(locked.db.allocator, 1);
            break :blk ptr;
        } else null;

        switch (status) {
            .new => try locked.db.queued_events.map.ensureUnusedCapacity(locked.db.allocator, 1),
            .untracked => {},
            .tracked => comptime unreachable,
        }
        errdefer comptime unreachable;

        const gop = locked.db.tree.files.getOrPutAssumeCapacity(path);
        if (gop.found_existing) std.debug.panic("TODO addFile file already exists", .{});
        gop.value_ptr.* = .{
            .directory = directory,
            .status = status,
            .local_file_id = local_file_id,
            .global_file_id = .unknown,
        };
        locked.db.tree.parent.putAssumeCapacityNoClobber(path, parent);
        locked.db.tree.meta.putAssumeCapacityNoClobber(path, switch (status) {
            .new => meta,
            .untracked => undefined,
            .tracked => unreachable,
        });
        switch (directory) {
            false => locked.db.tree.hash.putAssumeCapacityNoClobber(path, undefined),
            true => locked.db.tree.children.putAssumeCapacityNoClobber(path, .empty),
        }
        if (parent_children) |pc| pc.putAssumeCapacityNoClobber(path, {});
        switch (status) {
            .new => locked.queueEventAssumeCapacity(.{ .path = path }, .new),
            .untracked => {},
            .tracked => comptime unreachable,
        }
    }

    fn updateNewFile(
        locked: LockedDatabase,
        path: Path,
        local_file_id: w.LARGE_INTEGER,
        meta: Database.Tree.Metadata,
    ) void {
        const info = locked.db.tree.files.getPtr(path).?;
        info.local_file_id = local_file_id;
        locked.db.tree.meta.getPtr(path).?.* = meta;
    }

    fn changeUntrackedFileToNew(
        locked: LockedDatabase,
        path: Path,
        local_file_id: w.LARGE_INTEGER,
        meta: Database.Tree.Metadata,
    ) !void {
        const info = locked.db.tree.files.getEntry(path).?;

        try locked.db.queued_events.map.ensureUnusedCapacity(locked.db.allocator, 1);
        errdefer comptime unreachable;

        info.value_ptr.status = .new;
        info.value_ptr.local_file_id = local_file_id;
        locked.db.tree.meta.getPtr(path).?.* = meta;
        locked.queueEventAssumeCapacity(.{ .path = info.key_ptr.* }, .new);
    }

    fn updateTrackedRegularFile(
        locked: LockedDatabase,
        path: Path,
        local_file_id: w.LARGE_INTEGER,
        meta: Database.Tree.Metadata,
        hash: *const network.FileHash,
    ) !void {
        const info = locked.db.tree.files.getEntry(path).?;
        const meta_ptr = locked.db.tree.meta.getPtr(path).?;
        const hash_ptr = locked.db.tree.hash.getPtr(path).?;

        if (info.value_ptr.local_file_id == local_file_id and
            meta_ptr.size == meta.size and
            hash_ptr.eql(hash)) return;

        try locked.db.queued_events.map.ensureUnusedCapacity(locked.db.allocator, 1);
        errdefer comptime unreachable;

        info.value_ptr.local_file_id = local_file_id;
        meta_ptr.* = meta;
        hash_ptr.* = hash.*;
        locked.queueEventAssumeCapacity(.{ .file_id = info.value_ptr.global_file_id }, .modified);
    }

    fn updateTrackedDirectoryFile(
        locked: LockedDatabase,
        path: Path,
        local_file_id: w.LARGE_INTEGER,
        meta: Database.Tree.Metadata,
    ) void {
        const info = locked.db.tree.files.getPtr(path).?;
        info.local_file_id = local_file_id;
        locked.db.tree.meta.getPtr(path).?.* = meta;
    }

    fn deleteTrackedRegularFile(locked: LockedDatabase, path: Path) !void {
        try locked.db.queued_events.map.ensureUnusedCapacity(locked.db.allocator, 1);
        errdefer comptime unreachable;

        const info = locked.db.tree.files.fetchRemove(path).?;
        assert(locked.db.tree.meta.remove(path));
        assert(locked.db.tree.hash.remove(path));
        const parent = locked.db.tree.parent.fetchRemove(path).?.value;
        if (parent) |p| {
            const parent_children = locked.db.tree.children.getPtr(p).?;
            assert(parent_children.remove(path));
        }
        locked.queueEventAssumeCapacity(.{ .file_id = info.value.global_file_id }, .deleted);
    }

    fn changeTrackedRegularFileToUntracked(locked: LockedDatabase, path: Path) !void {
        try locked.db.queued_events.map.ensureUnusedCapacity(locked.db.allocator, 1);
        errdefer comptime unreachable;

        const info = locked.db.tree.files.getPtr(path).?;
        const file_id = info.global_file_id;
        info.status = .untracked;
        info.global_file_id = .unknown;
        locked.db.tree.meta.getPtr(path).?.* = undefined;
        locked.db.tree.hash.getPtr(path).?.* = undefined;
        locked.queueEventAssumeCapacity(.{ .file_id = file_id }, .deleted);
    }

    // called from Host
    fn setNewFileId(locked: LockedDatabase, path: Path, kind: network.FileKind, reverse_file_id_list: []const network.FileId, io: Io) !void {
        assert(locked.db.in_progress_events.map.fetchSwapRemove(.{ .path = path }).?.value == .new);

        const info = locked.db.tree.files.getPtr(path) orelse
            std.debug.panic("received file id for unknown file: {f}", .{path.formatUtf8()});
        // TODO make sure this is actually the same file that the event was created for
        switch (info.status) {
            .new => {},
            .tracked, .untracked => std.debug.panic("TODO: handle new file id for non-new file", .{}),
        }
        switch (kind) {
            .regular => if (info.directory) std.debug.panic("TODO", .{}),
            .directory => if (!info.directory) std.debug.panic("TODO", .{}),
        }

        try locked.db.file_id_map.ensureUnusedCapacity(locked.db.allocator, @as(fairy.PathComponentCount, @intCast(reverse_file_id_list.len)));
        try locked.db.queued_events.map.ensureUnusedCapacity(locked.db.allocator, 1);

        // TODO: do not compute the hash right now
        const hash = if (!info.directory) blk: {
            const file = try fairy.windows.openFile(locked.db.sync_dir, path, .read);
            defer fairy.windows.closeHandle(file);

            const Information = w.FILE.STANDARD_INFORMATION;
            var information: Information = undefined;
            var iosb: w.IO_STATUS_BLOCK = undefined;
            const status = w.ntdll.NtQueryInformationFile(file, &iosb, &information, @sizeOf(Information), .Standard);
            switch (status) {
                .SUCCESS => {},
                else => return w.unexpectedStatus(status),
            }

            break :blk try computeFileHash(file, information.EndOfFile);
        } else undefined;

        errdefer comptime unreachable;

        // Walk up the tree and set global file IDs for every path encountered
        const Iterator = std.fs.path.ComponentIterator(.windows, u16);
        var it = Iterator.init(path.slice);
        var i: fairy.PathComponentCount = 0;
        while (if (i == 0) it.last() else it.previous()) |component| : (i += 1) {
            const file_id = reverse_file_id_list[i];
            const path_info = locked.db.tree.files.getEntry(.assumeValidPath(component.path)).?;
            // TODO: switch (path_info.value_ptr.status) { ... }
            switch (path_info.value_ptr.global_file_id) {
                .unknown => {
                    path_info.value_ptr.global_file_id = file_id;
                    locked.db.file_id_map.putAssumeCapacityNoClobber(file_id, path_info.key_ptr.*);
                    fairy.log.debug("db: set file id {} for {f}", .{ @intFromEnum(file_id), path_info.key_ptr.formatUtf8() });
                },
                _ => {
                    if (path_info.value_ptr.global_file_id != file_id) {
                        std.debug.panic(
                            "TODO client/server conflict detected: {f} has client id {} and server id {}",
                            .{ path_info.key_ptr.formatUtf8(), path_info.value_ptr.global_file_id, file_id },
                        );
                    }
                    // TODO: break here?
                },
            }
        }
        assert(i == reverse_file_id_list.len);

        info.status = .tracked;
        if (!info.directory) locked.db.tree.hash.getPtr(path).?.* = hash;
        locked.queueEventAssumeCapacity(.{ .file_id = reverse_file_id_list[0] }, if (info.directory) .create_dir else .modified);
        locked.db.sendAlert(io);
    }

    // called from Host
    fn confirmDeleteFile(locked: LockedDatabase, file_id: network.FileId) !void {
        assert(locked.db.in_progress_events.map.fetchSwapRemove(.{ .file_id = file_id }).?.value == .deleted);
        assert(locked.db.file_id_map.remove(file_id));
    }

    // called from Host
    fn markFileAsSynced(locked: LockedDatabase, file_id: network.FileId) !void {
        assert(locked.db.in_progress_events.map.fetchSwapRemove(.{ .file_id = file_id }).?.value == .modified);
    }

    pub const Debug = struct {
        pub fn printFileEntries(debug: *const Debug, writer: *Io.Writer) !void {
            const locked: *const LockedDatabase = @alignCast(@fieldParentPtr("debug", debug));

            try writer.writeAll("Tracked files\n");
            var it = locked.db.tree.files.iterator();
            while (it.next()) |entry| {
                switch (entry.value_ptr.status) {
                    .tracked => {},
                    .new, .untracked => continue,
                }
                const meta = locked.db.tree.meta.get(entry.key_ptr.*).?;
                try writer.print(
                    "{f}: modified({}) size({}) hash({?f})\n",
                    .{
                        entry.key_ptr.formatUtf8(),
                        meta.modified_time,
                        meta.size,
                        locked.db.tree.hash.get(entry.key_ptr.*),
                    },
                );
            }

            try writer.writeAll("New files\n");
            it = locked.db.tree.files.iterator();
            while (it.next()) |entry| {
                switch (entry.value_ptr.status) {
                    .new => {},
                    .tracked, .untracked => continue,
                }
                const meta = locked.db.tree.meta.get(entry.key_ptr.*).?;
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
            it = locked.db.tree.files.iterator();
            while (it.next()) |entry| {
                switch (entry.value_ptr.status) {
                    .new, .tracked => continue,
                    .untracked => {},
                }
                try writer.print("{f}\n", .{entry.key_ptr.formatUtf8()});
            }

            try writer.writeAll("\n");
        }

        pub fn printFileEvents(debug: *const Debug, writer: *Io.Writer) !void {
            const locked: *const LockedDatabase = @alignCast(@fieldParentPtr("debug", debug));

            inline for (&[_]struct { Database.Event, []const u8 }{
                .{ .new, "Locally new files:\n" },
                .{ .modified, "Locally modified files:\n" },
                .{ .deleted, "Locally deleted files:\n" },
            }) |item| {
                const status, const text = item;
                try writer.writeAll(text);

                inline for (.{
                    .{ "queued_events", "Q" },
                    .{ "in_progress_events", "P" },
                }) |item2| {
                    const field_name, const symbol = item2;
                    var it = @field(locked.db, field_name).map.iterator();
                    while (it.next()) |entry| {
                        if (entry.value_ptr.* != status) continue;
                        switch (entry.key_ptr.*) {
                            .path => |path| try writer.print("\t{f} ({s})\n", .{ path.formatUtf8(), symbol }),
                            .file_id => |file_id| try writer.print("\tfile_id({}) ({s})\n", .{ @intFromEnum(file_id), symbol }),
                        }
                    }
                }
            }
        }
    };
};

const scan = struct {
    const Context = struct {
        locked: LockedDatabase,
        arena: *std.heap.ArenaAllocator,
        pending_dirs: std.ArrayList([]const u16),
        sub_path: std.ArrayList(u16),
        component_delimeters: std.ArrayList(u16),
        open_dir_handles: std.ArrayList(w.HANDLE),
        parent_paths: std.ArrayList(?Path),
        set_of_tracked_files: SetOfTrackedFiles,

        const SetOfTrackedFiles = PathHashMap(struct {
            status: Database.Tree.Status,
            directory: bool,
            already_seen: bool,
        });
    };

    fn initContext(locked: LockedDatabase, arena: *std.heap.ArenaAllocator) !Context {
        const allocator = arena.allocator();

        var parent_paths: std.ArrayList(?Path) = .empty;
        try parent_paths.append(allocator, null);

        var open_dir_handles: std.ArrayList(w.HANDLE) = .empty;
        try open_dir_handles.append(allocator, locked.db.sync_dir);

        var set_of_tracked_files: Context.SetOfTrackedFiles = .empty;
        try set_of_tracked_files.ensureTotalCapacity(allocator, locked.db.tree.files.count());
        var it = locked.db.tree.files.iterator();
        while (it.next()) |entry| {
            set_of_tracked_files.putAssumeCapacityNoClobber(entry.key_ptr.*, .{
                .status = entry.value_ptr.status,
                .directory = entry.value_ptr.directory,
                .already_seen = false,
            });
        }

        return .{
            .locked = locked,
            .arena = arena,
            .pending_dirs = .empty,
            .sub_path = .empty,
            .component_delimeters = .empty,
            .open_dir_handles = open_dir_handles,
            .parent_paths = parent_paths,
            .set_of_tracked_files = set_of_tracked_files,
        };
    }

    fn deinitContext(ctx: *Context) void {
        for (ctx.open_dir_handles.items[1..]) |handle| {
            w.CloseHandle(handle);
        }
        ctx.* = undefined;
    }

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
        var arena = locked.db.scan_arena.promote(locked.db.allocator);
        defer {
            _ = arena.reset(.retain_capacity);
            locked.db.scan_arena = arena.state;
        }

        var ctx = try initContext(locked, &arena);
        defer deinitContext(&ctx);

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

        try deleteFiles(&ctx);
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

        const allocator = ctx.arena.allocator();
        const component_delimeter_index = ctx.sub_path.items.len;
        defer ctx.sub_path.shrinkRetainingCapacity(component_delimeter_index);
        try ctx.sub_path.appendSlice(allocator, name);
        const path: Path = .assumeValidPath(ctx.sub_path.items);

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
        const allocator = ctx.arena.allocator();
        try ctx.component_delimeters.ensureTotalCapacity(allocator, 1);
        try ctx.sub_path.ensureUnusedCapacity(allocator, dir_name.len + delimeter.len);
        try ctx.parent_paths.ensureUnusedCapacity(allocator, 1);
        try ctx.open_dir_handles.ensureUnusedCapacity(allocator, 1);

        ctx.component_delimeters.appendAssumeCapacity(@intCast(ctx.sub_path.items.len));
        ctx.sub_path.appendSliceAssumeCapacity(dir_name);
        const parent_path_temp = ctx.sub_path.items;
        ctx.sub_path.appendSliceAssumeCapacity(delimeter);

        var path_arena = ctx.locked.db.path_arena.promote(ctx.locked.db.allocator);
        defer ctx.locked.db.path_arena = path_arena.state;
        const path_allocator = path_arena.allocator();
        const key = ctx.locked.db.tree.files.getKey(.assumeValidPath(parent_path_temp));
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
        ctx.sub_path.shrinkRetainingCapacity(component_delimeter_index);
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
        const local_file_id = information.FileId;
        const size = std.math.cast(w.ULARGE_INTEGER, information.EndOfFile) orelse return error.Unexpected;
        const meta = Database.Tree.Metadata{
            .modified_time = information.ChangeTime,
            .size = size,
        };

        const allocator = ctx.arena.allocator();
        const gop = try ctx.set_of_tracked_files.getOrPut(allocator, path);
        if (gop.found_existing) {
            if (gop.value_ptr.already_seen) std.debug.panic("TODO saw file more than once while scanning: {f}", .{path.formatUtf8()});
            gop.value_ptr.already_seen = true;
            if (gop.value_ptr.directory) std.debug.panic("TODO a directory was changed to a regular file: {f}", .{path.formatUtf8()});

            switch (gop.value_ptr.status) {
                .new => {
                    if (set_to_untracked) std.debug.panic("TODO set a new file to untracked: {f}", .{path.formatUtf8()});
                    ctx.locked.updateNewFile(path, local_file_id, meta);
                },
                .untracked => {
                    if (set_to_untracked) return;
                    try ctx.locked.changeUntrackedFileToNew(path, local_file_id, meta);
                    gop.value_ptr.status = .new;
                },
                .tracked => {
                    if (set_to_untracked) {
                        try ctx.locked.changeTrackedRegularFileToUntracked(path);
                    } else {
                        // TODO: do not compute the hash right now
                        const hash = blk: {
                            const file = try fairy.windows.openFile(ctx.locked.db.sync_dir, path, .read);
                            defer w.CloseHandle(file);
                            break :blk try computeFileHash(file, information.EndOfFile);
                        };

                        try ctx.locked.updateTrackedRegularFile(path, local_file_id, meta, &hash);
                    }
                },
            }
        } else {
            errdefer ctx.set_of_tracked_files.removeByPtr(gop.key_ptr);

            var path_arena = ctx.locked.db.path_arena.promote(ctx.locked.db.allocator);
            defer ctx.locked.db.path_arena = path_arena.state;
            const file_path_allocator = path_arena.allocator();

            const path_copy = try path.dupe(file_path_allocator);
            errdefer file_path_allocator.free(path_copy.slice);

            gop.key_ptr.* = path_copy;
            gop.value_ptr.* = .{ .status = undefined, .directory = false, .already_seen = true };

            const parent = ctx.parent_paths.getLast();
            if (set_to_untracked) {
                try ctx.locked.addFile(false, .untracked, path_copy, parent, local_file_id, {});
                gop.value_ptr.status = .untracked;
            } else {
                try ctx.locked.addFile(false, .new, path_copy, parent, local_file_id, meta);
                gop.value_ptr.status = .new;
            }
        }
    }

    fn processDirectoryFile(
        ctx: *Context,
        path: Path,
        information: *const NtQueryInformation,
        set_to_untracked: bool,
    ) !void {
        const local_file_id = information.FileId;
        const meta = Database.Tree.Metadata{
            .modified_time = information.ChangeTime,
            .size = 0,
        };

        const allocator = ctx.arena.allocator();
        const gop = try ctx.set_of_tracked_files.getOrPut(allocator, path);
        if (gop.found_existing) {
            if (gop.value_ptr.already_seen) std.debug.panic("TODO saw file more than once while scanning: {f}", .{path.formatUtf8()});
            gop.value_ptr.already_seen = true;
            if (!gop.value_ptr.directory) std.debug.panic("TODO a regular file was changed into a directory: {f}", .{path.formatUtf8()});

            switch (gop.value_ptr.status) {
                .new => {
                    if (set_to_untracked) std.debug.panic("TODO set a new file to untracked: {f}", .{path.formatUtf8()});
                    ctx.locked.updateNewFile(path, local_file_id, meta);
                },
                .untracked => std.debug.panic("TODO handle untracked folder: {f}", .{path.formatUtf8()}),
                .tracked => {
                    if (set_to_untracked) std.debug.panic("TODO set a tracked directory to untracked: {f}", .{path.formatUtf8()});
                    ctx.locked.updateTrackedDirectoryFile(path, local_file_id, meta);
                },
            }
        } else {
            errdefer ctx.set_of_tracked_files.removeByPtr(gop.key_ptr);

            var path_arena = ctx.locked.db.path_arena.promote(ctx.locked.db.allocator);
            defer ctx.locked.db.path_arena = path_arena.state;
            const path_allocator = path_arena.allocator();

            const path_copy = try path.dupe(path_allocator);
            errdefer path_allocator.free(path_copy.slice);

            gop.key_ptr.* = path_copy;
            gop.value_ptr.* = .{ .status = undefined, .directory = true, .already_seen = true };

            const parent = ctx.parent_paths.getLast();
            if (set_to_untracked) {
                std.debug.panic("TODO handle untracked folder: {f}", .{path.formatUtf8()});
            } else {
                try ctx.locked.addFile(true, .new, path_copy, parent, local_file_id, meta);
                gop.value_ptr.status = .new;
            }
        }
    }

    fn deleteFiles(ctx: *Context) !void {
        var it = ctx.set_of_tracked_files.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.already_seen) continue;
            const path = entry.key_ptr.*;
            switch (entry.value_ptr.status) {
                .new => std.debug.panic("TODO delete a new file: {f}", .{path.formatUtf8()}),
                .tracked => switch (entry.value_ptr.directory) {
                    false => try ctx.locked.deleteTrackedRegularFile(path),
                    true => std.debug.panic("TODO delete a tracked directory: {f}", .{path.formatUtf8()}),
                },
                .untracked => std.debug.panic("TODO delete an untracked file: {f}", .{path.formatUtf8()}),
            }
        }
    }
};

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
                    .send_metadata => try out_file_contents.sendMetadata(host, tx_id, host.tx.peer_tx_id, io, writer),
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
                        .state = .send_metadata,
                        .file_id = host.db.out_file_id,
                        .path = host.db.out_path,
                        .size = host.db.out_metadata.size,
                        .hash = host.db.out_metadata.hash,
                    },
                };
                host.tx.peer_tx_id = .invalid;

                host.db.out_file_id = undefined;
                host.db.out_path = undefined;
                host.db.out_metadata = undefined;
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
        network.Reader.ReceiveFileMetadataError ||
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
                            .send_metadata, .send_file_contents => unreachable,
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
                            .send_metadata, .send_file_contents => unreachable,
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
            try writer.sendPathByteCount(out_new_file.path.byteCount());
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
                        try locked.setNewFileId(out_new_file.path, out_new_file.kind, file_id_list.items, io);
                    }

                    host.debugLog("received file id {} for file {f}\n", .{ @intFromEnum(file_id_list.items[0]), out_new_file.path.formatUtf8() });
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
        size: w.ULARGE_INTEGER,
        hash: network.FileHash,

        pub const State = enum {
            send_metadata,
            receive_decision,
            send_file_contents,
            receive_result,
        };

        fn sendMetadata(
            out_file_contents: *OutFileContents,
            host: *Host,
            tx_id: network.TransactionId,
            peer_tx_id: network.TransactionId,
            io: Io,
            writer: network.Writer,
        ) !void {
            assert(out_file_contents.state == .send_metadata);
            assert(peer_tx_id == .invalid);

            const action: network.Action = .transfer_file_metadata;
            host.logMessage(.outgoing, tx_id, action, peer_tx_id);

            const file_size = std.math.cast(network.FileSize, out_file_contents.size) orelse
                std.debug.panic(
                    "TODO: File too large to transfer: '{f}' with size {}",
                    .{ out_file_contents.path.formatUtf8(), out_file_contents.size },
                );

            out_file_contents.state = .receive_decision;
            host.flipTransaction(.incoming, tx_id, io);

            try writer.sendMessageHeaderNewTx(tx_id);
            try writer.sendAction(action);
            try writer.sendFileMetadata(out_file_contents.file_id, file_size, &out_file_contents.hash);
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

            const handle = try host.db.openFileReadOnly(out_file_contents.path);
            defer host.db.closeFile(handle);

            out_file_contents.state = .receive_result;
            host.flipTransaction(.incoming, tx_id, io);

            try writer.sendMessageHeaderExistingTx(peer_tx_id);
            try writer.sendAction(action);
            try fairy.windows.sendFile(writer.io, handle, out_file_contents.size);
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
                        try locked.markFileAsSynced(out_file_contents.file_id);
                    }
                    host.debugLog("successfully synced file: {f}\n", .{out_file_contents.path.formatUtf8()});
                },
                .transfer_file_failure => {
                    // TODO mark file as failed to sync
                    {
                        const locked = try host.db.lock(io);
                        defer locked.unlock(io);
                        try locked.markFileAsSynced(out_file_contents.file_id);
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
                    host.debugLog(
                        "create dir with id {} name {f}\n",
                        .{ @intFromEnum(out_create_dir.file_id), out_create_dir.path.formatUtf8() },
                    );
                    host.deleteTransaction(tx_id, .incoming, io);
                },
                .not_a_directory, .unknown_file, .unexpected => {
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
                        try locked.confirmDeleteFile(out_delete_file.file_id);
                    }
                    host.deleteTransaction(tx_id, .incoming, io);
                },
                else => return error.InvalidAction,
            }
        }
    };
};
