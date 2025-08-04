const std = @import("std");
const xml = @import("cynicmoon-encore").xml;
const parseXml = @import("./parser.zig").parseXml;
const reg = @import("./registry.zig");
const IdRenderer = @import("./render-id.zig").IdRenderer;
const renderRegistry = @import("./render.zig").render;
const Allocator = std.mem.Allocator;
const FeatureLevel = reg.FeatureLevel;

const EnumFieldMerger = struct {
    const EnumExtensionMap = std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged(reg.Enum.Field));
    const ApiConstantMap = std.StringArrayHashMapUnmanaged(reg.ApiConstant);
    const FieldSet = std.StringArrayHashMapUnmanaged(void);

    arena: Allocator,
    registry: *reg.Registry,
    enum_extensions: EnumExtensionMap,
    api_constants: ApiConstantMap,
    field_set: FieldSet,

    fn init(arena: Allocator, registry: *reg.Registry) EnumFieldMerger {
        return .{
            .arena = arena,
            .registry = registry,
            .enum_extensions = .{},
            .api_constants = .{},
            .field_set = .{},
        };
    }

    fn putEnumExtension(this: *EnumFieldMerger, enum_name: []const u8, field: reg.Enum.Field) !void {
        const res = try this.enum_extensions.getOrPut(this.arena, enum_name);
        if (!res.found_existing) {
            res.value_ptr.* = std.ArrayListUnmanaged(reg.Enum.Field){};
        }
        try res.value_ptr.append(this.arena, field);
    }

    fn addRequires(this: *EnumFieldMerger, reqs: []const reg.Require) !void {
        for (reqs) |req| {
            for (req.extends) |enum_ext| {
                switch (enum_ext.value) {
                    .field => try this.putEnumExtension(enum_ext.extends, enum_ext.value.field),
                    .new_api_constant_expr => |expr| try this.api_constants.put(
                        this.arena,
                        enum_ext.extends,
                        .{
                            .name = enum_ext.extends,
                            .value = .{ .expr = expr },
                        },
                    ),
                }
            }
        }
    }

    fn mergeEnumFields(this: *EnumFieldMerger, name: []const u8, base_enum: *reg.Enum) !void {
        // If there are no extensions for this enum, assume its valid.
        const extensions = this.enum_extensions.get(name) orelse return;
        this.field_set.clearRetainingCapacity();

        const n_fields_upper_bound = base_enum.fields.len + extensions.items.len;
        const new_fields = try this.arena.alloc(reg.Enum.Field, n_fields_upper_bound);
        var i: usize = 0;

        for (base_enum.fields) |field| {
            const res = try this.field_set.getOrPut(this.arena, field.name);
            if (!res.found_existing) {
                new_fields[i] = field;
                i += 1;
            }
        }
        // Assume that if a field name clobbers, the value is the same
        for (extensions.items) |field| {
            const res = try this.field_set.getOrPut(this.arena, field.name);
            if (!res.found_existing) {
                new_fields[i] = field;
                i += 1;
            }
        }
        // Existing base_enum.fields was allocated by `self.arena`, so
        // it gets cleaned up whenever that is deinited.
        base_enum.fields = new_fields[0..i];
    }

    fn merge(this: *EnumFieldMerger) !void {
        for (this.registry.api_constants) |api_constant| {
            try this.api_constants.put(this.arena, api_constant.name, api_constant);
        }
        for (this.registry.features) |feature| {
            try this.addRequires(feature.requires);
        }
        for (this.registry.extensions) |ext| {
            try this.addRequires(ext.requires);
        }
        // Merge all the enum fields.
        // Assume that all keys of enum_extensions appear in `self.registry.decls`
        for (this.registry.decls) |*decl| {
            if (decl.decl_type == .enumeration) {
                try this.mergeEnumFields(decl.name, &decl.decl_type.enumeration);
            }
        }
        this.registry.api_constants = this.api_constants.values();
    }
};

