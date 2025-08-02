const std = @import("std");
const reg = @import("./registry.zig");
const render_id = @import("./render-id.zig");
const tokenizer = @import("./tokenizer.zig");
const Allocator = std.mem.Allocator;
const CaseStyle = render_id.CaseStyle;
const IdRenderer = render_id.IdRenderer;

const preamble =
    \\// This file is generated from the Khronos Vulkan XML API registry 
    \\
    \\const std = @import("std");
    \\const builtin = @import("builtin");
    \\const root = @import("root");
    \\const vk = @This();
    \\const Allocator = std.mem.Allocator;
    \\
    \\pub const vulkan_call_conv: std.builtin.CallingConvention = if (builtin.os.tag == .windows and builtin.cpu.arch == .x86)
    \\        .winapi
    \\    else if (builtin.abi == .android and (builtin.cpu.arch.isArm() or builtin.cpu.arch.isThumb()) and std.Target.arm.featureSetHas(builtin.cpu.features, .has_v7) and builtin.cpu.arch.ptrBitWidth() == 32)
    \\        // On Android 32-bit ARM targets, Vulkan functions use the "hardfloat"
    \\        // calling convention, i.e. float parameters are passed in registers. This
    \\        // is true even if the rest of the application passes floats on the stack,
    \\        // as it does by default when compiling for the armeabi-v7a NDK ABI.
    \\        .arm_aapcs_vfp
    \\    else
    \\        .c;
    // Note: Keep in sync with flag_functions
    \\pub fn FlagsMixin(comptime FlagsType: type) type {
    \\    return struct {
    \\        pub const IntType = @typeInfo(FlagsType).@"struct".backing_integer.?;
    \\        pub fn toInt(self: FlagsType) IntType {
    \\            return @bitCast(self);
    \\        }
    \\        pub fn fromInt(flags: IntType) FlagsType {
    \\            return @bitCast(flags);
    \\        }
    \\        pub fn merge(lhs: FlagsType, rhs: FlagsType) FlagsType {
    \\            return fromInt(toInt(lhs) | toInt(rhs));
    \\        }
    \\        pub fn intersect(lhs: FlagsType, rhs: FlagsType) FlagsType {
    \\            return fromInt(toInt(lhs) & toInt(rhs));
    \\        }
    \\        pub fn complement(self: FlagsType) FlagsType {
    \\            return fromInt(~toInt(self));
    \\        }
    \\        pub fn subtract(lhs: FlagsType, rhs: FlagsType) FlagsType {
    \\            return fromInt(toInt(lhs) & toInt(rhs.complement()));
    \\        }
    \\        pub fn contains(lhs: FlagsType, rhs: FlagsType) bool {
    \\            return toInt(intersect(lhs, rhs)) == toInt(rhs);
    \\        }
    \\    };
    \\}
    // Note: Keep in sync with flag_functions
    \\fn FlagFormatMixin(comptime FlagsType: type) type {
    \\    return struct {
    \\        pub fn format(
    \\            self: FlagsType,
    \\            comptime _: []const u8,
    \\            _: std.fmt.FormatOptions,
    \\            writer: anytype,
    \\        ) !void {
    \\            try writer.writeAll(@typeName(FlagsType) ++ "{");
    \\            var first = true;
    \\            @setEvalBranchQuota(100_000);
    \\            inline for (comptime std.meta.fieldNames(FlagsType)) |name| {
    \\                if (name[0] == '_') continue;
    \\                if (@field(self, name)) {
    \\                    if (first) {
    \\                        try writer.writeAll(" ." ++ name);
    \\                        first = false;
    \\                    } else {
    \\                        try writer.writeAll(", ." ++ name);
    \\                    }
    \\                }
    \\            }
    \\            if (!first) try writer.writeAll(" ");
    \\            try writer.writeAll("}");
    \\        }
    \\    };
    \\}
    \\pub const Version = packed struct(u32) {
    \\    patch: u12,
    \\    minor: u10,
    \\    major: u7,
    \\    variant: u3,
    \\};
    \\pub fn makeApiVersion(variant: u3, major: u7, minor: u10, patch: u12) Version {
    \\    return .{ .variant = variant, .major = major, .minor = minor, .patch = patch };
    \\}
    \\pub const ApiInfo = struct {
    \\    name: [:0]const u8 = "custom",
    \\    version: Version = makeApiVersion(0, 0, 0, 0),
    \\};
;

// Keep in sync with above definition of FlagsMixin
const flag_functions: []const []const u8 = &.{
    "toInt",
    "fromInt",
    "merge",
    "intersect",
    "complement",
    "subtract",
    "contains",
};

// Keep in sync with definition of command_flag_functions
const command_flags_mixin =
    \\pub fn CommandFlagsMixin(comptime CommandFlags: type) type {
    \\    return struct {
    \\        pub fn merge(lhs: CommandFlags, rhs: CommandFlags) CommandFlags {
    \\            var result: CommandFlags = .{};
    \\            @setEvalBranchQuota(10_000);
    \\            inline for (@typeInfo(CommandFlags).@"struct".fields) |field| {
    \\                @field(result, field.name) = @field(lhs, field.name) or @field(rhs, field.name);
    \\            }
    \\            return result;
    \\        }
    \\        pub fn intersect(lhs: CommandFlags, rhs: CommandFlags) CommandFlags {
    \\            var result: CommandFlags = .{};
    \\            @setEvalBranchQuota(10_000);
    \\            inline for (@typeInfo(CommandFlags).@"struct".fields) |field| {
    \\                @field(result, field.name) = @field(lhs, field.name) and @field(rhs, field.name);
    \\            }
    \\            return result;
    \\        }
    \\        pub fn complement(self: CommandFlags) CommandFlags {
    \\            var result: CommandFlags = .{};
    \\            @setEvalBranchQuota(10_000);
    \\            inline for (@typeInfo(CommandFlags).@"struct".fields) |field| {
    \\                @field(result, field.name) = !@field(self, field.name);
    \\            }
    \\            return result;
    \\        }
    \\        pub fn subtract(lhs: CommandFlags, rhs: CommandFlags) CommandFlags {
    \\            var result: CommandFlags = .{};
    \\            @setEvalBranchQuota(10_000);
    \\            inline for (@typeInfo(CommandFlags).@"struct".fields) |field| {
    \\                @field(result, field.name) = @field(lhs, field.name) and !@field(rhs, field.name);
    \\            }
    \\            return result;
    \\        }
    \\        pub fn contains(lhs: CommandFlags, rhs: CommandFlags) bool {
    \\            @setEvalBranchQuota(10_000);
    \\            inline for (@typeInfo(CommandFlags).@"struct".fields) |field| {
    \\                if (!@field(lhs, field.name) and @field(rhs, field.name)) {
    \\                    return false;
    \\                }
    \\            }
    \\            return true;
    \\        }
    \\    };
    \\}
    \\
;

// Keep in sync with above definition of CommandFlagsMixin
const command_flag_functions: []const []const u8 = &.{
    "merge",
    "intersect",
    "complement",
    "subtract",
    "contains",
};

const builtin_types = std.StaticStringMap([]const u8).initComptime(.{
    .{ "void", @typeName(void) },
    .{ "char", @typeName(u8) },
    .{ "float", @typeName(f32) },
    .{ "double", @typeName(f64) },
    .{ "uint8_t", @typeName(u8) },
    .{ "uint16_t", @typeName(u16) },
    .{ "uint32_t", @typeName(u32) },
    .{ "uint64_t", @typeName(u64) },
    .{ "int8_t", @typeName(i8) },
    .{ "int16_t", @typeName(i16) },
    .{ "int32_t", @typeName(i32) },
    .{ "int64_t", @typeName(i64) },
    .{ "size_t", @typeName(usize) },
    .{ "int", @typeName(c_int) },
});

const foreign_types = std.StaticStringMap([]const u8).initComptime(.{
    .{ "Display", "opaque {}" },
    .{ "VisualID", @typeName(c_uint) },
    .{ "Window", @typeName(c_ulong) },
    .{ "RROutput", @typeName(c_ulong) },
    .{ "wl_display", "opaque {}" },
    .{ "wl_surface", "opaque {}" },
    .{ "HINSTANCE", "std.os.windows.HINSTANCE" },
    .{ "HWND", "std.os.windows.HWND" },
    .{ "HMONITOR", "*opaque {}" },
    .{ "HANDLE", "std.os.windows.HANDLE" },
    .{ "SECURITY_ATTRIBUTES", "std.os.windows.SECURITY_ATTRIBUTES" },
    .{ "DWORD", "std.os.windows.DWORD" },
    .{ "LPCWSTR", "std.os.windows.LPCWSTR" },
    .{ "xcb_connection_t", "opaque {}" },
    .{ "xcb_visualid_t", @typeName(u32) },
    .{ "xcb_window_t", @typeName(u32) },
    .{ "zx_handle_t", @typeName(u32) },
    .{ "_screen_context", "opaque {}" },
    .{ "_screen_window", "opaque {}" },
    .{ "IDirectFB", "opaque {}" },
    .{ "IDirectFBSurface", "opaque {}" },
    .{ "NvSciSyncAttrList", "*opaque{}" },
    .{ "NvSciSyncObj", "*opaque{}" },
    .{ "NvSciSyncFence", "*opaque{}" },
    .{ "NvSciBufAttrList", "*opaque{}" },
    .{ "NvSciBufObj", "*opaque{}" },
    // We don't know the true size of these but whatever Stadia is dead anyway.
    .{ "GgpStreamDescriptor", "*opaque{}" },
    .{ "GgpFrameToken", "*opaque{}" },
    // The Vulkan Video tokens cannot be "opaque {}" and have to be handled
    // separately.
    .{ "StdVideoVP9Profile", "u32" },
    .{ "StdVideoVP9Level", "u32" },
});

