const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

pub const Content = union(enum) {
    char_data: []const u8,
    comment: []const u8,
    element: *Element,
};

pub const Element = struct {
    tag: []const u8,
    attributes: []Attribute = &.{},
    children: []Content = &.{},

    pub fn getAttribute(this: Element, attrib_name: []const u8) ?[]const u8 {
        for (this.attributes) |child| {
            if (std.mem.eql(u8, child.name, attrib_name)) {
                return child.value;
            }
        }
        return null;
    }

    pub fn getCharData(this: Element, child_tag: []const u8) ?[]const u8 {
        const child = this.findChildByTag(child_tag) orelse return null;

        if (child.children.len != 1) {
            return null;
        }
        return switch (child.children[0]) {
            .char_data => |char_data| char_data,
            else => null,
        };
    }

    pub fn iterator(this: Element) ChildIterator {
        return .{
            .items = this.children,
            .i = 0,
        };
    }

    pub fn elements(this: Element) ChildElementIterator {
        return .{
            .inner = this.iterator(),
        };
    }

    pub fn findChildByTag(this: Element, tag: []const u8) ?*Element {
        var it = this.findChildrenByTag(tag);
        return it.next();
    }

    pub fn findChildrenByTag(this: Element, tag: []const u8) FindChildrenByTagIterator {
        return .{
            .inner = this.elements(),
            .tag = tag,
        };
    }

    pub const ChildIterator = struct {
        items: []Content,
        i: usize,

        pub fn next(this: *ChildIterator) ?*Content {
            if (this.i < this.items.len) {
                this.i += 1;
                return &this.items[this.i - 1];
            }
            return null;
        }
    };

    pub const ChildElementIterator = struct {
        inner: ChildIterator,

        pub fn next(this: *ChildElementIterator) ?*Element {
            while (this.inner.next()) |child| {
                if (child.* != .element) {
                    continue;
                }
                return child.*.element;
            }
            return null;
        }
    };

    pub const FindChildrenByTagIterator = struct {
        inner: ChildElementIterator,
        tag: []const u8,

        pub fn next(this: *FindChildrenByTagIterator) ?*Element {
            while (this.inner.next()) |child| {
                if (!std.mem.eql(u8, child.tag, this.tag)) {
                    continue;
                }
                return child;
            }
            return null;
        }
    };
};

pub const Document = struct {
    arena: ArenaAllocator,
    xml_decl: ?*Element,
    root: *Element,

    pub fn deinit(this: Document) void {
        var arena = this.arena; // Copy to stack so self can be taken by value.
        arena.deinit();
    }
};

const Parser = struct {
    source: []const u8,
    offset: usize,
    line: usize,
    column: usize,

    fn init(source: []const u8) Parser {
        return .{
            .source = source,
            .offset = 0,
            .line = 0,
            .column = 0,
        };
    }

    fn peek(this: *Parser) ?u8 {
        return if (this.offset < this.source.len) this.source[this.offset] else null;
    }

    fn consume(this: *Parser) !u8 {
        if (this.offset < this.source.len) {
            return this.consumeNoEof();
        }
        return error.UnexpectedEof;
    }

    fn consumeNoEof(this: *Parser) u8 {
        std.debug.assert(this.offset < this.source.len);
        const c = this.source[this.offset];
        this.offset += 1;

        if (c == '\n') {
            this.line += 1;
            this.column = 0;
        } else {
            this.column += 1;
        }
        return c;
    }

    fn eat(this: *Parser, char: u8) bool {
        this.expect(char) catch return false;
        return true;
    }

    fn expect(this: *Parser, expected: u8) !void {
        if (this.peek()) |actual| {
            if (expected != actual) {
                return error.UnexpectedCharacter;
            }
            _ = this.consumeNoEof();
            return;
        }
        return error.UnexpectedEof;
    }

    fn eatStr(this: *Parser, text: []const u8) bool {
        this.expectStr(text) catch return false;
        return true;
    }

    fn expectStr(this: *Parser, text: []const u8) !void {
        if (this.source.len < this.offset + text.len) {
            return error.UnexpectedEof;
        } else if (std.mem.startsWith(u8, this.source[this.offset..], text)) {
            var i: usize = 0;
            while (i < text.len) : (i += 1) {
                _ = this.consumeNoEof();
            }
            return;
        }
        return error.UnexpectedCharacter;
    }

    fn eatWs(this: *Parser) bool {
        var ws = false;

        while (this.peek()) |ch| {
            switch (ch) {
                ' ', '\t', '\n', '\r' => {
                    ws = true;
                    _ = this.consumeNoEof();
                },
                else => break,
            }
        }
        return ws;
    }

    fn expectWs(this: *Parser) !void {
        if (!this.eatWs()) return error.UnexpectedCharacter;
    }

    fn currentLine(this: Parser) []const u8 {
        var begin: usize = 0;
        if (std.mem.lastIndexOfScalar(u8, this.source[0..this.offset], '\n')) |prev_nl| {
            begin = prev_nl + 1;
        }
        const end = std.mem.indexOfScalarPos(u8, this.source, this.offset, '\n') orelse this.source.len;
        return this.source[begin..end];
    }
};

