const std = @import("std");
const xml = @import("cmoon-encore").parsers.xml;

pub fn main() !void  {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 32 }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const arguments = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), arguments);

    var options = try parseCommandLineOptions(allocator, arguments);
    defer options.deinit();

    // Find which protocol each interface belongs to.
    var interface_locations = std.StringHashMap(InterfaceLocation).init(gpa.allocator());
    defer interface_locations.deinit();

    var source_protocols = std.StringArrayHashMap(Protocol).init(allocator);
    defer {
        for (source_protocols.values()) |*protocol| protocol.deinit();
        source_protocols.deinit();
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Read and in source protocol files.
    for (options.protocol_xml_filepaths.keys()) |source_filepath| {
        var protocol = try Protocol.parse(allocator, source_filepath);
        errdefer protocol.deinit();

        for (protocol.interfaces) |interface| {
            const gop = try interface_locations.getOrPut(source_filepath);
            if (gop.found_existing) {
                std.log.err("Conflicting definitions for \"{}\": firdt defined in \"{}\", then in \"{}\"", .{
                    std.zig.fmtEscapes(interface.name),
                    std.zig.fmtEscapes(gop.value_ptr.protocol),
                    std.zig.fmtEscapes(source_filepath),
                });
                std.process.exit(1);
            }
            gop.key_ptr.* = interface.name;
            gop.value_ptr.* = .{
                .protocol = protocol.name.?,
                .import = try std.fmt.allocPrint(arena.allocator(), "@import(\"./{}\")", .{ std.zig.fmtEscapes(protocol.output_filename) }),
            };
        }
        try source_protocols.putNoClobber(source_filepath, protocol);
    }
    // Read and in imported protocol files.
    var imported_protocols = std.StringArrayHashMap(Protocol).init(allocator);
    defer {
        for (imported_protocols.values()) |*protocol| protocol.deinit();
        imported_protocols.deinit();
    }
    for (options.imports.keys(), options.imports.values()) |imported_filepath, import_string| {
        var protocol = try Protocol.parse(allocator, imported_filepath);
        errdefer protocol.deinit();

        for (protocol.interfaces) |interface| {
            const gop = try interface_locations.getOrPut(interface.name);
            if (gop.found_existing) {
                std.log.err("Conflicting definitions for \"{}\": first defined in \"{}\", then in \"{}\"", .{
                    std.zig.fmtEscapes(interface.name),
                    std.zig.fmtEscapes(gop.value_ptr.protocol),
                    std.zig.fmtEscapes(imported_filepath),
                });
                std.process.exit(1);
            }
            gop.key_ptr.* = interface.name;
            gop.value_ptr.* = .{
                .protocol = protocol.name.?,
                .import = import_string,
            };
        }
        try imported_protocols.putNoClobber(imported_filepath, protocol);
    }
    // Write source protocol files to output directory.
    if (options.output) |output_dir_path| {
        var output_directory = try std.fs.cwd().makeOpenPath(output_dir_path, .{});
        defer output_directory.close();

        const root_zig_file = try output_directory.createFile("root.zig", .{});
        defer root_zig_file.close();

        for (source_protocols.values()) |source_protocol| {
            const output_file = try output_directory.createFile(source_protocol.output_filename, .{});
            defer output_file.close();

            try source_protocol.writeProtocolZig(
                output_file.writer().any(),
                options.interface_versions,
                &interface_locations.unmanaged,
            );

            try root_zig_file.writer().print("pub const {} = @import(\"{}\");\n", .{ std.zig.fmtId(source_protocol.name.?), std.zig.fmtEscapes(source_protocol.output_filename) });
        }
        try root_zig_file.writer().writeAll("\n");
    }
    if (options.output_compat) |output_compat_path| {
        var compat_zig_file = try std.fs.cwd().createFile(output_compat_path, .{});
        defer compat_zig_file.close();

        try compat_zig_file.writer().writeAll(
            \\const std = @import("std");
            \\const wire = @import("wayland-wire");
            \\
            \\const wl_proxy = wire.compat.wl_proxy;
            \\const wl_interface = wire.compat.wl_interface;
            \\const wl_message = wire.compat.wl_message;
            \\const wl_object = wire.compat.wl_object;
            \\const wl_argument = wire.compat.wl_argument;
            \\const MarshalFlags = wire.compat.MarshalFlags;
            \\
            \\extern fn wl_proxy_add_listener(proxy: *wl_proxy, listener: [*]const ?*const fn () callconv(.C) void, data: ?*anyopaque) c_int;
            \\extern fn wl_proxy_get_version(proxy: *wl_proxy) u32;
            \\extern fn wl_proxy_marshal_array_flags(proxy: *wl_proxy, opcode: u32, interface: ?*const wl_interface, version: u32, flags: MarshalFlags, args: ?[*]wl_argument) ?*wl_proxy;
            \\extern fn wl_proxy_destroy(proxy: ?*wl_proxy) void;
            \\
        );
        for (options.imports.keys(), options.imports.values()) |imported_filepath, import_string| {
            const import = imported_protocols.get(imported_filepath).?;
            for (import.interfaces) |interface| {
                try compat_zig_file.writer().print("const {} = {s}.{};\n", .{ std.zig.fmtId(interface.name), import_string, std.zig.fmtId(interface.name) });
            }
        }
        for (source_protocols.values()) |source_protocol| {
            try source_protocol.writeCompatZig(compat_zig_file.writer().any(), options.interface_versions);
        }
    }
}

pub const CommandLineOptions = struct {
    arena: std.heap.ArenaAllocator,
    output: ?[]const u8,
    output_compat: ?[]const u8,
    protocol_xml_filepaths: std.StringArrayHashMap(void),
    interface_versions: std.StringArrayHashMap(u32),
    imports: std.StringArrayHashMap([]const u8),

    fn deinit(this: *@This()) void  {
        this.protocol_xml_filepaths.deinit();
        this.interface_versions.deinit();
        this.imports.deinit();
        this.arena.deinit();
    }
};

