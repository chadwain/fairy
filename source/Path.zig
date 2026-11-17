//! A relative filesystem path.
//! On Windows, it is implemented as a WTF-16 encoded string, with the endianness of the host system.
//! On Linux, it is implemented as a WTF-8 encoded string.
//!
//! A `Path` must have these properties:
//! - It must be non-empty.
//! - It must not be longer than `max_len` code units long.
//! - It must not contain more than `max_components` components.
//! - No component may be empty. (Thus consecutive path separator codepoints are disallowed.)
//! - No component may be longer than `component_max_len` code units long.
//!
//! Additionally, on Windows, it must have these properties:
//! - It must not contain any '/' codepoints.
//! - It must not end with a '\' codepoint.
//! - No component may end with a '.', or ' ' codepoint. (Thus '.' and '..' are not valid components.)
//! - No component may be the same as a legacy DOS device name. (NUL, COM1, AUX, etc.)
//!
//! Additionally, on Linux, it must have these properties:
//! - It must not end with a '/' codepoint.
//! - No component may be empty. (Thus consecutive '/' codepoints are disallowed.)

// TODO: Reject invalid characters `/\:*"?<>|` and non-printable characters (0-31)
// TODO: Ensure that each component is 255 code units or less when converted to WTF-8

const Path = @This();

const std = @import("std");
const assert = std.debug.assert;
const w = std.os.windows;

const fairy = @import("fairy.zig");

slice: []const CodeUnit,

pub const max_len = switch (fairy.platform) {
    .windows => 32767,
    // TODO: On Linux, PATH_MAX might be determined at runtime
    .linux => 4095,
};

pub const component_max_len = switch (fairy.platform) {
    // TODO: The maximum length of a path component is actually a run-time known value,
    //       it can be retrieved using NtQueryVolumeInformationFile.
    .windows => 255,
    // TODO: On Linux, NAME_MAX might be determined at runtime
    .linux => 255,
};

const path_sep = switch (fairy.platform) {
    .windows => '\\',
    .linux => '/',
};

pub const CodeUnit = switch (fairy.platform) {
    .windows => u16,
    .linux => u8,
};

pub const ByteCount = u16;

pub const ComponentCount = u8;

/// The maximum number of components in a file/folder path that will be recognized.
/// If a path has more components than this, the file/folder will not be tracked.
pub const max_components: ComponentCount = 255;

pub fn fromSlice(slice: []const CodeUnit) error{InvalidPath}!Path {
    if (!isValidPath(slice)) return error.InvalidPath;
    return .{ .slice = slice };
}

pub fn assumeValidPath(slice: []const CodeUnit) Path {
    assert(isValidPath(slice));
    return .{ .slice = slice };
}

pub fn byteCount(path: Path) ByteCount {
    return switch (fairy.platform) {
        .windows => @intCast(path.slice.len * 2),
        .linux => @intCast(path.slice.len),
    };
}

// TODO: This should be deleted in favor of counting components at parse time.
pub fn componentCount(path: Path) ComponentCount {
    return @intCast(std.mem.countScalar(CodeUnit, path.slice, path_sep) + 1);
}

pub fn dupe(path: Path, allocator: std.mem.Allocator) !Path {
    return .{ .slice = try allocator.dupe(CodeUnit, path.slice) };
}

/// Does a potentially lossy conversion from WTF-16 (Windows) or WTF-8 (Linux) to UTF-8.
pub fn formatUtf8(path: Path) std.fmt.Alt(
    []const CodeUnit,
    switch (fairy.platform) {
        .windows => formatWtf16AsUtf8,
        .linux => formatWtf8AsUtf8,
    },
) {
    return .{ .data = path.slice };
}

fn formatWtf8AsUtf8(slice: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("{f}", .{std.unicode.fmtUtf8(slice)});
}

fn formatWtf16AsUtf8(slice: []const u16, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const cpu_endian = comptime @import("builtin").cpu.arch.endian();
    comptime assert(cpu_endian == .little);
    try writer.print("{f}", .{std.unicode.fmtUtf16Le(slice)});
}

