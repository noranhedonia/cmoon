const std = @import("std");
const registry = @import("./registry.zig");
const Allocator = std.mem.Allocator;
const ArraySize = registry.Array.ArraySize;
const TypeInfo = registry.TypeInfo;
const xml = @import("sorceress").xml;

pub const Token = struct {
    kind: Kind,
    text: []const u8,

    const Kind = enum {
        id, // Any id thats not a keyword
        name, // Vulkan <name>...</name>
        type_name, // Vulkan <type>...</type>
        enum_name, // Vulkan <enum>...</enum>
        int,
        star,
        comma,
        semicolon,
        colon,
        minus,
        tilde,
        dot,
        hash,
        lparen,
        rparen,
        lbracket,
        rbracket,
        kw_typedef,
        kw_const,
        kw_vkapi_ptr,
        kw_struct,
    };
};

pub const CTokenizer = struct {
    source: []const u8,
    offset: usize = 0,
    in_comment: bool = false,

    fn peek(this: CTokenizer) ?u8 {
        return if (this.offset < this.source.len) this.source[this.offset] else null;
    }

    fn consumeNoEof(this: *CTokenizer) u8 {
        const c = this.peek().?;
        this.offset += 1;
        return c;
    }

    fn consume(this: *CTokenizer) !u8 {
        return if (this.offset < this.source.len)
            return this.consumeNoEof()
        else
            return null;
    }

    fn keyword(this: *CTokenizer) Token {
        const start = this.offset;
        _ = this.consumeNoEof();

        while (true) {
            const c = this.peek() orelse break;
            switch (c) {
                'A'...'Z', 'a'...'z', '_', '0'...'9' => _ = this.consumeNoEof(),
                else => break,
            }
        }
        const token_text = this.source[start..this.offset];

        const kind = if (std.mem.eql(u8, token_text, "typedef"))
            Token.Kind.kw_typedef
        else if (std.mem.eql(u8, token_text, "const"))
            Token.Kind.kw_const
        else if (std.mem.eql(u8, token_text, "VKAPI_PTR"))
            Token.Kind.kw_vkapi_ptr
        else if (std.mem.eql(u8, token_text, "struct"))
            Token.Kind.kw_struct
        else
            Token.Kind.id;
        return .{ .kind = kind, .text = token_text };
    }

    fn int(this: *CTokenizer) Token {
        const start = this.offset;
        _ = this.consumeNoEof();

        const hex = this.peek() == 'x';
        if (hex) {
            _ = this.consumeNoEof();
        }
        while (true) {
            switch (this.peek() orelse break) {
                '0'...'9' => _ = this.consumeNoEof(),
                'A'...'F', 'a'...'f' => {
                    if (!hex) break;
                    _ = this.consumeNoEof();
                },
                else => break,
            }
        }
        return .{
            .kind = .int,
            .text = this.source[start..this.offset],
        };
    }

    fn skipws(this: *CTokenizer) void {
        while (true) {
            switch (this.peek() orelse break) {
                ' ', '\t', '\n', '\r' => _ = this.consumeNoEof(),
                else => break,
            }
        }
    }

    pub fn next(this: *CTokenizer) !?Token {
        this.skipws();
        if (std.mem.startsWith(u8, this.source[this.offset..], "//") or this.in_comment) {
            const end = std.mem.indexOfScalarPos(u8, this.source, this.offset, '\n') orelse {
                this.offset = this.source.len;
                this.in_comment = true;
                return null;
            };
            this.in_comment = false;
            this.offset = end + 1;
        }
        this.skipws();

        const c = this.peek() orelse return null;
        var kind: Token.Kind = undefined;
        switch (c) {
            'A'...'Z', 'a'...'z', '_' => return this.keyword(),
            '0'...'9' => return this.int(),
            '*' => kind = .star,
            ',' => kind = .comma,
            ';' => kind = .semicolon,
            ':' => kind = .colon,
            '-' => kind = .minus,
            '~' => kind = .tilde,
            '.' => kind = .dot,
            '#' => kind = .hash,
            '[' => kind = .lbracket,
            ']' => kind = .rbracket,
            '(' => kind = .lparen,
            ')' => kind = .rparen,
            else => return error.UnexpectedCharacter,
        }
        const start = this.offset;
        _ = this.consumeNoEof();
        return Token{ .kind = kind, .text = this.source[start..this.offset] };
    }
};

