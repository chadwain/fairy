const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const fairy = @import("fairy.zig");

/// The endianness of message contents, except for file paths, which have their own encoding.
pub const endian: std.builtin.Endian = .little;

pub const MessageHeaderTag = enum(u2) {
    disconnect,
    new_tx,
    new_tx_reply,
    existing_tx,
};

pub const TransactionId = enum(u3) {
    invalid = 7,
    _,

    pub fn format(tx_id: TransactionId, writer: *Io.Writer) Io.Writer.Error!void {
        if (std.enums.tagName(TransactionId, tx_id)) |name| {
            try writer.writeAll(name);
        } else {
            try writer.print("{}", .{@intFromEnum(tx_id)});
        }
    }
};

pub const MessageHeader = packed struct(u8) {
    tag: MessageHeaderTag,
    /// The transaction ID of the destination peer.
    /// Not valid when tag is `new_tx`.
    tx_id: TransactionId,
    /// The transaction ID of the source peer.
    /// Only valid when `tag` is `new_tx` or `new_tx_reply`.
    peer_tx_id: TransactionId,
};

pub const Action = enum(u8) {
    /// The client asks the server to resolve a file path.
    /// If successful, the server will ensure there is a `FileId` for every sub-component within the path.
    /// Sender: client
    /// Payload: `FileKind` + A path
    resolve_path,
    /// Sent in response to a `resolve_path` message.
    /// Payload: A `ResolvePathResponse`
    /// Payload(success): A sequence of `FileId`, one for each component of the requested path.
    resolve_path_response,

    transfer_file_id,
    transfer_file_accept,
    transfer_file_decline,
    transfer_file_contents,
    transfer_file_success,
    transfer_file_failure,

    /// The client asks the server to locally create a directory.
    create_dir,
    create_dir_response,

    /// A client has seen a file get deleted on its local filesystem.
    delete_file,
    /// The server notifies that a file has been globally deleted.
    delete_file_confirm,
};

pub const FileHash = struct {
    blake3: [byte_size]u8,

    pub const byte_size = 32;

    pub fn eql(lhs: *const FileHash, rhs: *const FileHash) bool {
        return std.mem.eql(u8, &lhs.blake3, &rhs.blake3);
    }

    pub fn format(hash: FileHash, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("{x}", .{std.mem.nativeToBig(@Int(.unsigned, byte_size * 8), @bitCast(hash.blake3))});
    }
};

pub const FileId = enum(u32) {
    // TODO delete this field
    unknown = 0,
    _,

    pub fn format(file_id: FileId, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("FileId({d})", .{@intFromEnum(file_id)});
    }
};

pub const FileSize = u64;

pub const FileKind = enum(u8) { regular, directory };

pub const PathEncoding = enum(u8) {
    wtf16le,
};

pub const PathByteCount = u16;

pub const FilePathBuffer = [1 << @bitSizeOf(PathByteCount)]u8;

pub const ResolvePathResponse = enum(u8) {
    success,
    invalid_path,
    exhausted_file_ids,
    invalid_folder,
    wrong_file_kind,
};

pub const CreateDirResponse = enum(u8) {
    success,
    not_a_directory,
    unknown_file,
    unexpected,
};

pub const min_reader_writer_buffer_size = FileHash.byte_size;

pub const Writer = struct {
    io: *Io.Writer,

    /// Asserts a writer buffer size of at least `min_reader_writer_buffer_size`.
    pub fn init(io_writer: *Io.Writer) Writer {
        assert(io_writer.buffer.len >= min_reader_writer_buffer_size);
        return .{ .io = io_writer };
    }

    pub fn flush(writer: Writer) !void {
        try writer.io.flush();
    }

    fn writeEnum(writer: Writer, comptime Enum: type, value: Enum) !void {
        try writer.io.writeInt(@typeInfo(Enum).@"enum".tag_type, @intFromEnum(value), endian);
    }

    pub fn sendMessageHeaderExistingTx(writer: Writer, peer_tx_id: TransactionId) !void {
        const header = MessageHeader{
            .tag = .existing_tx,
            .tx_id = peer_tx_id,
            .peer_tx_id = .invalid,
        };
        try writer.io.writeStruct(header, endian);
    }

    pub fn sendMessageHeaderNewTx(writer: Writer, tx_id: TransactionId) !void {
        const header = MessageHeader{
            .tag = .new_tx,
            .tx_id = .invalid,
            .peer_tx_id = tx_id,
        };
        try writer.io.writeStruct(header, endian);
    }

    pub fn sendMessageHeaderNewTxReply(writer: Writer, tx_id: TransactionId, peer_tx_id: TransactionId) !void {
        const header = MessageHeader{
            .tag = .new_tx_reply,
            .tx_id = peer_tx_id,
            .peer_tx_id = tx_id,
        };
        try writer.io.writeStruct(header, endian);
    }

    pub fn sendAction(writer: Writer, action: Action) !void {
        try writer.writeEnum(Action, action);
    }

    pub fn sendFileId(writer: Writer, id: FileId) !void {
        try writer.writeEnum(FileId, id);
    }

    pub fn sendFileKind(writer: Writer, kind: FileKind) Io.Writer.Error!void {
        try writer.writeEnum(FileKind, kind);
    }

    pub fn sendPathEncoding(writer: Writer, encoding: PathEncoding) Io.Writer.Error!void {
        try writer.writeEnum(PathEncoding, encoding);
    }

    pub fn sendWindowsPathByteCount(writer: Writer, byte_count: PathByteCount) Io.Writer.Error!void {
        assert(byte_count % 2 == 0);
        try writer.io.writeInt(PathByteCount, byte_count, endian);
    }

    pub fn sendFileSize(writer: Writer, file_size: FileSize) Io.Writer.Error!void {
        try writer.io.writeInt(FileSize, file_size, endian);
    }

    pub fn sendFileHash(writer: Writer, file_hash: *const FileHash) Io.Writer.Error!void {
        try writer.io.writeAll(&file_hash.blake3);
    }

    pub fn sendWindowsPath(writer: Writer, path: fairy.windows.Path) Io.Writer.Error!void {
        try writer.io.writeAll(@ptrCast(path.slice));
    }

    pub fn sendResolvePathResponse(writer: Writer, response: ResolvePathResponse) Io.Writer.Error!void {
        try writer.writeEnum(ResolvePathResponse, response);
    }

    pub fn sendCreateDirResponse(writer: Writer, response: CreateDirResponse) Io.Writer.Error!void {
        try writer.writeEnum(CreateDirResponse, response);
    }
};

