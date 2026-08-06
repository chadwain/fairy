const std = @import("std");
const assert = std.debug.assert;
const w = std.os.windows;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fairy = @import("fairy.zig");

const cpu_endian = @import("builtin").cpu.arch.endian();

/// A path to a location within the sync directory.
/// It is implemented as a WTF-16 encoded string, with the endianness of the host system.
/// It represents a subset of valid NT relative paths.
///
/// A `Path` must have these properties:
/// - It must be non-empty.
/// - It must not be longer than `Path.max_len` code units long.
/// - It must not contain more than `fairy.max_path_components` components.
/// - It must not contain any '/' codepoints.
/// - It must not end with a '\' codepoint.
/// - No component may be empty. (Thus consecutive '\' codepoints are disallowed.)
/// - No component may be longer than `Path.component_max_len` code units long.
/// - No component may end with a '.', or ' ' codepoint. (Thus '.' and '..' are not valid components.)
/// - No component may be the same as a legacy DOS device name. (NUL, COM1, AUX, etc.)

// TODO: The maximum length of a path component is actually a run-time known value,
//       it can be retrieved using NtQueryVolumeInformationFile.
pub const Path = struct {
    slice: []const u16,

    pub const max_len = 32767;
    pub const component_max_len = 255;

    pub fn fromSlice(slice: []const u16) error{InvalidPath}!Path {
        if (!isValidWindowsPath(slice)) return error.InvalidPath;
        return .{ .slice = slice };
    }

    pub fn assumeValidPath(slice: []const u16) Path {
        return .{ .slice = slice };
    }

    pub fn byteCount(path: Path) u16 {
        return @intCast(path.slice.len * 2);
    }

    pub fn dupe(path: Path, allocator: Allocator) !Path {
        return .{ .slice = try allocator.dupe(u16, path.slice) };
    }

    /// Does a potentially lossy conversion from WTF-16 to UTF-8.
    pub fn formatUtf8(path: Path) std.fmt.Alt([]const u16, formatWtf16AsUtf8) {
        return .{ .data = path.slice };
    }

    fn formatWtf16AsUtf8(slice: []const u16, writer: *Io.Writer) Io.Writer.Error!void {
        comptime assert(cpu_endian == .little);
        try writer.print("{f}", .{std.unicode.fmtUtf16Le(slice)});
    }

    pub const ComponentIterator = std.fs.path.ComponentIterator(.windows, u16);

    pub fn componentIterator(path: Path) ComponentIterator {
        return .init(path.slice);
    }

    // TODO: Unicode case mappings???

    pub fn hash(path: Path) u32 {
        // TODO: more efficient hashing
        var hasher = std.hash.Wyhash.init(0);
        for (path.slice) |c| {
            const uppercase = w.ntdll.RtlUpcaseUnicodeChar(c);
            std.hash.autoHash(&hasher, uppercase);
        }
        return @truncate(hasher.final());
    }

    pub fn eql(a: Path, b: Path) bool {
        return w.ntdll.RtlEqualUnicodeString(&.init(a.slice), &.init(b.slice), .TRUE).toBool();
    }
};

pub fn isValidWindowsPath(path: []const u16) bool {
    // My reference for how NT paths work is here:
    // https://projectzero.google/2016/02/the-definitive-guide-on-win32-to-nt.html

    if (path.len == 0) return false;
    if (path.len > Path.max_len) return false;
    switch (std.fs.path.getWin32PathType(u16, path)) {
        .relative => {},
        else => return false,
    }

    const c = asciiToUtf16;

    var index: u16 = 0;
    var component_len: u16 = 0;
    var component_count: fairy.PathComponentCount = 0;
    while (index < path.len) : (index += 1) {
        switch (path[index]) {
            c('\\') => {
                if (index + 1 == path.len) return false;
                const component = path[index - component_len .. index];
                component_len = 0;
                component_count = if (component_count < fairy.max_path_components) component_count + 1 else return false;
                if (!isValidComponent(component)) return false;
            },
            c('/') => return false,
            else => component_len += 1,
        }
    } else {
        const component = path[path.len - component_len ..];
        if (!isValidComponent(component)) return false;
        return true;
    }
}

