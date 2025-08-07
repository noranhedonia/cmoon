//! A list of types that the wire format specifies.
//! - [The Wayland Protocol, by Kristian Høgsberg](https://wayland.freedesktop.org/docs/html/ch04.html#sect-Protocol-Wire-Format)
//! - [The Wayland Protocol, by Drew DeVault](https://wayland-book.com/protocol-design/wire-protocol.html)
const std = @import("std");

/// The Wayland protocol is defined in terms of 32-bit native-endianess words.
pub const Word = u32;

pub const Header = extern struct {
    object: Object align(4),
    size_and_opcode: SizeAndOpcode align(4),

    /// Get the message size from the `size_and_opcode` word. See also `Header.SizeAndOpcode.size`.
    pub inline fn size(header: Header) u16 { return header.size_and_opcode.size; }

    /// Get the message opcode from the `size_and_opcode` word. See also `Header.SizeAndOpcode.opcode`.
    pub inline fn opcode(header: Header) u16 { return header.size_and_opcode.opcode; }

    /// Since Wayland uses 32-bit native-endianess words to encode data, the location of the 
    /// `size` and `opcode` fields change their memory position based on the native endian.
    pub const SizeAndOpcode = packed struct(u32) {
        /// Specifies which Request or Event type the payload corresponds to.
        /// - For messages sent from client to server, self indicates the Request type.
        /// - For messages sent from server to client, self indicates the Event type.
        opcode: u16,
        /// The size of the Wayland message, including the `Header`.
        size: u16,
    };
};

/// This exactly matches the wire format, so it may be directly passed to `read` or `write`.
pub const Int = i32;
/// This exactly matches the wire format, so it may be directly passed to `read` or `write`.
pub const Uint = u32;

pub const Fixed = packed struct(u32) {
    fraction: u8,
    integer: i24,

    pub fn fromInt(integer: i24, fraction: u8) @This() { 
        return .{ 
            .integer = integer, 
            .fraction = fraction 
        }; 
    }

    pub fn fromFloat(comptime T: type, float: T) @This() {
        const denominator: T = @floatFromInt(std.math.maxInt(u8));
        return .{
            .integer = @intFromFloat(float),
            .fraction = @intFromFloat((float - @floor(float)) * denominator),
        };
    }

    pub fn toFloat(self: @This(), comptime T: type) T {
        const fraction: T = @floatFromInt(self.fraction);
        const denominator: T = @floatFromInt(std.math.maxInt(u8));
        const integer: T = @floatFromInt(self.integer);
        return (integer * denominator + fraction) / denominator;
    }
};

/// A string, prefixed with a 32-bit integer specifying its length (in bytes),
/// followed by the string contents and a NUL terminator, padded to 32 bits with 
/// undefined data. The encoding is not specified, but in practice UTF-8 is used.
///
/// This data type does NOT match the wire format. Use custom write/read functions.
pub const String = [:0]const u8;

/// 32-bit object id. A value of 1 refers to the `core.wl_display` singleton object.
///
/// Most Wayland protocols specify the `Object`s interface ahead of time, and self 
/// is exposed using `Object.WithInterface(<INTERFACE>)`.
///
/// This exactly matches the wire format, so it may be directly passed to `read` or `write`.
/// However, to better integrate with Zig's type system, an `Object` should never be 0, 
/// and instead should be wrapped in an Optional type (like so: `?Object`). An optional 
/// `Object` DOES NOT match the wire format.
pub const Object = enum(Uint) {
    wl_display = 1, _,

    pub fn WithInterface(I: type) type {
        return enum(Uint) { _,
            pub const _SPECIFIED_INTERFACE = I;
            pub fn asObject(self: @This()) Object { return @enumFromInt(@intFromEnum(self)); }
            pub fn asNewId(self: @This()) NewId.WithInterface(I) { return @enumFromInt(@intFromEnum(self)); }
            pub fn asGenericNewId(self: @This()) NewId {
                return .{
                    .interface = I.NAME,
                    .version = I.VERSION,
                    .object = @enumFromInt(@intFromEnum(self)),
                };
            }
        };
    }
};