/// Only valid if the path represents a single component.
pub fn componentToWtf8(path: Path, buffer: *[255]u8) []u8 {
    const cpu_endian = comptime @import("builtin").cpu.arch.endian();
    comptime assert(cpu_endian == .little);
    const len = std.unicode.wtf16LeToWtf8(buffer, path.slice);
    return buffer[0..len];
}

pub const Iterator = struct {
    slice: []const CodeUnit,
    /// If equal to `max_len`, the iterator represents the entirety of `slice`.
    cursor: Index,
    /// true if the most recent iteration resulted in a null value.
    was_null: bool,

    pub const Index = u16;

    comptime {
        assert(max_len <= std.math.maxInt(Index));
    }

    /// Returns true if the iterator currently represents an empty path.
    /// This does NOT represent the end of iteration.
    pub fn empty(it: *const Iterator) bool {
        return it.cursor == 0;
    }

    /// Returns the start and end indeces of the next component.
    fn iterateForwards(it: *Iterator) ?[2]Index {
        if (it.cursor == max_len) {
            it.was_null = true;
            return null;
        }
        it.was_null = false;

        const start = if (it.cursor != 0) it.cursor + 1 else 0;
        if (std.mem.findScalarPos(CodeUnit, it.slice, start, path_sep)) |new_end| {
            it.cursor = @intCast(new_end);
            return .{ start, it.cursor };
        } else {
            it.cursor = max_len;
            return .{ start, @intCast(it.slice.len) };
        }
    }

    pub fn nextPath(it: *Iterator) ?Path {
        const bounds = it.iterateForwards() orelse return null;
        return .{ .slice = it.slice[0..bounds[1]] };
    }

    pub fn nextComponent(it: *Iterator) ?Path {
        const bounds = it.iterateForwards() orelse return null;
        return .{ .slice = it.slice[bounds[0]..bounds[1]] };
    }

    pub fn nextPathComponent(it: *Iterator) ?struct { path: Path, component: Path } {
        const bounds = it.iterateForwards() orelse return null;
        return .{
            .path = .{ .slice = it.slice[0..bounds[1]] },
            .component = .{ .slice = it.slice[bounds[0]..bounds[1]] },
        };
    }

    /// Undoes the most recent call to a `next` function.
    pub fn undoNext(it: *Iterator) void {
        if (!it.was_null) _ = it.iterateBackwards().?;
    }

    /// Returns the start and end indeces of the previous component.
    fn iterateBackwards(it: *Iterator) ?[2]Index {
        if (it.cursor == 0) {
            it.was_null = true;
            return null;
        }
        it.was_null = false;

        const end = if (it.cursor == max_len) @as(Index, @intCast(it.slice.len)) else it.cursor;
        if (std.mem.findScalarLast(CodeUnit, it.slice[0..end], path_sep)) |new_end| {
            it.cursor = @intCast(new_end);
            return .{ it.cursor + 1, end };
        } else {
            it.cursor = 0;
            return .{ 0, end };
        }
        return end;
    }

    pub fn previousPath(it: *Iterator) ?Path {
        const bounds = it.iterateBackwards() orelse return null;
        return .{ .slice = it.slice[0..bounds[1]] };
    }

    pub fn previousComponent(it: *Iterator) ?Path {
        const bounds = it.iterateBackwards() orelse return null;
        return .{ .slice = it.slice[bounds[0]..bounds[1]] };
    }

    pub const Direction = enum { forwards, backwards };

    /// Converts a forwards iterator to a backwards iterator, or
    /// a backwards iterator to a forwards iterator.
    /// Do not call this with the same direction as the iterator currently is.
    pub fn changeDirection(it: *Iterator, to: Direction) void {
        switch (to) {
            .forwards => {
                if (!it.was_null) _ = it.nextPath();
            },
            .backwards => {
                if (!it.was_null) _ = it.previousPath();
            },
        }
    }
};

/// Creates a forwards iterator. Calls to any `previous` functions are not allowed.
/// A forwards iterator starts from the first component and grows to include deeper components.
pub fn forwardsIterator(path: Path) Iterator {
    return .{ .slice = path.slice, .cursor = 0, .was_null = false };
}