fn parseCommandLineOptions(allocator: std.mem.Allocator, arguments: []const [:0]const u8) !CommandLineOptions {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var output_directory: ?[]const u8 = null;
    var output_compat: ?[]const u8 = null;
    var protocol_xml_filepaths = std.StringArrayHashMap(void).init(allocator);
    var interface_versions = std.StringArrayHashMap(u32).init(allocator);
    var imports = std.StringArrayHashMap([]const u8).init(allocator);
    var print_help = false;
    errdefer {
        protocol_xml_filepaths.deinit();
        interface_versions.deinit();
        imports.deinit();
    }
    var arg_parse_failed = false;
    var arg_index: usize = 1;
    while (arg_index < arguments.len) {
        if (arguments[arg_index].len == 0) continue;

        if (arguments[arg_index][0] != '-') {
            // Add a filepath to the list of input file paths.
            const source_filepath = arguments[arg_index];
            arg_index += 1;

            const gop = try protocol_xml_filepaths.getOrPut(source_filepath);
            if (gop.found_existing) {
                arg_parse_failed = true;
                std.log.err("\"{}\" specified multiple times", .{ std.zig.fmtEscapes(source_filepath) });
                continue;
            }
            gop.key_ptr.* = source_filepath;
            continue;
        }
        const flag = arguments[arg_index];
        arg_index += 1;
        const flag_args = arguments[arg_index..];
        if (std.mem.eql(u8, flag, "--output") or std.mem.eql(u8, flag, "-o")) {
            if (flag_args.len < 1) {
                arg_parse_failed = true;
                std.log.err("`--output` flag missing output directory", .{});
                break;
            }
            output_directory = flag_args[0];
            arg_index += 1;
        } else if (std.mem.eql(u8, flag, "--output-compat") or std.mem.eql(u8, flag, "-c")) {
            if (flag_args.len < 1) {
                arg_parse_failed = true;
                std.log.err("`--output-compat` flag missing output file", .{});
                break;
            }
            output_compat = flag_args[0];
            arg_index += 1;
        } else if (std.mem.eql(u8, flag, "--interface-version") or std.mem.eql(u8, flag, "-v")) {
            if (flag_args.len < 2) {
                arg_parse_failed = true;
                std.log.err("`--interface-version` requires 2 arguments, <interface name> and <version>", .{});
                break;
            }
            const interface_str = flag_args[0];
            const version_str = flag_args[1];
            arg_index += 2;

            const version = std.fmt.parseInt(u32, version_str, 10) catch |err| {
                arg_parse_failed = true;
                std.log.err("Failed to parse version string \"{}\": {}", .{ std.zig.fmtEscapes(version_str), err });
                continue;
            };
            const gop = try interface_versions.getOrPut(interface_str);
            if (gop.found_existing) {
                arg_parse_failed = true;
                std.log.err("\"{}\" version specified multiple times", .{ std.zig.fmtEscapes(interface_str) });
                continue;
            }
            gop.key_ptr.* = interface_str;
            gop.value_ptr.* = version;
        } else if (std.mem.eql(u8, flag, "--import") or std.mem.eql(u8, flag, "-i")) {
            if (flag_args.len < 2) {
                arg_parse_failed = true;
                std.log.err("`--import` requires 2 arguments, <protocol xml file> and <import string>", .{});
                break;
            }
            const protocol_xml_path = flag_args[0];
            const import_str = flag_args[1];
            arg_index += 2;

            if (protocol_xml_filepaths.contains(protocol_xml_path)) {
                std.log.err("\"{}\" specified both as an import and as a source file", .{ std.zig.fmtEscapes(protocol_xml_path) });
                continue;
            }
            const gop = try imports.getOrPut(protocol_xml_path);
            if (gop.found_existing) {
                arg_parse_failed = true;
                std.log.err("\"{}\" import specified multiple times", .{ std.zig.fmtEscapes(protocol_xml_path) });
                continue;
            }
            gop.key_ptr.* = protocol_xml_path;
            gop.value_ptr.* = import_str;
        } else if (std.mem.eql(u8, flag, "--help") or std.mem.eql(u8, flag, "-h")) {
            print_help = true;
        } else {
            std.log.err("Unknown flag \"{}\"", .{ std.zig.fmtEscapes(flag) });
            arg_parse_failed = true;
        }
    }
    if (print_help) {
        const stdout = std.io.getStdOut();
        try stdout.writer().print(
            \\Usage: {[command]s} <protocol xmls>... [options] --output <directory> --output-compat <file>
            \\
            \\Options:
            \\  -o, --output <directory>
            \\
            \\    The directory relative to zig-out/ to generate protocol.zig files into.
            \\    Each protocol.xml file specified will have it's interfaces generated into a 
            \\    zig file with a matching name. E.g. `wayland.xml` would become `wayland.zig`.
            \\
            \\    A file importing all of the generated protocols named `root.zig` will be created.
            \\
            \\  -c, --output-compat <file>
            \\
            \\    The path to generate a libwayland compatible protocol.zig file into.
            \\
            \\  -h, --help       Print this message :DDD.   
        , .{ .command = arguments[0] });
        std.process.exit(0);
    }
    if (protocol_xml_filepaths.count() < 1) {
        arg_parse_failed = true;
        std.log.err("No protocol XML files specified as inputs.", .{});
    }
    if (output_directory == null and output_compat == null) {
        arg_parse_failed = true;
        std.log.err("No outputs specified.", .{});
    }
    if (arg_parse_failed) std.process.exit(1);

    return .{
        .arena = arena,
        .output = output_directory,
        .output_compat = output_compat,
        .protocol_xml_filepaths = protocol_xml_filepaths,
        .interface_versions = interface_versions,
        .imports = imports,
    };
}

pub const InterfaceLocation = struct {
    protocol: []const u8,
    import: []const u8,
};