/// A new object id for generic cases where the interface cannot be inferred from the XML. One place 
/// where self is used is `wl_registry`s `bind` request. I guess everywhere else specifies the interface 
/// of the `NewId` ahead of time, it's exposed with `NewId.WithInterface(<INTERFACE>)`.
pub const NewId = struct {
    interface: String,
    version: u32,
    object: Object,

    /// A 32-bit object id. Unlike `object` however, self is only used when the id will be 
    /// freshly allocated before it is sent over the wire. On the other side of the connection
    /// self tells them what id you will use to refer to the new object.
    ///
    /// This exactly matches the wire format, so it may be directly passed to `read` or `write`.
    pub fn WithInterface(I: type) type {
        return enum(Uint) { _,
            pub const _IS_TYPED_NEW_ID = true;
            pub const _SPECIFIED_INTERFACE = I;
        };
    }
    pub fn isTypeNewId(T: type) bool { return @typeInfo(T) == .Enum and @hasDecl(T, "_IS_TYPED_NEW_ID") and T._IS_TYPED_NEW_ID; }
};

/// A blob of arbitrary data, prefixed with a 32-bit integer specifying its length (in bytes),
/// then the verbatim contents of the array, padded to 32 bits with undefined data.
///
/// Wayland XML files don't have a machine-readable way to specify the contents of an array.
/// Thus it falls on you as a Wayland developer to read the protocol documentation and 
/// determine how the bytes should be interpreted.
///
/// This does NOT match the wire format. Use custom write/read functions instead.
pub const Array = []const u8;

/// The file descriptor is not stored in the message buffer, but in the ancillery data 
/// of the UNIX domain socket message (msg_control). This means that the `fd` is packed 
/// into a `cmsg` before being sent in the `control` field of `sendmsg.msgheader`.
pub const Fd = enum(std.posix.fd_t) { _ };