/// Creates a backwards iterator. Calls to any `next` functions are not allowed.
/// A backwards iterator starts from the full path and shrinks to exclude deeper components.
pub fn backwardsIterator(path: Path) Iterator {
    return .{ .slice = path.slice, .cursor = max_len, .was_null = false };
}

test "Path.Iterator windows" {
    if (fairy.platform != .windows) return error.SkipZigTest;

    const wtf16 = std.unicode.wtf8ToWtf16LeStringLiteral;
    const expect = std.testing.expect;
    const expectEqualSlices = std.testing.expectEqualSlices;
    {
        const path = try fromSlice(wtf16("a\\b\\c"));
        var it = path.forwardsIterator();
        try expectEqualSlices(u16, wtf16("a"), it.nextPath().?.slice);
        try expectEqualSlices(u16, wtf16("a\\b"), it.nextPath().?.slice);
        it.changeDirection(.backwards);
        try expectEqualSlices(u16, wtf16("a"), it.previousPath().?.slice);
        it.changeDirection(.forwards);
        try expectEqualSlices(u16, wtf16("a\\b"), it.nextPath().?.slice);
        try expectEqualSlices(u16, wtf16("a\\b\\c"), it.nextPath().?.slice);
        try expect(it.nextPath() == null);
    }
    {
        const path = try fromSlice(wtf16("a\\b\\c"));
        var it = path.backwardsIterator();
        try expectEqualSlices(u16, wtf16("a\\b\\c"), it.previousPath().?.slice);
        try expectEqualSlices(u16, wtf16("a\\b"), it.previousPath().?.slice);
        it.changeDirection(.forwards);
        try expectEqualSlices(u16, wtf16("a\\b\\c"), it.nextPath().?.slice);
        it.changeDirection(.backwards);
        try expectEqualSlices(u16, wtf16("a\\b"), it.previousPath().?.slice);
        try expectEqualSlices(u16, wtf16("a"), it.previousPath().?.slice);
        try expect(it.previousPath() == null);
    }
}

test "Path.Iterator linux" {
    if (fairy.platform != .linux) return error.SkipZigTest;

    const expect = std.testing.expect;
    const expectEqualSlices = std.testing.expectEqualSlices;
    {
        const path = try fromSlice("a/b/c");
        var it = path.forwardsIterator();
        try expectEqualSlices(u8, "a", it.nextPath().?.slice);
        try expectEqualSlices(u8, "a/b", it.nextPath().?.slice);
        it.setDirection(.backwards);
        try expectEqualSlices(u8, "a", it.previousPath().?.slice);
        it.setDirection(.forwards);
        try expectEqualSlices(u8, "a/b", it.nextPath().?.slice);
        try expectEqualSlices(u8, "a/b/c", it.nextPath().?.slice);
        try expect(it.nextPath() == null);
    }
    {
        const path = try fromSlice("a/b/c");
        var it = path.backwardsIterator();
        try expectEqualSlices(u8, "a/b/c", it.previousPath().?.slice);
        try expectEqualSlices(u8, "a/b", it.previousPath().?.slice);
        it.setDirection(.forwards);
        try expectEqualSlices(u8, "a/b/c", it.nextPath().?.slice);
        it.setDirection(.backwards);
        try expectEqualSlices(u8, "a/b", it.previousPath().?.slice);
        try expectEqualSlices(u8, "a", it.previousPath().?.slice);
        try expect(it.previousPath() == null);
    }
}

pub fn hash(path: Path) u32 {
    // TODO: more efficient hashing
    var hasher = std.hash.Wyhash.init(0);
    for (path.slice) |c| {
        switch (fairy.platform) {
            .windows => {
                const uppercase = w.ntdll.RtlUpcaseUnicodeChar(c);
                std.hash.autoHash(&hasher, uppercase);
            },
            .linux => {
                std.hash.autoHash(&hasher, c);
            },
        }
    }
    return @truncate(hasher.final());
}

pub fn eql(a: Path, b: Path) bool {
    switch (fairy.platform) {
        .windows => return w.ntdll.RtlEqualUnicodeString(&.init(a.slice), &.init(b.slice), .TRUE).toBool(),
        .linux => return std.mem.eql(u8, a.slice, b.slice),
    }
}