pub const Protocol = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    document: xml.Document,
    name: ?[]const u8,
    copyright: ?[]const u8,
    interfaces: []const Interface,
    output_filename: []const u8,

    pub fn deinit(this: *@This()) void {
        this.allocator.free(this.output_filename);
        if (this.copyright) |copyright| this.allocator.free(copyright);
        for (this.interfaces) |interface| {
            this.allocator.free(interface.description);
            this.allocator.free(interface.enums);
            this.allocator.free(interface.requests);
            this.allocator.free(interface.events);
        }
        this.allocator.free(this.interfaces);
        this.arena.deinit();
        this.document.deinit();
    }
    pub fn parse(allocator: std.mem.Allocator, xml_file_path: []const u8) !@This() {
        if (!std.ascii.endsWithIgnoreCase(xml_file_path, ".xml")) return error.UnknownFileExtension;

        const xml_filename = std.fs.path.basename(xml_file_path);
        // Filename without the extension.
        const basename = xml_filename[0..xml_filename.len - ".xml".len];

        var document = try xml.parse(allocator, xml_file_path);
        errdefer document.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        var interfaces = std.ArrayList(Interface).init(allocator);
        errdefer {
            for (interfaces.items) |interface| {
                allocator.free(interface.description);
                allocator.free(interface.enums);
                allocator.free(interface.requests);
                allocator.free(interface.events);
            }
            interfaces.deinit();
        }
        var copyright: ?std.ArrayList(u8) = null;
        errdefer if (copyright) |*array_list| array_list.deinit();

        // TODO PARSE THE XML DOCUMENT

        const this_output_filename = try std.fmt.allocPrint(allocator, "{s}.zig", .{basename});
        errdefer allocator.free(this_output_filename);

        const interfaces_slice = try interfaces.toOwnedSlice();
        errdefer allocator.free(interfaces_slice);

        const copyright_slice: ?[]const u8 = if (copyright) |*array_list| try array_list.toOwnedSlice() else null;
        errdefer if (copyright_slice) allocator.free(copyright_slice);

        return @This(){
            .allocator = allocator,
            .arena = arena,
            .interfaces = interfaces_slice,
            .name = document.root.getAttribute("name"),
            .document = document,
            .copyright = copyright_slice,
            .output_filename = this_output_filename,
        };
    }

    fn getImports(
        this: @This(), 
        interface_locations: *const std.StringHashMapUnmanaged(InterfaceLocation),
        protocols_to_import: *std.StringArrayHashMap([]const u8),
    ) !void {
        for (this.interfaces) |interface| {
            for (interface.requests) |req| {
                for (req.args) |arg| {
                    if (arg.type.interface) |type_interface| {
                        if (interface_locations.get(type_interface)) |location| {
                            try protocols_to_import.put(location.protocol, location.import);
                        }
                    }
                }
            }
            for (interface.events) |event| {
                for (event.args) |arg| {
                    if (arg.type.interface) |type_interface| {
                        if (interface_locations.get(type_interface)) |location| {
                            try protocols_to_import.put(location.protocol, location.import);
                        }
                    }
                }
            }
        }
    }

    fn writeImports(
        this: @This(),
        writer: std.io.AnyWriter,
        interface_locations: *std.StringHashMapUnmanaged(InterfaceLocation),
    ) !void {
        var protocols_to_import = std.StringArrayHashMap([]const u8).init(this.allocator);
        defer protocols_to_import.deinit();
        try this.getImports(interface_locations, &protocols_to_import);

        for (protocols_to_import.keys(), protocols_to_import.values()) |protocol, import| {
            if (this.name != null and std.mem.eql(u8, protocol, this.name.?)) {
                try writer.print("const {} = @This();\n", .{ std.zig.fmtId(protocol) });
                continue;
            }
            try writer.print("const {} = {s};\n", .{ std.zig.fmtId(protocol), import });
        }
        try writer.writeByte('\n');
    }

    pub fn writeProtocolZig(
        this: @This(), 
        writer: std.io.AnyWriter,
        interface_versions: std.StringArrayHashMap(u32),
        interface_locations: *std.StringHashMapUnmanaged(InterfaceLocation),
    ) !void {
        if (this.copyright) |copyright| try writer.writeAll(copyright);
        try writer.writeAll(
            \\const wire = @import("wayland-wire");
            \\
        );
        try this.writeImports(writer, interface_locations);
        for (this.interfaces) |interface| {
            const target_version = interface_versions.get(interface.name) orelse interface.version;
            try interface.writeZig(writer, interface_locations, target_version);
        }
    }

    pub fn writeCompatZig(
        this: @This(), 
        writer: std.io.AnyWriter,
        interface_versions: std.StringArrayHashMap(u32),
    ) !void {
        for (this.interfaces) |interface| {
            const target_version = interface_versions.get(interface.name) orelse interface.version;
            try interface.writeCompatZig(writer, target_version);
        }
    }
};