pub const ParseError = error{
    IllegalCharacter,
    UnexpectedEof,
    UnexpectedCharacter,
    UnclosedValue,
    UnclosedComment,
    InvalidName,
    InvalidEntity,
    InvalidStandaloneValue,
    NonMatchingClosingTag,
    InvalidDocument,
    OutOfMemory,
};

pub fn parse(backing_allocator: Allocator, source: []const u8) !Document {
    var parser = Parser.init(source);
    return try parseDocument(&parser, backing_allocator);
}

fn parseDocument(parser: *Parser, backing_allocator: Allocator) !Document {
    var doc = Document{
        .arena = ArenaAllocator.init(backing_allocator),
        .xml_decl = null,
        .root = undefined,
    };
    errdefer doc.deinit();
    const allocator = doc.arena.allocator();
    try skipComments(parser, allocator);

    doc.xml_decl = try parseElement(parser, allocator, .xml_decl);
    _ = parser.eatWs();
    try skipComments(parser, allocator);

    doc.root = (try parseElement(parser, allocator, .element)) orelse return error.InvalidDocument;
    _ = parser.eatWs();
    try skipComments(parser, allocator);

    if (parser.peek() != null) return error.InvalidDocument;
    return doc;
}

fn parseAttrValue(parser: *Parser, alloc: Allocator) ![]const u8 {
    const quote = try parser.consume();
    if (quote != '"' and quote != '\'') return error.UnexpectedCharacter;

    const begin = parser.offset;
    while (true) {
        const c = parser.consume() catch return error.UnclosedValue;
        if (c == quote) break;
    }
    const end = parser.offset - 1;
    return try unescape(alloc, parser.source[begin..end]);
}

fn parseEqAttrValue(parser: *Parser, alloc: Allocator) ![]const u8 {
    _ = parser.eatWs();
    try parser.expect('=');
    _ = parser.eatWs();
    return try parseAttrValue(parser, alloc);
}

fn parseNameNoDupe(parser: *Parser) ![]const u8 {
    // XML's spec on names is very long, so to make this easier
    // we just take any character that is not special and not whitespace
    const begin = parser.offset;

    while (parser.peek()) |ch| {
        switch (ch) {
            ' ', '\t', '\n', '\r' => break,
            '&', '"', '\'', '<', '>', '?', '=', '/' => break,
            else => _ = parser.consumeNoEof(),
        }
    }
    const end = parser.offset;
    if (begin == end) return error.InvalidName;

    return parser.source[begin..end];
}

fn parseCharData(parser: *Parser, alloc: Allocator) !?[]const u8 {
    const begin = parser.offset;

    while (parser.peek()) |ch| {
        switch (ch) {
            '<' => break,
            else => _ = parser.consumeNoEof(),
        }
    }
    const end = parser.offset;
    if (begin == end) return null;

    return try unescape(alloc, parser.source[begin..end]);
}

fn parseContent(parser: *Parser, alloc: Allocator) ParseError!Content {
    if (try parseCharData(parser, alloc)) |cd| {
        return Content{ .char_data = cd };
    } else if (try parseComment(parser, alloc)) |comment| {
        return Content{ .comment = comment };
    } else if (try parseElement(parser, alloc, .element)) |elem| {
        return Content{ .element = elem };
    } else {
        return error.UnexpectedCharacter;
    }
}

