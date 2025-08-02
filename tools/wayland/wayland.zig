const std = @import("std");
const builtin = @import("builtin");

pub const wire = @import("wayland-wire");
pub const wp = @import("wayland-protocols");
pub const compat = @import("./libwayland-compat.zig");

comptime { if (builtin.is_test) _ = wire; }

/// No message can be larger than this, since the size of a message is stored in 16 bits.
pub const MAX_MESSAGE_WORDSIZE = MAX_MESSAGE_SIZE / @sizeOf(u32);
/// No message can be larger than this, since the size of a message is stored in 16 bits.
pub const MAX_MESSAGE_SIZE = std.math.maxInt(u16);

/// Open a connection to the Wayland compositor, handling the various environment variables that may be set.
pub fn openConnection(allocator: std.mem.Allocator, options: Connection.OpenOptions) !Connection {
    const location = try findConnectionLocation();

    const message_buffer = try allocator.alloc(u8, options.recv_buffer_size);
    errdefer allocator.free(message_buffer);

    const control_buffer = try allocator.alloc(u8, options.control_recv_buffer_size);
    errdefer allocator.free(control_buffer);

    switch (location) {
        .fd => |socket_fd| {
            return Connection{
                .allocator = allocator,
                .socket = socket_fd,
                .recv_buffer = message_buffer,
                .control_recv_buffer = control_buffer,
            };
        },
        .path => |path_array| {
            const stream = try std.net.connectUnixSocket(path_array.slice());
            errdefer stream.close();

            return Connection{
                .allocator = allocator,
                .socket = stream.handle,
                .recv_buffer = message_buffer,
                .control_recv_buffer = control_buffer,
            };
        },
    }
}