fn isValidPath(path: []const CodeUnit) bool {
    switch (fairy.platform) {
        .windows => return isValidPathWindows(path),
        .linux => return isValidPathLinux(path),
    }
}

fn isValidPathWindows(path: []const u16) bool {
    // My reference for how NT paths work is here:
    // https://projectzero.google/2016/02/the-definitive-guide-on-win32-to-nt.html

    if (path.len == 0) return false;
    if (path.len > max_len) return false;
    // TODO No sense in calling a function that takes Win32 paths
    switch (std.fs.path.getWin32PathType(u16, path)) {
        .relative => {},
        else => return false,
    }

    const c = asciiToUtf16;

    var index: u16 = 0;
    var component_len: u16 = 0;
    var component_count: ComponentCount = 0;
    while (index < path.len) : (index += 1) {
        switch (path[index]) {
            c('\\') => {
                if (index + 1 == path.len) return false;
                const component = path[index - component_len .. index];
                component_len = 0;
                component_count = if (component_count < max_components) component_count + 1 else return false;
                if (!isValidComponentWindows(component)) return false;
            },
            c('/') => return false,
            else => component_len += 1,
        }
    } else {
        const component = path[path.len - component_len ..];
        if (!isValidComponentWindows(component)) return false;
        return true;
    }
}

fn isValidComponentWindows(component: []const u16) bool {
    const L = std.unicode.wtf8ToWtf16LeStringLiteral;
    const c = asciiToUtf16;

    if (component.len == 0) return false;
    if (component.len > component_max_len) return false;
    if (std.mem.trimEnd(u16, component, comptime L(" .")).len != component.len) return false;
    if (beginsWithLegacyDeviceName(component)) |index| {
        for (component[index..]) |codepoint| {
            switch (codepoint) {
                c(' ') => continue,
                c('.'), c(':') => return false,
                else => break,
            }
        } else return false;
    }
    return true;
}

fn beginsWithLegacyDeviceName(component: []const u16) ?u16 {
    const L = std.unicode.wtf8ToWtf16LeStringLiteral;
    if (std.mem.startsWith(u16, component, comptime L("PRN")) or
        std.mem.startsWith(u16, component, comptime L("AUX")) or
        std.mem.startsWith(u16, component, comptime L("NUL")) or
        std.mem.startsWith(u16, component, comptime L("CON")))
        return 3
    else if (std.mem.startsWith(u16, component, comptime L("LPT")) or
        std.mem.startsWith(u16, component, comptime L("COM")))
    {
        if (component.len > 3 and
            // TODO: Check the iswdigit function
            switch (component[3]) {
                '0'...'9', '¹', '²', '³' => true,
                else => false,
            }) return 4;
    } else if (std.mem.startsWith(u16, component, comptime L("CONIN$")))
        return 6
    else if (std.mem.startsWith(u16, component, comptime L("CONOUT$")))
        return 7;

    return null;
}

fn asciiToUtf16(comptime char: u8) u16 {
    return comptime blk: {
        assert(char < 128);
        const as_utf16 = std.unicode.utf8ToUtf16LeStringLiteral(&.{char});
        assert(as_utf16.len == 1);
        break :blk as_utf16[0];
    };
}

fn isValidPathLinux(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path.len > max_len) return false;

    var index: ByteCount = 0;
    var component_len: ByteCount = 0;
    var component_count: ComponentCount = 0;
    while (index < path.len) : (index += 1) {
        switch (path[index]) {
            '/' => {
                if (index + 1 == path.len) return false;
                const component = path[index - component_len .. index];
                component_len = 0;
                component_count = if (component_count < max_components) component_count + 1 else return false;
                if (!isValidComponentLinux(component)) return false;
            },
            else => component_len += 1,
        }
    } else {
        const component = path[path.len - component_len ..];
        if (!isValidComponentLinux(component)) return false;
        return true;
    }
}

fn isValidComponentLinux(component: []const u8) bool {
    if (component.len == 0) return false;
    if (component.len > component_max_len) return false;
    return true;
}

pub fn HashMap(comptime V: type) type {
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

pub fn ArrayHashMap(comptime V: type) type {
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