pub const MessageWriter = struct {
    pointer: ?*const anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        create_id_fn: *const fn (context: ?*const anyopaque, name: [:0]const u8, version: u32) Error!Object,
        destroy_id_fn: *const fn (context: ?*const anyopaque, object_id: Object) void,
        begin_fn: *const fn (context: ?*const anyopaque, object_id: Object, opcode: u16) Error!void,
        write_fn: *const fn (context: ?*const anyopaque, bytes: []const u8) Error!void,
        write_control_message_fn: *const fn (context: ?*const anyopaque, bytes: []const u8) Error!void,
        end_fn: *const fn (context: ?*const anyopaque) Error!void,
    };
    pub const Error = error{OutOfMemory};

    pub fn createId(self: @This(), name: [:0]const u8, version: u32) Error!Object {
        return self.vtable.create_id_fn(self.pointer, name, version);
    }

    pub fn destroyId(self: @This(), object_id: Object) void {
        return self.vtable.destroy_id_fn(self.pointer, object_id);
    }

    pub fn begin(self: @This(), object_id: Object, opcode: u16) Error!void {
        return self.vtable.begin_fn(self.pointer, object_id, opcode);
    }

    pub fn write(self: @This(), bytes: []const u8) Error!void {
        return self.vtable.write_fn(self.pointer, bytes);
    }

    pub fn writeControlMessage(self: @This(), bytes: []const u8) Error!void {
        return self.vtable.write_control_message_fn(self.pointer, bytes);
    }

    pub fn end(self: @This()) Error!void { return self.vtable.end_fn(self.pointer); }
    pub fn writeUnsigned(self: @This(), uint: Uint) !void { try self.write(std.mem.asBytes(&uint)); }
    pub fn writeInteger(self: @This(), int: Int) !void { try self.writeUnsigned(@bitCast(int)); }
    pub fn writeObject(self: @This(), object: Object) !void { try self.writeUnsigned(@intFromEnum(object)); }

    pub fn writeString(self: @This(), string: String) !void {
        try self.writeUnsigned(@intCast(string.len + 1));
        try self.write(string);

        const aligned_len = std.mem.alignForward(usize, string.len + 1, @sizeOf(Word));
        const nul_bytes_required = aligned_len - string.len;
        const nul_word = [4]u8{ 0, 0, 0, 0 };
        try self.write(nul_word[0..nul_bytes_required]);
    }

    pub fn writeArray(self: @This(), array: Array) !void {
        try self.writeUnsigned(@intCast(array.len));
        try self.write(array);

        const aligned_len = std.mem.alignForward(usize, array.len + 1, @sizeOf(Word));
        const nul_bytes_required = aligned_len - array.len;
        const nul_word = [4]u8{ 0, 0, 0, 0 };
        try self.write(nul_word[0..nul_bytes_required]);
    }

    pub fn writeOptionalObject(self: @This(), optional_object: ?Object) !void {
        if (optional_object) |object| {
            try self.writeObject(object);
        } else {
            try self.writeUnsigned(0);
        }
    }

    pub fn writeOptionalString(self: @This(), optional_string: ?String) !void {
        if (optional_string) |string| {
            try self.writeString(string);
        } else {
            try self.writeUnsigned(0);
        }
    }

    pub fn writeOptionalArray(self: @This(), optional_array: ?Array) !void {
        if (optional_array) |array| {
            try self.writeArray(array);
        } else {
            try self.writeUnsigned(0);
        }
    }

    pub fn writeFd(self: @This(), fd: Fd) !void {
        const scm_rights_msg: cmsg(std.posix.fd_t) = .{
            .level = std.posix.SOL.SOCKET,
            .type = SCM.RIGHTS,
            .data = @intFromEnum(fd),
        };
        try self.writeControlMessage(std.mem.asBytes(&scm_rights_msg));
    }

    pub fn writeStruct(msg_writer: MessageWriter, comptime Signature: type, message: Signature) MessageWriter.Error!void {
        if (Signature == void) return;
        if (@typeInfo(Signature) != .Struct) @compileError("Unexpected type " ++ @typeName(Signature) ++ 
            ", expected Struct found " ++ @tagName(@typeInfo(Signature)));
        inline for (std.meta.fields(Signature)) |field| {
            const field_compile_error_prefix = @typeName(Signature) ++ "." ++ field.name ++ ": " ++ @typeName(field.type);

            switch (field.type) {
                Uint, Int, Fixed, Object, => try msg_writer.writeUnsigned(@bitCast(@field(message, field.name))),
                ?Object, => try msg_writer.writeOptionalObject(@field(message, field.name)),
                String, => try msg_writer.writeString(@field(message, field.name)),
                Array, => try msg_writer.writeArray(@field(message, field.name)),
                ?String, => try msg_writer.writeOptionalString(@field(message, field.name)),
                ?Array, => try msg_writer.writeOptionalArray(@field(message, field.name)),
                Fd => try msg_writer.writeFd(@field(message, field.name)),
                NewId => {
                    const new_id: NewId = @field(message, field.name);
                    try msg_writer.writeString(new_id.interface);
                    try msg_writer.writeUnsigned(new_id.version);
                    try msg_writer.writeUnsigned(@intFromEnum(new_id.object));
                },
                else => switch (@typeInfo(field.type)) {
                    .Enum => |enum_info| {
                        if (@bitSizeOf(enum_info.tag_type) != 32) @compileError(field_compile_error_prefix ++ 
                            ": enums must have a 32-bit backing integer");
                        try msg_writer.writeUnsigned(@bitCast(@intFromEnum(@field(message, field.name))));
                    },
                    .Struct => |struct_info| {
                        if (struct_info.layout != .Packed) @compileError(field_compile_error_prefix ++
                            ": only 32-bit packed structs have a defined format");
                        if (@bitSizeOf(struct_info.backing_integer.?) != 32) @compileError(field_compile_error_prefix ++
                            ": only 32-bit packed structs have a defined format");
                        try msg_writer.writeUnsigned(@bitCast(@field(message, field.name)));
                    },
                    .Optional => |optional_info| {
                        // We should only be here when a message contains an `?Object.WithInterface(T)` type.
                        if (@typeInfo(optional_info.child) != .Enum) @compileError(field_compile_error_prefix ++
                            ": only `Object` enums may be null");
                        if (!@hasDecl(optional_info.child, "_SPECIFIED_TYPE")) @compileError(field_compile_error_prefix ++
                            ": only `Object` enums may be null");
                        if (@bitSizeOf(@typeInfo(optional_info.child).Enum.tag_type) != 32) @compileError(field_compile_error_prefix ++
                            ": enums must have a 32-bit backing integer");
                        try msg_writer.writeUnsigned(@bitCast(@intFromEnum(@field(message, field.name))));
                    }, 
                    else => @compileError(field_compile_error_prefix ++ ": unsupported type"),
                },
            }
        }
    }
};

pub fn serialize(comptime Union: type, msg_writer: MessageWriter, object_id: Object, message: Union) MessageWriter.Error!void {
    if (@typeInfo(Union).Union.fields.len == 0) @compileError(@typeName(Union) ++ " has no valid messages!");

    try msg_writer.begin(object_id, @intFromEnum(std.meta.activeTag(message)));
    switch (message) {
        inline else => |payload| try msg_writer.writeStruct(@TypeOf(payload), payload),
    }
    try msg_writer.end();
}