const CommandDispatchType = enum {
    base,
    instance,
    device,

    fn name(self: CommandDispatchType) []const u8 {
        return switch (self) {
            .base => "Base",
            .instance => "Instance",
            .device => "Device",
        };
    }

    fn nameLower(self: CommandDispatchType) []const u8 {
        return switch (self) {
            .base => "base",
            .instance => "instance",
            .device => "device",
        };
    }
};

const dispatchable_handles = std.StaticStringMap(CommandDispatchType).initComptime(.{
    .{ "VkDevice", .device },
    .{ "VkCommandBuffer", .device },
    .{ "VkQueue", .device },
    .{ "VkInstance", .instance },
});

const additional_namespaces = std.StaticStringMap([]const u8).initComptime(.{
    // vkCmdBegin...
    .{ "VkCommandBuffer", "Cmd" },
    // vkQueueSubmit...
    .{ "VkQueue", "Queue" },
});

const dispatch_override_functions = std.StaticStringMap(CommandDispatchType).initComptime(.{
    // See https://registry.khronos.org/vulkan/specs/1.3-extensions/html/vkspec.html#initialization-functionpointers
    .{ "vkGetInstanceProcAddr", .base },
    .{ "vkGetDeviceProcAddr", .instance },

    .{ "vkEnumerateInstanceVersion", .base },
    .{ "vkEnumerateInstanceExtensionProperties", .base },
    .{ "vkEnumerateInstanceLayerProperties", .base },
    .{ "vkCreateInstance", .base },
});

// Functions that return an array of objects via a count and data pointer.
const enumerate_functions = std.StaticStringMap(void).initComptime(.{
    .{"vkEnumeratePhysicalDevices"},
    .{"vkEnumeratePhysicalDeviceGroups"},
    .{"vkGetPhysicalDeviceQueueFamilyProperties"},
    .{"vkGetPhysicalDeviceQueueFamilyProperties2"},
    .{"vkEnumerateInstanceLayerProperties"},
    .{"vkEnumerateInstanceExtensionProperties"},
    .{"vkEnumerateDeviceLayerProperties"},
    .{"vkEnumerateDeviceExtensionProperties"},
    .{"vkGetImageSparseMemoryRequirements"},
    .{"vkGetImageSparseMemoryRequirements2"},
    .{"vkGetDeviceImageSparseMemoryRequirements"},
    .{"vkGetPhysicalDeviceSparseImageFormatProperties"},
    .{"vkGetPhysicalDeviceSparseImageFormatProperties2"},
    .{"vkGetPhysicalDeviceToolProperties"},
    .{"vkGetPipelineCacheData"},

    .{"vkGetPhysicalDeviceSurfaceFormatsKHR"},
    .{"vkGetPhysicalDeviceSurfaceFormats2KHR"},
    .{"vkGetPhysicalDeviceSurfacePresentModesKHR"},

    .{"vkGetSwapchainImagesKHR"},
    .{"vkGetPhysicalDevicePresentRectanglesKHR"},

    .{"vkGetPhysicalDeviceCalibrateableTimeDomainsKHR"},
});

// Given one of the above commands, returns the type of the array elements
// (and performs some basic verification that the command has the expected signature).
fn getEnumerateFunctionDataType(command: reg.Command) !reg.TypeInfo {
    if (command.params.len < 2) {
        return error.InvalidRegistry;
    }
    const count_param = command.params[command.params.len - 2];
    if (!count_param.is_buffer_len) {
        return error.InvalidRegistry;
    }
    const data_param = command.params[command.params.len - 1];
    return switch (data_param.param_type) {
        .pointer => |pointer| pointer.child.*,
        else => error.InvalidRegistry,
    };
}

fn eqlIgnoreCase(lhs: []const u8, rhs: []const u8) bool {
    if (lhs.len != rhs.len) {
        return false;
    }
    for (lhs, rhs) |l, r| {
        if (std.ascii.toLower(l) != std.ascii.toLower(r)) {
            return false;
        }
    }
    return true;
}

pub fn trimVkNamespace(id: []const u8) []const u8 {
    const prefixes = [_][]const u8{ "VK_", "vk", "Vk", "PFN_vk" };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, id, prefix)) {
            return id[prefix.len..];
        }
    }
    return id;
}

