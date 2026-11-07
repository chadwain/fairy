const std = @import("std");
const assert = std.debug.assert;
const printf = std.debug.print;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fairy = @import("fairy");
const build_options = @import("build-options");
const host_type = build_options.host_type;

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
    //       https://codeberg.org/ziglang/zig/issues/31112
    var threaded_io = std.Io.Threaded.init(allocator, .{});
    defer threaded_io.deinit();
    const io = threaded_io.io();

    const args = try Args.init(init.args, &arena);
    const port = try args.port();
    const addr = try Io.net.IpAddress.parseIp4("127.0.0.1", port);
    const sync_dir = switch (fairy.platform) {
        .windows => try std.unicode.wtf8ToWtf16LeAllocZ(allocator, args.syncDir()),
        .linux => args.syncDir(),
    };
    defer switch (fairy.platform) {
        .windows => allocator.free(sync_dir),
        .linux => {},
    };

    switch (host_type) {
        .server => {
            var net_server = try addr.listen(io, .{});
            defer net_server.deinit(io);

            while (net_server.accept(io)) |stream| {
                defer stream.close(io);

                var fairy_server = switch (fairy.platform) {
                    .windows => try fairy.Server.initWindows(sync_dir, allocator),
                    .linux => try fairy.Server.initLinux(sync_dir, io, allocator),
                };
                defer switch (fairy.platform) {
                    .windows => fairy_server.deinitWindows(),
                    .linux => fairy_server.deinitLinux(io),
                };

                const U = union(enum) {
                    loop: @typeInfo(@TypeOf(fairy.Server.eventLoop)).@"fn".return_type.?,
                    cli: @typeInfo(@TypeOf(runServerCli)).@"fn".return_type.?,
                    host: @typeInfo(@TypeOf(startHost)).@"fn".return_type.?,
                };
                var buffer: [3]U = undefined;
                var select = Io.Select(U).init(io, &buffer);
                defer select.cancelDiscard();

                try select.concurrent(.loop, fairy.Server.eventLoop, .{ &fairy_server, io });
                try select.concurrent(.host, startHost, .{ io, &fairy_server, stream });
                try select.concurrent(.cli, runServerCli, .{ io, &fairy_server });
                switch (try select.await()) {
                    .loop => continue,
                    .cli => |val| return try val,
                    .host => continue,
                }
            } else |err| return err;
        },
        .client => {
            var cdb = try fairy.client.Database.init(sync_dir, allocator, .{ .name = "client" });
            defer cdb.deinit();

            var cdb_run_task = try io.concurrent(fairy.client.Database.run, .{ &cdb, io });
            defer cdb_run_task.cancel(io) catch {};

            var host_task = try io.concurrent(startClientHost, .{ io, &cdb, addr });
            defer host_task.cancel(io) catch {};

            try runClientCli(io, &cdb);
        },
    }
}

fn print(message: []const u8) void {
    printf("{s}\n", .{message});
}