pub const BufferedMessageWriter = struct {
    allocator: std.mem.Allocator,
    message_buffer: std.ArrayListUnmanaged(u8),
    control_message_buffer: std.ArrayListUnmanaged(u8),
    header_index: ?usize,
    next_id: u32,

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{
            .allocator = allocator,
            .message_buffer = .{},
            .control_message_buffer = .{},
            .header_index = null,
            .next_id = 2,
        };
    }

    pub fn fini(self: *@This()) void {
        if (self.header_index != null) {
            std.debug.print("BufferedMessageWriter: `fini()` called before `end()` called", .{});
        }
        self.message_buffer.deinit(self.allocator);
        self.control_message_buffer.deinit(self.allocator);
    }

    const MESSAGE_WRITER_VTABLE = &MessageWriter.VTable{
        .create_id_fn = messageWriterCreateId,
        .destroy_id_fn = messageWriterDestroyId,
        .begin_fn = messageWriterBegin,
        .write_fn = messageWriterWrite,
        .write_control_message_fn = messageWriterWriteControlMessage,
        .end_fn = messageWriterEnd,
    };

    pub fn messageWriter(self: *@This()) MessageWriter {
        return MessageWriter{ .pointer = self, .vtable = MESSAGE_WRITER_VTABLE };
    }

    fn messageWriterCreateId(this_opaque: ?*const anyopaque, name: [:0]const u8, version: u32) MessageWriter.Error!Object {
        const self: *@This() = @constCast(@ptrCast(@alignCast(this_opaque)));
        _ = name;
        _ = version;
        defer self.next_id += 1;
        return @enumFromInt(self.next_id);
    }

    fn messageWriterDestroyId(this_opaque: ?*const anyopaque, object_id: Object) void {
        const self: *@This() = @constCast(@ptrCast(@alignCast(this_opaque)));
        _ = self;
        _ = object_id;
    }

    fn messageWriterBegin(this_opaque: ?*const anyopaque, object_id: Object, opcode: u16) MessageWriter.Error!void {
        const self: *@This() = @constCast(@ptrCast(@alignCast(this_opaque)));
        if (self.header_index != null) {
            std.debug.panic("message_writer.begin() called again before message_writer.end() was called", .{});
        }
        try self.message_buffer.ensureUnusedCapacity(self.gpa, @sizeOf(Header));
        const header = Header{
            .object = object_id,
            .size_and_opcode = .{
                .opcode = opcode,
                .size = undefined,
            },
        };
        self.header_index = self.message_buffer.items.len;
        self.message_buffer.appendSliceAssumeCapacity(std.mem.asBytes(&header));
    }

    fn messageWriterEnd(this_opaque: ?*const anyopaque) MessageWriter.Error!void {
        const self: *@This() = @constCast(@ptrCast(@alignCast(this_opaque)));
        const header_index = self.header_index orelse {
            std.debug.panic("message_writer.end() called before message_writer.begin()", .{});
        };
        std.debug.assert(header_index + @sizeOf(Header) < self.message_buffer.items.len);

        const header: *Header = @ptrCast(@alignCast(self.message_buffer.items[header_index..][0..@sizeOf(Header)]));
        header.size_and_opcode.size = @intCast(self.message_buffer.items.len - header_index);
        self.header_index = null;
    }

    fn messageWriterWrite(this_opaque: ?*const anyopaque, bytes: []const u8) MessageWriter.Error!void {
        const self: *@This() = @constCast(@ptrCast(@alignCast(this_opaque)));
        try self.message_buffer.appendSlice(self.allocator, bytes);
    }

    fn messageWriterWriteControlMessage(this_opaque: ?*const anyopaque, bytes: []const u8) MessageWriter.Error!void {
        const self: *@This() = @constCast(@ptrCast(@alignCast(this_opaque)));
        try self.control_message_buffer.appendSlice(self.allocator, bytes);
    }
};

pub const DeserializeError = error{
    InvalidOpcode,
    InvalidEnumTag,
    UnexpectedNullString,
    UnexpectedNullArray,
    UnexpectedEndOfMessage,
    UnexpectedEndOfControlMessage,
};