pub const Reader = struct {
    io: *Io.Reader,

    /// Asserts a reader buffer size of at least `min_reader_writer_buffer_size`.
    pub fn init(io_reader: *Io.Reader) Reader {
        assert(io_reader.buffer.len >= min_reader_writer_buffer_size);
        return .{ .io = io_reader };
    }

    fn readEnum(reader: Reader, comptime Enum: type) Io.Reader.Error!?Enum {
        const int = try reader.io.takeInt(@typeInfo(Enum).@"enum".tag_type, endian);
        return std.enums.fromInt(Enum, int);
    }

    pub fn receiveMessageHeader(reader: Reader) Io.Reader.Error!MessageHeader {
        return reader.io.takeStruct(MessageHeader, endian);
    }

    pub const ReceiveActionError = error{UnknownAction} || Io.Reader.Error;

    pub fn receiveAction(reader: Reader) ReceiveActionError!Action {
        return try reader.readEnum(Action) orelse error.UnknownAction;
    }

    pub fn receiveFileId(reader: Reader) Io.Reader.Error!FileId {
        // All values of FileId are valid
        return reader.io.takeEnumNonexhaustive(FileId, endian);
    }

    pub const ReceiveFileKindError = error{UnknownFileKind} || Io.Reader.Error;

    pub fn receiveFileKind(reader: Reader) ReceiveFileKindError!FileKind {
        return try reader.readEnum(FileKind) orelse error.UnknownFileKind;
    }

    pub const ReceivePathEncodingError = error{UnknownPathEncoding} || Io.Reader.Error;

    pub fn receivePathEncoding(reader: Reader) ReceivePathEncodingError!PathEncoding {
        return try reader.readEnum(PathEncoding) orelse error.UnknownPathEncoding;
    }

    pub const ReceiveWindowsPathByteCountError = error{InvalidWindowsPathByteCount} || Io.Reader.Error;

    pub fn receiveWindowsPathByteCount(reader: Reader) ReceiveWindowsPathByteCountError!PathByteCount {
        const int = try reader.io.takeInt(PathByteCount, endian);
        if (int % 2 == 1) return error.InvalidWindowsPathByteCount;
        return int;
    }

    pub fn receiveFileSize(reader: Reader) Io.Reader.Error!FileSize {
        return try reader.io.takeInt(FileSize, endian);
    }

    pub fn receiveFileHash(reader: Reader) Io.Reader.Error!FileHash {
        const hash_bytes = try reader.io.takeArray(FileHash.byte_size);
        return .{ .blake3 = hash_bytes.* };
    }

    pub const ReceiveWindowsPathError = error{InvalidPath} || Io.Reader.Error;

    pub fn receiveWindowsPath(
        reader: Reader,
        byte_count: PathByteCount,
        encoding: PathEncoding,
        buffer: *align(2) FilePathBuffer,
    ) ReceiveWindowsPathError!fairy.windows.Path {
        assert(byte_count % 2 == 0);
        switch (encoding) {
            .wtf16le => {},
        }

        var file_path_writer: Io.Writer = .fixed(buffer);
        reader.io.streamExact(&file_path_writer, byte_count) catch |err| switch (err) {
            error.WriteFailed => unreachable,
            error.ReadFailed, error.EndOfStream => |e| return e,
        };
        const path = buffer[0..byte_count];
        return try .fromSlice(@ptrCast(path));
    }

    pub const ReceiveResolvePathResponseError = error{UnknownResolvePathResponse} || Io.Reader.Error;

    pub fn receiveResolvePathResponse(reader: Reader) ReceiveResolvePathResponseError!ResolvePathResponse {
        return try reader.readEnum(ResolvePathResponse) orelse error.UnknownResolvePathResponse;
    }

    pub const ReceiveCreateDirResponseError = error{UnknownCreateDirResponse} || Io.Reader.Error;

    pub fn receiveCreateDirResponse(reader: Reader) ReceiveCreateDirResponseError!CreateDirResponse {
        return try reader.readEnum(CreateDirResponse) orelse error.UnknownCreateDirResponse;
    }
};
