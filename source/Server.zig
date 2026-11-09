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
events: Events,
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
        .events = .init,
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
    server.events.deinit(server.allocator);
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
    history: std.ArrayList(u8),
    revisions: std.ArrayList(usize),

    pub const FileInfo = struct {
        status: Status,
        directory: bool,
        path: Path,
        component: Path,
        parent: ?network.FileId,

        pub const Status = enum {
            new,
            synced,
            deleted,
        };
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

pub const Events = struct {
    /// Controls when the event loop wakes up.
    /// Does not protect a critical section.
    alert: std.atomic.Value(Alert),
    delete: std.AutoArrayHashMapUnmanaged(network.FileId, void),
    sync: std.AutoHashMapUnmanaged(network.FileId, struct { canceled: bool = false }),

    pub const Alert = enum(u32) { sleep, wake };

    const init: Events = .{
        .alert = .init(.sleep),
        .delete = .empty,
        .sync = .empty,
    };

    fn deinit(events: *Events, allocator: Allocator) void {
        events.delete.deinit(allocator);
        events.sync.deinit(allocator);
    }

    fn queueDeleteEventAssumeCapacity(events: *Events, file_id: network.FileId, io: Io) void {
        if (events.sync.getPtr(file_id)) |sync| {
            sync.canceled = true;
        }
        events.delete.putAssumeCapacityNoClobber(file_id, {});
        events.alert.store(.wake, .monotonic);
        io.futexWake(Events.Alert, &events.alert.raw, 1);
    }
};

pub fn eventLoop(server: *Server, io: Io) !void {
    while (true) {
        if (server.events.alert.cmpxchgStrong(.wake, .sleep, .monotonic, .monotonic)) |_| {
            try io.futexWait(Events.Alert, &server.events.alert.raw, .sleep);
            continue;
        }

        try server.mutex.lock(io);

        if (server.events.delete.count() > 0) {
            const file_id = server.events.delete.keys()[0];

            // Delete events should cancel sync events.
            if (server.events.sync.get(file_id)) |value| {
                assert(value.canceled);
            }

            const info = server.db.files.getPtr(file_id).?;
            assert(info.status == .deleted);
            const path, const directory = .{ info.path, info.directory };
            server.mutex.unlock(io);

            switch (directory) {
                true => {
                    // TODO: Treat file not found as success
                    switch (fairy.platform) {
                        .windows => try fairy.windows.deleteTree(server.sync_dir, path, server.allocator),
                        .linux => try server.sync_dir.deleteTree(io, path.slice),
                    }

                    server.mutex.lockUncancelable(io);
                    defer server.mutex.unlock(io);

                    server.events.delete.orderedRemoveAt(0);

                    const Item = struct {
                        children: []const network.FileId,
                        index: fairy.FileCount = 0,
                        state: State = .iterate,

                        const State = enum { iterate, delete };
                    };
                    var stack: [fairy.max_path_components]Item = undefined;

                    const root_dir_entry = server.db.directory_file_info.getEntry(file_id).?;
                    stack[0] = .{ .children = root_dir_entry.value_ptr.children.keys() };

                    var stack_len: fairy.PathComponentCount = 1;
                    while (stack_len > 0) {
                        const item = &stack[stack_len - 1];
                        if (item.index == item.children.len) {
                            item.* = undefined;
                            stack_len -= 1;
                            continue;
                        }

                        const child_file_id = item.children[item.index];
                        const child_info = server.db.files.getEntry(child_file_id).?;

                        if (child_info.value_ptr.directory and item.state == .iterate) enter_dir: {
                            const dir_entry = server.db.directory_file_info.getPtr(child_file_id).?;
                            const children = dir_entry.children.keys();
                            if (children.len == 0) break :enter_dir;

                            item.state = .delete;
                            stack[stack_len] = .{ .children = children };
                            stack_len += 1;
                            continue;
                        }

                        if (child_info.value_ptr.directory) {
                            item.state = .iterate;
                            assert(server.db.directory_file_info.remove(child_file_id));
                        } else {
                            assert(server.db.regular_file_info.remove(child_file_id));
                        }
                        server.db.files.removeByPtr(child_info.key_ptr);

                        item.index += 1;
                    }

                    assert(server.db.files.remove(file_id));
                    server.db.directory_file_info.removeByPtr(root_dir_entry.key_ptr);
                },
                false => {
                    // TODO: Treat file not found as success
                    switch (fairy.platform) {
                        .windows => try fairy.windows.deleteFile(server.sync_dir, path),
                        .linux => try server.sync_dir.deleteFile(io, path.slice),
                    }

                    server.mutex.lockUncancelable(io);
                    defer server.mutex.unlock(io);

                    server.events.delete.orderedRemoveAt(0);
                    assert(server.db.files.remove(file_id));
                    assert(server.db.regular_file_info.remove(file_id));
                },
            }

            continue;
        }

        server.mutex.unlock(io);
    }
}

const Diagnostics = union {
    client: Client,
    global: Global,
    internal: Internal,

    /// Client-side errors; usually because the client is out of sync.
    const Client = error{
        UnknownFileId,
        NotRegularFile,
        NotDirectoryFile,
        FileAlreadyExists,
    };

    /// Errors that arise because of operations that cannot be completed.
    const Global = error{
        ExhaustedRevisionIds,
        ExhaustedFileIds,
    };

    /// Internal server errors.
    const Internal = Allocator.Error ||
        switch (fairy.platform) {
            .windows => error{Unexpected},
            .linux => Io.Dir.DeleteFileError ||
                Io.Dir.DeleteDirError,
        };

    fn errClient(diag: *Diagnostics, value: Client) error{Client} {
        diag.* = .{ .client = value };
        return error.Client;
    }

    fn errGlobal(diag: *Diagnostics, value: Global) error{Global} {
        diag.* = .{ .global = value };
        return error.Global;
    }

    fn errInternal(diag: *Diagnostics, value: Internal) error{Internal} {
        diag.* = .{ .internal = value };
        return error.Internal;
    }
};

/// Creates a regular file for writing to. Creates parent directories as necessary.
fn createRegularFileWindows(server: *Server, full_path: Path, file_size: w.LARGE_INTEGER) !w.HANDLE {
    // TODO: Take the parent dir as a parameter instead of the server
    // TODO: We must check that the opened dirs have the same case as in `full_path`
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

/// Creates a regular file for writing to. Creates parent directories as necessary.
fn createRegularFileLinux(server: *Server, full_path: Path, io: Io) !Io.File {
    // TODO: Take the parent dir as a parameter instead of the server
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

    return try dir_handle.createFile(io, last_component.slice, .{ .truncate = true });
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

    pub fn printRevision(debug: *Debug, writer: *Io.Writer, io: Io, revision: network.RevisionId) !void {
        const server: *Server = @alignCast(@fieldParentPtr("debug", debug));
        try server.mutex.lock(io);
        defer server.mutex.unlock(io);

        const revision_number = @backingInt(revision);
        if (revision_number == 0) {
            try writer.writeAll("initial revision\n");
            return;
        }
        if (revision_number - 1 >= server.db.revisions.items.len) return error.InvalidRevision;
        const history = blk: {
            const begin = if (revision_number != 1) server.db.revisions.items[revision_number - 2] else 0;
            const end = server.db.revisions.items[revision_number - 1];
            break :blk server.db.history.items[begin..end];
        };
        var reader = Io.Reader.fixed(history);
        while (true) {
            const entry = reader.takeEnum(network.history.Entry, network.endian) catch |err| switch (err) {
                error.EndOfStream => break,
                error.InvalidEnumTag, error.ReadFailed => unreachable,
            };
            switch (entry) {
                .create => {
                    const create = reader.takeStruct(network.history.Create, network.endian) catch unreachable;
                    try writer.print(
                        "create: kind={s}, parent={?f}, length={}\n",
                        .{ @tagName(create.kind), if (!create.top_level) create.parent else null, create.num_new_files },
                    );
                    for (0..create.num_new_files) |_| {
                        const file_id = reader.takeEnumNonexhaustive(network.FileId, network.endian) catch unreachable;
                        const component = (reader.takeDelimiter(0) catch unreachable).?;
                        try writer.print("\tid={f}, name={f}\n", .{ file_id, std.unicode.fmtUtf8(component) });
                    }
                },
                .delete => {
                    const delete = reader.takeStruct(network.history.Delete, network.endian) catch unreachable;
                    try writer.print(
                        "delete: kind={s}, id={f}\n",
                        .{ @tagName(delete.kind), delete.file_id },
                    );
                },
                else => std.debug.panic("TODO", .{}),
            }
        }
    }
};

const Locked = struct {
    server: *Server,

    fn unlock(locked: Locked, io: Io) void {
        locked.server.mutex.unlock(io);
    }

    fn ensureUnusedRevision(locked: Locked, diag: *Diagnostics) error{ Global, Internal }!void {
        if (locked.server.db.revisions.items.len == std.math.maxInt(std.meta.Tag(network.RevisionId)) - 1) {
            return diag.errGlobal(error.ExhaustedRevisionIds);
        }
        locked.server.db.revisions.ensureUnusedCapacity(locked.server.allocator, 1) catch |err| return diag.errInternal(err);
    }

    fn createRevisionAssumeAvailable(locked: Locked) network.RevisionId {
        locked.server.db.revisions.appendAssumeCapacity(locked.server.db.history.items.len);
        const int: std.meta.Tag(network.RevisionId) = @intCast(locked.server.db.revisions.items.len);
        locked.server.debug.log(.info, "created revision {}", .{int});
        return @fromBackingInt(int);
    }

    fn newFile(
        locked: Locked,
        path_unowned: Path,
        kind: network.FileKind,
        diag: *Diagnostics,
    ) error{ Client, Global, Internal }!network.FileId {
        const s = locked.server;

        var it = path_unowned.pathIterator();
        var parent_file_id: ?network.FileId = null;
        // TODO: Calculate the number of components earlier
        var num_new_files = path_unowned.componentCount();
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
                    if (!file_info.directory) return diag.errClient(error.NotDirectoryFile);
                    component = next;
                    parent_dir_entry = s.db.directory_file_info.getPtr(file_id).?;
                    parent_file_id = file_id;
                    num_new_files -= 1;
                } else {
                    return diag.errClient(error.FileAlreadyExists);
                }
            }
        }

        var path_arena = s.path_arena.promote(s.allocator);
        defer s.path_arena = path_arena.state;
        const path_allocator = path_arena.allocator();
        const path = path_unowned.dupe(path_allocator) catch |err| return diag.errInternal(err);
        errdefer path_allocator.free(path.slice);

        var children_arena = s.children_arena.promote(s.allocator);
        defer s.children_arena = children_arena.state;
        const children_allocator = children_arena.allocator();

        const is_directory = switch (kind) {
            .directory => true,
            .regular => false,
        };
        try locked.ensureUnusedRevision(diag);
        try locked.ensureUnusedFileIds(num_new_files, diag);
        s.db.files.ensureUnusedCapacity(s.allocator, num_new_files) catch |err| return diag.errInternal(err);
        s.db.regular_file_info.ensureUnusedCapacity(s.allocator, @intFromBool(!is_directory)) catch |err| return diag.errInternal(err);
        s.db.directory_file_info.ensureUnusedCapacity(s.allocator, num_new_files - @intFromBool(!is_directory)) catch |err| return diag.errInternal(err);
        const history_needed_capacity = @sizeOf(network.history.Entry) +
            @sizeOf(network.history.Create) +
            @as(usize, num_new_files) * (@sizeOf(network.FileId) + Path.component_max_len + 1);
        s.db.history.ensureUnusedCapacity(s.allocator, history_needed_capacity) catch |err| return diag.errInternal(err);
        errdefer comptime unreachable;

        var history_writer = Io.Writer.Allocating.fromArrayList(s.allocator, &s.db.history);
        defer {
            s.db.history = history_writer.toArrayList();
            const revision = locked.createRevisionAssumeAvailable();
            _ = revision; // TODO
        }
        const history = &history_writer.writer;

        history.writeInt(std.meta.Tag(network.history.Entry), @backingInt(network.history.Entry.create), network.endian) catch unreachable;
        history.writeStruct(network.history.Create{
            .kind = kind,
            .num_new_files = num_new_files,
            .top_level = (parent_file_id == null),
            .parent = parent_file_id orelse @fromBackingInt(0x12345678),
        }, network.endian) catch unreachable;

        it.replacePath(path);
        var item = it.nextPathComponent().?;
        var parent_dir_entry = if (parent_file_id) |file_id| s.db.directory_file_info.getPtr(file_id).? else &s.db.sync_dir_entry;
        while (true) {
            const file_id = locked.nextFileIdAssumeAvailable();
            parent_dir_entry.children.putNoClobber(children_allocator, file_id, {}) catch |err| std.debug.panic("TODO: {s}", .{@errorName(err)});
            parent_dir_entry.children_by_component.putNoClobber(children_allocator, item.component, file_id) catch |err| std.debug.panic("TODO: {s}", .{@errorName(err)});

            history.writeInt(std.meta.Tag(network.FileId), @backingInt(file_id), network.endian) catch unreachable;
            switch (fairy.platform) {
                .windows => {
                    var wtf8_buffer: [255]u8 = undefined;
                    history.writeAll(item.component.componentToWtf8(&wtf8_buffer)) catch unreachable;
                },
                .linux => history.writeAll(item.component.slice) catch unreachable,
            }
            history.writeByte(0) catch unreachable;

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
                return file_id;
            }
        }
    }

    fn ensureUnusedFileIds(locked: Locked, num: std.meta.Tag(network.FileId), diag: *Diagnostics) error{Global}!void {
        assert(num > 0);
        const next = locked.server.next_file_id orelse return diag.errGlobal(error.ExhaustedFileIds);
        _ = std.math.add(std.meta.Tag(network.FileId), next, num - 1) catch return diag.errGlobal(error.ExhaustedFileIds);
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
        db.files.putAssumeCapacityNoClobber(file_id, .{
            .status = .new,
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

        db.files.putAssumeCapacityNoClobber(file_id, .{
            .status = .synced,
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
    ) []network.FileId {
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

    fn getRegularFilePath(locked: Locked, file_id: network.FileId, diag: *Diagnostics) error{Client}!Path {
        const info = locked.server.db.files.getPtr(file_id) orelse return diag.errClient(error.UnknownFileId);
        if (info.directory) return diag.errClient(error.NotRegularFile);
        return info.path;
    }

    fn deleteGlobalFile(
        locked: Locked,
        file_id: network.FileId,
        io: Io,
        diag: *Diagnostics,
    ) error{ Client, Global, Internal }!void {
        const s = locked.server;

        const file_info = s.db.files.getPtr(file_id) orelse return diag.errClient(error.UnknownFileId);
        switch (file_info.status) {
            .new => std.debug.panic("TODO", .{}),
            .synced => {},
            .deleted => return diag.errClient(error.UnknownFileId),
        }
        if (file_info.directory) return diag.errClient(error.NotRegularFile);

        try locked.ensureUnusedRevision(diag);
        const history_needed_capacity = @sizeOf(network.history.Entry) +
            @sizeOf(network.history.Delete);
        s.db.history.ensureUnusedCapacity(s.allocator, history_needed_capacity) catch |err| return diag.errInternal(err);
        s.events.delete.ensureUnusedCapacity(s.allocator, 1) catch |err| return diag.errInternal(err);
        errdefer comptime unreachable;

        file_info.status = .deleted;

        const parent_children = if (file_info.parent) |parent_file_id|
            s.db.directory_file_info.getPtr(parent_file_id).?
        else
            &s.db.sync_dir_entry;
        assert(parent_children.children.swapRemove(file_id));
        assert(parent_children.children_by_component.swapRemove(file_info.component));

        var history_writer = Io.Writer.Allocating.fromArrayList(s.allocator, &s.db.history);
        defer {
            s.db.history = history_writer.toArrayList();
            const revision = locked.createRevisionAssumeAvailable();
            _ = revision; // TODO
        }
        const history = &history_writer.writer;

        history.writeInt(std.meta.Tag(network.history.Entry), @backingInt(network.history.Entry.delete), network.endian) catch unreachable;
        history.writeStruct(network.history.Delete{
            .kind = .regular,
            .file_id = file_id,
        }, network.endian) catch unreachable;

        s.events.queueDeleteEventAssumeCapacity(file_id, io);
    }

    /// Sets all files within a tree to the deleted status.
    fn deleteGlobalDir(
        locked: Locked,
        root_file_id: network.FileId,
        io: Io,
        diag: *Diagnostics,
    ) error{ Client, Global, Internal }!void {
        const s = locked.server;

        const root_info = s.db.files.getPtr(root_file_id) orelse return diag.errClient(error.UnknownFileId);
        switch (root_info.status) {
            .new => std.debug.panic("TODO", .{}),
            .synced => {},
            .deleted => return diag.errClient(error.UnknownFileId),
        }
        if (!root_info.directory) return diag.errClient(error.NotDirectoryFile);

        try locked.ensureUnusedRevision(diag);
        const history_needed_capacity = @sizeOf(network.history.Entry) +
            @sizeOf(network.history.Delete);
        s.db.history.ensureUnusedCapacity(s.allocator, history_needed_capacity) catch |err| return diag.errInternal(err);
        s.events.delete.ensureUnusedCapacity(s.allocator, 1) catch |err| return diag.errInternal(err);
        errdefer comptime unreachable;

        root_info.status = .deleted;

        const Item = struct {
            children: []const network.FileId,
            index: fairy.FileCount = 0,
        };
        var buffer: [fairy.max_path_components]Item = undefined;
        var stack = std.ArrayList(Item).initBuffer(&buffer);
        stack.appendAssumeCapacity(.{ .children = s.db.directory_file_info.getPtr(root_file_id).?.children.keys() });
        while (stack.lastPtr()) |item| {
            if (item.index == item.children.len) {
                _ = stack.pop();
                continue;
            }

            const file_id = item.children[item.index];
            item.index += 1;
            const info = s.db.files.getPtr(file_id).?;
            switch (info.status) {
                .new => std.debug.panic("TODO", .{}),
                .synced => info.status = .deleted,
                .deleted => continue,
            }
            // TODO: cancel sync events

            if (info.directory) {
                const dir_info = s.db.directory_file_info.getPtr(file_id).?;
                const children = dir_info.children.keys();
                if (children.len != 0) {
                    stack.appendAssumeCapacity(.{ .children = children });
                }
            }
        }

        const parent_dir_info = if (root_info.parent) |parent_file_id|
            s.db.directory_file_info.getPtr(parent_file_id).?
        else
            &s.db.sync_dir_entry;
        assert(parent_dir_info.children.swapRemove(root_file_id));
        assert(parent_dir_info.children_by_component.swapRemove(root_info.component));

        var history_writer = Io.Writer.Allocating.fromArrayList(s.allocator, &s.db.history);
        defer {
            s.db.history = history_writer.toArrayList();
            const revision = locked.createRevisionAssumeAvailable();
            _ = revision; // TODO
        }
        const history = &history_writer.writer;

        history.writeInt(std.meta.Tag(network.history.Entry), @backingInt(network.history.Entry.delete), network.endian) catch unreachable;
        history.writeStruct(network.history.Delete{
            .kind = .directory,
            .file_id = root_file_id,
        }, network.endian) catch unreachable;
        s.events.queueDeleteEventAssumeCapacity(root_file_id, io);
    }
};

pub const Host = struct {
    setup: std.atomic.Value(Setup),
    mt: MessageThread,
    mt_status: std.atomic.Value(MtStatus),
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

    pub const MtStatus = enum(u32) {
        /// The message thread is free to use.
        init,
        /// The message thread is locked and owned by the outgoing task.
        outgoing,
        /// The message thread is locked and owned by the outgoing task, which is currently transmitting data.
        transmitting,
        /// The message thread is locked and owned by the incoming task.
        incoming,
    };

    pub fn init(server: *Server, debug: Host.Debug) Host {
        return .{
            .setup = .init(.send_platform),
            .mt = undefined,
            .mt_status = .init(.init),
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
        diag: ?*Host.Diagnostics,
        io: Io,
        reader: *Io.Reader,
        writer: *Io.Writer,
    ) RunError!void {
        const ns = struct {
            const SelectUnion = union(enum) {
                send_error: SendError!void,
                recv_error: RecvError!void,
            };

            fn addToDiagnostics(d: ?*Host.Diagnostics, u: SelectUnion) void {
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
            try writer.sendPlatform(fairy.platform);
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
                const mt_status = host.mt_status.load(.acquire);
                if (mt_status == .outgoing) break;
                try io.futexWait(MtStatus, &host.mt_status.raw, mt_status);
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
            switch (header) {
                .disconnect => break,
                .new_thread => {
                    while (host.mt_status.cmpxchgStrong(.init, .incoming, .acquire, .monotonic)) |current_value| {
                        switch (current_value) {
                            .init, .incoming => unreachable,
                            .outgoing => return error.UnexpectedIncomingMessage,
                            .transmitting => try io.futexWait(MtStatus, &host.mt_status.raw, .transmitting),
                        }
                    }

                    const action = try reader.receiveAction();
                    host.logMessage(.incoming, action);
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
                    return error.UnexpectedIncomingMessage;
                },
                .sync_file_request => {
                    return error.UnexpectedIncomingMessage;
                },
                .sync_file_response => std.debug.panic("TODO", .{}),
            }
        }
    }

    fn setOutgoingMessage(host: *Host, io: Io, data: MessageThread) void {
        host.mt = data;
        assert(host.mt_status.cmpxchgStrong(.incoming, .outgoing, .release, .monotonic) == null);
        io.futexWake(MtStatus, &host.mt_status.raw, 1);
    }

    fn beginTransmitting(host: *Host) void {
        assert(host.mt_status.cmpxchgStrong(.outgoing, .transmitting, .acq_rel, .monotonic) == null);
    }

    fn deleteMessageThread(host: *Host, io: Io) void {
        host.mt = undefined;
        assert(host.mt_status.cmpxchgStrong(.transmitting, .init, .release, .monotonic) == null);
        io.futexWake(MtStatus, &host.mt_status.raw, 1);
    }

    fn receiveSyncFileResponse(host: *Host, io: Io, reader: network.Reader) !void {
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
                    var diag: Server.Diagnostics = undefined;
                    break :blk locked.getRegularFilePath(file_id, &diag) catch |err| switch (err) {
                        error.Client => std.debug.panic("TODO: Client error: {s}", .{@errorName(diag.client)}),
                    };
                };
                const handle = host.server.createRegularFileWindows(path, file_size) catch |err| switch (err) {
                    error.Unexpected => |e| return e,
                };
                defer fairy.windows.closeHandle(handle);
                try fairy.windows.receiveFile(reader.io, handle, file_size);
                {
                    const locked = try host.server.lock(io);
                    defer locked.unlock(io);
                    const info = locked.server.db.files.getPtr(file_id) orelse std.debug.panic("TODO", .{});
                    switch (info.status) {
                        .new => info.status = .synced,
                        .synced => {},
                        .deleted => {},
                    }
                }
            },
            .linux => {
                const file_size = try reader.receiveFileSize();
                const path = blk: {
                    const locked = try host.server.lock(io);
                    defer locked.unlock(io);
                    var diag: Server.Diagnostics = undefined;
                    break :blk locked.getRegularFilePath(file_id, &diag) catch |err| switch (err) {
                        error.Client => std.debug.panic("TODO: Client error: {s}", .{@errorName(diag.client)}),
                    };
                };
                const file = host.server.createRegularFileLinux(path, io) catch |err| switch (err) {
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

    }

    fn debugLog(host: *const Host, comptime fmt: []const u8, args: anytype) void {
        fairy.log.debug("(host:{s}) " ++ fmt, .{host.debug.name} ++ args);
    }

    fn logMessage(
        host: *const Host,
        comptime mt_status: MtStatus,
        action: network.Action,
    ) void {
        switch (mt_status) {
            .init, .transmitting => comptime unreachable,
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
        result: network.FileId,

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
                .windows => try reader.receiveWindowsPath(path_byte_count, &file_path_buffer),
                .linux => try reader.receiveLinuxPath(path_byte_count, &file_path_buffer),
            };
            const file_id = blk: {
                const locked = try host.server.lock(io);
                defer locked.unlock(io);

                var diag: Server.Diagnostics = undefined;
                break :blk locked.newFile(path, kind, &diag) catch |err| switch (err) {
                    error.Global => std.debug.panic("TODO: Global error: {s}", .{@errorName(diag.global)}),
                    error.Client => std.debug.panic("TODO: Client error: {s}", .{@errorName(diag.client)}),
                    error.Internal => std.debug.panic("TODO: Internal error: {s}", .{@errorName(diag.internal)}),
                };
            };

            const data: MessageThread = .{
                .in_new_file = .{
                    .result = file_id,
                },
            };
            host.setOutgoingMessage(io, data);
        }

        fn sendDecision(
            in_new_file: *const InNewFile,
            host: *Host,
            io: Io,
            writer: network.Writer,
        ) !void {
            const action: network.Action = .resolve_path_response;
            host.logMessage(.outgoing, action);

            var reverse_file_ids_buffer: [fairy.max_path_components]network.FileId = undefined;
            const reversed_file_id_path = blk: {
                const locked = try host.server.lock(io);
                defer locked.unlock(io);
                break :blk locked.getReverseFileIdPath(in_new_file.result, &reverse_file_ids_buffer);
            };

            host.beginTransmitting();

            try writer.sendMessageHeader(.thread_reply);
            try writer.sendAction(action);
            for (0..reversed_file_id_path.len) |index| {
                try writer.sendFileId(reversed_file_id_path[reversed_file_id_path.len - 1 - index]);
            }
            try writer.flush();

            host.deleteMessageThread(io);
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
                        var diag: Server.Diagnostics = undefined;
                        break :blk locked.getRegularFilePath(file_id, &diag) catch |err| switch (err) {
                            error.Client => std.debug.panic("TODO: Client error: {s}", .{@errorName(diag.client)}),
                        };
                    };
                    const handle = host.server.createRegularFileWindows(path, file_size) catch |err| switch (err) {
                        error.Unexpected => |e| return e,
                    };
                    defer fairy.windows.closeHandle(handle);
                    try fairy.windows.receiveFile(reader.io, handle, file_size);
                    {
                        const locked = try host.server.lock(io);
                        defer locked.unlock(io);
                        const info = locked.server.db.files.getPtr(file_id) orelse std.debug.panic("TODO", .{});
                        switch (info.status) {
                            .new => info.status = .synced,
                            .synced => {},
                            .deleted => {},
                        }
                    }
                },
                .linux => {
                    const file_size = try reader.receiveFileSize();
                    const path = blk: {
                        const locked = try host.server.lock(io);
                        defer locked.unlock(io);
                        var diag: Server.Diagnostics = undefined;
                        break :blk locked.getRegularFilePath(file_id, &diag) catch |err| switch (err) {
                            error.Client => std.debug.panic("TODO: Client error: {s}", .{@errorName(diag.client)}),
                        };
                    };
                    const file = host.server.createRegularFileLinux(path, io) catch |err| switch (err) {
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
            host.setOutgoingMessage(io, data);
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

            host.beginTransmitting();

            try writer.sendMessageHeader(.thread_reply);
            try writer.sendAction(action);
            try writer.flush();

            host.deleteMessageThread(io);
        }
    };

    pub const InDeleteFile = struct {
        fn initMessageThread(
            host: *Host,
            io: Io,
            reader: network.Reader,
        ) !void {
            const file_id = try reader.receiveFileId();
            {
                const locked = try host.server.lock(io);
                defer locked.unlock(io);
                var diag: Server.Diagnostics = undefined;
                locked.deleteGlobalFile(file_id, io, &diag) catch |err| switch (err) {
                    error.Client => std.debug.panic("TODO: Client error: {s}", .{@errorName(diag.client)}),
                    error.Global => std.debug.panic("TODO: Global error: {s}", .{@errorName(diag.global)}),
                    error.Internal => std.debug.panic("TODO: Internal error: {s}", .{@errorName(diag.internal)}),
                };
            }

            const data: MessageThread = .{
                .in_delete_file = .{},
            };
            host.setOutgoingMessage(io, data);
        }

        fn sendConfirmation(
            _: *InDeleteFile,
            host: *Host,
            io: Io,
            writer: network.Writer,
        ) !void {
            const action: network.Action = .delete_file_confirm;
            host.logMessage(.outgoing, action);

            host.beginTransmitting();

            try writer.sendMessageHeader(.thread_reply);
            try writer.sendAction(action);
            try writer.flush();

            host.deleteMessageThread(io);
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
                var diag: Server.Diagnostics = undefined;
                locked.deleteGlobalDir(file_id, io, &diag) catch |err| switch (err) {
                    error.Client => std.debug.panic("TODO: Client error: {s}", .{@errorName(diag.client)}),
                    error.Global => std.debug.panic("TODO: Global error: {s}", .{@errorName(diag.global)}),
                    error.Internal => std.debug.panic("TODO: Internal error: {s}", .{@errorName(diag.internal)}),
                };
            }

            const data: MessageThread = .{
                .in_delete_dir = .{},
            };
            host.setOutgoingMessage(io, data);
        }

        fn sendConfirmation(
            _: *InDeleteDir,
            host: *Host,
            io: Io,
            writer: network.Writer,
        ) !void {
            const action: network.Action = .delete_dir_confirm;
            host.logMessage(.outgoing, action);

            host.beginTransmitting();

            try writer.sendMessageHeader(.thread_reply);
            try writer.sendAction(action);
            try writer.flush();

            host.deleteMessageThread(io);
        }
    };
};
