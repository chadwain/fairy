const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fairy = @import("fairy.zig");

/// A path to a location within the sync directory.
/// It is implemented as a WTF-8 encoded string.
///
/// A `Path` must have these properties:
/// - It must be non-empty.
/// - It must not be longer than `Path.max_len` code units long.
/// - It must not contain more than `fairy.max_path_components` components.
/// - It must not end with a '/' codepoint.
/// - No component may be empty. (Thus consecutive '/' codepoints are disallowed.)
/// - No component may be longer than `Path.component_max_len` code units long.

// TODO: Reject non-printable characters (0-31)
pub const Path = struct {
    slice: []const u8,

    pub const ByteCount = u16;

    // TODO: On Linux, PATH_MAX might be determined at runtime
    pub const max_len = 4095;

    // TODO: On Linux, NAME_MAX might be determined at runtime
    pub const component_max_len = 255;

    pub fn fromSlice(slice: []const u8) error{InvalidPath}!Path {
        if (!isValidPath(slice)) return error.InvalidPath;
        return .{ .slice = slice };
    }

    pub fn assumeValidPath(slice: []const u8) Path {
        return .{ .slice = slice };
    }

    pub fn byteCount(path: Path) ByteCount {
        return @intCast(path.slice.len);
    }

    pub fn dupe(path: Path, allocator: Allocator) !Path {
        return .{ .slice = try allocator.dupe(u8, path.slice) };
    }

    pub fn parent(path: Path) ?Path {
        var it = backwardsPathIterator(path);
        return it.previous();
    }

    /// Does a potentially lossy conversion from WTF-8 to UTF-8.
    pub fn formatUtf8(path: Path) std.fmt.Alt([]const u8, formatWtf8AsUtf8) {
        return .{ .data = path.slice };
    }

    fn formatWtf8AsUtf8(slice: []const u8, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("{f}", .{std.unicode.fmtUtf8(slice)});
    }

    pub const PathIterator = struct {
        slice: []const u8,
        /// `Path.max_len` is used to represent the entirety of `slice`.
        end: ByteCount,
        was_null: bool,

        pub fn empty(it: *const PathIterator) bool {
            return it.end == 0;
        }

        fn goForwards(it: *PathIterator) ?[2]ByteCount {
            if (it.end == max_len) {
                it.was_null = true;
                return null;
            }
            it.was_null = false;

            const start = if (it.end != 0) it.end + 1 else 0;
            if (std.mem.findScalarPos(u8, it.slice, start, '/')) |new_end| {
                it.end = @intCast(new_end);
                return .{ start, it.end };
            } else {
                it.end = max_len;
                return .{ start, @intCast(it.slice.len) };
            }
        }

        pub fn next(it: *PathIterator) ?Path {
            const bounds = it.goForwards() orelse return null;
            return .{ .slice = it.slice[0..bounds[1]] };
        }

        pub fn nextComponent(it: *PathIterator) ?Path {
            const bounds = it.goForwards() orelse return null;
            return .{ .slice = it.slice[bounds[0]..bounds[1]] };
        }

        pub fn nextPathComponent(it: *PathIterator) ?struct { path: Path, component: Path } {
            const bounds = it.goForwards() orelse return null;
            return .{
                .path = .{ .slice = it.slice[0..bounds[1]] },
                .component = .{ .slice = it.slice[bounds[0]..bounds[1]] },
            };
        }

        fn goBackwards(it: *PathIterator) ?[2]ByteCount {
            if (it.end == 0) {
                it.was_null = true;
                return null;
            }
            it.was_null = false;

            const end = if (it.end == max_len) @as(ByteCount, @intCast(it.slice.len)) else it.end;
            if (std.mem.findScalarLast(u8, it.slice[0..end], '/')) |new_end| {
                it.end = @intCast(new_end);
                return .{ it.end + 1, end };
            } else {
                it.end = 0;
                return .{ 0, end };
            }
            return end;
        }

        pub fn previous(it: *PathIterator) ?Path {
            const bounds = it.goBackwards() orelse return null;
            return .{ .slice = it.slice[0..bounds[1]] };
        }

        pub fn previousComponent(it: *PathIterator) ?Path {
            const bounds = it.goBackwards() orelse return null;
            return .{ .slice = it.slice[bounds[0]..bounds[1]] };
        }

        pub const Direction = enum { forwards, backwards };

        pub fn setDirection(it: *PathIterator, direction: Direction) void {
            switch (direction) {
                .forwards => {
                    if (!it.was_null) _ = it.next();
                },
                .backwards => {
                    if (!it.was_null) _ = it.previous();
                },
            }
        }

        pub fn replacePath(it: *PathIterator, new_path: Path) void {
            assert(std.mem.eql(u8, it.slice, new_path.slice));
            it.slice = new_path.slice;
        }
    };

    pub fn pathIterator(path: Path) PathIterator {
        return .{ .slice = path.slice, .end = 0, .was_null = false };
    }

    pub fn backwardsPathIterator(path: Path) PathIterator {
        return .{ .slice = path.slice, .end = max_len, .was_null = false };
    }

    test PathIterator {
        const expect = std.testing.expect;
        const expectEqualSlices = std.testing.expectEqualSlices;
        {
            const path = try fromSlice("a/b/c");
            var it = path.pathIterator();
            try expectEqualSlices(u8, "a", it.next().?.slice);
            try expectEqualSlices(u8, "a/b", it.next().?.slice);
            it.setDirection(.backwards);
            try expectEqualSlices(u8, "a", it.previous().?.slice);
            it.setDirection(.forwards);
            try expectEqualSlices(u8, "a/b", it.next().?.slice);
            try expectEqualSlices(u8, "a/b/c", it.next().?.slice);
            try expect(it.next() == null);
        }
        {
            const path = try fromSlice("a/b/c");
            var it = path.backwardsPathIterator();
            try expectEqualSlices(u8, "a/b/c", it.previous().?.slice);
            try expectEqualSlices(u8, "a/b", it.previous().?.slice);
            it.setDirection(.forwards);
            try expectEqualSlices(u8, "a/b/c", it.next().?.slice);
            it.setDirection(.backwards);
            try expectEqualSlices(u8, "a/b", it.previous().?.slice);
            try expectEqualSlices(u8, "a", it.previous().?.slice);
            try expect(it.previous() == null);
        }
    }

    // TODO: Unicode case mappings???

    pub fn hash(path: Path) u32 {
        // TODO: more efficient hashing
        var hasher = std.hash.Wyhash.init(0);
        for (path.slice) |c| {
            std.hash.autoHash(&hasher, c);
        }
        return @truncate(hasher.final());
    }

    pub fn eql(a: Path, b: Path) bool {
        return std.mem.eql(u8, a.slice, b.slice);
    }
};