pub const Type = struct {
    kind: Kind,
    interface: ?[]const u8,
    enum_str: ?[]const u8,
    allow_null: bool,

    pub const Kind = enum { uint, int, fixed, new_id, object, fd, string, array, };

    pub fn isGenericNewId(this: @This()) bool { return this.kind == .new_id and this.interface == null; }

    pub fn writeType(
        this: @This(),
        writer: anytype,
        this_interface: []const u8,
        type_locations: *const std.StringHashMapUnmanaged(InterfaceLocation),
    ) @TypeOf(writer).Error!void {
        switch (this.kind) {
            .uint => if (this.enum_str) |str| {
                if (std.mem.lastIndexOfScalar(u8, str, '.')) |dot_index| {
                    try writer.writeAll(str[0..dot_index + 1]);
                    try writer.print("{}", .{ SnakeToCamelCaseFormatted{ .snake_phrase = str[dot_index + 1..] }});
                } else {
                    try writer.print("{}.{}", .{ std.zig.fmtId(this_interface), SnakeToCamelCaseFormatted{ .snake_phrase = str } });
                }
            } else {
                try writer.writeAll("wire.Uint");
            },
            .int => try writer.writeAll("wire.Int"),
            .fixed => try writer.writeAll("wire.Fixed"),
            .new_id => if (this.interface) |interface| {
                try writer.writeAll("wire.NewId.WithInterface(");
                if (type_locations.get(interface)) |location| try writer.print("{}.", .{ std.zig.fmtId(location.protocol) });
                try writer.writeAll(interface);
                try writer.writeAll(")");
            } else {
                try writer.writeAll("wire.NewId");
            },
            .object => if (this.interface) |interface| {
                if (type_locations.get(interface)) |location| try writer.print("{}.", .{ std.zig.fmtId(location.protocol) });
                try writer.writeAll(interface);
            } else {
                try writer.writeAll("wire.Object");
            },
            .fd => try writer.writeAll("wire.Fd"),
            .string => if (this.allow_null) {
                try writer.writeAll("?wire.String");
            } else {
                try writer.writeAll("wire.String");
            },
            .array => try writer.writeAll("wire.Array"),
        }
    }

    pub fn writeFunctionType(
        this: @This(),
        writer: anytype,
        this_interface: []const u8,
        type_locations: *const std.StringHashMapUnmanaged(InterfaceLocation),
    ) @TypeOf(writer).Error!void {
        switch (this.kind) {
            .uint => if (this.enum_str) |str| {
                if (std.mem.lastIndexOfScalar(u8, str, '.')) |dot_index| {
                    try writer.writeAll(str[0..dot_index + 1]);
                    try writer.print("{}", .{ SnakeToCamelCaseFormatted{ .snake_phrase = str[dot_index + 1..] }});
                } else {
                    try writer.print("{}.{}", .{ std.zig.fmtId(this_interface), SnakeToCamelCaseFormatted{ .snake_phrase = str } });
                }
            } else {
                try writer.writeAll("wire.Uint");
            },
            .int => try writer.writeAll("wire.Int"),
            .fixed => try writer.writeAll("wire.Fixed"),
            .new_id, .object => if (this.interface) |interface| {
                if (type_locations.get(interface)) |location| try writer.print("{}.", .{ std.zig.fmtId(location.protocol) });
                try writer.writeAll(interface);
            } else {
                try writer.writeAll("wire.Object");
            },
            .fd => try writer.writeAll("wire.Fd"),
            .string => if (this.allow_null) {
                try writer.writeAll("?wire.String");
            } else {
                try writer.writeAll("wire.String");
            },
            .array => try writer.writeAll("wire.Array"),
        }
    }

    pub fn writeCompatType(
        this: @This(),
        writer: anytype,
        this_interface: []const u8,
    ) @TypeOf(writer).Error!void {
        switch (this.kind) {
            .uint => if (this.enum_str) |str| {
                if (std.mem.lastIndexOfScalar(u8, str, '.')) |dot_index| {
                    try writer.writeAll(str[0 .. dot_index + 1]);
                    try writer.print("{}", .{ SnakeToCamelCaseFormatted{ .snake_phrase = str[dot_index + 1 ..] }});
                } else {
                    try writer.print("{}.{}", .{ std.zig.fmtId(this_interface), SnakeToCamelCaseFormatted{ .snake_phrase = str } });
                }
            } else {
                try writer.writeAll("u32");
            },
            .int => try writer.writeAll("i32"),
            .fixed => try writer.writeAll("wire.Fixed"),
            .new_id => std.debug.panic("NewId should be handled as a return type", .{}),
            .object => if (this.interface) |interface| {
                try writer.writeAll("*");
                try writer.writeAll(interface);
            } else {
                try writer.writeAll("*wl_object");
            },
            .fd => try writer.writeAll("wire.Fd"),
            .string => if (this.allow_null) {
                try writer.writeAll("?[*:0]const u8");
            } else {
                try writer.writeAll("[*:0]const u8");
            },
            .array => try writer.writeAll("wire.Array"),
        }
    }

    pub fn writeCompatSignature(this: @This(), writer: anytype) @TypeOf(writer).Error!void {
        switch (this.kind) {
            .uint => try writer.writeAll("u"),
            .int => try writer.writeAll("i"),
            .fixed => try writer.writeAll("f"),
            .new_id => if (this.interface != null) {
                try writer.writeAll("n");
            } else {
                try writer.writeAll("sun");
            },
            .object => try writer.writeAll("o"),
            .fd => try writer.writeAll("h"),
            .string => if (this.allow_null) {
                try writer.writeAll("?s");
            } else {
                try writer.writeAll("s");
            },
            .array => if (this.allow_null) {
                try writer.writeAll("?a");
            } else {
                try writer.writeAll("a");
            },
        }
    }
};

