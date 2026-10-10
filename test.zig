const std = @import("std");
const assert = std.debug.assert;
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fairy = @import("fairy");

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    defer switch (debug_allocator.deinit()) {
        .leak => unreachable,
        .ok => {},
    };
    const allocator = debug_allocator.allocator();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // TODO: Much of our code does I/O outside of the std.Io interface, so using Io.Threaded is necessary for now.
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const args = try Args.init(init.args, &arena);

    const sync_dir = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, args.syncDir());
    defer allocator.free(sync_dir);
    const peer_sync_dir = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, args.peerSyncDir());
    defer allocator.free(peer_sync_dir);

    var cdb = try fairy.client.Database.init(sync_dir, allocator, .{ .name = "client" });
    defer cdb.deinit();

    var sdb = try fairy.server.Database.init(peer_sync_dir, allocator);
    defer sdb.deinit();

    var cdb_run_task = try io.concurrent(fairy.client.Database.run, .{ &cdb, io });
    defer cdb_run_task.cancel(io) catch {};

    var host_pair_task = try io.concurrent(startServerAndClient, .{ io, &cdb, &sdb });
    defer host_pair_task.cancel(io) catch {};

    try runCli(io, &cdb, &sdb);
}

fn runCli(io: Io, cdb: *fairy.client.Database, sdb: *fairy.server.Database) !void {
    var stdin_buffer: [64]u8 = undefined;
    var stdin = Io.File.stdin().reader(io, &stdin_buffer);
    const reader = &stdin.interface;

    var stdout_file_writer = Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_file_writer.interface;

    const Command = enum {
        quit,
        client_print_files,
        client_print_local_events,
        client_scan,
        server_print_files_folders,
        help,
    };
    const commands = std.StaticStringMap(Command).initComptime(.{
        .{ "q", Command.quit },
        .{ "a", Command.client_print_files },
        .{ "e", Command.client_print_local_events },
        .{ "s", Command.client_scan },
        .{ "sa", Command.server_print_files_folders },
        .{ "?", Command.help },
    });

    const help = comptime blk: {
        var msg: []const u8 = "";
        for (commands.keys(), commands.values(), 0..) |k, v, i| {
            msg = msg ++ "[" ++ k ++ "] " ++ @tagName(v) ++ (if (i != commands.kvs.len - 1) ", " else "\n");
        }
        break :blk msg;
    };
    print("{s}", .{help});
    while (true) {
        var line: []const u8 = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.ReadFailed, error.EndOfStream => |e| return e,
            error.StreamTooLong => {
                _ = try reader.discardDelimiterInclusive('\n');
                continue;
            },
        };
        reader.toss(1);
        line = std.mem.trimEnd(u8, line, "\r");

        switch (commands.get(line) orelse continue) {
            .quit => break,
            .client_print_files => {
                const locked = try cdb.lock(io);
                defer locked.unlock(io);
                try locked.debug.printFileEntries(stdout);
                try stdout.flush();
            },
            .client_print_local_events => {
                const locked = try cdb.lock(io);
                defer locked.unlock(io);
                try locked.debug.printLocalEvents(stdout);
                try stdout.flush();
            },
            .client_scan => {
                const locked = try cdb.lock(io);
                defer locked.unlock(io);
                try locked.manualScan(io);
                try stdout.writeAll("scan complete\n");
                try stdout.flush();
            },
            .server_print_files_folders => {
                try sdb.debug.printFileEntries(stdout, io);
                try stdout.flush();
            },
            .help => print("{s}", .{help}),
        }
    }
}

const Args = struct {
    slice: []const [:0]const u8,

    fn init(args: std.process.Args, arena: *std.heap.ArenaAllocator) !Args {
        const slice = try args.toSlice(arena.allocator());

        switch (slice.len) {
            3 => return .{ .slice = slice },
            else => return error.InvalidArguments,
        }
    }

    fn syncDir(args: Args) []const u8 {
        return args.slice[1];
    }

    fn peerSyncDir(args: Args) []const u8 {
        return args.slice[2];
    }
};

const buffer_size = @max(fairy.network.min_reader_writer_buffer_size, 128);

fn startServerAndClient(
    io: Io,
    client_db: *fairy.client.Database,
    server_db: *fairy.server.Database,
) !void {
    const addr = comptime Io.net.IpAddress.parseIp4("127.0.0.1", 0) catch unreachable;
    var server = try addr.listen(io, .{});
    defer server.deinit(io);

    var peer = try io.concurrent(startServer, .{ io, server_db, server.socket.address });
    defer peer.cancel(io) catch {};

    const stream = try server.accept(io);
    defer stream.close(io);
    print("connected\n", .{});

    var read_buffer: [buffer_size]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var write_buffer: [buffer_size]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    const name = "client";
    var host = fairy.client.Host.init(client_db, .{ .name = name });
    defer host.deinit();
    var diag: fairy.client.Host.Diagnostics = .{};
    defer {
        print("{s} send result: {s}, recv result: {s}\n", .{
            name,
            blk: {
                const err = diag.send_error orelse break :blk "OK";
                break :blk (if (err == error.WriteFailed) @errorName(writer.err.?) else @errorName(err));
            },
            blk: {
                const err = diag.recv_error orelse break :blk "OK";
                break :blk (if (err == error.ReadFailed) @errorName(reader.err.?) else @errorName(err));
            },
        });
    }
    try host.run(&diag, io, &reader.interface, &writer.interface);
}

fn startServer(io: Io, server_db: *fairy.server.Database, addr: Io.net.IpAddress) !void {
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var read_buffer: [buffer_size]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var write_buffer: [buffer_size]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    const name = "server";
    var host = fairy.server.Host.init(server_db, .{ .name = name });
    defer host.deinit();
    var diag: fairy.server.Host.Diagnostics = .{};
    defer {
        // TODO (Windows) this print statement randomly doesn't show up in the terminal for some reason
        print("{s} send result: {s}, recv result: {s}\n", .{
            name,
            blk: {
                const err = diag.send_error orelse break :blk "OK";
                break :blk (if (err == error.WriteFailed) @errorName(writer.err.?) else @errorName(err));
            },
            blk: {
                const err = diag.recv_error orelse break :blk "OK";
                break :blk (if (err == error.ReadFailed) @errorName(reader.err.?) else @errorName(err));
            },
        });
    }
    try host.run(&diag, io, &reader.interface, &writer.interface);
}