pub fn deserialize(
    comptime Union: type, 
    buffer: []const u8, 
    index: *usize, 
    control_buffer: []const u8, 
    control_index: *usize,
) DeserializeError!Union {
    if (std.meta.fields(Union).len == 0) std.debug.panic(@typeName(Union) ++ " event has no tags!", .{});     
    const header: *const Header = @ptrCast(@alignCast(buffer[index.*..][0..@sizeOf(Header)]));
    if (header.size() > buffer[index.*..].len) { return error.UnexpectedEndOfMessage; }

    const op = std.meta.intToEnum(std.meta.Tag(Union), header.opcode()) catch return error.InvalidOpcode;

    var sub_index = index.* + @sizeOf(Header);
    var sub_control_index = control_index.*;
    switch (op) {
        inline else => |f| {
            const TagPayload = std.meta.TagPayload(Union, f);
            const payload = try deserializeArguments(TagPayload, buffer, &sub_index, control_buffer, &sub_control_index);
            index.* = sub_index;
            control_index.* = sub_control_index;
            return @unionInit(Union, @tagName(f), payload);
        },
    }
}

pub fn deserializeArguments(
    comptime Signature: type, 
    buffer: []const u8,
    index: *usize,
    control_buffer: []const u8,
    control_index: *usize,
) DeserializeError!Signature {
    if (Signature == void) return {};
    if (@typeInfo(Signature) != .Struct) @compileError("Unexpected type " ++ @typeName(Signature) ++ 
        ", expected Struct found " ++ @tagName(@typeInfo(Signature)));
    var sub_index = index.*;
    var sub_control_index = control_index.*;
    var result: Signature = undefined;

    inline for (std.meta.fields(Signature)) |field| {
        const field_compile_error_prefix = @typeName(Signature)  ++ "." ++ field.name ++ ": " ++ @typeName(field.type);
        switch (field.type) {
            Uint, Int, Fixed, => @field(result, field.name) = @bitCast(try readUnsigned(buffer, &sub_index)),
            Object, => @field(result, field.name) = @enumFromInt(try readUnsigned(buffer, &sub_index)),
            ?Object, => @field(result, field.name) = try readOptionalObject(buffer, &sub_index),
            String, => @field(result, field.name) = (try readString(buffer, &sub_index)) orelse return error.UnexpectedNullString,
            Array, => @field(result, field.name) = try readArray(buffer, &sub_index),
            ?String, => @field(result, field.name) = try readString(buffer, &sub_index),
            Fd, => @field(result, field.name) = try readFd(control_buffer, &sub_control_index),
            NewId, => {
                @field(result, field.name) = NewId{
                    .interface = (try readString(buffer, &sub_index)) orelse return error.UnexpectedNullString,
                    .version = try readUnsigned(buffer, &sub_index),
                    .object = try readUnsigned(buffer, &sub_index),
                };
            },
            else => switch (@typeInfo(field.type)) {
                .Enum => |enum_info| {
                    if (@bitSizeOf(enum_info.tag_type) != 32) @compileError(field_compile_error_prefix ++ 
                        ": enums must have a 32-bit backing integer");
                    @field(result, field.name) = @enumFromInt(try readUnsigned(buffer, &sub_index));
                },
                .Struct => |struct_info| {
                    if (struct_info.layout != .Packed) @compileError(field_compile_error_prefix ++
                        ": only 32-bit packed structs have a defined format");
                    if (@bitSizeOf(struct_info.backing_integer.?) != 32) @compileError(field_compile_error_prefix ++
                        ": only 32-bit packed structs have a defined format");
                    @field(result, field.name) = @bitCast(try readUnsigned(buffer, &sub_index));
                },
                .Optional => |optional_info| {
                    // We should only be here when a message contains an `?Object.WithInterface(T)` type.
                    if (@typeInfo(optional_info.child) != .Enum) @compileError(field_compile_error_prefix ++
                        ": only `Object` enums may be null");
                    if (!@hasDecl(optional_info.child, "_SPECIFIED_TYPE")) @compileError(field_compile_error_prefix ++
                        ": only `Object` enums may be null");
                    if (@bitSizeOf(@typeInfo(optional_info.child).Enum.tag_type) != 32) @compileError(field_compile_error_prefix ++
                        ": enums must have a 32-bit backing integer");
                    const uint = try readUnsigned(buffer, &sub_index);
                    if (uint == 0) {
                        @field(result, field.name) = null;
                    } else {
                        @field(result, field.name) = @enumFromInt(uint);
                    }
                }, 
                else => @compileError(field_compile_error_prefix ++ ": unsupported type"),
            },
        }
    }
    index.* = sub_index;
    control_index.* = sub_control_index;
    return result;
}