const Interface = struct {
    name: []const u8,
    version: u32,
    description: []const []const u8,
    enums: []const Enum,
    requests: []const Message,
    events: []const Message,
    error_enum: ?Enum,

    pub fn writeZig(
        interface: @This(), 
        writer: std.io.AnyWriter, 
        interface_locations: *const std.StringHashMapUnmanaged(InterfaceLocation), 
        target_version: u32,
    ) !void {
        for (interface.description) |desc| {
            var line_iter = std.mem.splitScalar(u8, desc, '\n');
            while (line_iter.next()) |line| {
                try writer.writeAll("/// ");
                try writer.writeAll(std.mem.trimLeft(u8, line, " \t"));
                try writer.writeAll("\n");
            }
        }
        try printIndented(writer, 0, "pub const {[name]s} = enum(u32) {{\n", .{ .name = interface.name });
        try writeIndented(writer, 1, "_,\n\n");
        try printIndented(writer, 1, "pub const NAME = \"{}\";\n", .{ std.zig.fmtEscapes(interface.name) });
        try printIndented(writer, 1, "pub const VERSION = {};\n", .{ target_version });
        try writer.writeByte('\n');
        // Requests enum
        try writeIndented(writer, 1, "pub const Request = union(enum) {\n");
        for (interface.requests) |req| {
            if (req.since > target_version) break;
            try req.writeUnionField(writer, "Request", 2);
        }
        try writer.writeByte('\n');
        for (interface.requests) |req| {
            if (req.since > target_version) break;
            try req.writeType(writer, interface.name, interface_locations, 2);
        }
        try writeIndented(writer, 1, "};\n\n");
        // print out Events union
        try writeIndented(writer, 1, "pub const Event = union(enum) {\n");
        for (interface.events) |event| {
            if (target_version < event.since) break;
            try event.writeUnionField(writer, "Event", 2);
        }
        try writer.writeByte('\n');
        for (interface.events) |event| {
            if (target_version < event.since) break;
            try event.writeType(writer, interface.name, interface_locations, 2);
        }
        try writeIndented(writer, 1, "};\n\n");
        // protocol defined enums
        for (interface.enums) |interface_enum| {
            if (target_version < interface_enum.since) break;
            try interface_enum.writeZig(writer, target_version, 1);
        }
        // output request functions
        for (interface.requests) |request| {
            if (target_version < request.since) break;
            try request.writeSendFn(writer, interface.name, interface_locations, 1);
        }
        try writeIndented(writer, 0, "};\n");
        try writer.writeAll("\n");
    }

    pub fn writeCompatZig(
        interface: @This(), 
        writer: std.io.AnyWriter, 
        target_version: u32,
    ) !void {
        for (interface.description) |desc| {
            var line_iter = std.mem.splitScalar(u8, desc, '\n');
            while (line_iter.next()) |line| {
                try writer.writeAll("/// ");
                try writer.writeAll(std.mem.trimLeft(u8, line, " \t"));
                try writer.writeAll("\n");
            }
        }
        try printIndented(writer, 0, "pub const {[name]s} = opaque {{\n", .{ .name = interface.name });
        try printIndented(writer, 1, "pub const NAME = \"{}\";\n", .{ std.zig.fmtEscapes(interface.name) });
        try printIndented(writer, 1, "pub const VERSION = {};\n", .{ target_version });
        try writer.writeAll("\n");

        try writeIndented(writer, 1, "comptime{\n");
        try printIndented(writer, 2, "@export(INTERFACE, .{{ .name = \"{}_interface\" }});\n", .{ std.zig.fmtEscapes(interface.name) });
        try writeIndented(writer, 1, "}\n");
        try writer.writeAll("\n");

        try writeIndented(writer, 1, "pub const INTERFACE: *const wl_interface = &.{\n");
        try printIndented(writer, 2, ".name = \"{}\",\n", .{ std.zig.fmtEscapes(interface.name) });
        try printIndented(writer, 2, ".version = {d},\n", .{ target_version });
        try printIndented(writer, 2, ".requests = &{s}.REQUESTS,\n", .{ interface.name });
        try printIndented(writer, 2, ".request_count = {s}.REQUESTS.len,\n", .{ interface.name });
        try printIndented(writer, 2, ".events = &{s}.EVENTS,\n", .{ interface.name });
        try printIndented(writer, 2, ".event_count = {s}.EVENTS.len,\n", .{ interface.name });
        try writeIndented(writer, 1, "};\n");
        try writer.writeAll("\n");

        var request_count: u32 = 0;
        var event_count: u32 = 0;

        for (interface.requests) |req| {
            if (req.since > target_version) break;
            request_count += 1;
        }
        for (interface.events) |event| {
            if (event.since > target_version) break;
            event_count += 1;
        }
        try printIndented(writer, 1, "pub const REQUESTS: [{}]wl_message = .{{\n", .{ request_count });
        for (interface.requests) |req| {
            if (req.since > target_version) break;
            try req.writeCompatMessageStruct(writer, 2);
            try writer.writeAll(",\n");
        }
        try writeIndented(writer, 1, "};\n\n");
        try printIndented(writer, 1, "pub const EVENTS: [{}]wl_message = .{{\n", .{ event_count });
        for (interface.events) |event| {
            if (event.since > target_version) break;
            try event.writeCompatMessageStruct(writer, 2);
            try writer.writeAll(",\n");
        }
        try writeIndented(writer, 1, "};\n\n");
        // protocol defined enums
        for (interface.enums) |interface_enum| {
            if (target_version < interface_enum.since) break;
            try interface_enum.writeZig(writer, target_version, 1);
        }
        // print out EventListener struct
        try writeIndented(writer, 1, "\npub const EventListener = extern struct {\n");
        for (interface.events) |event| {
            if (target_version < event.since) break;
            try printIndented(writer, 2, "{}: *const ", .{ std.zig.fmtId(event.name) });
            try event.writeCompatListenerFn(writer, interface.name);
            try writer.writeAll(",\n");
        }
        try writeIndented(writer, 1, "};\n\n");
        try writeIndented(writer, 1,
            \\pub fn addEventListener(this: *@This(), listener: *const EventListener, userdata: ?*anyopaque) error{AlreadySet}!void {
            \\    if (wl_proxy_add_listener(@ptrCast(this), @ptrCast(listener), userdata) == -1) return error.AlreadySet;
            \\}
            \\
            \\
        );
        for (interface.requests) |req| {
            if (target_version < req.since) break;
            try req.writeCompatSendFn(writer, interface.name, 1);
        }
        // End of proxy opaque
        try writeIndented(writer, 0, "};\n");
        try writer.writeAll("\n");
        try printIndented(writer, 0, "comptime {{ _ = {[name]s}.INTERFACE; }}\n", .{ .name = interface.name });
    }
};