pub fn isValidPath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path.len > Path.max_len) return false;

    var index: Path.ByteCount = 0;
    var component_len: Path.ByteCount = 0;
    var component_count: fairy.PathComponentCount = 0;
    while (index < path.len) : (index += 1) {
        switch (path[index]) {
            '/' => {
                if (index + 1 == path.len) return false;
                const component = path[index - component_len .. index];
                component_len = 0;
                component_count = if (component_count < fairy.max_path_components) component_count + 1 else return false;
                if (!isValidComponent(component)) return false;
            },
            else => component_len += 1,
        }
    } else {
        const component = path[path.len - component_len ..];
        if (!isValidComponent(component)) return false;
        return true;
    }
}

fn isValidComponent(component: []const u8) bool {
    if (component.len == 0) return false;
    if (component.len > Path.component_max_len) return false;
    return true;
}

pub fn PathHashMap(comptime V: type) type {
    const Context = struct {
        pub fn hash(_: @This(), self: Path) u32 {
            return self.hash();
        }

        pub fn eql(_: @This(), a: Path, b: Path) bool {
            return Path.eql(a, b);
        }
    };
    return std.HashMapUnmanaged(Path, V, Context, std.hash_map.default_max_load_percentage);
}

pub fn PathArrayHashMap(comptime V: type) type {
    const Context = struct {
        pub fn hash(_: @This(), self: Path) u32 {
            return self.hash();
        }

        pub fn eql(_: @This(), a: Path, b: Path, _: usize) bool {
            return Path.eql(a, b);
        }
    };
    return std.ArrayHashMapUnmanaged(Path, V, Context, true);
}