pub fn readUnsigned(buffer: []const u8, parent_pos: *usize) !Uint {
    var pos = parent_pos.*;
    if (pos + @sizeOf(Word) > buffer.len) return error.UnexpectedEndOfMessage;

    const uint = std.mem.bytesToValue(Uint, buffer[pos..][0..4]);
    pos += @sizeOf(Uint);
    parent_pos.* = pos;
    return uint;
}

pub fn readInteger(buffer: []const u8, pos: *usize) !Int {
    const uint = try readUnsigned(buffer, pos);
    return @bitCast(uint);
}

pub fn readString(buffer: []const u8, parent_pos: *usize) !?String {
    var pos = parent_pos.*;
    const len = try readUnsigned(buffer, &pos);
    if (len == 0) {
        parent_pos.* = pos;
        return null;
    }
    const aligned_size = std.mem.alignForward(usize, len, @sizeOf(Word));

    if (pos + aligned_size > buffer.len) return error.UnexpectedEndOfMessage;
    const string = buffer[pos..][0 .. len - 1 :0];
    pos += aligned_size;
    parent_pos.* = pos;
    return string;
}

pub fn readArray(buffer: []const u8, parent_pos: *usize) !Array {
    var pos = parent_pos.*;
    const byte_size = try readUnsigned(buffer, &pos);
    const aligned_size = std.mem.alignForward(usize, byte_size, @sizeOf(Word));

    if (aligned_size > buffer[pos..].len) { return error.UnexpectedEndOfMessage; }

    const array = buffer[pos..][0..byte_size];
    pos += aligned_size;
    parent_pos.* = pos;
    return array;
}

pub fn readObject(buffer: []const u8, pos: *usize) !Object { 
    return @enumFromInt(try readUnsigned(buffer, pos));
}

pub fn readOptionalObject(buffer: []const u8, pos: *usize) !?Object {
    const uint = try readUnsigned(buffer, pos, 0);
    if (uint == 0) return null;
    return @enumFromInt(uint);
}

pub fn readFd(control_buffer: []const u8, control_pos: *usize) !Fd {
    const MSG_SIZE = @sizeOf(cmsg(std.posix.fd_t));
    const scm_rights_msg: *const cmsg(std.posix.fd_t) = @ptrCast(@alignCast(control_buffer[control_pos.*..][0..MSG_SIZE]));
    control_pos.* += MSG_SIZE;
    return @enumFromInt(scm_rights_msg.data);
}

pub const MessageSize = struct {
    /// The number of 32-bit words required to serialize the payload.
    payload_words: u14,
    /// The number of bytes required for the control message.
    control_message_bytes: u32,
};

pub const MessageSizeEstimate = struct {
    min_message_size: u16,
    /// How many dynamic elements (strings and arrays) are in self message signature.
    dynamic_element_count: u32,
    /// The exact number of bytes needed to send the control message.
    /// Possible to know because the fd messages are not variably sized.
    control_message_bytes: u32,
};