fn Renderer(comptime WriterType: type) type { 
    return struct {
        const WriteError = WriterType.Error;
        const RenderTypeInfoError = WriteError || std.fmt.ParseIntError || error{ OutOfMemory, InvalidRegistry };

        const BitflagName = struct {
            /// Name without FlagBits, so VkSurfaceTransformFlagBitsKHR
            /// becomes VkSurfaceTransform
            base_name: []const u8,
            /// Optional flag bits revision, used in places like VkAccessFlagBits2KHR
            revision: ?[]const u8,
            /// Optional tag of the flag
            tag: ?[]const u8,
        };

        const ParamType = enum {
            in_pointer,
            out_pointer,
            in_out_pointer,
            bitflags,
            mut_buffer_len,
            buffer_len,
            dispatch_handle,
            other,
        };

        const ReturnValue = struct {
            name: []const u8,
            return_value_type: reg.TypeInfo,
            origin: enum {
                parameter,
                inner_return_value,
            },
        };

        writer: WriterType,
        allocator: Allocator,
        registry: *const reg.Registry,
        id_renderer: *IdRenderer,
        decls_by_name: std.StringArrayHashMap(reg.DeclarationType),
        structure_types: std.StringHashMap(void),
        have_video: bool,

        fn init(
            writer: WriterType,
            allocator: Allocator,
            registry: *const reg.Registry,
            id_renderer: *IdRenderer,
            have_video: bool,
        ) !@This() {
            var decls_by_name = std.StringArrayHashMap(reg.DeclarationType).init(allocator);
            errdefer decls_by_name.deinit();

            for (registry.decls) |*decl| {
                const result = try decls_by_name.getOrPut(decl.name);
                if (result.found_existing) {
                    // Allow overriding 'foreign' types. These are for example the Vulkan Video types
                    // declared as foreign type in the vk.xml, then defined in video.xml. Sometimes
                    // this also includes types like uint32_t, for these we don't really care.
                    // Just make sure to keep the non-foreign variant.
                    if (result.value_ptr.* == .foreign) {
                        result.value_ptr.* = decl.decl_type;
                    } else if (decl.decl_type == .foreign) {
                        // Foreign type trying to override a non-foreign one. Just keep the current
                        // one, and don't generate an error.
                    } else {
                        std.log.err("duplicate registry entry '{s}'", .{decl.name});
                        return error.InvalidRegistry;
                    }
                } else {
                    result.value_ptr.* = decl.decl_type;
                }
            }
            const vk_structure_type_decl = decls_by_name.get("VkStructureType") orelse return error.InvalidRegistry;
            const vk_structure_type = switch (vk_structure_type_decl) {
                .enumeration => |e| e,
                else => return error.InvalidRegistry,
            };
            var structure_types = std.StringHashMap(void).init(allocator);
            errdefer structure_types.deinit();

            for (vk_structure_type.fields) |field| {
                try structure_types.put(field.name, {});
            }
            return @This(){
                .writer = writer,
                .allocator = allocator,
                .registry = registry,
                .id_renderer = id_renderer,
                .decls_by_name = decls_by_name,
                .structure_types = structure_types,
                .have_video = have_video,
            };
        }

        fn deinit(this: *@This()) void {
            this.decls_by_name.deinit();
        }

        fn writeIdentifier(this: *@This(), id: []const u8) !void {
            try render_id.writeIdentifier(this.writer, id);
        }

        fn writeIdentifierWithCase(this: *@This(), case: CaseStyle, id: []const u8) !void {
            try this.id_renderer.renderWithCase(this.writer, case, id);
        }

        fn writeIdentifierFmt(this: *@This(), comptime fmt: []const u8, args: anytype) !void {
            try this.id_renderer.renderFmt(this.writer, fmt, args);
        }

        fn extractEnumFieldName(this: @This(), enum_name: []const u8, field_name: []const u8) ![]const u8 {
            const adjusted_enum_name = this.id_renderer.stripAuthorTag(enum_name);

            var enum_it = render_id.SegmentIterator.init(adjusted_enum_name);
            var field_it = render_id.SegmentIterator.init(field_name);

            while (true) {
                const rest = field_it.rest();
                const field_segment = field_it.next() orelse return error.InvalidRegistry;
                const enum_segment = enum_it.next() orelse return rest;

                if (!eqlIgnoreCase(enum_segment, field_segment)) {
                    return rest;
                }
            }
        }

        fn extractBitflagFieldName(bitflag_name: BitflagName, field_name: []const u8) ![]const u8 {
            var flag_it = render_id.SegmentIterator.init(bitflag_name.base_name);
            var field_it = render_id.SegmentIterator.init(field_name);

            while (true) {
                const rest = field_it.rest();
                const field_segment = field_it.next() orelse return error.InvalidRegistry;
                const flag_segment = flag_it.next() orelse {
                    if (bitflag_name.revision) |revision| {
                        if (std.mem.eql(u8, revision, field_segment))
                            return field_it.rest();
                    }

                    return rest;
                };
                if (!eqlIgnoreCase(flag_segment, field_segment)) {
                    return rest;
                }
            }
        }

        fn extractBitflagName(this: @This(), name: []const u8) !?BitflagName {
            const tag = this.id_renderer.getAuthorTag(name);
            const tagless_name = if (tag) |tag_name| name[0 .. name.len - tag_name.len] else name;
            // Strip out the "version" number of a bitflag, like VkAccessFlagBits2KHR.
            const base_name = std.mem.trimRight(u8, tagless_name, "0123456789");

            const maybe_flag_bits_index = std.mem.lastIndexOf(u8, base_name, "FlagBits");
            if (maybe_flag_bits_index == null) {
                return null;
            } else if (maybe_flag_bits_index != base_name.len - "FlagBits".len) {
                // It is unlikely that a type that is not a flag bit would contain FlagBits,
                // and more likely that we have missed something if FlagBits isn't the last
                // part of base_name
                return error.InvalidRegistry;
            }
            return BitflagName{
                .base_name = base_name[0 .. base_name.len - "FlagBits".len],
                .revision = if (base_name.len != tagless_name.len) tagless_name[base_name.len..] else null,
                .tag = tag,
            };
        }

        fn isFlags(this: @This(), name: []const u8) bool {
            const tag = this.id_renderer.getAuthorTag(name);
            const tagless_name = if (tag) |tag_name| name[0 .. name.len - tag_name.len] else name;
            const base_name = std.mem.trimRight(u8, tagless_name, "0123456789");
            return std.mem.endsWith(u8, base_name, "Flags");
        }

        fn resolveDeclaration(this: @This(), name: []const u8) ?reg.DeclarationType {
            const decl = this.decls_by_name.get(name) orelse return null;
            return this.resolveAlias(decl) catch return null;
        }

        fn resolveAlias(this: @This(), start_decl: reg.DeclarationType) !reg.DeclarationType {
            var decl = start_decl;
            while (true) {
                const name = switch (decl) {
                    .alias => |alias| alias.name,
                    else => return decl,
                };
                decl = this.decls_by_name.get(name) orelse return error.InvalidRegistry;
            }
        }

        fn isInOutPointer(this: @This(), ptr: reg.Pointer) !bool {
            if (ptr.child.* != .name) {
                return false;
            }
            const decl = this.resolveDeclaration(ptr.child.name) orelse return error.InvalidRegistry;
            if (decl != .container) {
                return false;
            }
            const container = decl.container;
            if (container.is_union) {
                return false;
            }
            for (container.fields) |field| {
                if (std.mem.eql(u8, field.name, "pNext")) {
                    return true;
                }
            }
            return false;
        }

        fn classifyParam(this: @This(), param: reg.Command.Param) !ParamType {
            switch (param.param_type) {
                .pointer => |ptr| {
                    if (param.is_buffer_len) {
                        if (ptr.is_const or ptr.is_optional) {
                            return error.InvalidRegistry;
                        }

                        return .mut_buffer_len;
                    }
                    if (ptr.child.* == .name) {
                        const child_name = ptr.child.name;
                        if (std.mem.eql(u8, child_name, "void")) {
                            return .other;
                        } else if (builtin_types.get(child_name) == null and trimVkNamespace(child_name).ptr == child_name.ptr) {
                            return .other; // External type
                        }
                    }
                    if (ptr.size == .one and !ptr.is_optional) {
                        // Sometimes, a mutable pointer to a struct is taken, even though
                        // Vulkan expects this struct to be initialized. This is particularly the case
                        // for getting structs which include pNext chains.
                        if (ptr.is_const) {
                            return .in_pointer;
                        } else if (try this.isInOutPointer(ptr)) {
                            return .in_out_pointer;
                        } else {
                            return .out_pointer;
                        }
                    }
                },
                .name => |name| {
                    if (dispatchable_handles.get(name) != null) {
                        return .dispatch_handle;
                    }
                    if ((try this.extractBitflagName(name)) != null or this.isFlags(name)) {
                        return .bitflags;
                    }
                },
                else => {},
            }
            if (param.is_buffer_len) {
                return .buffer_len;
            }
            return .other;
        }

        fn classifyCommandDispatch(name: []const u8, command: reg.Command) CommandDispatchType {
            if (dispatch_override_functions.get(name)) |dispatch_type| {
                return dispatch_type;
            }
            switch (command.params[0].param_type) {
                .name => |first_param_type_name| {
                    if (dispatchable_handles.get(first_param_type_name)) |dispatch_type| {
                        return dispatch_type;
                    }
                },
                else => {},
            }
            return .instance;
        }

        fn render(this: *@This()) !void {
            try this.writer.writeAll(preamble);
            try this.writer.print("pub const have_vulkan_video = {};\n", .{ this.have_video });

            for (this.registry.api_constants) |api_constant| {
                try this.renderApiConstant(api_constant);
            }
            for (this.decls_by_name.keys(), this.decls_by_name.values()) |name, decl_type| {
                try this.renderDecl(.{
                    .name = name,
                    .decl_type = decl_type,
                });
            }
            try this.renderCommandPtrs();
            try this.renderFeatureInfo();
            try this.renderExtensionInfo();
            try this.renderDispatchTables();
            try this.renderWrappers();
            try this.renderProxies();
        }

        fn renderApiConstant(this: *@This(), api_constant: reg.ApiConstant) !void {
            try this.writer.writeAll("pub const ");
            try this.renderName(api_constant.name);
            try this.writer.writeAll(" = ");

            switch (api_constant.value) {
                .expr => |expr| try this.renderApiConstantExpr(expr),
                inline .version, .video_std_version => |version, kind| {
                    try this.writer.writeAll("makeApiVersion(");
                    // For Vulkan Video, just re-use the API version and set the variant to 0.
                    if (kind == .video_std_version) {
                        try this.writer.writeAll("0, ");
                    }
                    for (version, 0..) |part, i| {
                        if (i != 0) {
                            try this.writer.writeAll(", ");
                        }
                        try this.renderApiConstantExpr(part);
                    }
                    try this.writer.writeAll(")");
                },
            }
            try this.writer.writeAll(";\n");
        }

        fn renderApiConstantExpr(this: *@This(), expr: []const u8) !void {
            const adjusted_expr = if (expr.len > 2 and expr[0] == '(' and expr[expr.len - 1] == ')')
                expr[1 .. expr.len - 1]
            else
                expr;

            var ctok = tokenizer.CTokenizer{ .source = adjusted_expr };
            var peeked: ?tokenizer.Token = null;
            while (true) {
                const tok = peeked orelse (try ctok.next()) orelse break;
                peeked = null;

                switch (tok.kind) {
                    .lparen, .rparen, .tilde, .minus => {
                        try this.writer.writeAll(tok.text);
                        continue;
                    },
                    .id => {
                        try this.renderName(tok.text);
                        continue;
                    },
                    .int => {},
                    else => return error.InvalidApiConstant,
                }
                const suffix = (try ctok.next()) orelse {
                    try this.writer.writeAll(tok.text);
                    break;
                };
                switch (suffix.kind) {
                    .id => {
                        if (std.mem.eql(u8, suffix.text, "ULL")) {
                            try this.writer.print("@as(u64, {s})", .{tok.text});
                        } else if (std.mem.eql(u8, suffix.text, "U")) {
                            try this.writer.print("@as(u32, {s})", .{tok.text});
                        } else {
                            std.debug.print("aaa {s}\n", .{suffix.text});
                            return error.InvalidApiConstant;
                        }
                    },
                    .dot => {
                        const decimal = (try ctok.next()) orelse return error.InvalidConstantExpr;
                        try this.writer.print("@as(f32, {s}.{s})", .{ tok.text, decimal.text });

                        const f = (try ctok.next()) orelse return error.InvalidConstantExpr;
                        if (f.kind != .id or f.text.len != 1 or (f.text[0] != 'f' and f.text[0] != 'F')) {
                            return error.InvalidApiConstant;
                        }
                    },
                    else => {
                        try this.writer.writeAll(tok.text);
                        peeked = suffix;
                    },
                }
            }
        }

        fn renderTypeInfo(this: *@This(), type_info: reg.TypeInfo) RenderTypeInfoError!void {
            switch (type_info) {
                .name => |name| try this.renderName(name),
                .command_ptr => |command_ptr| try this.renderCommandPtr(command_ptr, true),
                .pointer => |pointer| try this.renderPointer(pointer),
                .array => |array| try this.renderArray(array),
            }
        }

        fn renderName(this: *@This(), name: []const u8) !void {
            if (builtin_types.get(name)) |zig_name| {
                try this.writer.writeAll(zig_name);
                return;
            } else if (try this.extractBitflagName(name)) |bitflag_name| {
                try this.writeIdentifierFmt("{s}Flags{s}{s}", .{
                    trimVkNamespace(bitflag_name.base_name),
                    @as([]const u8, if (bitflag_name.revision) |revision| revision else ""),
                    @as([]const u8, if (bitflag_name.tag) |tag| tag else ""),
                });
                return;
            } else if (std.mem.startsWith(u8, name, "vk")) {
                // Function type, always render with the exact same text for linking purposes.
                try this.writeIdentifier(name);
                return;
            } else if (std.mem.startsWith(u8, name, "Vk")) {
                // Type, strip namespace and write, as they are alreay in title case.
                try this.writeIdentifier(name[2..]);
                return;
            } else if (std.mem.startsWith(u8, name, "PFN_vk")) {
                // Function pointer type, strip off the PFN_vk part and replace it with Pfn. Note that
                // this function is only called to render the typedeffed function pointers like vkVoidFunction
                try this.writeIdentifierFmt("Pfn{s}", .{name[6..]});
                return;
            } else if (std.mem.startsWith(u8, name, "VK_")) {
                // Constants
                try this.writeIdentifier(name[3..]);
                return;
            }
            try this.writeIdentifier(name);
        }

        fn renderCommandPtr(this: *@This(), command_ptr: reg.Command, optional: bool) !void {
            if (optional) {
                try this.writer.writeByte('?');
            }
            try this.writer.writeAll("*const fn(");
            for (command_ptr.params) |param| {
                try this.writeIdentifierWithCase(.snake, param.name);
                try this.writer.writeAll(": ");

                blk: {
                    if (param.param_type == .name) {
                        if (try this.extractBitflagName(param.param_type.name)) |bitflag_name| {
                            try this.writeIdentifierFmt("{s}Flags{s}{s}", .{
                                trimVkNamespace(bitflag_name.base_name),
                                @as([]const u8, if (bitflag_name.revision) |revision| revision else ""),
                                @as([]const u8, if (bitflag_name.tag) |tag| tag else ""),
                            });
                            break :blk;
                        } else if (this.isFlags(param.param_type.name)) {
                            try this.renderTypeInfo(param.param_type);
                            break :blk;
                        }
                    }
                    try this.renderTypeInfo(param.param_type);
                }
                try this.writer.writeAll(", ");
            }
            try this.writer.writeAll(") callconv(vulkan_call_conv)");
            try this.renderTypeInfo(command_ptr.return_type.*);
        }

        fn renderPointer(this: *@This(), pointer: reg.Pointer) !void {
            const child_is_void = pointer.child.* == .name and std.mem.eql(u8, pointer.child.name, "void");

            if (pointer.is_optional) {
                try this.writer.writeByte('?');
            }
            const size = if (child_is_void) .one else pointer.size;
            switch (size) {
                .one => try this.writer.writeByte('*'),
                .many, .other_field => try this.writer.writeAll("[*]"),
                .zero_terminated => try this.writer.writeAll("[*:0]"),
            }
            if (pointer.is_const) {
                try this.writer.writeAll("const ");
            }
            if (child_is_void) {
                try this.writer.writeAll("anyopaque");
            } else {
                try this.renderTypeInfo(pointer.child.*);
            }
        }

        fn renderArray(this: *@This(), array: reg.Array) !void {
            try this.writer.writeByte('[');
            switch (array.size) {
                .int => |size| try this.writer.print("{}", .{size}),
                .alias => |alias| try this.renderName(alias),
            }
            try this.writer.writeByte(']');
            try this.renderTypeInfo(array.child.*);
        }

        fn renderDecl(this: *@This(), decl: reg.Declaration) !void {
            switch (decl.decl_type) {
                .container => |container| try this.renderContainer(decl.name, container),
                .enumeration => |enumeration| try this.renderEnumeration(decl.name, enumeration),
                .bitmask => |bitmask| try this.renderBitmask(decl.name, bitmask),
                .handle => |handle| try this.renderHandle(decl.name, handle),
                .command => {},
                .alias => |alias| try this.renderAlias(decl.name, alias),
                .foreign => |foreign| try this.renderForeign(decl.name, foreign),
                .typedef => |type_info| try this.renderTypedef(decl.name, type_info),
                .external => try this.renderExternal(decl.name),
            }
        }

        fn renderSpecialContainer(this: *@This(), name: []const u8) !bool {
            const maybe_author = this.id_renderer.getAuthorTag(name);
            const basename = this.id_renderer.stripAuthorTag(name);
            if (std.mem.eql(u8, basename, "VkAccelerationStructureInstance")) {
                try this.writer.print(
                    \\extern struct {{
                    \\    transform: TransformMatrix{s},
                    \\    instance_custom_index_and_mask: packed struct(u32) {{
                    \\        instance_custom_index: u24,
                    \\        mask: u8,
                    \\    }},
                    \\    instance_shader_binding_table_record_offset_and_flags: packed struct(u32) {{
                    \\        instance_shader_binding_table_record_offset: u24,
                    \\        flags: u8, // GeometryInstanceFlagsKHR
                    \\    }},
                    \\    acceleration_structure_reference: u64,
                    \\}};
                    \\
                ,
                    .{maybe_author orelse ""},
                );
                return true;
            } else if (std.mem.eql(u8, basename, "VkAccelerationStructureSRTMotionInstance")) {
                try this.writer.print(
                    \\extern struct {{
                    \\    transform_t0: SRTData{0s},
                    \\    transform_t1: SRTData{0s},
                    \\    instance_custom_index_and_mask: packed struct(u32) {{
                    \\        instance_custom_index: u24,
                    \\        mask: u8,
                    \\    }},
                    \\    instance_shader_binding_table_record_offset_and_flags: packed struct(u32) {{
                    \\        instance_shader_binding_table_record_offset: u24,
                    \\        flags: u8, // GeometryInstanceFlagsKHR
                    \\    }},
                    \\    acceleration_structure_reference: u64,
                    \\}};
                    \\
                ,
                    .{maybe_author orelse ""},
                );
                return true;
            } else if (std.mem.eql(u8, basename, "VkAccelerationStructureMatrixMotionInstance")) {
                try this.writer.print(
                    \\extern struct {{
                    \\    transform_t0: TransformMatrix{0s},
                    \\    transform_t1: TransformMatrix{0s},
                    \\    instance_custom_index_and_mask: packed struct(u32) {{
                    \\        instance_custom_index: u24,
                    \\        mask: u8,
                    \\    }},
                    \\    instance_shader_binding_table_record_offset_and_flags: packed struct(u32) {{
                    \\        instance_shader_binding_table_record_offset: u24,
                    \\        flags: u8, // GeometryInstanceFlagsKHR
                    \\    }},
                    \\    acceleration_structure_reference: u64,
                    \\}};
                    \\
                ,
                    .{maybe_author orelse ""},
                );
                return true;
            } else if (std.mem.eql(u8, basename, "VkClusterAccelerationStructureBuildTriangleClusterInfo")) {
                try this.writer.print(
                    \\extern struct {{
                    \\    cluster_id: u32,
                    \\    cluster_flags: ClusterAccelerationStructureClusterFlags{0s},
                    \\    cluster_data: packed struct(u32) {{
                    \\        triangle_count: u9,
                    \\        vertex_count: u9,
                    \\        position_truncate_bit_count: u6,
                    \\        index_type: u4,
                    \\        opacity_micromap_index_type: u4,
                    \\    }},
                    \\    base_geometry_index_and_geometry_flags: ClusterAccelerationStructureGeometryIndexAndGeometryFlags{0s},
                    \\    index_buffer_stride: u16,
                    \\    vertex_buffer_stride: u16,
                    \\    geometry_index_and_flags_buffer_stride: u16,
                    \\    opacity_micromap_index_buffer_stride: u16,
                    \\    index_buffer: DeviceAddress,
                    \\    vertex_buffer: DeviceAddress,
                    \\    geometry_index_and_flags_buffer: DeviceAddress,
                    \\    opacity_micromap_array: DeviceAddress,
                    \\    opacity_micromap_index_buffer: DeviceAddress,
                    \\}};
                ,
                    .{maybe_author orelse ""},
                );
                return true;
            } else if (std.mem.eql(u8, basename, "VkClusterAccelerationStructureBuildTriangleClusterTemplateInfo")) {
                try this.writer.print(
                    \\extern struct {{
                    \\    cluster_id: u32,
                    \\    cluster_flags: ClusterAccelerationStructureClusterFlags{0s},
                    \\    cluster_data: packed struct(u32) {{
                    \\        triangle_count: u9,
                    \\        vertex_count: u9,
                    \\        position_truncate_bit_count: u6,
                    \\        index_type: u4,
                    \\        opacity_micromap_index_type: u4,
                    \\    }},
                    \\    base_geometry_index_and_geometry_flags: ClusterAccelerationStructureGeometryIndexAndGeometryFlags{0s},
                    \\    index_buffer_stride: u16,
                    \\    vertex_buffer_stride: u16,
                    \\    geometry_index_and_flags_buffer_stride: u16,
                    \\    opacity_micromap_index_buffer_stride: u16,
                    \\    index_buffer: DeviceAddress,
                    \\    vertex_buffer: DeviceAddress,
                    \\    geometry_index_and_flags_buffer: DeviceAddress,
                    \\    opacity_micromap_array: DeviceAddress,
                    \\    opacity_micromap_index_buffer: DeviceAddress,
                    \\    instantiation_bounding_box_limit: DeviceAddress,
                    \\}};
                ,
                    .{maybe_author orelse ""},
                );
                return true;
            } else if (std.mem.eql(u8, basename, "VkClusterAccelerationStructureInstantiateClusterInfo")) {
                try this.writer.print(
                    \\extern struct {{
                    \\    cluster_id_offset: u32,
                    \\    geometry_index_offset: packed struct(u32) {{
                    \\       offset: u24,
                    \\       reserved: u8 = 0,
                    \\    }},
                    \\    cluster_template_address: DeviceAddress,
                    \\    vertex_buffer: StridedDeviceAddress{0s},
                    \\}};
                ,
                    .{maybe_author orelse ""},
                );
                return true;
            }
            return false;
        }

        fn renderSimpleBitContainer(this: *@This(), container: reg.Container) !bool {
            var total_bits: usize = 0;
            var is_flags_container = true;
            for (container.fields) |field| {
                const bits = field.bits orelse {
                    // C abi type - not a packed struct.
                    return false;
                };
                total_bits += bits;
                if (bits != 1) {
                    is_flags_container = false;
                }
            }
            try this.writer.writeAll("packed struct(u32) {");

            for (container.fields) |field| {
                const bits = field.bits.?;
                try this.writeIdentifierWithCase(.snake, field.name);
                try this.writer.writeAll(": ");

                // Default-zero fields that look like they are not used.
                if (std.mem.eql(u8, field.name, "reserved")) {
                    try this.writer.print(" u{} = 0,\n", .{field.bits.?});
                } else if (bits == 1) {
                    // Assume its a flag.
                    if (is_flags_container) {
                        try this.writer.writeAll(" bool = false,\n");
                    } else {
                        try this.writer.writeAll(" bool,\n");
                    }
                } else {
                    try this.writer.print(" u{},\n", .{field.bits.?});
                }
            }
            if (total_bits != 32) {
                try this.writer.print("_reserved: u{} = 0,\n", .{32 - total_bits});
            }
            try this.writer.writeAll("};\n");
            return true;
        }

        fn renderContainer(this: *@This(), name: []const u8, container: reg.Container) !void {
            try this.writer.writeAll("pub const ");
            try this.renderName(name);
            try this.writer.writeAll(" = ");

            if (try this.renderSimpleBitContainer(container)) {
                return;
            }
            if (try this.renderSpecialContainer(name)) {
                return;
            }
            for (container.fields) |field| {
                if (field.bits != null) {
                    return error.UnhandledBitfieldStruct;
                }
            } else {
                try this.writer.writeAll("extern ");
            }
            if (container.is_union) {
                try this.writer.writeAll("union {");
            } else {
                try this.writer.writeAll("struct {");
            }
            for (container.fields) |field| {
                try this.writeIdentifierWithCase(.snake, field.name);
                try this.writer.writeAll(": ");
                if (field.bits) |bits| {
                    try this.writer.print(" u{},", .{bits});
                    if (field.field_type != .name or builtin_types.get(field.field_type.name) == null) {
                        try this.writer.writeAll("// ");
                        try this.renderTypeInfo(field.field_type);
                        try this.writer.writeByte('\n');
                    }
                } else {
                    try this.renderTypeInfo(field.field_type);
                    if (!container.is_union) {
                        try this.renderContainerDefaultField(name, container, field);
                    }
                    try this.writer.writeAll(", ");
                }
            }
            try this.writer.writeAll("};\n");
        }

        fn renderContainerDefaultField(this: *@This(), name: []const u8, container: reg.Container, field: reg.Container.Field) !void {
            if (std.mem.eql(u8, field.name, "sType")) {
                if (container.stype == null) {
                    return;
                }
                const stype = container.stype.?;
                if (!std.mem.startsWith(u8, stype, "VK_STRUCTURE_TYPE_")) {
                    return error.InvalidRegistry;
                }
                // Some structures dont have a VK_STRUCTURE_TYPE for some reason apparently...
                // See https://github.com/KhronosGroup/Vulkan-Docs/issues/1225
                _ = this.structure_types.get(stype) orelse return;

                try this.writer.writeAll(" = .");
                try this.writeIdentifierWithCase(.snake, stype["VK_STRUCTURE_TYPE_".len..]);
            } else if (field.field_type == .name and std.mem.eql(u8, "VkBool32", field.field_type.name) and isFeatureStruct(name, container.extends)) {
                try this.writer.writeAll(" = FALSE");
            } else if (field.is_optional) {
                if (field.field_type == .name) {
                    const field_type_name = field.field_type.name;
                    if (this.resolveDeclaration(field_type_name)) |decl_type| {
                        if (decl_type == .handle) {
                            try this.writer.writeAll(" = .null_handle");
                        } else if (decl_type == .bitmask) {
                            try this.writer.writeAll(" = .{}");
                        } else if (decl_type == .typedef and decl_type.typedef == .command_ptr) {
                            try this.writer.writeAll(" = null");
                        } else if ((decl_type == .typedef and builtin_types.has(decl_type.typedef.name)) or
                            (decl_type == .foreign and builtin_types.has(field_type_name)))
                        {
                            try this.writer.writeAll(" = 0");
                        }
                    }
                } else if (field.field_type == .pointer) {
                    try this.writer.writeAll(" = null");
                }
            } else if (field.field_type == .pointer and field.field_type.pointer.is_optional) {
                // pointer nullability could be here or above
                try this.writer.writeAll(" = null");
            }
        }

        fn isFeatureStruct(name: []const u8, maybe_extends: ?[]const []const u8) bool {
            if (std.mem.eql(u8, name, "VkPhysicalDeviceFeatures")) return true;
            if (maybe_extends) |extends| {
                return for (extends) |extend| {
                    if (std.mem.eql(u8, extend, "VkDeviceCreateInfo")) break true;
                } else false;
            }
            return false;
        }

        fn renderEnumFieldName(this: *@This(), name: []const u8, field_name: []const u8) !void {
            try this.writeIdentifierWithCase(.snake, try this.extractEnumFieldName(name, field_name));
        }

        fn renderEnumeration(this: *@This(), name: []const u8, enumeration: reg.Enum) !void {
            if (enumeration.is_bitmask) {
                try this.renderBitmaskBits(name, enumeration);
                return;
            }
            try this.writer.writeAll("pub const ");
            try this.renderName(name);
            try this.writer.writeAll(" = enum(i32) {");

            for (enumeration.fields) |field| {
                if (field.value == .alias)
                    continue;

                try this.renderEnumFieldName(name, field.name);
                switch (field.value) {
                    .int => |int| try this.writer.print(" = {}, ", .{int}),
                    .bitpos => |pos| try this.writer.print(" = 1 << {}, ", .{pos}),
                    .bit_vector => |bv| try this.writer.print("= 0x{X}, ", .{bv}),
                    .alias => unreachable,
                }
            }
            try this.writer.writeAll("_,");

            for (enumeration.fields) |field| {
                if (field.value != .alias or field.value.alias.is_compat_alias)
                    continue;

                try this.writer.writeAll("pub const ");
                try this.renderEnumFieldName(name, field.name);
                try this.writer.writeAll(" = ");
                try this.renderName(name);
                try this.writer.writeByte('.');
                try this.renderEnumFieldName(name, field.value.alias.name);
                try this.writer.writeAll(";\n");
            }
            try this.writer.writeAll("};\n");
        }

        fn bitmaskFlagsType(bitwidth: u8) ![]const u8 {
            return switch (bitwidth) {
                32 => "Flags",
                64 => "Flags64",
                else => return error.InvalidRegistry,
            };
        }

        fn renderBitmaskBits(this: *@This(), name: []const u8, bits: reg.Enum) !void {
            try this.writer.writeAll("pub const ");
            try this.renderName(name);
            const flags_type = try bitmaskFlagsType(bits.bitwidth);
            try this.writer.print(" = packed struct({s}) {{", .{flags_type});

            const bitflag_name = (try this.extractBitflagName(name)) orelse return error.InvalidRegistry;

            if (bits.fields.len == 0) {
                try this.writer.print("_reserved_bits: {s} = 0,", .{flags_type});
            } else {
                var flags_by_bitpos = [_]?[]const u8{null} ** 64;
                for (bits.fields) |field| {
                    if (field.value == .bitpos) {
                        flags_by_bitpos[field.value.bitpos] = field.name;
                    }
                }

                for (flags_by_bitpos[0..bits.bitwidth], 0..) |maybe_flag_name, bitpos| {
                    if (maybe_flag_name) |flag_name| {
                        const field_name = try extractBitflagFieldName(bitflag_name, flag_name);
                        try this.writeIdentifierWithCase(.snake, field_name);
                    } else {
                        try this.writer.print("_reserved_bit_{}", .{bitpos});
                    }
                    try this.writer.writeAll(": bool = false,");
                }
            }
            try this.renderFlagFunctions(name, "FlagsMixin", flag_functions, null);
            try this.writer.writeAll("};\n");
        }

        fn renderBitmask(this: *@This(), name: []const u8, bitmask: reg.Bitmask) !void {
            if (bitmask.bits_enum == null) {
                // The bits structure is generated by renderBitmaskBits, but that wont
                // output flags with no associated bits type.

                const flags_type = try bitmaskFlagsType(bitmask.bitwidth);

                try this.writer.writeAll("pub const ");
                try this.renderName(name);
                try this.writer.print(
                    \\ = packed struct {{
                    \\_reserved_bits: {s} = 0,
                , .{ flags_type });
                try this.renderFlagFunctions(name, "FlagsMixin", flag_functions, null);
                try this.writer.writeAll("};\n");
            }
        }

        fn renderFlagFunctions(
            this : *@This(),
            name: []const u8,
            mixin: []const u8,
            functions: []const []const u8,
            name_suffix: ?[]const u8,
        ) !void {
            try this.writer.writeAll("\n");
            for (functions) |function| {
                try this.writer.print("pub const {s} = {s}(", .{ function, mixin });
                try this.renderName(name);
                try this.writer.print("{s}).{s};\n", .{ name_suffix orelse "", function });
            }
            try this.writer.writeAll("pub const format = FlagFormatMixin(");
            try this.renderName(name);
            try this.writer.print("{s}).format;\n", .{name_suffix orelse ""});
        }

        fn renderHandle(this: *@This(), name: []const u8, handle: reg.Handle) !void {
            const backing_type: []const u8 = if (handle.is_dispatchable) "usize" else "u64";

            try this.writer.writeAll("pub const ");
            try this.renderName(name);
            try this.writer.print(" = enum({s}) {{null_handle = 0, _}};\n", .{backing_type});
        }

        fn renderAlias(this: *@This(), name: []const u8, alias: reg.Alias) !void {
            if (alias.target == .other_command) {
                return;
            } else if ((try this.extractBitflagName(name)) != null) {
                // Don't make aliases of the bitflag names, as those are replaced by just the flags type
                return;
            }
            try this.writer.writeAll("pub const ");
            try this.renderName(name);
            try this.writer.writeAll(" = ");
            try this.renderName(alias.name);
            try this.writer.writeAll(";\n");
        }

        fn renderExternal(this: *@This(), name: []const u8) !void {
            try this.writer.writeAll("pub const ");
            try this.renderName(name);
            try this.writer.writeAll(" = opaque {};\n");
        }

        fn renderForeign(this: *@This(), name: []const u8, foreign: reg.Foreign) !void {
            if (std.mem.eql(u8, foreign.depends, "vk_platform") or
                builtin_types.get(name) != null)
            {
                return; // Skip built-in types, they are handled differently
            }
            try this.writer.writeAll("pub const ");
            try this.writeIdentifier(name);
            try this.writer.print(" = if (@hasDecl(root, \"{s}\")) root.", .{name});
            try this.writeIdentifier(name);
            try this.writer.writeAll(" else ");

            if (foreign_types.get(name)) |default| {
                try this.writer.writeAll(default);
                try this.writer.writeAll(";\n");
            } else {
                try this.writer.print("opaque {{}};\n", .{});
            }
        }

        fn renderTypedef(this: *@This(), name: []const u8, type_info: reg.TypeInfo) !void {
            try this.writer.writeAll("pub const ");
            try this.renderName(name);
            try this.writer.writeAll(" = ");
            try this.renderTypeInfo(type_info);
            try this.writer.writeAll(";\n");
        }

        fn renderCommandPtrName(this: *@This(), name: []const u8) !void {
            try this.writeIdentifierFmt("Pfn{s}", .{trimVkNamespace(name)});
        }

        fn renderCommandPtrs(this: *@This()) !void {
            for (this.decls_by_name.keys(), this.decls_by_name.values()) |name, decl_type| {
                switch (decl_type) {
                    .command => {
                        try this.writer.writeAll("pub const ");
                        try this.renderCommandPtrName(name);
                        try this.writer.writeAll(" = ");
                        try this.renderCommandPtr(decl_type.command, false);
                        try this.writer.writeAll(";\n");
                    },
                    .alias => |alias| if (alias.target == .other_command) {
                        try this.writer.writeAll("pub const ");
                        try this.renderCommandPtrName(name);
                        try this.writer.writeAll(" = ");
                        try this.renderCommandPtrName(alias.name);
                        try this.writer.writeAll(";\n");
                    },
                    else => {},
                }
            }
        }

        fn renderFeatureInfo(this: *@This()) !void {
            try this.writer.writeAll(
                \\pub const features = struct {
                \\
            );
            for (this.registry.features) |feature| {
                try this.writer.writeAll("pub const ");
                try this.writeIdentifierWithCase(.snake, trimVkNamespace(feature.name));
                try this.writer.writeAll("= ApiInfo {\n");
                try this.writer.print(".name = \"{s}\", .version = makeApiVersion(0, {}, {}, 0),\n}};\n", .{
                    trimVkNamespace(feature.name),
                    feature.level.major,
                    feature.level.minor,
                });
            }
            try this.writer.writeAll("};\n");
        }

        fn renderExtensionInfo(this: *@This()) !void {
            try this.writer.writeAll(
                \\pub const extensions = struct {
                \\
            );
            for (this.registry.extensions) |ext| {
                try this.writer.writeAll("pub const ");
                if (ext.extension_type == .video) {
                    // These are already in the right form, and the auto-casing style transformer
                    // is prone to messing up these names.
                    try this.writeIdentifier(trimVkNamespace(ext.name));
                } else {
                    try this.writeIdentifierWithCase(.snake, trimVkNamespace(ext.name));
                }
                try this.writer.writeAll("= ApiInfo {\n");
                try this.writer.print(".name = \"{s}\", .version = ", .{ext.name});
                switch (ext.version) {
                    .int => |version| try this.writer.print("makeApiVersion(0, {}, 0, 0)", .{version}),
                    // This should be the same as in self.renderApiConstant.
                    // We assume that this is already a vk.Version type.
                    .alias => |alias| try this.renderName(alias),
                    .unknown => try this.writer.writeAll("makeApiVersion(0, 0, 0, 0)"),
                }
                try this.writer.writeAll(",};\n");
            }
            try this.writer.writeAll("};\n");
        }

        fn renderDispatchTables(this: *@This()) !void {
            try this.renderDispatchTable(.base);
            try this.renderDispatchTable(.instance);
            try this.renderDispatchTable(.device);
        }

        fn renderDispatchTable(this: *@This(), dispatch_type: CommandDispatchType) !void {
            try this.writer.print(
                "pub const {s}Dispatch = struct {{\n",
                .{ dispatch_type.name() },
            );

            for (this.decls_by_name.keys(), this.decls_by_name.values()) |name, decl_type| {
                const final_decl_type = this.resolveAlias(decl_type) catch continue;
                const command = switch (final_decl_type) {
                    .command => |cmd| cmd,
                    else => continue,
                };
                if (classifyCommandDispatch(name, command) != dispatch_type) {
                    continue;
                }
                try this.writeIdentifier(name);
                try this.writer.writeAll(": ?");
                try this.renderCommandPtrName(name);
                try this.writer.writeAll(" = null,\n");
            }
            try this.writer.writeAll("};\n");
        }

        fn renderWrappers(this: *@This()) !void {
            try this.writer.writeAll(command_flags_mixin);
            try this.renderWrappersOfDispatchType(.base);
            try this.renderWrappersOfDispatchType(.instance);
            try this.renderWrappersOfDispatchType(.device);
        }

        fn renderWrappersOfDispatchType(this: *@This(), dispatch_type: CommandDispatchType) !void {
            const name = dispatch_type.name();

            try this.writer.print(
                \\pub const {0s}Wrapper = {0s}WrapperWithCustomDispatch({0s}Dispatch);
                \\pub fn {0s}WrapperWithCustomDispatch(DispatchType: type) type {{
                \\    return struct {{
                \\        const Self = @This();
                \\        pub const Dispatch = DispatchType;
                \\
                \\        dispatch: Dispatch,
                \\
            , .{name});
            try this.renderWrapperLoader(dispatch_type);

            for (this.registry.decls) |decl| {
                // If the target type does not exist, it was likely an empty enum -
                // assume spec is correct and that this was not a function alias.
                const decl_type = this.resolveAlias(decl.decl_type) catch continue;
                const command = switch (decl_type) {
                    .command => |cmd| cmd,
                    else => continue,
                };

                if (classifyCommandDispatch(decl.name, command) != dispatch_type) {
                    continue;
                }
                // Note: If this decl is an alias, generate a full wrapper instead of simply an
                // alias like `const old = new;`. This ensures that Vulkan bindings generated
                // for newer versions of vulkan can still invoke extension behavior on older
                // implementations.
                try this.renderWrapper(decl.name, command);
                if (enumerate_functions.has(decl.name)) {
                    try this.renderWrapperAlloc(decl.name, command);
                }
            }
            try this.writer.writeAll("};}\n");
        }

        fn renderWrapperLoader(this: *@This(), dispatch_type: CommandDispatchType) !void {
            const params = switch (dispatch_type) {
                .base => "loader: anytype",
                .instance => "instance: Instance, loader: anytype",
                .device => "device: Device, loader: anytype",
            };
            const loader_first_arg = switch (dispatch_type) {
                .base => "Instance.null_handle",
                .instance => "instance",
                .device => "device",
            };
            @setEvalBranchQuota(2000);

            try this.writer.print(
                \\pub fn load({[params]s}) Self {{
                \\    var self: Self = .{{ .dispatch = .{{}} }};
                \\    inline for (std.meta.fields(Dispatch)) |field| {{
                \\        const cmd_ptr = loader({[first_arg]s}, field.name.ptr) orelse undefined;
                \\        @field(self.dispatch, field.name) = @ptrCast(cmd_ptr);
                \\    }}
                \\    return self;
                \\}}
            , .{ .params = params, .first_arg = loader_first_arg });
        }

        fn renderProxies(this: *@This()) !void {
            try this.renderProxy(.instance, "VkInstance", true);
            try this.renderProxy(.device, "VkDevice", true);
            try this.renderProxy(.device, "VkCommandBuffer", false);
            try this.renderProxy(.device, "VkQueue", false);
        }

        fn renderProxy(
            this: *@This(),
            dispatch_type: CommandDispatchType,
            dispatch_handle: []const u8,
            also_add_other_commands: bool,
        ) !void {
            const loader_name = dispatch_type.name();

            try this.writer.print(
                \\pub const {0s}Proxy = {0s}ProxyWithCustomDispatch({1s}Dispatch);
                \\pub fn {0s}ProxyWithCustomDispatch(DispatchType: type) type {{
                \\    return struct {{
                \\        const Self = @This();
                \\        pub const Wrapper = {1s}WrapperWithCustomDispatch(DispatchType);
                \\
                \\        handle: {0s},
                // Note: This is a pointer because in the past there were some performance
                // issues with putting an object and vtable in the same structure. This also
                // affected std.mem.Allocator, which is why its like that too.
                \\    wrapper: *const Wrapper,
                \\
                \\    pub fn init(handle: {0s}, wrapper: *const Wrapper) Self {{
                \\        return .{{
                \\            .handle = handle,
                \\            .wrapper = wrapper,
                \\        }};
                \\    }}
            , .{ trimVkNamespace(dispatch_handle), loader_name });

            for (this.registry.decls) |decl| {
                const decl_type = this.resolveAlias(decl.decl_type) catch continue;
                const command = switch (decl_type) {
                    .command => |cmd| cmd,
                    else => continue,
                };
                if (classifyCommandDispatch(decl.name, command) != dispatch_type) {
                    continue;
                }
                switch (command.params[0].param_type) {
                    .name => |name| {
                        const skip = blk: {
                            if (std.mem.eql(u8, name, dispatch_handle)) {
                                break :blk false;
                            }
                            break :blk !also_add_other_commands;
                        };
                        if (skip) continue;
                    },
                    else => continue, // Not a dispatchable handle
                }
                try this.renderProxyCommand(decl.name, command, dispatch_handle);
                if (enumerate_functions.has(decl.name)) {
                    try this.renderProxyCommandAlloc(decl.name, command, dispatch_handle);
                }
            }
            try this.writer.writeAll(
                \\    };
                \\}
            );
        }

        fn renderProxyCommand(this: *@This(), name: []const u8, command: reg.Command, dispatch_handle: []const u8) !void {
            const returns_vk_result = command.return_type.* == .name and std.mem.eql(u8, command.return_type.name, "VkResult");
            const returns = try this.extractReturns(command);

            if (returns_vk_result) {
                try this.writer.writeAll("pub const ");
                try this.renderErrorSetName(name);
                try this.writer.writeAll(" = Wrapper.");
                try this.renderErrorSetName(name);
                try this.writer.writeAll(";\n");
            }
            if (returns.len > 1) {
                try this.writer.writeAll("pub const ");
                try this.renderReturnStructName(name);
                try this.writer.writeAll(" = Wrapper.");
                try this.renderReturnStructName(name);
                try this.writer.writeAll(";\n");
            }
            try this.renderWrapperPrototype(name, command, returns, dispatch_handle, .proxy);
            try this.writer.writeAll(
                \\{
                \\return self.wrapper.
            );
            try this.writeIdentifierWithCase(.camel, trimVkNamespace(name));
            try this.writer.writeByte('(');

            for (command.params) |param| {
                switch (try this.classifyParam(param)) {
                    .out_pointer => continue,
                    .dispatch_handle => {
                        if (std.mem.eql(u8, param.param_type.name, dispatch_handle)) {
                            try this.writer.writeAll("self.handle");
                        } else {
                            try this.writeIdentifierWithCase(.snake, param.name);
                        }
                    },
                    else => {
                        try this.writeIdentifierWithCase(.snake, param.name);
                    },
                }
                try this.writer.writeAll(", ");
            }
            try this.writer.writeAll(
                \\);
                \\}
                \\
            );
        }

        // vkFooKHR => vkFooAllocKHR
        fn makeAllocWrapperName(this: *@This(), wrapped_name: []const u8) ![]const u8 {
            const tag = this.id_renderer.getAuthorTag(wrapped_name) orelse "";
            const base_len = wrapped_name.len - tag.len;
            return std.mem.concat(this.allocator, u8, &.{ wrapped_name[0..base_len], "Alloc", tag });
        }

        fn renderProxyCommandAlloc(this: *@This(), wrapped_name: []const u8, command: reg.Command, dispatch_handle: []const u8) !void {
            const returns_vk_result = command.return_type.* == .name and std.mem.eql(u8, command.return_type.name, "VkResult");

            const name = try this.makeAllocWrapperName(wrapped_name);
            defer this.allocator.free(name);

            if (command.params.len < 2) {
                return error.InvalidRegistry;
            }
            const params = command.params[0 .. command.params.len - 2];
            const data_type = try getEnumerateFunctionDataType(command);

            if (returns_vk_result) {
                try this.writer.writeAll("pub const ");
                try this.renderErrorSetName(name);
                try this.writer.writeAll(" = Wrapper.");
                try this.renderErrorSetName(name);
                try this.writer.writeAll(";\n");
            }

            try this.renderAllocWrapperPrototype(name, params, returns_vk_result, data_type, dispatch_handle, .proxy);
            try this.writer.writeAll(
                \\{
                \\return self.wrapper.
            );
            try this.writeIdentifierWithCase(.camel, trimVkNamespace(name));
            try this.writer.writeByte('(');

            for (params) |param| {
                switch (try this.classifyParam(param)) {
                    .out_pointer => return error.InvalidRegistry,
                    .dispatch_handle => {
                        if (std.mem.eql(u8, param.param_type.name, dispatch_handle)) {
                            try this.writer.writeAll("self.handle");
                        } else {
                            try this.writeIdentifierWithCase(.snake, param.name);
                        }
                    },
                    else => {
                        try this.writeIdentifierWithCase(.snake, param.name);
                    },
                }
                try this.writer.writeAll(", ");
            }
            try this.writer.writeAll(
                \\allocator,);
                \\}
                \\
            );
        }

        fn derefName(name: []const u8) []const u8 {
            var it = render_id.SegmentIterator.init(name);
            return if (std.mem.eql(u8, it.next().?, "p"))
                name[1..]
            else
                name;
        }

        const WrapperKind = enum {
            wrapper,
            proxy,
        };

        fn renderWrapperName(
            this: *@This(),
            name: []const u8,
            dispatch_handle: []const u8,
            kind: WrapperKind,
        ) !void {
            const trimmed_name = switch (kind) {
                .wrapper => trimVkNamespace(name),
                .proxy => blk: {
                    // Strip additional namespaces: queue for VkQueue and cmd for VkCommandBuffer
                    const no_vk = trimVkNamespace(name);
                    const additional_namespace = additional_namespaces.get(dispatch_handle) orelse break :blk no_vk;
                    if (std.mem.startsWith(u8, no_vk, additional_namespace)) {
                        break :blk no_vk[additional_namespace.len..];
                    }

                    break :blk no_vk;
                },
            };
            try this.writeIdentifierWithCase(.camel, trimmed_name);
        }

        fn renderWrapperParam(this: *@This(), param: reg.Command.Param) !void {
            try this.writeIdentifierWithCase(.snake, param.name);
            try this.writer.writeAll(": ");
            try this.renderTypeInfo(param.param_type);
            try this.writer.writeAll(", ");
        }

        fn renderWrapperPrototype(
            this: *@This(),
            name: []const u8,
            command: reg.Command,
            returns: []const ReturnValue,
            dispatch_handle: []const u8,
            kind: WrapperKind,
        ) !void {
            try this.writer.writeAll("pub fn ");
            try this.renderWrapperName(name, dispatch_handle, kind);
            try this.writer.writeAll("(self: Self, ");

            for (command.params) |param| {
                const class = try this.classifyParam(param);
                // Skip the dispatch type for proxying wrappers
                if (kind == .proxy and class == .dispatch_handle and std.mem.eql(u8, param.param_type.name, dispatch_handle)) {
                    continue;
                }
                // This parameter is returned instead.
                if (class == .out_pointer) {
                    continue;
                }
                try this.renderWrapperParam(param);
            }
            try this.writer.writeAll(") ");

            const returns_vk_result = command.return_type.* == .name and std.mem.eql(u8, command.return_type.name, "VkResult");
            if (returns_vk_result) {
                try this.renderErrorSetName(name);
                try this.writer.writeByte('!');
            }
            if (returns.len == 1) {
                try this.renderTypeInfo(returns[0].return_value_type);
            } else if (returns.len > 1) {
                try this.renderReturnStructName(name);
            } else {
                try this.writer.writeAll("void");
            }
        }

        fn renderWrapperCall(
            this: *@This(),
            name: []const u8,
            command: reg.Command,
            returns: []const ReturnValue,
            return_var_name: ?[]const u8,
        ) !void {
            try this.writer.writeAll("self.dispatch.");
            try this.writeIdentifier(name);
            try this.writer.writeAll(".?(");

            for (command.params) |param| {
                switch (try this.classifyParam(param)) {
                    .out_pointer => {
                        try this.writer.writeByte('&');
                        try this.writeIdentifierWithCase(.snake, return_var_name.?);
                        if (returns.len > 1) {
                            try this.writer.writeByte('.');
                            try this.writeIdentifierWithCase(.snake, derefName(param.name));
                        }
                    },
                    else => {
                        try this.writeIdentifierWithCase(.snake, param.name);
                    },
                }
                try this.writer.writeAll(", ");
            }
            try this.writer.writeAll(")");
        }

        fn extractReturns(this: *@This(), command: reg.Command) ![]const ReturnValue {
            var returns = std.ArrayList(ReturnValue).init(this.allocator);

            if (command.return_type.* == .name) {
                const return_name = command.return_type.name;
                if (!std.mem.eql(u8, return_name, "void") and !std.mem.eql(u8, return_name, "VkResult")) {
                    try returns.append(.{
                        .name = "return_value",
                        .return_value_type = command.return_type.*,
                        .origin = .inner_return_value,
                    });
                }
            }
            if (command.success_codes.len > 1) {
                if (command.return_type.* != .name or !std.mem.eql(u8, command.return_type.name, "VkResult")) {
                    return error.InvalidRegistry;
                }
                try returns.append(.{
                    .name = "result",
                    .return_value_type = command.return_type.*,
                    .origin = .inner_return_value,
                });
            } else if (command.success_codes.len == 1 and !std.mem.eql(u8, command.success_codes[0], "VK_SUCCESS")) {
                return error.InvalidRegistry;
            }
            for (command.params) |param| {
                if ((try this.classifyParam(param)) == .out_pointer) {
                    try returns.append(.{
                        .name = derefName(param.name),
                        .return_value_type = param.param_type.pointer.child.*,
                        .origin = .parameter,
                    });
                }
            }
            return try returns.toOwnedSlice();
        }

        fn renderReturnStructName(this: *@This(), command_name: []const u8) !void {
            try this.writeIdentifierFmt("{s}Result", .{trimVkNamespace(command_name)});
        }

        fn renderErrorSetName(this: *@This(), name: []const u8) !void {
            try this.writeIdentifierWithCase(.title, trimVkNamespace(name));
            try this.writer.writeAll("Error");
        }

        fn renderReturnStruct(this: *@This(), command_name: []const u8, returns: []const ReturnValue) !void {
            try this.writer.writeAll("pub const ");
            try this.renderReturnStructName(command_name);
            try this.writer.writeAll(" = struct {\n");
            for (returns) |ret| {
                try this.writeIdentifierWithCase(.snake, ret.name);
                try this.writer.writeAll(": ");
                try this.renderTypeInfo(ret.return_value_type);
                try this.writer.writeAll(", ");
            }
            try this.writer.writeAll("};\n");
        }

        fn renderWrapper(this: *@This(), name: []const u8, command: reg.Command) !void {
            const returns_vk_result = command.return_type.* == .name and std.mem.eql(u8, command.return_type.name, "VkResult");
            const returns_void = command.return_type.* == .name and std.mem.eql(u8, command.return_type.name, "void");
            const returns = try this.extractReturns(command);

            if (returns.len > 1) {
                try this.renderReturnStruct(name, returns);
            }
            if (returns_vk_result) {
                try this.writer.writeAll("pub const ");
                try this.renderErrorSetName(name);
                try this.writer.writeAll(" = ");
                try this.renderErrorSet(command.error_codes);
                try this.writer.writeAll(";\n");
            }
            try this.renderWrapperPrototype(name, command, returns, "", .wrapper);

            if (returns.len == 1 and returns[0].origin == .inner_return_value) {
                try this.writer.writeAll("{\n\n");

                if (returns_vk_result) {
                    try this.writer.writeAll("const result = ");
                    try this.renderWrapperCall(name, command, returns, null);
                    try this.writer.writeAll(";\n");

                    try this.renderErrorSwitch("result", command);
                    try this.writer.writeAll("return result;\n");
                } else {
                    try this.writer.writeAll("return ");
                    try this.renderWrapperCall(name, command, returns, null);
                    try this.writer.writeAll(";\n");
                }
                try this.writer.writeAll("\n}\n");
                return;
            }
            const return_var_name = if (returns.len == 1)
                try std.fmt.allocPrint(this.allocator, "out_{s}", .{returns[0].name})
            else
                "return_values";

            try this.writer.writeAll("{\n");
            if (returns.len == 1) {
                try this.writer.writeAll("var ");
                try this.writeIdentifierWithCase(.snake, return_var_name);
                try this.writer.writeAll(": ");
                try this.renderTypeInfo(returns[0].return_value_type);
                try this.writer.writeAll(" = undefined;\n");
            } else if (returns.len > 1) {
                try this.writer.writeAll("var return_values: ");
                try this.renderReturnStructName(name);
                try this.writer.writeAll(" = undefined;\n");
            }
            if (returns_vk_result) {
                try this.writer.writeAll("const result = ");
                try this.renderWrapperCall(name, command, returns, return_var_name);
                try this.writer.writeAll(";\n");
                try this.renderErrorSwitch("result", command);
                if (command.success_codes.len > 1) {
                    try this.writer.writeAll("return_values.result = result;\n");
                }
            } else {
                if (!returns_void) {
                    try this.writer.writeAll("return_values.return_value = ");
                }
                try this.renderWrapperCall(name, command, returns, return_var_name);
                try this.writer.writeAll(";\n");
            }
            if (returns.len >= 1) {
                try this.writer.writeAll("return ");
                try this.writeIdentifierWithCase(.snake, return_var_name);
                try this.writer.writeAll(";\n");
            }
            try this.writer.writeAll("}\n");
        }

        fn renderAllocWrapperPrototype(
            this: *@This(),
            name: []const u8,
            params: []const reg.Command.Param,
            returns_vk_result: bool,
            data_type: reg.TypeInfo,
            dispatch_handle: []const u8,
            kind: WrapperKind,
        ) !void {
            try this.writer.writeAll("pub fn ");
            try this.renderWrapperName(name, "", .wrapper);
            try this.writer.writeAll("(self: Self, ");
            for (params) |param| {
                const class = try this.classifyParam(param);
                // Skip the dispatch type for proxying wrappers
                if (kind == .proxy and class == .dispatch_handle and std.mem.eql(u8, param.param_type.name, dispatch_handle)) {
                    continue;
                }
                try this.renderWrapperParam(param);
            }
            try this.writer.writeAll("allocator: Allocator,) ");

            if (returns_vk_result) {
                try this.renderErrorSetName(name);
            } else {
                try this.writer.writeAll("Allocator.Error");
            }
            try this.writer.writeAll("![]");
            try this.renderTypeInfo(data_type);
        }

        fn renderWrapperAlloc(this: *@This(), wrapped_name: []const u8, command: reg.Command) !void {
            const returns_vk_result = command.return_type.* == .name and std.mem.eql(u8, command.return_type.name, "VkResult");

            const name = try this.makeAllocWrapperName(wrapped_name);
            defer this.allocator.free(name);

            if (command.params.len < 2) {
                return error.InvalidRegistry;
            }
            const params = command.params[0 .. command.params.len - 2];
            const data_type = try getEnumerateFunctionDataType(command);

            if (returns_vk_result) {
                try this.writer.writeAll("pub const ");
                try this.renderErrorSetName(name);
                try this.writer.writeAll(" =\n    ");
                try this.renderErrorSetName(wrapped_name);
                try this.writer.writeAll(" || Allocator.Error;\n");
            }
            try this.renderAllocWrapperPrototype(name, params, returns_vk_result, data_type, "", .wrapper);
            try this.writer.writeAll(
                \\{
                \\    var count: u32 = undefined;
            );
            if (returns_vk_result) {
                try this.writer.writeAll("var data: []");
                try this.renderTypeInfo(data_type);
                try this.writer.writeAll(
                    \\ = &.{};
                    \\errdefer allocator.free(data);
                    \\var result = Result.incomplete;
                    \\while (result == .incomplete) {
                    \\    _ = try
                );
            }
            try this.writer.writeAll(" self.");
            try this.renderWrapperName(wrapped_name, "", .wrapper);
            try this.writer.writeAll("(\n");
            for (params) |param| {
                try this.writeIdentifierWithCase(.snake, param.name);
                try this.writer.writeAll(", ");
            }
            try this.writer.writeAll("&count, null);\n");

            if (returns_vk_result) {
                try this.writer.writeAll(
                    \\data = try allocator.realloc(data, count);
                    \\result = try
                );
            } else {
                try this.writer.writeAll("const data = try allocator.alloc(");
                try this.renderTypeInfo(data_type);
                try this.writer.writeAll(
                    \\, count);
                    \\errdefer allocator.free(data);
                );
            }
            try this.writer.writeAll(" self.");
            try this.renderWrapperName(wrapped_name, "", .wrapper);
            try this.writer.writeAll("(\n");
            for (params) |param| {
                try this.writeIdentifierWithCase(.snake, param.name);
                try this.writer.writeAll(", ");
            }
            try this.writer.writeAll("&count, data.ptr);\n");

            if (returns_vk_result) {
                try this.writer.writeAll("}\n");
            }
            try this.writer.writeAll(
                \\    return if (count == data.len) data else allocator.realloc(data, count);
                \\}
            );
        }

        fn renderErrorSwitch(this: *@This(), result_var: []const u8, command: reg.Command) !void {
            try this.writer.writeAll("switch (");
            try this.writeIdentifier(result_var);
            try this.writer.writeAll(") {\n");

            for (command.success_codes) |success| {
                try this.writer.writeAll("Result.");
                try this.renderEnumFieldName("VkResult", success);
                try this.writer.writeAll(" => {},");
            }
            for (command.error_codes) |err| {
                try this.writer.writeAll("Result.");
                try this.renderEnumFieldName("VkResult", err);
                try this.writer.writeAll(" => return error.");
                try this.renderResultAsErrorName(err);
                try this.writer.writeAll(", ");
            }
            try this.writer.writeAll("else => return error.Unknown,}\n");
        }

        fn renderErrorSet(this: *@This(), errors: []const []const u8) !void {
            try this.writer.writeAll("error{");
            for (errors) |name| {
                if (std.mem.eql(u8, name, "VK_ERROR_UNKNOWN")) {
                    continue;
                }
                try this.renderResultAsErrorName(name);
                try this.writer.writeAll(", ");
            }
            try this.writer.writeAll("Unknown, }");
        }

        fn renderResultAsErrorName(this: *@This(), name: []const u8) !void {
            const error_prefix = "VK_ERROR_";
            if (std.mem.startsWith(u8, name, error_prefix)) {
                try this.writeIdentifierWithCase(.title, name[error_prefix.len..]);
            } else {
                // Apparently some commands (VkAcquireProfilingLockInfoKHR) return
                // success codes as error...
                try this.writeIdentifierWithCase(.title, trimVkNamespace(name));
            }
        }
    };
}

pub fn render(
    writer: anytype,
    allocator: Allocator,
    registry: *const reg.Registry,
    id_renderer: *IdRenderer,
    have_video: bool,
) !void {
    var renderer = try Renderer(@TypeOf(writer)).init(writer, allocator, registry, id_renderer, have_video);
    defer renderer.deinit();
    try renderer.render();
}