fn isValidComponent(component: []const u16) bool {
    const L = std.unicode.wtf8ToWtf16LeStringLiteral;
    const c = asciiToUtf16;

    if (component.len == 0) return false;
    if (component.len > Path.component_max_len) return false;
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

pub fn asciiToUtf16(comptime char: u8) u16 {
    return comptime blk: {
        assert(char < 128);
        const as_utf16 = std.unicode.utf8ToUtf16LeStringLiteral(&.{char});
        assert(as_utf16.len == 1);
        break :blk as_utf16[0];
    };
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

pub fn openSyncDir(path: []const u16) !w.HANDLE {
    var handle: w.HANDLE = undefined;
    var unicode_string = w.UNICODE_STRING.init(path);
    const object_attributes: w.OBJECT.ATTRIBUTES = .{
        .Length = @sizeOf(w.OBJECT.ATTRIBUTES),
        .RootDirectory = null,
        .ObjectName = &unicode_string,
        .Attributes = .{
            .CASE_INSENSITIVE = true,
        },
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
    var iosb: w.IO_STATUS_BLOCK = undefined;
    const status = w.ntdll.NtCreateFile(
        &handle,
        .{
            .STANDARD = .{
                .RIGHTS = .READ,
                .SYNCHRONIZE = true,
            },
            .SPECIFIC = .{
                .FILE_DIRECTORY = .{
                    .LIST = true,
                    .TRAVERSE = true,
                },
            },
        },
        &object_attributes,
        &iosb,
        null,
        .{ .NORMAL = true },
        .{
            .READ = true,
            .WRITE = true,
            .DELETE = true,
        },
        .OPEN,
        .{
            .IO = .SYNCHRONOUS_NONALERT,
            .DIRECTORY_FILE = true,
            .OPEN_FOR_BACKUP_INTENT = true,
        },
        null,
        0,
    );

    switch (status) {
        .SUCCESS => return handle,
        else => return w.unexpectedStatus(status),
    }
}

pub fn createDir(parent: w.HANDLE, path: Path) !w.HANDLE {
    var handle: w.HANDLE = undefined;
    var unicode_string = w.UNICODE_STRING.init(path.slice);
    const object_attributes: w.OBJECT.ATTRIBUTES = .{
        .Length = @sizeOf(w.OBJECT.ATTRIBUTES),
        .RootDirectory = parent,
        .ObjectName = &unicode_string,
        .Attributes = .{
            .CASE_INSENSITIVE = true,
        },
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
    var iosb: w.IO_STATUS_BLOCK = undefined;
    const status = w.ntdll.NtCreateFile(
        &handle,
        .{
            .STANDARD = .{
                .RIGHTS = .READ,
                .SYNCHRONIZE = true,
            },
            .SPECIFIC = .{
                .FILE_DIRECTORY = .{
                    .LIST = true,
                    .TRAVERSE = true,
                },
            },
        },
        &object_attributes,
        &iosb,
        null,
        .{ .NORMAL = true },
        .{
            .READ = true,
            .WRITE = true,
            .DELETE = true,
        },
        .OPEN_IF,
        .{
            .IO = .SYNCHRONOUS_NONALERT,
            .DIRECTORY_FILE = true,
            .OPEN_FOR_BACKUP_INTENT = true,
        },
        null,
        0,
    );

    switch (status) {
        .SUCCESS => return handle,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => return error.ParentDirNotFound,
        else => return w.unexpectedStatus(status),
    }
}

pub fn openDir(parent: w.HANDLE, path: Path) !w.HANDLE {
    var handle: w.HANDLE = undefined;
    var unicode_string = w.UNICODE_STRING.init(path.slice);
    const object_attributes: w.OBJECT.ATTRIBUTES = .{
        .Length = @sizeOf(w.OBJECT.ATTRIBUTES),
        .RootDirectory = parent,
        .ObjectName = &unicode_string,
        .Attributes = .{
            .CASE_INSENSITIVE = true,
        },
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
    var iosb: w.IO_STATUS_BLOCK = undefined;
    const status = w.ntdll.NtCreateFile(
        &handle,
        .{
            .STANDARD = .{
                .RIGHTS = .READ,
                .SYNCHRONIZE = true,
            },
            .SPECIFIC = .{
                .FILE_DIRECTORY = .{
                    .LIST = true,
                    .TRAVERSE = true,
                },
            },
        },
        &object_attributes,
        &iosb,
        null,
        .{ .NORMAL = true },
        .{
            .READ = true,
            .WRITE = true,
            .DELETE = true,
        },
        .OPEN,
        .{
            .IO = .SYNCHRONOUS_NONALERT,
            .DIRECTORY_FILE = true,
            .OPEN_FOR_BACKUP_INTENT = true,
        },
        null,
        0,
    );

    switch (status) {
        .SUCCESS => return handle,
        else => return w.unexpectedStatus(status),
    }
}

pub fn closeHandle(handle: w.HANDLE) void {
    switch (w.ntdll.NtClose(handle)) {
        .SUCCESS => {},
        .INVALID_HANDLE => unreachable,
        else => {}, // Not much we can do.
    }
}

pub const CreateFileOptions = struct {
    initial_size: w.LARGE_INTEGER,
};

pub fn createFile(parent: w.HANDLE, path: Path, options: CreateFileOptions) !w.HANDLE {
    var handle: w.HANDLE = undefined;
    var unicode_string = w.UNICODE_STRING.init(path.slice);
    const object_attributes: w.OBJECT.ATTRIBUTES = .{
        .Length = @sizeOf(w.OBJECT.ATTRIBUTES),
        .RootDirectory = parent,
        .ObjectName = &unicode_string,
        .Attributes = .{
            .CASE_INSENSITIVE = true,
        },
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
    var iosb: w.IO_STATUS_BLOCK = undefined;

    const status = w.ntdll.NtCreateFile(
        &handle,
        .{
            .STANDARD = .{ .SYNCHRONIZE = true },
            .GENERIC = .{ .READ = true, .WRITE = true },
        },
        &object_attributes,
        &iosb,
        &options.initial_size,
        .{ .NORMAL = true },
        .{},
        .OVERWRITE_IF,
        .{
            .NON_DIRECTORY_FILE = true,
            .IO = .SYNCHRONOUS_NONALERT,
        },
        null,
        0,
    );

    switch (status) {
        .SUCCESS => return handle,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => return error.ParentDirNotFound,
        else => return w.unexpectedStatus(status),
    }
}

pub const OpenFileOptions = enum {
    read,
};

pub fn openFile(parent: w.HANDLE, path: Path, options: OpenFileOptions) !w.HANDLE {
    var handle: w.HANDLE = undefined;
    var unicode_string = w.UNICODE_STRING.init(path.slice);
    const object_attributes: w.OBJECT.ATTRIBUTES = .{
        .Length = @sizeOf(w.OBJECT.ATTRIBUTES),
        .RootDirectory = parent,
        .ObjectName = &unicode_string,
        .Attributes = .{
            .CASE_INSENSITIVE = true,
        },
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
    var iosb: w.IO_STATUS_BLOCK = undefined;

    const status = switch (options) {
        .read => w.ntdll.NtOpenFile(
            &handle,
            .{
                .STANDARD = .{ .SYNCHRONIZE = true },
                .GENERIC = .{ .READ = true },
            },
            &object_attributes,
            &iosb,
            .{ .READ = true },
            .{
                .NON_DIRECTORY_FILE = true,
                .IO = .SYNCHRONOUS_NONALERT,
            },
        ),
    };

    switch (status) {
        .SUCCESS => return handle,
        else => return w.unexpectedStatus(status),
    }
}

extern "ntdll" fn NtDeleteFile(
    ObjectAttributes: *const w.OBJECT.ATTRIBUTES,
) callconv(.winapi) w.NTSTATUS;

pub fn deleteFile(parent: w.HANDLE, path: Path) !void {
    var unicode_string: w.UNICODE_STRING = .init(path.slice);
    const object_attributes: w.OBJECT.ATTRIBUTES = .{
        .Length = @sizeOf(w.OBJECT.ATTRIBUTES),
        .RootDirectory = parent,
        .ObjectName = &unicode_string,
        .Attributes = .{
            .CASE_INSENSITIVE = true,
        },
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
    const status = NtDeleteFile(&object_attributes);
    switch (status) {
        .SUCCESS => {},
        else => return w.unexpectedStatus(status),
    }
}

pub const SendFileError = Io.Writer.Error || Io.UnexpectedError;

pub fn sendFile(
    writer: *Io.Writer,
    handle: w.HANDLE,
    file_size: w.ULARGE_INTEGER,
) SendFileError!void {
    // TODO: Actually use sendfile or whatever it is on Windows
    var iosb: w.IO_STATUS_BLOCK = undefined;
    var written: w.LARGE_INTEGER = 0;
    while (written < file_size) {
        const buffer = buffer: {
            const slice = try writer.writableSliceGreedy(1);
            break :buffer slice[0..@min(
                slice.len,
                file_size - @as(w.ULARGE_INTEGER, @intCast(written)),
                comptime std.math.maxInt(w.ULONG),
            )];
        };
        // TODO NtReadFileScatter
        const status = w.ntdll.NtReadFile(
            handle,
            null,
            null,
            null,
            &iosb,
            buffer.ptr,
            @intCast(buffer.len),
            &written,
            null,
        );
        switch (status) {
            .SUCCESS => {
                writer.advance(iosb.Information);
                written += @intCast(iosb.Information);
            },
            else => return w.unexpectedStatus(status),
        }
    }
    // TODO: the file could have been modified by another thread; consider locking
    if (written != file_size) return error.Unexpected;
}

pub const ReceiveFileError = Io.Reader.Error || Io.UnexpectedError;

pub fn receiveFile(
    reader: *Io.Reader,
    handle: w.HANDLE,
    file_size: w.LARGE_INTEGER,
) ReceiveFileError!void {
    // TODO: Actually use sendfile or whatever it is on Windows
    var read: w.LARGE_INTEGER = 0;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    while (read < file_size) {
        const buffer = buffer: {
            const slice = try reader.peekGreedy(1);
            break :buffer slice[0..@min(
                slice.len,
                @as(w.ULARGE_INTEGER, @intCast(file_size - read)),
                comptime std.math.maxInt(w.ULONG),
            )];
        };
        // TODO NtWriteFileGather
        const status = w.ntdll.NtWriteFile(
            handle,
            null,
            null,
            null,
            &iosb,
            buffer.ptr,
            @intCast(buffer.len),
            &read,
            null,
        );
        switch (status) {
            .SUCCESS => {
                reader.toss(iosb.Information);
                read += @intCast(iosb.Information);
            },
            else => return w.unexpectedStatus(status),
        }
    }
    // TODO: the file could have been modified by another thread; consider locking
    if (read != file_size) return error.Unexpected;
}