pub const XmlCTokenizer = struct {
    it: xml.Element.ChildIterator,
    ctok: ?CTokenizer = null,
    current: ?Token = null,

    pub fn init(elem: *xml.Element) XmlCTokenizer {
        return .{
            .it = elem.iterator(),
        };
    }

    fn elemToToken(elem: *xml.Element) !?Token {
        // Sometimes we encounter empty comment tags. Filter those out
        // by early returning here, otherwise the next check will
        // determine that the input is not valid XML.
        if (std.mem.eql(u8, elem.tag, "comment")) {
            return null;
        } else if (elem.children.len != 1 or elem.children[0] != .char_data) {
            return error.InvalidXml;
        }

        const text = elem.children[0].char_data;
        if (std.mem.eql(u8, elem.tag, "type")) {
            return Token{ .kind = .type_name, .text = text };
        } else if (std.mem.eql(u8, elem.tag, "enum")) {
            return Token{ .kind = .enum_name, .text = text };
        } else if (std.mem.eql(u8, elem.tag, "name")) {
            return Token{ .kind = .name, .text = text };
        } else {
            return error.InvalidTag;
        }
    }

    fn next(this: *XmlCTokenizer) !?Token {
        if (this.current) |current| {
            const token = current;
            this.current = null;
            return token;
        }
        var in_comment: bool = false;

        while (true) {
            if (this.ctok) |*ctok| {
                if (try ctok.next()) |tok| {
                    return tok;
                }
                in_comment = ctok.in_comment;
            }
            this.ctok = null;

            if (this.it.next()) |child| {
                switch (child.*) {
                    .char_data => |cdata| this.ctok = CTokenizer{ .source = cdata, .in_comment = in_comment },
                    .comment => {}, // xml comment
                    .element => |elem| if (!in_comment) if (try elemToToken(elem)) |tok| return tok,
                }
            } else {
                return null;
            }
        }
    }

    fn nextNoEof(this: *XmlCTokenizer) !Token {
        return (try this.next()) orelse return error.UnexpectedEof;
    }

    fn peek(this: *XmlCTokenizer) !?Token {
        if (this.current) |current| {
            return current;
        }
        this.current = try this.next();
        return this.current;
    }

    fn peekNoEof(this: *XmlCTokenizer) !Token {
        return (try this.peek()) orelse return error.UnexpectedEof;
    }

    fn expect(this: *XmlCTokenizer, kind: Token.Kind) !Token {
        const tok = (try this.next()) orelse return error.UnexpectedEof;
        if (tok.kind != kind) {
            return error.UnexpectedToken;
        }
        return tok;
    }
};

// TYPEDEF = kw_typedef DECLARATION ';'
pub fn parseTypedef(
    allocator: Allocator, 
    xctok: *XmlCTokenizer, 
    ptrs_optional: bool,
) !registry.Declaration {
    _ = try xctok.expect(.kw_typedef);
    const decl = try parseDeclaration(allocator, xctok, ptrs_optional);
    _ = try xctok.expect(.semicolon);
    if (try xctok.peek()) |_| {
        return error.InvalidSyntax;
    }
    return registry.Declaration{
        .name = decl.name orelse return error.MissingTypeIdentifier,
        .decl_type = .{ .typedef = decl.decl_type },
    };
}

// MEMBER = DECLARATION (':' int)?
pub fn parseMember(
    allocator: Allocator, 
    xctok: *XmlCTokenizer, 
    ptrs_optional: bool,
) !registry.Container.Field {
    const decl = try parseDeclaration(allocator, xctok, ptrs_optional);
    var field = registry.Container.Field{
        .name = decl.name orelse return error.MissingTypeIdentifier,
        .field_type = decl.decl_type,
        .bits = null,
        .is_buffer_len = false,
        .is_optional = false,
    };
    if (try xctok.peek()) |tok| {
        if (tok.kind != .colon) {
            return error.InvalidSyntax;
        }
        _ = try xctok.nextNoEof();
        const bits = try xctok.expect(.int);
        field.bits = try std.fmt.parseInt(usize, bits.text, 10);
        // Assume for now that there won't be any invalid C types like `char char* x : 4`.
        if (try xctok.peek()) |_| {
            return error.InvalidSyntax;
        }
    }
    return field;
}

