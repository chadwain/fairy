const std = @import("std");
const assert = std.debug.assert;
const w = std.os.windows;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fairy = @import("fairy.zig");
const Path = fairy.Path;

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
    return openDirRaw(parent, path.slice);
}

fn openDirRaw(parent: w.HANDLE, path: []const u16) !w.HANDLE {
    var handle: w.HANDLE = undefined;
    var unicode_string = w.UNICODE_STRING.init(path);
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

/// Creates the directory specified by `path` and returns a handle to it.
/// Creates intermediate directories as necessary.
pub fn createDirPath(root_dir: w.HANDLE, path: Path) !w.HANDLE {
    // TODO: We must check that the opened dirs have the same case as in `path`
    var it = path.backwardsIterator();
    var dir_handle = blk: {
        while (it.previousPath()) |sub_path| {
            const handle = createDir(root_dir, sub_path) catch |err| switch (err) {
                error.ParentDirNotFound => continue,
                error.Unexpected => |e| return e,
            };
            break :blk handle;
        } else std.debug.panic("TODO: Could not create a file in the root directory", .{});
    };
    defer closeHandle(dir_handle);
    errdefer std.debug.panic("TODO: Delete intermediate directories and files", .{});

    it.changeDirection(.forwards);
    var component = it.nextComponent().?;
    while (true) {
        const child_handle = createDir(dir_handle, component) catch |err| switch (err) {
            error.ParentDirNotFound => {
                std.debug.panic("TODO: Directory not found even though we have an open handle to it (?)", .{});
            },
            error.Unexpected => |e| return e,
        };
        errdefer comptime unreachable;

        component = it.nextComponent() orelse return child_handle;
        closeHandle(dir_handle);
        dir_handle = child_handle;
    }

    unreachable;
}

pub const FileClass = enum {
    /// A read-only file.
    read,
    /// A write-only file.
    write,
    /// A file that is intended to be renamed.
    rename,

    pub fn accessMask(class: FileClass) w.ACCESS_MASK {
        return switch (class) {
            .read => .{
                .STANDARD = .{ .SYNCHRONIZE = true },
                .GENERIC = .{ .READ = true },
            },
            .write => .{
                .SPECIFIC = .{
                    .FILE = .{
                        .WRITE_DATA = true,
                        .APPEND_DATA = true,
                    },
                },
                .STANDARD = .{
                    .RIGHTS = .{
                        // .READ_CONTROL = true,
                    },
                    .SYNCHRONIZE = true,
                },
            },
            .rename => .{
                .STANDARD = .{
                    .RIGHTS = .{
                        .DELETE = true,
                        // .READ_CONTROL = true,
                    },
                    .SYNCHRONIZE = true,
                },
            },
        };
    }
};

pub const CreateFileOptions = struct {
    initial_size: w.LARGE_INTEGER,
    class: FileClass,
};

pub const CreateFileError = error{ ParentDirNotFound, Unexpected };

/// Creates a new file, or overwrites an existing one.
pub fn createFile(parent: w.HANDLE, path: Path, options: CreateFileOptions) CreateFileError!w.HANDLE {
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
        options.class.accessMask(),
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

pub fn openFile(parent: w.HANDLE, path: Path, class: FileClass) !w.HANDLE {
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

    const status = w.ntdll.NtOpenFile(
        &handle,
        class.accessMask(),
        &object_attributes,
        &iosb,
        .{ .READ = true },
        .{
            .NON_DIRECTORY_FILE = true,
            .IO = .SYNCHRONOUS_NONALERT,
        },
    );

    switch (status) {
        .SUCCESS => return handle,
        else => return w.unexpectedStatus(status),
    }
}

pub fn renameFile(
    handle: w.HANDLE,
    new_parent: w.HANDLE,
    /// Must be a single component.
    new_name: Path,
) !void {
    var iosb: w.IO_STATUS_BLOCK = undefined;
    // https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_rename_information
    const RenameInformation = extern struct {
        ReplaceIfExists: w.BOOLEAN,
        RootDirectory: w.HANDLE,
        FileNameLength: w.ULONG,
        FileName: [Path.component_max_len]w.WCHAR,
    };
    var information: RenameInformation = .{
        .ReplaceIfExists = .TRUE,
        .RootDirectory = new_parent,
        .FileNameLength = new_name.byteCount(),
        .FileName = undefined,
    };
    @memcpy((&information.FileName)[0..new_name.slice.len], new_name.slice);
    const status = w.ntdll.NtSetInformationFile(handle, &iosb, &information, @sizeOf(RenameInformation), .Rename);
    switch (status) {
        .SUCCESS => {},
        else => return w.unexpectedStatus(status),
    }
}

// TODO: replace usage of this with NtCreateFile -> NtSetInformationFile -> NtClose
extern "ntdll" fn NtDeleteFile(
    ObjectAttributes: *const w.OBJECT.ATTRIBUTES,
) callconv(.winapi) w.NTSTATUS;

pub fn deleteFile(parent: w.HANDLE, path: Path) !void {
    try deleteFileRaw(parent, path.slice);
}

fn deleteFileRaw(parent: w.HANDLE, path: []const u16) !void {
    var unicode_string: w.UNICODE_STRING = .init(path);
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

pub fn deleteTree(parent: w.HANDLE, path: Path, allocator: Allocator) !void {
    // https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_file_id_extd_both_dir_information
    // TODO: see if there's a smaller query type
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

    const Item = struct {
        handle: w.HANDLE,
        buffer: [512]u8 align(@alignOf(NtQueryInformation)) = undefined,
        index: ?w.ULONG = null,
        restart_scan: w.BOOLEAN = .TRUE,
        state: enum { enter, exit } = .enter,
    };

    var stack: std.ArrayList(Item) = .empty; // TODO initCapacity
    defer {
        for (stack.items) |item| closeHandle(item.handle);
        stack.deinit(allocator);
    }

    {
        try stack.ensureUnusedCapacity(allocator, 1);
        const handle = try openDir(parent, path);
        stack.appendAssumeCapacity(.{ .handle = handle });
    }
    var io_status_block: w.IO_STATUS_BLOCK = undefined;
    while (stack.lastPtr()) |item| {
        if (item.index == null) {
            const status = w.ntdll.NtQueryDirectoryFile(
                item.handle,
                null,
                null,
                null,
                &io_status_block,
                &item.buffer,
                item.buffer.len,
                nt_query_information_class,
                .FALSE,
                null,
                item.restart_scan,
            );
            switch (status) {
                .NO_MORE_FILES => {
                    closeHandle(item.handle);
                    _ = stack.pop();
                    continue;
                },
                .BUFFER_OVERFLOW => return error.NtBufferOverflow,
                .SUCCESS => {
                    if (io_status_block.Information == 0) return error.NtBufferOverflow;
                    item.restart_scan = .FALSE;
                    item.index = 0;
                },
                else => return w.unexpectedStatus(status),
            }
        }

        const info: *const NtQueryInformation = @ptrCast(@alignCast(&item.buffer[item.index.?]));
        const offset_of_file_name = @offsetOf(NtQueryInformation, "FileName");
        const file_name_bytes = item.buffer[item.index.? + offset_of_file_name ..][0..info.FileNameLength];
        const file_name: []const u16 = @ptrCast(@alignCast(file_name_bytes));

        const wtf16 = std.unicode.wtf8ToWtf16LeStringLiteral;
        if (std.mem.eql(u16, file_name, comptime wtf16(".")) or
            std.mem.eql(u16, file_name, comptime wtf16("..")))
        {
            item.index = if (info.NextEntryOffset != 0) item.index.? + info.NextEntryOffset else null;
            continue;
        }

        if (info.FileAttributes.DIRECTORY) {
            switch (item.state) {
                .enter => {
                    const handle = item.handle;
                    item.state = .exit;
                    try stack.ensureUnusedCapacity(allocator, 1);
                    const child_handle = try openDirRaw(handle, file_name);
                    stack.appendAssumeCapacity(.{ .handle = child_handle });
                    continue;
                },
                .exit => {
                    item.state = .enter;
                    try deleteFileRaw(item.handle, file_name);
                },
            }
        } else {
            try deleteFileRaw(item.handle, file_name);
        }

        item.index = if (info.NextEntryOffset != 0) item.index.? + info.NextEntryOffset else null;
    }

    try deleteFile(parent, path);
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
