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
    // var interface_locations = std.StringHashMap(InterfaceLocation).init(gpa.allocator());
    // defer interface_locations.deinit();

    var source_protocols = std.StringArrayHashMap(Protocol).init(allocator);
    defer {
        for (source_protocols.values()) |*protocol| protocol.deinit();
        source_protocols.deinit();
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Read and in source protocol files.
    // for (options.protocol_xml_filepaths.keys()) |source_filepath| {
    //     var protocol = try Protocol.parse(allocator, source_filepath);
    //     errdefer protocol.deinit();

    //     for (protocol.interfaces) |inte
    // }

}

pub const CommandLineOptions = struct {
    arena: std.heap.ArenaAllocator,
    output: ?[]const u8,
    compat_output: ?[]const u8,
    protocol_xml_filepaths: std.StringArrayHashMap(void),

    fn deinit(this: *@This()) void  {
        this.protocol_xml_filepaths.deinit();
        this.arena.deinit();
    }
};

fn parseCommandLineOptions(allocator: std.mem.Allocator, arguments: []const [:0]const u8) !CommandLineOptions {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var output_directory: ?[]const u8 = null;
    var output_compat: ?[]const u8 = null;
    var protocol_xml_filepaths = std.StringArrayHashMap(void).init(allocator);
    var print_help = false;
    errdefer protocol_xml_filepaths.deinit();

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
            \\  -h, --help        Print this message :D
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
    };
}

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

        const xml_file = try std.fs.cwd().openFile(xml_file_path, .{});
        defer xml_file.close();

        var document = try xml.parse(allocator, xml_file_path, xml_file.reader());
        errdefer document.deinit();
        document.acquire();
        defer document.release();

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        var interfaces = std.ArrayList(Interface).init(allocator);
        errdefer {
            for (interfaces.items) |interface| {
                allocator.free(interface.description);
                this.allocator.free(interface.enums);
                this.allocator.free(interface.requests);
                this.allocator.free(interface.events);
            }
            interfaces.deinit();
        }
        var copyright: ?std.ArrayList(u8) = null;
        errdefer if (copyright) |*array_list| array_list.deinit();

        for (document.root.children()) |child| {
            const child_element = switch (document.nodes.get(@intFromEnum(child))) {
                .element => |elem| elem, else => continue,
            };
            const child_tag = child_element.tag_name.slice();

            if (std.mem.eql(u8, child_tag, "interface")) {
                const name = child_element.attr("name") orelse return error.InvalidFormat;
                const version_str = child_element.attr("version") orelse return error.InvalidFormat;
                const version = try std.fmt.parseInt(u16, version_str, 10);

                var description = std.ArrayList([]const u8).init(allocator);
                var enums = std.ArrayList(Enum).init(allocator);
                var requests = std.ArrayList(Message).init(allocator);
                var events = std.ArrayList(Message).init(allocator);
                errdefer {
                    descriptions.deinit();
                    enums.deinit();
                    requests.deinit();
                    events.deinit();
                }
                for (child_element.children()) |grandchild| {
                    const grandchild_element = switch (document.nodes.get(@intFromEnum(grandchild))) {
                        .element => |elem| elem, else => continue,
                    };
                    const grandchild_tag = grandchild_element.tag_name.slice();

                    if (std.mem.eql(u8, grandchild_tag, "request")) {
                        const request = try Message.parse(arena.allocator(), &document, grandchild_element, @intCast(requests.items.len));
                        try requests.append(request);
                    } else if (std.mem.eql(u8, grandchild_tag, "event")) {
                        const event = try Message.parse(arena.allocator(), &document, grandchild_element, @intCast(events.items.len));
                        try events.append(event);
                    } else if (std.mem.eql(u8, grandchild_tag, "description")) {
                        for (grandchild_element.children()) |desc_child_id| {
                            switch (document.nodes.get(@intFromEnum(desc_child_id))) {
                                .text => |txt| try description.append(txt.slice()),
                                else => continue,
                            }
                        }
                    } else if (std.mem.eql(u8, grandchild_tag, "enum")) {
                        const entry = try Enum.parse(arena.allocator(), &document, grandchild_element);
                        try enums.append(entry);
                    }
                }
                const description_slice = try description.toOwnedSlice();
                errdefer allocator.free(description_slice);

                const enums_slice = try enums.toOwnedSlice();
                errdefer allocator.free(enums_slice);

                const requests_slice = try requests.toOwnedSlice();
                errdefer allocator.free(requests_slice);

                const events_slice = try events.toOwnedSlice();
                errdefer allocator.free(events_slice);

                try interfaces.append(Interface{
                    .name = name,
                    .version = version,
                    .description = description_slice,
                    .enums = enum_slice,
                    .requests = requests_slice,
                    .events = events_slice,
                    .error_enum = null,
                });
            } else if (std.mem.eql(u8, child_tag, "copyright")) {
                if (copyright == null) copyright = std.ArrayList(u8).init(allocator);
                for (child_element.children()) |grandchild| {
                    const grandchild_node = document.nodes.get(@intFromEnum(grandchild));
                    const text = grandchild_node.text.slice();
                    var line_iter = std.mem.splitScalar(u8, text, '\n');
                    while (line_iter.next()) |line| {
                        try copyright.?.writer().writeAll("// ");
                        try copyright.?.writer().writeAll(std.mem.trimLeft(u8, line, " \t"));
                        try copyright.?.writer().writeAll("\n");
                    }
                    try copyright.?.writer().writeAll("\n");
                }
            }
        }
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
            .name = document.root.attr("name"),
            .document = document,
            .copyright = copyright_slice,
            .output_filename = this_output_filename,
        };
    }

    pub fn writeProtocolZig(this: @This(), writer: std.io.AnyWriter) !void {
        if (this.copyright) |copyright| try writer.writeAll(copyright);
        try writer.writeAll(
            \\const wire = @import("wayland-wire");
            \\
        );
        for (this.interfaces) |interface| try interface.writeZig(writer, interface.version);
    }

    pub fn writeCompatZig(this: @This(), writer: std.io.AnyWriter) !void {
        for (this.interfaces) |interface| try interface.writeCompatZig(writer, interface.version);
    }
};

pub const Type = struct {

};

const Interface = struct {
    name: []const u8,
    version: u32,
    description: []const []const u8,
    enums: []const Enum,
    requests: []const Message,
    events: []const Message,
    error_enum: ?Enum,
};

const Message = struct {
    name: []const u8,
    opcode: u16,
    summary: ?[]const u8,
    description: []const []const u8,
    args: []const Arg,
    since: u32,
    is_destructor: bool,
};

pub const Arg = struct {
    name: []const u8,
    summary: ?[]const u8,
    type: Type,
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
};