pub const Generator = struct {
    arena: std.heap.ArenaAllocator,
    registry: reg.Registry,
    id_renderer: IdRenderer,
    have_video: bool,

    fn init(allocator: Allocator, spec: *xml.Element, maybe_video_spec: ?*xml.Element, api: reg.Api) !Generator {
        const result = try parseXml(allocator, spec, maybe_video_spec, api);

        const tags = try allocator.alloc([]const u8, result.registry.tags.len);
        for (tags, result.registry.tags) |*tag, registry_tag| tag.* = registry_tag.name;

        return Generator{
            .arena = result.arena,
            .registry = result.registry,
            .id_renderer = IdRenderer.init(allocator, tags),
            .have_video = maybe_video_spec != null,
        };
    }

    fn deinit(this: Generator) void {
        this.arena.deinit();
    }

    fn stripFlagBits(this: Generator, name: []const u8) []const u8 {
        const tagless = this.id_renderer.stripAuthorTag(name);
        return tagless[0 .. tagless.len - "FlagBits".len];
    }

    fn stripFlags(this: Generator, name: []const u8) []const u8 {
        const tagless = this.id_renderer.stripAuthorTag(name);
        return tagless[0 .. tagless.len - "Flags".len];
    }

    // Solve `registry.declarations` according to `registry.extensions` and `registry.features`.
    fn mergeEnumFields(this: *Generator) !void {
        var merger = EnumFieldMerger.init(this.arena.allocator(), &this.registry);
        try merger.merge();
    }

    // https://github.com/KhronosGroup/Vulkan-Docs/pull/1556
    fn fixupBitFlags(this: *Generator) !void {
        var seen_bits = std.StringArrayHashMap(void).init(this.arena.allocator());
        defer seen_bits.deinit();

        for (this.registry.decls) |decl| {
            const bitmask = switch (decl.decl_type) {
                .bitmask => |bm| bm,
                else => continue,
            };
            if (bitmask.bits_enum) |bits_enum| {
                try seen_bits.put(bits_enum, {});
            }
        }
        var i: usize = 0;

        for (this.registry.decls) |decl| {
            switch (decl.decl_type) {
                .enumeration => |e| {
                    if (e.is_bitmask and seen_bits.get(decl.name) == null)
                        continue;
                },
                else => {},
            }
            this.registry.decls[i] = decl;
            i += 1;
        }
        this.registry.decls.len = i;
    }

    fn render(this: *Generator, writer: anytype) !void {
        try renderRegistry(writer, this.arena.allocator(), &this.registry, &this.id_renderer, this.have_video);
    }
};

/// The vulkan registry contains the specification for multiple APIs: Vulkan and VulkanSC. This enum
/// describes applicable APIs.
pub const Api = reg.Api;

/// Main function for generating the Vulkan bindings. vk.xml is to be provided via `spec_xml`,
/// and the resulting binding is written to `writer`. `allocator` will be used to allocate temporary
/// internal datastructures - mostly via an ArenaAllocator, but sometimes a hashmap uses this allocator
/// directly. `api` is the API to generate the bindings for, usually `.vulkan`.
pub fn generate(
    allocator: Allocator,
    api: Api,
    spec_xml: []const u8,
    maybe_video_spec_xml: ?[]const u8,
    writer: anytype,
) !void {
    const spec = xml.parse(allocator, spec_xml) catch |err| switch (err) {
        error.InvalidDocument,
        error.UnexpectedEof,
        error.UnexpectedCharacter,
        error.IllegalCharacter,
        error.InvalidEntity,
        error.InvalidName,
        error.InvalidStandaloneValue,
        error.NonMatchingClosingTag,
        error.UnclosedComment,
        error.UnclosedValue,
        => return error.InvalidXml,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer spec.deinit();

    const maybe_video_spec_root = if (maybe_video_spec_xml) |video_spec_xml| blk: {
        const video_spec = xml.parse(allocator, video_spec_xml) catch |err| switch (err) {
            error.InvalidDocument,
            error.UnexpectedEof,
            error.UnexpectedCharacter,
            error.IllegalCharacter,
            error.InvalidEntity,
            error.InvalidName,
            error.InvalidStandaloneValue,
            error.NonMatchingClosingTag,
            error.UnclosedComment,
            error.UnclosedValue,
            => return error.InvalidXml,
            error.OutOfMemory => return error.OutOfMemory,
        };
        break :blk video_spec.root;
    } else null;

    var gen = Generator.init(allocator, spec.root, maybe_video_spec_root, api) catch |err| switch (err) {
        error.InvalidXml,
        error.InvalidCharacter,
        error.Overflow,
        error.InvalidFeatureLevel,
        error.InvalidSyntax,
        error.InvalidTag,
        error.MissingTypeIdentifier,
        error.UnexpectedCharacter,
        error.UnexpectedEof,
        error.UnexpectedToken,
        error.InvalidRegistry,
        => return error.InvalidRegistry,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer gen.deinit();

    try gen.mergeEnumFields();
    try gen.fixupBitFlags();
    gen.render(writer) catch |err| switch (err) {
        error.InvalidApiConstant,
        error.InvalidConstantExpr,
        error.InvalidRegistry,
        error.UnexpectedCharacter,
        error.InvalidCharacter,
        error.Overflow,
        => return error.InvalidRegistry,
        else => |others| return others,
    };
}