pub const Connection = struct {
    allocator: std.mem.Allocator,
    socket: std.posix.fd_t,
    /// The next object id that will be allocated.
    next_id: u32 = 2,
    /// Object ids that have been released by the compositor. If the `free_ids` buffer fills up
    /// the Connection will start "losing" ids. However, in practice this shouldn't be an issue:
    ///
    /// 1. cases where many ids are allocated and freed are rare
    /// 2. the lost ids don't represent lost memory, just lost address space
    ///
    /// The number 1024 is arbitrary.
    free_ids: std.BoundedArray(u32, 1024) = .{},
    objects: std.AutoHashMapUnmanaged(wire.Object, ObjectInfo) = .{},
    /// A buffer to read data into.
    recv_buffer: []u8,
    /// Keeps track of where should we start reading into recv_buffer.
    recv_index: u32 = 0,
    /// Keep the recv iov with the struct so we can return pointers to it.
    recv_iov: [1]std.posix.iovec = undefined,
    /// A buffer to read control messages into.
    control_recv_buffer: []u8,
    /// Keeps track of where should we start reading into control_recv_buffer.
    control_index: u32 = 0,

    recv_msghdr: std.posix.msghdr = undefined,
    send_buffer: std.ArrayListUnmanaged(u8) = .{},
    send_control_buffer: std.ArrayListUnmanaged(u8) = .{},
    /// Index of the header of the message that is currently being written
    header_index: ?usize = null,

    pub const OpenOptions = struct {
        recv_buffer_size: u32 = MAX_MESSAGE_SIZE,
        control_recv_buffer_size: u32 = 1024,
    };
    pub fn close(connection: *Connection) void {
        if (builtin.mode == .Debug) {
            var iov = [_]std.posix.iovec{
                .{ // only read into the unused portion of the buffer 
                    .base = connection.recv_buffer[connection.recv_index..].ptr,
                    .len = connection.recv_buffer[connection.recv_index..].len,
                },
            };
            const control_recv_unused = connection.control_recv_buffer[connection.control_index..];
            var recv_msg = std.os.linux.msghdr{
                .name = null,
                .namelen = 0,
                .iov = &iov,
                .iovlen = iov.len,
                // only read into the unused portion of the buffer 
                .control = control_recv_unused.ptr,
                .controllen = @intCast(control_recv_unused.len),
                .flags = 0,
            };
            const bytes_read = std.os.linux.recvmsg(connection.socket, &recv_msg, std.posix.MSG.DONTWAIT);
            const errno = std.posix.errno(bytes_read);
            if (errno == .SUCCESS) {
                connection.recv_index += @intCast(bytes_read);
                connection.control_index += recv_msg.controllen;
            } else if (errno != .AGAIN) {
                std.log.warn("Error while reading from socket: {}", .{errno});
            }
            // search for error messages
            var index: usize = 0;
            var control_index: usize = 0;
            while (connection.recv_buffer[index..connection.recv_index].len > @sizeOf(wire.Header)) {
                const header: *const wire.Header = @ptrCast(@alignCast(connection.recv_buffer[index..][0..@sizeOf(wire.Header)]));

                if (header.object == .wl_display) {
                    const event = wire.deserialize(wp.wl_display.Event, connection.recv_buffer[0..connection.recv_index],
                        &index, connection.control_recv_buffer[0..connection.control_index], &control_index) catch |err| 
                    {
                        std.log.warn("Error deserializing message: {}", .{err});
                        index += std.mem.alignForward(usize, header.size(), @sizeOf(wire.Word));
                        continue;
                    };
                    switch (event) {
                        .@"error" => |err| if (connection.objects.get(err.object_id)) |object_info| {
                                std.log.warn("{s}@{} error {} \"{}\"", .{ object_info.interface_name, 
                                    @intFromEnum(err.object_id), err.code, std.zig.fmtEscapes(err.message) });
                            } else {
                                std.log.warn("unknown@{} error {} \"{}\"", .{ 
                                    @intFromEnum(err.object_id), err.code, std.zig.fmtEscapes(err.message) });
                            }, 
                        else => {},
                    }
                } else {
                    index += std.mem.alignForward(usize, header.size(), @sizeOf(wire.Word));
                }
            }
            if (connection.send_buffer.items.len > 0) {
                std.log.warn("Unsent bytes left in send buffer", .{});
                std.debug.dump_hex(connection.send_buffer.items);
            }
            if (connection.send_control_buffer.items.len > 0) {
                std.log.warn("Unsent bytes left in control send buffer", .{});
                std.debug.dump_hex(connection.send_control_buffer.items);
            }
            if (connection.header_index != null) std.log.warn("Connection.close called before message finished being written.", .{});
        }
        var object_iter = connection.objects.iterator();
        while (object_iter.next()) |entry| {
            if (entry.value_ptr.*.delete_listener) |delete_listener| {
                delete_listener.callback(connection, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        connection.objects.deinit(connection.allocator);

        connection.send_buffer.deinit(connection.allocator);
        connection.send_control_buffer.deinit(connection.allocator);

        connection.allocator.free(connection.recv_buffer);
        connection.allocator.free(connection.control_recv_buffer);
        std.posix.close(connection.socket);
    }

    pub fn getDisplay(connection: *Connection) wp.wl_display {
        _ = connection;
        return @enumFromInt(@intFromEnum(wire.Object.wl_display));
    }

    /// Does not inform the server of the existence of this object. That is up to the caller to handle,
    /// using one of the protocol requests defined by Wayland. The code will look something like this:
    ///
    /// ```zig 
    /// const new_object = try connection.createObject(INTERFACE_TYPE);
    /// try existing_object.send(.{ .request_name = .{ .new_id = new_object.id } });
    /// ```
    pub fn createObject(connection: *Connection, I: type) !I {
        try connection.objects.ensureTotalCapacity(connection.allocator, 1);

        const id = connection.free_ids.popOrNull() orelse alloc_id: {
            defer connection.next_id += 1;
            break :alloc_id connection.next_id;
        };
        connection.objects.putAssumeCapacityNoClobber(@enumFromInt(id), .{
            .interface_name = I.NAME,
            .interface_version = I.VERSION,
            .listener = null,
            .listener_destructor = null,
        });
        return @enumFromInt(id);
    }

    const MESSAGE_WRITER_VTABLE = &wire.MessageWriter.VTable{
        .create_id_fn = messageWriterCreateId,
        .destroy_id_fn = messageWriterDestroyId,
        .begin_fn = messageWriterBegin,
        .write_fn = messageWriterWrite,
        .write_control_message_fn = messageWriterWriteControlMessage,
        .end_fn = messageWriterEnd,
    };

    pub fn messageWriter(this: *@This()) wire.MessageWriter {
        return wire.MessageWriter{
            .pointer = this,
            .vtable = MESSAGE_WRITER_VTABLE,
        };
    }

    fn messageWriterCreateId(context: ?*const anyopaque, name: [:0]const u8, version: u32) wire.MessageWriter.Error!wire.Object {
        const connection: *Connection = @ptrCast(@alignCast(@constCast(context)));
        try connection.objects.ensureUnusedCapacity(connection.allocator, 1);

        const id = connection.free_ids.popOrNull() orelse alloc_id: {
            defer connection.next_id += 1;
            break :alloc_id connection.next_id;
        };
        connection.objects.putAssumeCapacityNoClobber(@enumFromInt(id), .{
            .interface_name = name,
            .interface_version = version,
            .listener = null,
            .listener_destructor = null,
        });
        return @enumFromInt(id);
    }

    fn messageWriterDestroyId(context: ?*const anyopaque, object_id: wire.Object) void {
        const connection: *Connection = @ptrCast(@alignCast(@constCast(context.?)));
        const entry = connection.objects.fetchRemove(object_id) orelse {
            std.log.warn("Unknown object id destroyed", .{});
            std.debug.dumpCurrentStackTrace(@returnAddress());
            return;
        };
        if (entry.value.delete_listener) |listen| {
            listen.callback();
        }
    }

    fn messageWriterBegin(this_opaque: ?*const anyopaque, object_id: wire.Object, opcode: u16) wire.MessageWriter.Error!void {
        const this: *@This() = @constCast(@ptrCast(@alignCast(this_opaque)));

        if (this.header_index != null) {
            std.debug.panic("message_writer.begin() called again before message_writer.end() was called", .{});
        }
        try this.send_buffer.ensureUnusedCapacity(this.allocator, @sizeOf(wire.Header));

        const header = wire.Header{
            .object = object_id,
            .size_and_opcode = .{
                .opcode = opcode,
                .size = undefined,
            },
        };
        this.header_index = this.send_buffer.items.len;
        this.send_buffer.appendSliceAssumeCapacity(std.mem.asBytes(&header));
    }

    fn messageWriterEnd(this_opaque: ?*const anyopaque) wire.MessageWriter.Error!void {
        const this: *@This() = @constCast(@ptrCast(@alignCast(this_opaque)));

        const header_index = this.header_index orelse {
            std.debug.panic("message_writer.end() called before message_writer.begin()", .{});
        };
        std.debug.assert(header_index + @sizeOf(wire.Header) <= this.send_buffer.items.len);

        const header: *wire.Header = @ptrCast(@alignCast(this.send_buffer.items[header_index..][0..@sizeOf(wire.Header)]));
        header.size_and_opcode.size = @intCast(this.send_buffer.items.len - header_index);
        this.header_index = null;
    }

    fn messageWriterWrite(this_opaque: ?*const anyopaque, bytes: []const u8) wire.MessageWriter.Error!void {
        const this: *@This() = @constCast(@ptrCast(@alignCast(this_opaque)));
        try this.send_buffer.appendSlice(this.allocator, bytes);
    }

    fn messageWriterWriteControlMessage(this_opaque: ?*const anyopaque, bytes: []const u8) wire.MessageWriter.Error!void {
        const this: *@This() = @constCast(@ptrCast(@alignCast(this_opaque)));
        try this.send_control_buffer.appendSlice(this.allocator, bytes);
    }

    pub fn sendRequest(
        connection: *Connection, 
        I: type, 
        object: wire.Object.WithInterface(I), 
        comptime opcode: std.meta.Tag(I.Request), 
        params: RequestWithoutNewId(I.Request, opcode),
    ) !RequestReturnType(I.Request, opcode) {
        var result: RequestReturnType(I.Request, opcode) = undefined;
        if (RequestReturnType(I.Request, opcode) != void)
            result = try connection.createObject(@TypeOf(result)._INTERFACE);
        // The original parameters type, including the new id
        var original_params: std.meta.TagPayload(I.Request, opcode) = undefined;
        inline for (@typeInfo(std.meta.TagPayload(I.Request, opcode)).Struct.fields) |original_field| {
            if (comptime wire.NewId.isTypedNewId(original_field.type)) {
                @field(original_params, original_field.name) = result.id.asNewId();
            } else {
                @field(original_params, original_field.name) = @field(params, original_field.name);
            }
        }
        try wire.serialize(I.Request, connection.messageWriter(), object.asObject(), @unionInit(I.Request, @tagName(opcode), original_params), );
        return result;
    }

    pub fn flushSendBuffers(connection: *Connection) !void {
        std.debug.assert(connection.header_index == null);
        const msg_iov = [_]std.posix.iovec_const{
            .{
                .base = connection.send_buffer.items.ptr,
                .len = connection.send_buffer.items.len,
            },
        };
        const socket_msg = std.posix.msghdr_const{
            .name = null,
            .namelen = 0,
            .iov = &msg_iov,
            .iovlen = msg_iov.len,
            .control = connection.send_control_buffer.items.ptr,
            .controllen = @intCast(connection.send_control_buffer.items.len),
            .flags = 0,
        };
        _ = try std.posix.sendmsg(connection.socket, &socket_msg, 0);
        connection.send_buffer.shrinkRetainingCapacity(0);
        connection.send_control_buffer.shrinkRetainingCapacity(0);
    }

    pub fn recv(connection: *Connection) !void {
        try connection.flushSendBuffers();
        const bytes_read = std.os.linux.recvmsg(connection.socket, connection.getRecvMsgHdr(), 0);
        try connection.processRecvMsgReturn(bytes_read);
    }

    pub fn getRecvMsgHdr(connection: *Connection) *std.posix.msghdr {
        connection.recv_iov = [_]std.posix.iovec{
            .{
                .base = connection.recv_buffer[connection.recv_index..].ptr,
                .len = connection.recv_buffer[connection.recv_index..].len,
            },
        };
        const control_recv_unused = connection.control_recv_buffer[connection.control_index..];
        connection.recv_msghdr = .{
            .name = null,
            .namelen = 0,
            .iov = &connection.recv_iov,
            .iovlen = connection.recv_iov.len,
            .control = control_recv_unused.ptr,
            .controllen = @intCast(control_recv_unused.len),
            .flags = 0,
        };
        return &connection.recv_msghdr;
    }

    pub fn processRecvMsgReturn(connection: *Connection, bytes_read: usize) !void {
        const res = std.posix.errno(bytes_read);
        if (res != .SUCCESS) {
            std.debug.print("Error while reading from socket: {}", .{res});
            return error.Unknown;
        }
        connection.recv_index += @intCast(bytes_read);
        connection.control_index += connection.recv_msghdr.controllen;

        const unused = try connection.dispatchMessages(
            connection.recv_buffer[0..connection.recv_index],
            connection.control_recv_buffer[0..connection.control_index],
        );
        // Move unused portions of the recv buffers to the start of their buffers
        for (connection.recv_buffer[0..unused.buffer.len], unused.buffer) |*dest, src| { dest.* = src; }
        for (connection.control_recv_buffer[0..unused.control.len], unused.control) |*dest, src| { dest.* = src; }
    }

    pub fn dispatchMessages(
        connection: *Connection, 
        buffer: []const u8, 
        control_messages: []const u8,
    ) !struct { buffer: []const u8, control: []const u8 } {
        var index: usize = 0;
        var control_index: usize = 0;
        while (buffer[index..].len >= @sizeOf(wire.Header)) {
            const header: *const wire.Header = @ptrCast(@alignCast(buffer[index..][0..@sizeOf(wire.Header)]));

            if (connection.objects.get(header.object)) |object_info| {
                if (object_info.listener) |listener| {
                    try listener.callback(connection, header.object, object_info, buffer, &index, control_messages, &control_index);
                } else {
                    index += std.mem.alignForward(usize, header.size(), @sizeOf(wire.Word));
                    continue;
                }
            } else if (header.object == .wl_display) {
                switch (try wire.deserialize(wp.wl_display.Event, buffer, &index, control_messages, &control_index)) {
                    .@"error" => |err| if (connection.objects.get(err.object_id)) |object_info| {
                        std.log.warn("{s}@{} error {} \"{}\"", .{ object_info.interface_name, @intFromEnum(err.object_id), err.code, std.zig.fmtEscapes(err.message) });
                    } else {
                        std.log.warn("Unknown@{} error {} \"{}\"", .{ @intFromEnum(err.object_id), err.code, std.zig.fmtEscapes(err.message) });
                    },
                    .delete_id => |delete_id| {
                        if (connection.objects.fetchRemove(@enumFromInt(delete_id.id))) |entry| {
                            if (entry.value.listener_destructor) |destructor| {
                                destructor.callback(connection, entry.key, entry.value);
                            }
                        }
                        connection.free_ids.append(delete_id.id) catch std.log.debug("{*} leaked id {}", .{ connection, delete_id.id });
                    },
                }
            } else {
                std.log.warn("Unknown object id = 0x{x}", .{@intFromEnum(header.object)});
                return error.UnknownObject;
            }
        }
        return .{
            .buffer = buffer[index..],
            .control = control_messages[control_index..],
        };
    }

    pub fn setEventListener(
        connection: *Connection, 
        ObjectI: type, 
        obj: ObjectI, 
        listener: *Listener, 
        comptime callback: *const fn (*Listener, *Connection, ObjectI, ObjectI.Event)
        Listener.Error!void,
        userdata: ?*anyopaque,
    ) void {
        const Wrapper = struct {
            fn onMessageReceived(
                connection_inner: *Connection, 
                object: wire.Object, 
                object_info: ObjectInfo, 
                message_buffer: []const u8,
                message_index: *usize,
                control_buffer: []const u8,
                control_index: *usize)
                Listener.Error!void 
            {
                const event = try wire.deserialize(ObjectI.Event, message_buffer, message_index, control_buffer, control_index);
                try callback(object_info.listener.?, connection_inner, @enumFromInt(@intFromEnum(object)), event);
            }
        };
        listener.* = .{
            .callback = Wrapper.onMessageReceived,
            .userdata = userdata,
        };
        connection.objects.getPtr(@enumFromInt(@intFromEnum(obj))).?.listener = listener;
    }

    pub fn removeListener(this: @This()) void {
        this.connection.objects.getPtr(this.id.asObject()).?.listener = null;
    }
};

pub fn globalMatchesInterface(global: std.meta.TagPayload(wp.wl_registry.Event, .global), I: type) bool {
    return std.mem.eql(u8, global.interface, I.NAME) and global.version >= I.VERSION;
}

pub const Listener = struct {
    callback: *const fn (connection: *Connection, wire.Object, ObjectInfo, message_buffer: []const u8, message_index: *usize, control_buffer: []const u8, control_index: *usize) Listener.Error!void,
    userdata: ?*anyopaque,
    pub const Error = wire.DeserializeError || wire.MessageWriter.Error || std.posix.SendMsgError;
};

pub const ListenerDestructor = struct {
    callback: *const fn (connection: *Connection, wire.Object, ObjectInfo) void,
};

pub const ObjectInfo = struct {
    interface_name: wire.String,
    interface_version: wire.Uint,
    listener: ?*Listener,
    listener_destructor: ?*ListenerDestructor,
};

/// A location the Wayland connection might be at, according to the environment 
/// variables described in the Wayland protocol.
pub const ConnectionLocation = union(enum) {
    /// The Wayland connection is on an already open file descriptor, likely opened by the parent process.
    fd: std.posix.fd_t,
    /// According to the set environment variables, the Wayland connection should be at this path.
    /// The connection won't be at that path if the user doesn't have a Wayland compositor, 
    /// so there is no guarantee that it is definitely at this path.
    path: std.BoundedArray(u8, std.fs.max_path_bytes),
};

pub fn findConnectionLocation() error{ Overflow, InvalidCharacter, XDGRuntimeDirEnvironmentVariableNotFound }!ConnectionLocation {
    if (std.process.parseEnvVarInt("WAYLAND_SOCKET", std.posix.fd_t, 10)) |file_descriptor| {
        return ConnectionLocation{ .fd = file_descriptor };
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => |e| return e,
    }
    // We will possibly allocate two paths (one for WAYLAND_DISPLAY and another for XDG_RUNTIME_DIR).
    // I double that number (just in case) and use it to create a fixed buffer allocator.
    var alloc_buffer: [2 * 2 * std.fs.max_path_bytes]u8 = undefined;
    var fixed_buffer_allocator = std.heap.FixedBufferAllocator.init(&alloc_buffer);
    const allocator = fixed_buffer_allocator.allocator();

    const display_name = std.process.getEnvVarOwned(allocator, "WAYLAND_DISPLAY") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => "wayland-0",
        error.InvalidWtf8 => @panic("Linux does not use WTF-8, Windows does not use Wayland"),
        error.OutOfMemory => return error.Overflow,
    };
    if (std.fs.path.isAbsolute(display_name)) {
        var path = std.BoundedArray(u8, std.fs.max_path_bytes){};
        try path.appendSlice(display_name);
        return ConnectionLocation{ .path = path };
    }
    const xdg_runtime_dir_path = std.process.getEnvVarOwned(allocator, "XDG_RUNTIME_DIR") catch |err| switch (err) {
        error.InvalidWtf8 => @panic("Linux does not use WTF-8, Windows does not use Wayland"),
        // XDG_RUNTIME_DIR doesn't have a default value, so we give up if we can't find it.
        error.EnvironmentVariableNotFound => return error.XDGRuntimeDirEnvironmentVariableNotFound,
        error.OutOfMemory => return error.Overflow,
    };
    var path = std.BoundedArray(u8, std.fs.max_path_bytes){};
    try path.appendSlice(std.mem.trimRight(u8, xdg_runtime_dir_path, std.fs.path.sep_str));
    try path.appendSlice(std.fs.path.sep_str);
    try path.appendSlice(display_name);
    return ConnectionLocation{ .path = path };
}

pub fn RequestWithoutNewId(Request: type, comptime opcode: std.meta.Tag(Request)) type {
    const Payload = std.meta.TagPayload(Request, opcode);

    const original_struct_info = @typeInfo(Payload).Struct;
    comptime var new_fields = std.BoundedArray(std.builtin.Type.StructField, original_struct_info.fields.len){};
    new_fields.appendSliceAssumeCapacity(original_struct_info.fields);

    comptime var original_index = 0;
    comptime var new_index = 0;
    inline while (original_index < @typeInfo(Payload).Struct.fields.len) : (original_index += 1) {
        if (wire.NewId.isTypedNewId(original_struct_info.fields[original_index].type)) {
            _ = new_fields.orderedRemove(new_index);
        } else {
            new_index += 1;
        }
    }
    return @Type(.{ .Struct = .{
        .is_tuple = false,
        .layout = .auto,
        .fields = new_fields.slice(),
        .decls = &.{},
    } });
}

pub fn RequestReturnType(Request: type, comptime opcode: std.meta.Tag(Request)) type {
    const Payload = std.meta.TagPayload(Request, opcode);

    inline for (@typeInfo(Payload).Struct.fields) |field| {
        if (wire.NewId.isTypedNewId(field.type)) {
            return field.type._SPECIFIED_INTERFACE;
        }
    }
    return void;
}

test "serialize Registry.Event.Global" {
    var buffered_message_writer = wire.BufferedMessageWriter.init(std.testing.allocator);
    defer buffered_message_writer.deinit();
    try buffered_message_writer.messageWriter().writeStruct(wp.wl_registry.Event.Global, .{
        .name = 1,
        .interface = "wl_shm",
        .version = 3,
    });
    try std.testing.expectEqualSlices(u8,
        std.mem.sliceAsBytes(&[_]u32{
            1,
            7,
            @bitCast(@as([4]u8, "wl_s".*)),
            @bitCast(@as([4]u8, "hm\x00\x00".*)),
            3,
        }),
        buffered_message_writer.message_buffer.items,
    );
}

test "deserialize Registry.Event.Global" {
    const words = [_]u32{
        1,
        7,
        @bitCast(@as([4]u8, "wl_s".*)),
        @bitCast(@as([4]u8, "hm\x00\x00".*)),
        3,
    };
    var words_index: usize = 0;
    const control = [_]u8{};
    var control_index: usize = 0;

    const parsed = try wire.deserializeArguments(
        std.meta.TagPayload(wp.wl_registry.Event, .global),
        std.mem.sliceAsBytes(&words),
        &words_index,
        &control,
        &control_index,
    );
    try std.testing.expectEqualDeep(std.meta.TagPayload(wp.wl_registry.Event, .global){
        .name = 1,
        .interface = "wl_shm",
        .version = 3,
    }, parsed);
}

test "deserialize Registry.Event" {
    const header = wire.Header{
        .object = @enumFromInt(123),
        .size_and_opcode = .{
            .size = 28,
            .opcode = @intFromEnum(std.meta.Tag(wp.wl_registry.Event).global),
        },
    };
    const words = @as([2]u32, @bitCast(header)) ++ [_]u32{
        1,
        7,
        @bitCast(@as([4]u8, "wl_s".*)),
        @bitCast(@as([4]u8, "hm\x00\x00".*)),
        3,
    };
    var words_index: usize = 0;
    var control_buffer = [_]u8{};
    var control_index: usize = 0;

    const parsed = try wire.deserialize(wp.wl_registry.Event, std.mem.sliceAsBytes(&words), &words_index, &control_buffer, &control_index);
    try std.testing.expectEqualDeep(
        wp.wl_registry.Event{ .global = .{
            .name = 1,
            .interface = "wl_shm",
            .version = 3,
        } },
        parsed,
    );
    const payload2 = [_]u32{
        1,
        15,
        40,
        @bitCast(@as([4]u8, "inva".*)),
        @bitCast(@as([4]u8, "lid ".*)),
        @bitCast(@as([4]u8, "argu".*)),
        @bitCast(@as([4]u8, "ment".*)),
        @bitCast(@as([4]u8, "s to".*)),
        @bitCast(@as([4]u8, " wl_".*)),
        @bitCast(@as([4]u8, "regi".*)),
        @bitCast(@as([4]u8, "stry".*)),
        @bitCast(@as([4]u8, "@2.b".*)),
        @bitCast(@as([4]u8, "ind\x00".*)),
    };
    const header2 = wire.Header{
        .object = .wl_display,
        .size_and_opcode = .{
            .size = payload2.len * @sizeOf(u32) + @sizeOf(wire.Header),
            .opcode = @intFromEnum(std.meta.Tag(wp.wl_display.Event).@"error"),
        },
    };
    const words2 = @as([2]u32, @bitCast(header2)) ++ payload2;
    control_buffer = [0]u8{};

    words_index = 0;
    control_index = 0;

    const parsed2 = try wire.deserialize(
        wp.wl_display.Event,
        std.mem.sliceAsBytes(&words2),
        &words_index,
        &control_buffer,
        &control_index,
    );
    try std.testing.expectEqualDeep(
        wp.wl_display.Event{ .@"error" = .{
            .object_id = .wl_display,
            .code = 15,
            .message = "invalid arguments to wl_registry@2.bind",
        } },
        parsed2,
    );
}