/// Estimates the space required to serialize a given message.
pub fn estimateSerializedSize(comptime Signature: type) MessageSizeEstimate {
    var estimate = MessageSizeEstimate{
        .min_message_size = @sizeOf(Header),
        .dynamic_element_count = 0,
        .control_message_bytes = 0,
    };
    inline for (std.meta.fields(Signature)) |field| {
        switch (field.type) {
            Uint, Int, Fixed, Object, ?Object, => estimate.min_message_size += @sizeOf(Word),
            String, ?String, Array, ?Array, => {
                // add 1 for the string length prefix word
                estimate.min_message_size += @sizeOf(Word);
                estimate.dynamic_element_count += 1;
            },
            Fd => estimate.control_message_bytes += @sizeOf(cmsg(std.posix.fd_t)),
            NewId => {
                const new_id_estimate = estimateSerializedSize(NewId);
                estimate.min_message_size += new_id_estimate.min_message_size;
                estimate.dynamic_element_count += new_id_estimate.dynamic_element_count;
                estimate.control_message_bytes += new_id_estimate.control_message_bytes;
            },
            else => switch (@typeInfo(field.type)) {
                .Enum => |enum_info| {
                    if (@bitSizeOf(enum_info.tag_type) != 32) @compileError("Unsupported type " ++ @typeName(field.type) ++
                        " in " ++ @typeName(Signature) ++ " (field " ++ field.name ++ "): enums must have a 32-bit backing integer");
                    estimate.min_message_size += @sizeOf(Word);
                },
                .Struct => |struct_info| {
                    if (struct_info.layout != .Packed) @compileError("Unsupported type " ++ @typeName(field.type) ++
                        " in " ++ @typeName(Signature) ++ " (field " ++ field.name ++ "): only packed structs are allowed");
                    if (@bitSizeOf(struct_info.backing_integer.?) != 32) @compileError("Unsupported type " ++ @typeName(field.type) ++
                        " in " ++ @typeName(Signature) ++ " (field " ++ field.name ++ "): packed structs must have a 32-bit backing integer");
                    estimate.min_message_size += @sizeOf(Word);
                },
                .Optional => |optional_info| {
                    // We should only be here when a message contains an `?Object.WithInterface(T)` type.
                    if (@typeInfo(optional_info.child) != .Enum) @compileError("Unsupported type " ++ @typeName(field.type) ++
                        " in " ++ @typeName(Signature) ++ " (field " ++ field.name ++ "): only `Object` enums may be null");
                    if (!@hasDecl(optional_info.child, "_SPECIFIED_TYPE")) @compileError("Unsupported type " ++ @typeName(field.type) ++
                        " in " ++ @typeName(Signature) ++ " (field " ++ field.name ++ "): only `Object` enums may be null");
                    if (@bitSizeOf(@typeInfo(optional_info.child).Enum.tag_type) != 32) @compileError("Unsupported type " ++ @typeName(field.type) ++
                        " in " ++ @typeName(Signature) ++ " (field " ++ field.name ++ "): enums must have a 32-bit backing integer");
                    estimate.min_message_size += @sizeOf(Word);
                }, 
                else => @compileError("Unsupported type " ++ @typeName(field.type) ++ " in " ++ @typeName(Signature) ++ " (field " ++ field.name ++ ")"),
            },
        }
    }
    return estimate;
}

/// Returns the length of the serialized message in `u32` words.
pub fn calculateSerializedWordLen(comptime Signature: type, message: Signature) MessageSize {
    var message_size = MessageSize{
        .payload_words = 0,
        .control_message_bytes = 0,
    };
    inline for (std.meta.fields(Signature)) |field| {
        switch (field.type) {
            Uint, Int, Fixed, Object, ?Object, => message_size.payload_words += 1,
            String => {
                message_size.payload_words += 1; // add 1 for the string length prefix word
                const byte_size = @field(message, field.name).len + 1; // add 1 for the null byte 
                message_size.payload_words += std.mem.alignForward(usize, byte_size, @sizeOf(u32)) / @sizeOf(u32);
            },
            ?String => {
                message_size.payload_words += 1; // add 1 for the string length prefix word
                if (@field(message, field.name)) |string| {
                    const byte_size = string.len + 1; // add 1 for the null byte 
                    message_size.payload_words += std.mem.alignForward(usize, byte_size, @sizeOf(u32)) / @sizeOf(u32);
                }
            },
            Array => {
                message_size.payload_words += 1; // add 1 for the array length prefix word
                const byte_size = @field(message, field.name).len;
                message_size.payload_words += std.mem.alignForward(usize, byte_size, @sizeOf(u32)) / @sizeOf(u32);
            },
            ?Array => {
                message_size.payload_words += 1; // add 1 for the array length prefix word
                if (@field(message, field.name)) |array| {
                    const byte_size = array.len;
                    message_size.payload_words += std.mem.alignForward(usize, byte_size, @sizeOf(u32)) / @sizeOf(u32);
                }
            },
            Fd => message_size.control_message_bytes += @sizeOf(cmsg(std.posix.fd_t)),
            NewId => {
                const new_id_size = calculateSerializedWordLen(NewId, @field(message, field.name));
                message_size.payload_words += new_id_size.payload_words;
                message_size.control_message_bytes += new_id_size.control_message_bytes;
            },
            else => switch (@typeInfo(field.type)) {
                .Enum => |enum_info| {
                    if (@bitSizeOf(enum_info.tag_type) != 32) @compileError("Unsupported type " ++ @typeName(field.type) ++
                        " in " ++ @typeName(Signature) ++ " (field " ++ field.name ++ "): enums must have a 32-bit backing integer");
                    message_size.payload_words += 1;
                },
                .Struct => |struct_info| {
                    if (struct_info.layout != .Packed) @compileError("Unsupported type " ++ @typeName(field.type) ++
                        " in " ++ @typeName(Signature) ++ " (field " ++ field.name ++ "): only packed structs are allowed");
                    if (@bitSizeOf(struct_info.backing_integer.?) != 32) @compileError("Unsupported type " ++ @typeName(field.type) ++
                        " in " ++ @typeName(Signature) ++ " (field " ++ field.name ++ "): packed structs must have a 32-bit backing integer");
                    message_size.payload_words += 1;
                },
                .Optional => |optional_info| {
                    // We should only be here when a message contains an `?Object.WithInterface(T)` type.
                    if (@typeInfo(optional_info.child) != .Enum) @compileError("Unsupported type " ++ @typeName(field.type) ++
                        " in " ++ @typeName(Signature) ++ " (field " ++ field.name ++ "): only `Object` enums may be null");
                    if (!@hasDecl(optional_info.child, "_SPECIFIED_TYPE")) @compileError("Unsupported type " ++ @typeName(field.type) ++
                        " in " ++ @typeName(Signature) ++ " (field " ++ field.name ++ "): only `Object` enums may be null");
                    if (@bitSizeOf(@typeInfo(optional_info.child).Enum.tag_type) != 32) @compileError("Unsupported type " ++ @typeName(field.type) ++
                        " in " ++ @typeName(Signature) ++ " (field " ++ field.name ++ "): enums must have a 32-bit backing integer");
                    message_size.payload_words += 1;
                }, 
                else => @compileError("Unsupported type " ++ @typeName(field.type) ++ " in " ++ @typeName(Signature) ++ " (field " ++ field.name ++ ")"),
            },
        }
    }
}