pub fn parseParamOrProto(
    allocator: Allocator, 
    xctok: *XmlCTokenizer, 
    ptrs_optional: bool,
) !registry.Declaration {
    var decl = try parseDeclaration(allocator, xctok, ptrs_optional);
    if (try xctok.peek()) |_| {
        return error.InvalidSyntax;
    }
    // Decay pointers
    switch (decl.decl_type) {
        .array => {
            const child = try allocator.create(TypeInfo);
            child.* = decl.decl_type;

            decl.decl_type = .{
                .pointer = .{
                    .is_const = decl.is_const,
                    .is_optional = false,
                    .size = .one,
                    .child = child,
                },
            };
        },
        else => {},
    }
    return registry.Declaration{
        .name = decl.name orelse return error.MissingTypeIdentifier,
        .decl_type = .{ .typedef = decl.decl_type },
    };
}

pub const Declaration = struct {
    name: ?[]const u8, // Parameter names may be optional, especially in case of func(void)
    decl_type: TypeInfo,
    is_const: bool,
};

pub const ParseError = error{
    OutOfMemory,
    InvalidSyntax,
    InvalidTag,
    InvalidXml,
    Overflow,
    UnexpectedEof,
    UnexpectedCharacter,
    UnexpectedToken,
    MissingTypeIdentifier,
};

// DECLARATION = kw_const? type_name DECLARATOR
// DECLARATOR = POINTERS (id | name)? ('[' ARRAY_DECLARATOR ']')*
//     | POINTERS '(' FNPTRSUFFIX
fn parseDeclaration(
    allocator: Allocator, 
    xctok: *XmlCTokenizer, 
    ptrs_optional: bool,
) ParseError!Declaration {
    // Parse declaration constness
    var tok = try xctok.nextNoEof();
    const inner_is_const = tok.kind == .kw_const;
    if (inner_is_const) {
        tok = try xctok.nextNoEof();
    }
    if (tok.kind == .kw_struct) {
        tok = try xctok.nextNoEof();
    }
    // Parse type name
    if (tok.kind != .type_name and tok.kind != .id) return error.InvalidSyntax;
    const type_name = tok.text;
    var type_info = TypeInfo{ .name = type_name };

    // Parse pointers
    type_info = try parsePointers(allocator, xctok, inner_is_const, type_info, ptrs_optional);
    // Parse name / fn ptr

    if (try parseFnPtrSuffix(allocator, xctok, type_info, ptrs_optional)) |decl| {
        return Declaration{
            .name = decl.name,
            .decl_type = decl.decl_type,
            .is_const = inner_is_const,
        };
    }
    const name = blk: {
        const name_tok = (try xctok.peek()) orelse break :blk null;
        if (name_tok.kind == .id or name_tok.kind == .name) {
            _ = try xctok.nextNoEof();
            break :blk name_tok.text;
        } else {
            break :blk null;
        }
    };

    var inner_type = &type_info;
    while (try parseArrayDeclarator(xctok)) |array_size| {
        // Move the current inner type to a new node on the heap
        const child = try allocator.create(TypeInfo);
        child.* = inner_type.*;

        // Re-assign the previous inner type for the array type info node
        inner_type.* = .{
            .array = .{
                .size = array_size,
                .valid_size = .all, // Refined later
                .is_optional = true,
                .child = child,
            },
        };
        // update the inner_type pointer so it points to the proper
        // inner type again
        inner_type = child;
    }
    return Declaration{
        .name = name,
        .decl_type = type_info,
        .is_const = inner_is_const,
    };
}