fn runClientCli(io: Io, cdb: *fairy.client.Database) !void {
    var stdin_buffer: [64]u8 = undefined;
    var stdin = Io.File.stdin().reader(io, &stdin_buffer);
    const reader = &stdin.interface;

    var stdout_file_writer = Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_file_writer.interface;

    const Command = enum {
        quit,
        print_files,
        print_local_events,
        scan,
        toggle_auto_scanning,
        help,
    };
    const commands = std.StaticStringMap(Command).initComptime(.{
        .{ "q", Command.quit },
        .{ "a", Command.print_files },
        .{ "e", Command.print_local_events },
        .{ "s", Command.scan },
        .{ "t", Command.toggle_auto_scanning },
        .{ "?", Command.help },
    });

    const help = comptime blk: {
        var msg: []const u8 = "";
        for (commands.keys(), commands.values(), 0..) |k, v, i| {
            msg = msg ++ "[" ++ k ++ "] " ++ @tagName(v) ++ (if (i != commands.kvs.len - 1) ", " else "\n");
        }
        break :blk msg;
    };
    printf("{s}", .{help});
    var disabled_auto_scanning = false;
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
            .print_files => {
                const locked = try cdb.lock(io);
                defer locked.unlock(io);
                try locked.debug.printFileEntries(stdout);
                try stdout.flush();
            },
            .print_local_events => {
                const locked = try cdb.lock(io);
                defer locked.unlock(io);
                try locked.debug.printLocalEvents(stdout);
                try stdout.flush();
            },
            .scan => {
                const locked = try cdb.lock(io);
                defer locked.unlock(io);
                try locked.manualScan(io);
                try stdout.writeAll("scan complete\n");
                try stdout.flush();
            },
            .toggle_auto_scanning => {
                if (disabled_auto_scanning) {
                    disabled_auto_scanning = false;
                    cdb.enableAutoScanning(io);
                } else {
                    disabled_auto_scanning = true;
                    cdb.disableAutoScanning();
                }
            },
            .help => printf("{s}", .{help}),
        }
    }
}

fn runServerCli(io: Io, server: *fairy.Server) !void {
    var stdin_buffer: [64]u8 = undefined;
    var stdin = Io.File.stdin().reader(io, &stdin_buffer);
    const reader = &stdin.interface;

    var stdout_file_writer = Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_file_writer.interface;

    const Command = enum {
        quit,
        print_files_folders,
        print_revision,
        help,
    };
    const commands = std.StaticStringMap(Command).initComptime(.{
        .{ "q", Command.quit },
        .{ "a", Command.print_files_folders },
        .{ "r", Command.print_revision },
        .{ "?", Command.help },
    });

    const help = comptime blk: {
        var msg: []const u8 = "";
        for (commands.keys(), commands.values(), 0..) |k, v, i| {
            msg = msg ++ "[" ++ k ++ "] " ++ @tagName(v) ++ (if (i != commands.kvs.len - 1) ", " else "\n");
        }
        break :blk msg;
    };
    printf("{s}", .{help});
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
        var splitter = std.mem.splitScalar(u8, line, ' ');
        switch (commands.get(splitter.first()) orelse {
            print("invalid command");
            continue;
        }) {
            .quit => break,
            .print_files_folders => {
                try server.debug.printFileEntries(stdout, io);
                try stdout.flush();
            },
            .print_revision => {
                const number = splitter.next() orelse {
                    print("invalid args");
                    continue;
                };
                const revision_number = std.fmt.parseInt(std.meta.Tag(fairy.network.RevisionId), number, 10) catch {
                    print("not a valid revision number");
                    continue;
                };
                server.debug.printRevision(stdout, io, @fromBackingInt(revision_number)) catch |err| {
                    printf("error: {s}\n", .{@errorName(err)});
                    continue;
                };
                try stdout.flush();
            },
            .help => printf("{s}", .{help}),
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

    fn port(args: Args) !u16 {
        return try std.fmt.parseInt(u16, args.slice[1], 10);
    }

    fn syncDir(args: Args) [:0]const u8 {
        return args.slice[2];
    }
};

const buffer_size = @max(fairy.network.min_reader_writer_buffer_size, 128);

fn startClientHost(io: Io, db: *fairy.client.Database, addr: Io.net.IpAddress) !void {
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    try startHost(io, db, stream);
}

fn startHost(
    io: Io,
    db: switch (host_type) {
        .server => *fairy.Server,
        .client => *fairy.client.Database,
    },
    stream: Io.net.Stream,
) !void {
    var read_buffer: [buffer_size]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var write_buffer: [buffer_size]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);

    const name = @tagName(host_type);
    const Host = switch (host_type) {
        .server => fairy.Server.Host,
        .client => fairy.client.Host,
    };
    var host = Host.init(db, .{ .name = name });
    defer host.deinit();
    var diag: Host.Diagnostics = .{};
    defer {
        printf("{s} send result: {s}, recv result: {s}\n", .{
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
