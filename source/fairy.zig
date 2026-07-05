pub const client = @import("client.zig");
pub const network = @import("network.zig");
pub const server = @import("server.zig");
pub const windows = @import("windows.zig");

pub const log = @import("std").log.scoped(.fairy);

pub const PathComponentCount = u8;
/// The maximum number of components in a file/folder path that will be recognized.
/// If a path has more components than this, the file/folder will not be tracked.
pub const max_path_components: PathComponentCount = 255;

pub fn print(message: []const u8) void {
    @import("std").debug.print("{s}\n", .{message});
}

pub const printf = @import("std").debug.print;

comptime {
    if (@import("builtin").cpu.arch.endian() != .little) {
        // In particular, the Windows and Unicode parts of the stdlib have poor big endian support.
        @compileError("non-little endian CPUs are not supported");
    }
}