// FNPTRSUFFIX = kw_vkapi_ptr '*' name' ')' '(' ('void' | (DECLARATION (',' DECLARATION)*)?) ')'
fn parseFnPtrSuffix(
    allocator: Allocator, 
    xctok: *XmlCTokenizer, 
    return_type: TypeInfo, 
    ptrs_optional: bool,
) !?Declaration {
    const lparen = try xctok.peek();
    if (lparen == null or lparen.?.kind != .lparen) {
        return null;
    }
    _ = try xctok.nextNoEof();
    _ = try xctok.expect(.kw_vkapi_ptr);
    _ = try xctok.expect(.star);
    const name = try xctok.expect(.name);
    _ = try xctok.expect(.rparen);
    _ = try xctok.expect(.lparen);

    const return_type_heap = try allocator.create(TypeInfo);
    return_type_heap.* = return_type;

    var command_ptr = Declaration{
        .name = name.text,
        .decl_type = .{
            .command_ptr = .{
                .params = &[_]registry.Command.Param{},
                .return_type = return_type_heap,
                .success_codes = &[_][]const u8{},
                .error_codes = &[_][]const u8{},
            },
        },
        .is_const = false,
    };
    const first_param = try parseDeclaration(allocator, xctok, ptrs_optional);
    if (first_param.name == null) {
        if (first_param.decl_type != .name or !std.mem.eql(u8, first_param.decl_type.name, "void")) {
            return error.InvalidSyntax;
        }
        _ = try xctok.expect(.rparen);
        return command_ptr;
    }
    // There is no good way to estimate the number of parameters beforehand.
    // Fortunately, there are usually a relatively low number of parameters to a function pointer,
    // so an ArrayList backed by an arena allocator is good enough.
    var params = std.ArrayList(registry.Command.Param).init(allocator);
    try params.append(.{
        .name = first_param.name.?,
        .param_type = first_param.decl_type,
        .is_buffer_len = false,
        .is_optional = false,
    });
    while (true) {
        switch ((try xctok.peekNoEof()).kind) {
            .rparen => break,
            .comma => _ = try xctok.nextNoEof(),
            else => return error.InvalidSyntax,
        }
        const decl = try parseDeclaration(allocator, xctok, ptrs_optional);
        try params.append(.{
            .name = decl.name orelse return error.MissingTypeIdentifier,
            .param_type = decl.decl_type,
            .is_buffer_len = false,
            .is_optional = false,
        });
    }
    _ = try xctok.nextNoEof();
    command_ptr.decl_type.command_ptr.params = try params.toOwnedSlice();
    return command_ptr;
}

// POINTERS = (kw_const? '*')*
fn parsePointers(
    allocator: Allocator, 
    xctok: *XmlCTokenizer, 
    inner_const: bool, 
    inner: TypeInfo, 
    ptrs_optional: bool,
) !TypeInfo {
    var type_info = inner;
    var first_const = inner_const;

    while (true) {
        var tok = (try xctok.peek()) orelse return type_info;
        var is_const = first_const;
        first_const = false;

        if (tok.kind == .kw_const) {
            is_const = true;
            _ = try xctok.nextNoEof();
            tok = (try xctok.peek()) orelse return type_info;
        }
        if (tok.kind != .star) {
            // if `is_const` is true at this point, there was a trailing const,
            // and the declaration itself is const.
            return type_info;
        }
        _ = try xctok.nextNoEof();
        const child = try allocator.create(TypeInfo);
        child.* = type_info;

        type_info = .{
            .pointer = .{
                .is_const = is_const or first_const,
                .is_optional = ptrs_optional, // set elsewhere
                .size = .one, // set elsewhere
                .child = child,
            },
        };
    }
}

// ARRAY_DECLARATOR = '[' (int | enum_name) ']'
fn parseArrayDeclarator(xctok: *XmlCTokenizer) !?ArraySize {
    const lbracket = try xctok.peek();
    if (lbracket == null or lbracket.?.kind != .lbracket) {
        return null;
    }
    _ = try xctok.nextNoEof();
    const size_tok = try xctok.nextNoEof();
    const size: ArraySize = switch (size_tok.kind) {
        .int => .{
            .int = std.fmt.parseInt(usize, size_tok.text, 10) catch |err| switch (err) {
                error.Overflow => return error.Overflow,
                error.InvalidCharacter => unreachable,
            },
        },
        // Sometimes, arrays are declared as `<type>T</type> <name>aa</name>[<enum>SIZE</enum>]`,
        // and sometimes just as `<type>T</type> <name>aa</name>[SIZE]`, so we have to account
        // for both `.enum_name` and `.id` here.
        .enum_name, .id => .{ .alias = size_tok.text },
        else => return error.InvalidSyntax,
    };
    _ = try xctok.expect(.rbracket);
    return size;
}