const Message = struct {
    name: []const u8,
    opcode: u16,
    summary: ?[]const u8,
    description: []const []const u8,
    args: []const Arg,
    since: u32,
    is_destructor: bool,

    pub fn parse(
        gpa: std.mem.Allocator, 
        document: *const xml.Document, 
        element: xml.Element, 
        opcode: u16
    ) !Message {
        _ = gpa;
        _ = document;
        _ = element;
        _ = opcode;
        // TODO PARSE THE XML DOCUMENT
    }

    pub fn writeUnionField(message: @This(), writer: std.io.AnyWriter, message_union_name: []const u8, indent: u32) !void {
        try printIndented(writer, indent, "{[name]}: {[union_name]}.{[type_name]},\n", .{
            .name = std.zig.fmtId(message.name),
            .union_name = std.zig.fmtId(message_union_name),
            .type_name = SnakeToCamelCaseFormatted{ .snake_phrase = message.name },
        });
    }

    pub fn writeType(
        message: @This(),
        writer: std.io.AnyWriter,
        this_interface: []const u8,
        interface_locations: *const std.StringHashMapUnmanaged(InterfaceLocation),
        indent: u32,
    ) !void {
        if (message.summary) |summary| {
            try printIndented(writer, indent, "/// {s}\n", .{ stripNewlines(std.mem.trim(u8, summary, " \t\n")) });
            if (message.description.len > 0) try writeIndented(writer, indent, "///\n");
        }
        for (message.description) |desc| {
            var line_iter = std.mem.splitScalar(u8, desc, '\n');
            while (line_iter.next()) |line| {
                try writeIndented(writer, indent, "/// ");
                try writer.writeAll(std.mem.trim(u8, line, " \t"));
                try writer.writeByte('\n');
            }
        }
        try printIndented(writer, indent, "pub const {[name]} = struct {{\n", .{ .name = SnakeToCamelCaseFormatted{ .snake_phrase = message.name } });
        try printIndented(writer, indent + 1, "pub const NAME = \"{}\";\n", .{ std.zig.fmtEscapes(message.name) });
        try printIndented(writer, indent + 1, "pub const OPCODE = {};\n", .{ message.opcode });
        try printIndented(writer, indent + 1, "pub const SINCE = {};\n", .{ message.since });
        // message arg struct
        if (message.args.len > 0) try writer.writeAll("\n");
        for (message.args) |arg| {
            if (arg.summary) |summary| {
                try printIndented(writer, indent + 1, "/// {s}\n", .{ stripNewlines(std.mem.trim(u8, summary, " \t\n")) });
            }
            if (arg.type.isGenericNewId()) {
                try printIndented(writer, indent + 1, "{}: wire.NewId,\n", .{ std.zig.fmtId(arg.name) });
                continue;
            }
            try printIndented(writer, indent + 1, "{[name]s}: ", .{ .name = arg.name });
            try arg.type.writeType(writer, this_interface, interface_locations);
            try writer.writeAll(",\n");
        }
        try writeIndented(writer, indent, "};\n\n");
    }

    pub fn writeSendFn(
        message: @This(),
        writer: std.io.AnyWriter,
        this_interface: []const u8,
        type_locations: *const std.StringHashMapUnmanaged(InterfaceLocation),
        indent: u32,
    ) !void {
        try printIndented(writer, indent + 0, "pub fn {}(this: {}, message_writer: wire.MessageWriter", .{ std.zig.fmtId(message.name), std.zig.fmtId(this_interface) });
        var newid_type_opt: ?Type = null;
        var args_len: usize = message.args.len;

        for (message.args) |arg| {
            if (arg.type.isGenericNewId()) {
                try writer.writeAll(", interface: [:0]const u8, version: u32");
                newid_type_opt = arg.type;
                args_len += 1;
                continue;
            } else if (arg.type.kind == .new_id) {
                newid_type_opt = arg.type;
                continue;
            }
            try writer.print(", {[name]s}: ", .{ .name = arg.name });
            try arg.type.writeFunctionType(writer, this_interface, type_locations);
        }
        try writer.writeAll(") !");
        if (newid_type_opt) |newid_type| {
            try newid_type.writeFunctionType(writer, this_interface, type_locations);
        } else {
            try writer.writeAll("void");
        }
        try writer.writeAll(" {\n");

        if (newid_type_opt) |newid_type| {
            if (newid_type.interface) |interface| {
                if (type_locations.get(interface)) |location| {
                    try printIndented(writer, indent + 1, "const new_id = try message_writer.createId({}.{}.NAME, {}.{}.VERSION);\n", .{
                        std.zig.fmtId(location.protocol),
                        std.zig.fmtId(interface),
                        std.zig.fmtId(location.protocol),
                        std.zig.fmtId(interface),
                    });
                } else {
                    try printIndented(writer, indent + 1, "const new_id = try message_writer.createId({}.NAME, {}.VERSION);\n", .{
                        std.zig.fmtId(interface),
                        std.zig.fmtId(interface),
                    });
                }
            } else {
                try printIndented(writer, indent + 1, "const new_id = try message_writer.createId({}.NAME, {}.VERSION);\n", .{
                    std.zig.fmtId(this_interface),
                    std.zig.fmtId(this_interface),
                });
            }
            try writeIndented(writer, indent + 1, "errdefer message_writer.destroyId(new_id);\n");
        }
        const message_name_formatted = SnakeToCamelCaseFormatted{ .snake_phrase = message.name };
        try printIndented(writer, indent + 1, "try message_writer.begin(@enumFromInt(@intFromEnum(this)), Request.{}.OPCODE);\n", .{message_name_formatted});
        try printIndented(writer, indent + 1, "try message_writer.writeStruct(@This().Request.{}, .{{\n", .{message_name_formatted});
        for (message.args) |arg| {
            switch (arg.type.kind) {
                .new_id => if (arg.type.interface) |_| {
                    try printIndented(writer, indent + 2, ".{} = @enumFromInt(@intFromEnum(new_id)),\n", .{ std.zig.fmtId(arg.name) });
                } else {
                    try printIndented(writer, indent + 2, ".{} = .{{ .interface = interface, .version = version, .object = new_id }}\n", .{ std.zig.fmtId(arg.name) });
                },
                else => try printIndented(writer, indent + 2, ".{} = {},\n", .{ std.zig.fmtId(arg.name), std.zig.fmtId(arg.name) }),
            }
        }
        try writeIndented(writer, indent + 1, "});\n");
        try writeIndented(writer, indent + 1, "try message_writer.end();\n");
        if (newid_type_opt) |newid_type| {
            if (newid_type.interface) |_| {
                try writeIndented(writer, indent + 1, "return @enumFromInt(@intFromEnum(new_id));\n");
            } else {
                try writeIndented(writer, indent + 1, "return @enumFromInt(@intFromEnum(new_id));\n");
            }
        }
        try writeIndented(writer, indent + 0, "}\n\n");
    }

    pub fn writeCompatListenerFn(message: @This(), writer: std.io.AnyWriter, this_interface: []const u8) !void {
        try writer.print("fn(?*anyopaque, *{s}", .{this_interface}); // COMPAT_LISTENER_FN
        for (message.args) |arg| {
            if (arg.type.isGenericNewId()) {
                try writer.writeAll(", name: u32, interface: *const wl_interface, version: u32");
                continue;
            } else if (arg.type.kind == .new_id) {
                try writer.print(", *{}", .{ std.zig.fmtId(arg.type.interface.?) });
                continue;
            }
            try writer.print(", {[name]s}: ", .{ .name = arg.name });
            try arg.type.writeCompatType(writer, this_interface);
        }
        try writer.writeAll(") callconv(.C) void");
    }

    pub fn writeCompatSendFn(message: @This(), writer: std.io.AnyWriter, this_interface: []const u8, indent: u32) !void {
        try printIndented(writer, indent + 0, "pub fn {}(this: *@This()", .{ std.zig.fmtId(message.name) });
        var newid_type_opt: ?Type = null;
        var args_len: usize = message.args.len;
        for (message.args) |arg| {
            if (arg.type.isGenericNewId()) {
                try writer.writeAll(", interface: *const wl_interface, version: u32");
                newid_type_opt = arg.type;
                args_len += 1;
                continue;
            } else if (arg.type.kind == .new_id) {
                newid_type_opt = arg.type;
                continue;
            }
            try writer.print(", {[name]s}: ", .{ .name = arg.name });
            try arg.type.writeCompatType(writer, this_interface);
        }
        try writer.writeAll(")");
        if (newid_type_opt) |newid_type| {
            try writer.writeAll(" error{Failure}!*");
            try writer.writeAll(newid_type.interface orelse "wl_proxy");
        } else {
            try writer.writeAll(" void");
        }
        try writer.writeAll(" {\n");
        try printIndented(writer, indent + 1, "var args: [{}]wl_argument = .{{", .{args_len});
        for (message.args) |arg| {
            switch (arg.type.kind) {
                .new_id => if (arg.type.interface) |_| {
                    try writeIndented(writer, indent + 2, ".{ .object = null },\n");
                } else {
                    try writeIndented(writer, indent + 2, ".{ .string = interface.name },\n");
                    try writeIndented(writer, indent + 2, ".{ .uint = version },\n");
                },
                .uint => if (arg.type.enum_str) |_| {
                    try printIndented(writer, indent + 2, ".{{ .uint = @intFromEnum({}) }},\n", .{ std.zig.fmtId(arg.name) });
                } else {
                    try printIndented(writer, indent + 2, ".{{ .uint = {} }},\n", .{ std.zig.fmtId(arg.name) });
                },
                .int => try printIndented(writer, indent + 2, ".{{ .int = {} }},\n", .{ std.zig.fmtId(arg.name) }),
                .fixed => try printIndented(writer, indent + 2, ".{{ .fixed = {} }},\n", .{ std.zig.fmtId(arg.name) }),
                .object => try printIndented(writer, indent + 2, ".{{ .object = @ptrCast({}) }},\n", .{ std.zig.fmtId(arg.name) }),
                .fd => try printIndented(writer, indent + 2, ".{{ .fd = @intFromEnum({}) }},\n", .{ std.zig.fmtId(arg.name) }),
                .string => try printIndented(writer, indent + 2, ".{{ .string = {} }},\n", .{ std.zig.fmtId(arg.name) }),
                .array => try printIndented(writer, indent + 2, ".{{ .array = {} }},\n", .{ std.zig.fmtId(arg.name) }),
            }
        }
        try writeIndented(writer, indent + 1, "};\n\n");

        const flags = if (message.is_destructor) ".{ .destroy = true }" else ".{}";
        if (newid_type_opt) |newid_type| {
            if (newid_type.interface) |interface| {
                try printIndented(writer, indent + 1, "return @ptrCast(wl_proxy_marshal_array_flags(@ptrCast(this), {}, {s}.INTERFACE, wl_proxy_get_version(@ptrCast(this)), {s}, &args", .{ message.opcode, interface, flags });
            } else {
                try printIndented(writer, indent + 1, "return @ptrCast(wl_proxy_marshal_array_flags(@ptrCast(this), {}, interface, wl_proxy_get_version(@ptrCast(this)), {s}, &args", .{ message.opcode, flags });
            }
            try writeIndented(writer, indent + 1, ") orelse return error.Failure);\n");
        } else {
            try printIndented(writer, indent + 1, "_ = wl_proxy_marshal_array_flags(@ptrCast(this), {}, null, wl_proxy_get_version(@ptrCast(this)), {s}, &args", .{ message.opcode, flags });
            try writeIndented(writer, indent + 1, ");\n");
        }
        try writeIndented(writer, indent + 0, "}\n\n");
    }

    pub fn writeCompatMessageStruct(message: @This(), writer: std.io.AnyWriter, indent: u32) !void {
        try writeIndented(writer, indent + 0, "wl_message{\n");
        try printIndented(writer, indent + 1, ".name = \"{}\",\n", .{ std.zig.fmtEscapes(message.name) });
        try writeIndented(writer, indent + 1, ".signature = \"");
        if (message.since > 0) try writer.print("{d}", .{message.since});
        for (message.args) |arg| {
            try arg.type.writeCompatSignature(writer);
        }
        try writer.writeAll("\",\n");

        if (message.args.len > 0) {
            try writeIndented(writer, indent + 1, ".types = &.{\n");
            for (message.args) |arg| {
                if (arg.type.interface) |interface_name| {
                    try printIndented(writer, indent + 2, "@extern(?*const wl_interface, .{{ .name = \"{}_interface\" }}),\n", .{ std.zig.fmtEscapes(interface_name) });
                } else {
                    try writeIndented(writer, indent + 2, "null,\n");
                }
            }
            try writeIndented(writer, indent + 1, "},\n");
        } else {
            try writeIndented(writer, indent + 1, ".types = &[0]?*const wire.compat.wl_interface{},\n");
        }
        try writeIndented(writer, indent + 0, "}");
    }
};