fn parseAttr(parser: *Parser, alloc: Allocator) !?Attribute {
    const name = parseNameNoDupe(parser) catch return null;
    _ = parser.eatWs();
    try parser.expect('=');
    _ = parser.eatWs();
    const value = try parseAttrValue(parser, alloc);

    const attr = Attribute{
        .name = try alloc.dupe(u8, name),
        .value = value,
    };
    return attr;
}

const ElementKind = enum {
    xml_decl,
    element,
};

fn parseElement(parser: *Parser, alloc: Allocator, comptime kind: ElementKind) !?*Element {
    const start = parser.offset;

    const tag = switch (kind) {
        .xml_decl => blk: {
            if (!parser.eatStr("<?") or !std.mem.eql(u8, try parseNameNoDupe(parser), "xml")) {
                parser.offset = start;
                return null;
            }
            break :blk "xml";
        },
        .element => blk: {
            if (!parser.eat('<')) return null;
            const tag = parseNameNoDupe(parser) catch {
                parser.offset = start;
                return null;
            };
            break :blk tag;
        },
    };
    var attributes = std.ArrayList(Attribute).init(alloc);
    defer attributes.deinit();

    var children = std.ArrayList(Content).init(alloc);
    defer children.deinit();

    while (parser.eatWs()) {
        const attr = (try parseAttr(parser, alloc)) orelse break;
        try attributes.append(attr);
    }
    switch (kind) {
        .xml_decl => try parser.expectStr("?>"),
        .element => {
            if (!parser.eatStr("/>")) {
                try parser.expect('>');

                while (true) {
                    if (parser.peek() == null) {
                        return error.UnexpectedEof;
                    } else if (parser.eatStr("</")) {
                        break;
                    }
                    const content = try parseContent(parser, alloc);
                    try children.append(content);
                }
                const closing_tag = try parseNameNoDupe(parser);
                if (!std.mem.eql(u8, tag, closing_tag)) {
                    return error.NonMatchingClosingTag;
                }
                _ = parser.eatWs();
                try parser.expect('>');
            }
        },
    }
    const element = try alloc.create(Element);
    element.* = .{
        .tag = try alloc.dupe(u8, tag),
        .attributes = try attributes.toOwnedSlice(),
        .children = try children.toOwnedSlice(),
    };
    return element;
}

fn skipComments(parser: *Parser, alloc: Allocator) !void {
    while ((try parseComment(parser, alloc)) != null) {
        _ = parser.eatWs();
    }
}

fn parseComment(parser: *Parser, alloc: Allocator) !?[]const u8 {
    if (!parser.eatStr("<!--")) return null;

    const begin = parser.offset;
    while (!parser.eatStr("-->")) {
        _ = parser.consume() catch return error.UnclosedComment;
    }
    const end = parser.offset - "-->".len;
    return try alloc.dupe(u8, parser.source[begin..end]);
}

fn unescapeEntity(text: []const u8) !u8 {
    const EntitySubstition = struct { text: []const u8, replacement: u8 };

    const entities = [_]EntitySubstition{
        .{ .text = "&lt;", .replacement = '<' },
        .{ .text = "&gt;", .replacement = '>' },
        .{ .text = "&amp;", .replacement = '&' },
        .{ .text = "&apos;", .replacement = '\'' },
        .{ .text = "&quot;", .replacement = '"' },
    };
    for (entities) |entity| {
        if (std.mem.eql(u8, text, entity.text)) return entity.replacement;
    }
    return error.InvalidEntity;
}

fn unescape(arena: Allocator, text: []const u8) ![]const u8 {
    const unescaped = try arena.alloc(u8, text.len);

    var j: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (j += 1) {
        if (text[i] == '&') {
            const entity_end = 1 + (std.mem.indexOfScalarPos(u8, text, i, ';') orelse return error.InvalidEntity);
            unescaped[j] = try unescapeEntity(text[i..entity_end]);
            i = entity_end;
        } else {
            unescaped[j] = text[i];
            i += 1;
        }
    }
    return unescaped[0..j];
}