pub fn parseVersion(xctok: *XmlCTokenizer) !registry.ApiConstant.Value {
    _ = try xctok.expect(.hash);
    const define = try xctok.expect(.id);
    if (!std.mem.eql(u8, define.text, "define")) {
        return error.InvalidVersion;
    }
    _ = try xctok.expect(.name);
    const vk_make_version = try xctok.expect(.type_name);
    if (std.mem.eql(u8, vk_make_version.text, "VK_MAKE_API_VERSION")) {
        return .{
            .version = try parseVersionValues(xctok, 4),
        };
    } else if (std.mem.eql(u8, vk_make_version.text, "VK_MAKE_VIDEO_STD_VERSION")) {
        return .{
            .video_std_version = try parseVersionValues(xctok, 3),
        };
    } else {
        return error.NotVersion;
    }
}

fn parseVersionValues(xctok: *XmlCTokenizer, comptime count: usize) ![count][]const u8 {
    _ = try xctok.expect(.lparen);
    var version: [count][]const u8 = undefined;
    for (&version, 0..) |*part, i| {
        if (i != 0) {
            _ = try xctok.expect(.comma);
        }
        const tok = try xctok.nextNoEof();
        switch (tok.kind) {
            .id, .int => part.* = tok.text,
            else => return error.UnexpectedToken,
        }
    }
    _ = try xctok.expect(.rparen);
    return version;
}

fn testTokenizer(tokenizer: anytype, expected_tokens: []const Token) !void {
    for (expected_tokens) |expected| {
        const tok = (tokenizer.next() catch unreachable).?;
        try std.testing.expectEqual(expected.kind, tok.kind);
        try std.testing.expectEqualSlices(u8, expected.text, tok.text);
    }
    if (tokenizer.next() catch unreachable) |_| unreachable;
}

test "CTokenizer" {
    var ctok = CTokenizer{ .source = "typedef ([const)]** VKAPI_PTR 123,;aaaa" };

    try testTokenizer(&ctok, &[_]Token{
        .{ .kind = .kw_typedef, .text = "typedef" },
        .{ .kind = .lparen, .text = "(" },
        .{ .kind = .lbracket, .text = "[" },
        .{ .kind = .kw_const, .text = "const" },
        .{ .kind = .rparen, .text = ")" },
        .{ .kind = .rbracket, .text = "]" },
        .{ .kind = .star, .text = "*" },
        .{ .kind = .star, .text = "*" },
        .{ .kind = .kw_vkapi_ptr, .text = "VKAPI_PTR" },
        .{ .kind = .int, .text = "123" },
        .{ .kind = .comma, .text = "," },
        .{ .kind = .semicolon, .text = ";" },
        .{ .kind = .id, .text = "aaaa" },
    });
}

test "XmlCTokenizer" {
    const document = try xml.parse(std.testing.allocator,
        \\<root>// comment <name>commented name</name> <type>commented type</type> trailing
        \\    typedef void (VKAPI_PTR *<name>PFN_vkVoidFunction</name>)(void);
        \\</root>
    );
    defer document.deinit();

    var xctok = XmlCTokenizer.init(document.root);

    try testTokenizer(&xctok, &[_]Token{
        .{ .kind = .kw_typedef, .text = "typedef" },
        .{ .kind = .id, .text = "void" },
        .{ .kind = .lparen, .text = "(" },
        .{ .kind = .kw_vkapi_ptr, .text = "VKAPI_PTR" },
        .{ .kind = .star, .text = "*" },
        .{ .kind = .name, .text = "PFN_vkVoidFunction" },
        .{ .kind = .rparen, .text = ")" },
        .{ .kind = .lparen, .text = "(" },
        .{ .kind = .id, .text = "void" },
        .{ .kind = .rparen, .text = ")" },
        .{ .kind = .semicolon, .text = ";" },
    });
}

test "parseTypedef" {
    const document = try xml.parse(std.testing.allocator,
        \\<root> // comment <name>commented name</name> trailing
        \\    typedef const struct <type>Python</type>* pythons[4];
        \\ // more comments
        \\</root>
        \\
    );
    defer document.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var xctok = XmlCTokenizer.init(document.root);
    const decl = try parseTypedef(arena.allocator(), &xctok, false);

    try std.testing.expectEqualSlices(u8, "pythons", decl.name);
    const array = decl.decl_type.typedef.array;
    try std.testing.expectEqual(ArraySize{ .int = 4 }, array.size);
    const ptr = array.child.pointer;
    try std.testing.expectEqual(true, ptr.is_const);
    try std.testing.expectEqualSlices(u8, "Python", ptr.child.name);
}