pub const Arg = struct {
    name: []const u8,
    summary: ?[]const u8,
    type: Type,

    pub fn parse(document: *const xml.Document, element: xml.Element) !Arg {
        _ = document;
        _ = element;
        // TODO PARSE THE XML DOCUMENT
    }
};

pub const Enum = struct {
    name: []const u8,
    since: u32,
    bitfield: bool,
    entries: []const Entry,

    pub const Entry = struct {
        name: []const u8,
        value: []const u8,
        summary: ?[]const u8,
        since: u32,
    };

    pub fn parse(gpa: std.mem.Allocator, document: *const xml.Document, element: xml.Element) !Enum {
        _ = gpa;
        _ = document;
        _ = element;
        // TODO PARSE THE XML DOCUMENT
    }

    pub fn writeZig(this_enum: @This(), writer: std.io.AnyWriter, target_version: u32, indent: u32) !void {
        if (this_enum.bitfield) {
            return this_enum.writeZigBitfield(writer, target_version, indent);
        }
        try printIndented(writer, indent, "pub const {}", .{ SnakeToCamelCaseFormatted{ .snake_phrase = this_enum.name }});
        try writer.writeAll(" = enum(wire.Uint) {\n");
        for (this_enum.entries) |entry| {
            if (entry.since > target_version) break;
            if (entry.summary) |summary| {
                var line_iter = std.mem.splitScalar(u8, summary, '\n');
                while (line_iter.next()) |line| {
                    try printIndented(writer, indent + 1, "/// {s}\n", .{line});
                }
            }
            try printIndented(writer, indent + 1, "{[name]} = {[value]s},\n", .{ .name = std.zig.fmtId(entry.name), .value = entry.value });
        }
        try writeIndented(writer, indent, "};\n\n");
    }

    fn writeZigBitfield(this_enum: @This(), writer: std.io.AnyWriter, target_version: u32, indent: u32) !void {
        try printIndented(writer, indent, "pub const {}", .{ SnakeToCamelCaseFormatted{ .snake_phrase = this_enum.name }});

        // check for duplicate bit fields
        var bits = std.bit_set.IntegerBitSet(32).initEmpty();
        for (this_enum.entries) |entry| {
            errdefer std.log.debug("entry name = {s}.{s}", .{ this_enum.name, entry.name });

            if (entry.since > target_version) continue;
            const entry_int = try std.fmt.parseInt(u32, entry.value, 0);

            if (entry_int == 0) continue;
            if (@popCount(entry_int) > 1) continue;
            const bit_index = std.math.log2(entry_int);

            if (bits.isSet(bit_index)) return error.DuplicateBitField;
            bits.set(bit_index);
        }
        try writer.writeAll(" = packed struct(wire.Uint) {\n");
        // write out field names
        var bit_iter = bits.iterator(.{});
        var prev_index: usize = 0;
        var padding_number: usize = 1;
        while (bit_iter.next()) |bit_index| {
            if (bit_index - prev_index > 1) {
                try printIndented(writer, indent + 1, "padding_{}: u{} = 0,\n", .{ padding_number, bit_index - prev_index });
                padding_number += 1;
            }
            for (this_enum.entries) |entry| {
                if (entry.since > target_version) break;
                const entry_int = try std.fmt.parseInt(u32, entry.value, 0);

                if (entry_int == 0) continue;
                if (@popCount(entry_int) > 1) continue;
                const value_bit_index = std.math.log2(entry_int);

                if (value_bit_index != bit_index) continue;
                if (entry.summary) |summary| try printIndented(writer, indent + 1, "/// {s}\n", .{summary});
                try printIndented(writer, indent + 1, "{[name]}: bool,\n", .{ .name = std.zig.fmtId(entry.name) });
            }
            prev_index = bit_index;
        }
        if (prev_index != 31) {
            try printIndented(writer, indent + 1, "padding_{}: u{} = 0,\n", .{ padding_number, 31 - prev_index });
        }
        // write out multi bit values as declarations
        for (this_enum.entries) |entry| {
            errdefer std.log.debug("entry name = {s}.{s}", .{ this_enum.name, entry.name });

            if (entry.since > target_version) continue;
            const entry_int = try std.fmt.parseInt(u32, entry.value, 0);
            if (@popCount(entry_int) == 1) continue;

            try printIndented(writer, indent + 1, "pub const {}: @This() = @enumFromInt({s});\n", .{ std.zig.fmtId(entry.name), entry.value });
        }
        try writeIndented(writer, indent, "};\n\n");
        return;
    }
};