const SCM = struct { const RIGHTS = 0x01; };

/// We define a generic `cmsg` type here for reading and writing control messages.
/// In C, self is accomplished using macros.
fn cmsg(comptime T: type) type {
    const raw_struct_size = @sizeOf(c_ulong) + @sizeOf(c_int) + @sizeOf(c_int) + @sizeOf(T);
    const padded_struct_size = std.mem.alignForward(usize, @sizeOf(c_ulong) + @sizeOf(c_int) + @sizeOf(c_int) + @sizeOf(T), @alignOf(c_ulong));
    const padding_size = padded_struct_size - raw_struct_size;
    return extern struct {
        len: c_ulong = raw_struct_size,
        level: c_int,
        type: c_int,
        data: T,
        _padding: [padding_size]u8 align(1) = [_]u8{0} ** padding_size,
        // Calculate the size of the message if padding is included.
        // This function was made for reading potentially unknown control messages, using `cmsg(void)`.
        pub fn size(self: @This()) usize { return std.mem.alignForward(usize, self.len, @alignOf(c_long)); }
    };
}

test "[]u32 from header" {
    try std.testing.expectEqualSlices(u32,
        &[_]u32{1, (@as(u32, 12) << 16) | (4), },
        &@as([2]u32, @bitCast(Header{
            .object_id = 1,
            .size_and_opcode = .{
                .size = 12,
                .opcode = 4,
            },
        })),
    );
}

test "header from []u32" {
    try std.testing.expectEqualDeep(
        Header{
            .object_id = 1,
            .size_and_opcode = .{
                .size = 12,
                .opcode = 4,
            },
        }, @as(Header, @bitCast([2]u32{
            1, (@as(u32, 12) << 16) | (4),
        })),
    );
}

/// Structs and functions for interfacing with libwayland.
pub const compat = struct {

    pub const wl_message = extern struct {
        name: [*:0]const u8,
        signature: [*:0]const u8,
        types: [*]const ?*const wl_interface,
    };

    pub const wl_interface = extern struct {
        name: [*:0]const u8,
        version: c_int,
        request_count: c_int,
        requests: ?[*]const wl_message,
        event_count: c_int,
        events: ?[*]const wl_message,
    };

    pub const wl_array = extern struct {
        size: usize,
        capacity: usize,
        data: ?*anyopaque,
    };

    pub const wl_fixed = Fixed;
    pub const wl_argument = extern union {
        int: i32,
        uint: u32,
        fixed: wl_fixed,
        string: ?[*:0]const u8,
        object: ?*wl_object,
        new_id: u32,
        array: *wl_array,
        fd: std.posix.fd_t,
    };

    pub const wl_object = opaque {};
    pub const wl_proxy = opaque {};

    pub const MarshalFlags = packed struct(u32) {
        destroy: bool = false,
        _: u31 = 0,
    };
};
