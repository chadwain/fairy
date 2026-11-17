pub const client = @import("client.zig");
pub const network = @import("network.zig");
pub const Path = @import("Path.zig");
pub const Server = @import("Server.zig");
pub const windows = @import("windows.zig");

pub const log = @import("std").log.scoped(.fairy);

pub const Platform = enum(u8) { windows, linux };

pub const platform: Platform = switch (@import("builtin").target.os.tag) {
    .windows => .windows,
    .linux => .linux,
    else => @compileError("Unsupported OS"),
};

pub const FileCount = u32;

pub fn print(message: []const u8) void {
    @import("std").debug.print("{s}\n", .{message});
}

pub const printf = @import("std").debug.print;

comptime {
    if (@import("builtin").cpu.arch.endian() != .little) {
        // In particular, the Windows and Unicode parts of the stdlib have poor big endian support.
        @compileError("non-little endian CPUs are not supported");
    }

    if (@import("builtin").is_test) {
        _ = Path;
    }
}