pub const SnakeToCamelCaseFormatted = struct {
    snake_phrase: []const u8,

    pub fn format(
        this: @This(),
        comptime fmt_text: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt_text;
        _ = options;
        var word_iter = std.mem.splitScalar(u8, this.snake_phrase, '_');
        while (word_iter.next()) |word| {
            if (word.len == 0) continue;
            try writer.writeByte(std.ascii.toUpper(word[0]));
            try writer.writeAll(word[1..]);
        }
    }
};

fn stripNewlines(text: []const u8) StripNewlineFormatter {
    return .{ .text = text };
}

const StripNewlineFormatter = struct {
    text: []const u8,

    pub fn format(
        this: @This(),
        comptime fmt_text: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt_text;
        _ = options;

        var line_iter = std.mem.tokenizeScalar(u8, this.text, '\n');
        while (line_iter.next()) |line| {
            try writer.writeAll(line);
        }
    }
};

pub fn writeIndented(writer: std.io.AnyWriter, indent: u32, bytes: []const u8) !void {
    var line_iter = std.mem.splitScalar(u8, bytes, '\n');
    var first = true;
    while (line_iter.next()) |line| {
        if (line.len == 0) {
            try writer.writeByte('\n');
            continue;
        }
        if (!first) {
            try writer.writeByte('\n');
        }
        try writer.writeByteNTimes(' ', indent * 4);
        try writer.writeAll(line);

        first = false;
    }
}

pub fn printIndented(writer: std.io.AnyWriter, indent: u32, comptime template_string: []const u8, args: anytype) !void {
    try writer.writeByteNTimes(' ', indent * 4);
    try writer.print(template_string, args);
}
