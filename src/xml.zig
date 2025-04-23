const utf = @import("utf.zig");
const std = @import("std");

const XmlError = error{
    MissingClosingTag,
    InvalidCharacter,
    InvalidAttribute,
    InvalidAttributeEquals,
    InvalidAttributeQuote,
    InvalidName,
    IncompleteTag,
    InvaildClosingTag,
    ReadError,
};

const XmlNodeType = enum {
    Element,
    ProcessingInstruction,
    Comment,
};

pub const XmlAttribute = struct {
    name: []utf.WChar,
    value: []utf.WChar,
    allocator: std.mem.Allocator,

    pub fn init(name: []utf.WChar, value: []utf.WChar, alloc: std.mem.Allocator) XmlAttribute {
        return XmlAttribute{
            .name = name,
            .value = value,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: XmlAttribute) void {
        self.allocator.free(self.name);
        self.allocator.free(self.value);
    }
};

pub const XmlNode = struct {
    const AttributesList = std.ArrayList(XmlAttribute);
    name: []utf.WChar,
    attributes: AttributesList,
    children: std.ArrayList(XmlNode),
    allocator: std.mem.Allocator,
    node_type: XmlNodeType,
    closed: bool,

    pub fn element(name: []utf.WChar, closed: bool, alloc: std.mem.Allocator) XmlNode {
        return XmlNode{
            .name = name,
            .attributes = AttributesList.init(alloc),
            .children = std.ArrayList(XmlNode).init(alloc),
            .allocator = alloc,
            .node_type = XmlNodeType.Element,
            .closed = closed,
        };
    }

    pub fn processing_instruction(name: []utf.WChar, alloc: std.mem.Allocator) XmlNode {
        return XmlNode{
            .name = name,
            .attributes = AttributesList.init(alloc),
            .children = std.ArrayList(XmlNode).init(alloc),
            .allocator = alloc,
            .node_type = XmlNodeType.ProcessingInstruction,
            .closed = true,
        };
    }

    pub fn comment(alloc: std.mem.Allocator) XmlNode {
        var name = alloc.alloc(utf.WChar, 1) catch unreachable;
        name[0] = 0; // Null-terminate the string

        return XmlNode{
            .name = name,
            .attributes = AttributesList.init(alloc),
            .children = std.ArrayList(XmlNode).init(alloc),
            .allocator = alloc,
            .node_type = XmlNodeType.Comment,
            .closed = true,
        };
    }

    pub fn debug(self: *const XmlNode) void {
        std.debug.print("Node Name: ", .{});
        utf.printWString(self.name);
        std.debug.print("\n", .{});
        std.debug.print("Node Type: {}\n", .{self.node_type});
        std.debug.print("Closed: {}\n", .{self.closed});

        for (self.attributes.items) |entry| {
            std.debug.print("Attribute: ", .{});
            utf.printWString(entry.name);
            std.debug.print(" = ", .{});
            utf.printWString(entry.value);
            std.debug.print("\n", .{});
        }
    }

    pub fn deinit(self: XmlNode) void {
        for (self.attributes.items) |attr| {
            attr.deinit();
        }

        self.attributes.deinit();
        self.allocator.free(self.name);

        for (self.children.items) |child| {
            child.deinit();
        }

        self.children.deinit();
    }
};

pub const Xml = struct {
    const Self = @This();
    reader: utf.UtfReader,
    alloc: std.mem.Allocator,

    pub fn init(reader: std.io.AnyReader, alloc: std.mem.Allocator) Xml {
        return Xml{
            .reader = utf.UtfReader.init(reader),
            .alloc = alloc,
        };
    }

    fn isNameStartChar(c: utf.WChar) bool {
        return c == ':' or c == '_' or (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= 0xC0 and c <= 0xD6) or (c >= 0xD8 and c <= 0xF6) or (c >= 0xF8 and c <= 0x2FF) or (c >= 0x370 and c <= 0x37D) or (c >= 0x37F and c <= 0x1FFF) or (c >= 0x200C and c <= 0x200D) or (c >= 0x2070 and c <= 0x218F) or (c >= 0x2C00 and c <= 0x2FEF) or (c >= 0x3001 and c <= 0xD7FF) or (c >= 0xF900 and c <= 0xFDCF) or (c >= 0xFDFD and c <= 0xFFFD) or (c >= 0x10000 and c <= 0xEFFFF);
    }

    fn isNameChar(c: utf.WChar) bool {
        return isNameStartChar(c) or c == '-' or c == '.' or (c >= '0' and c <= '9') or (c >= 0xB7 and c <= 0xB7) or (c >= 0x0300 and c <= 0x036F) or (c >= 0x203F and c <= 0x2040);
    }

    fn nameLength(name: []utf.WChar) !usize {
        return for (name, 0..) |c, i| {
            if (!isNameChar(c)) {
                break i;
            }
        } else return XmlError.InvalidName;
    }

    fn isValueChar(c: utf.WChar) bool {
        return c == 0x09 or c == 0x0a or c == 0x0d or (c >= 0x20 and c <= 0xD7FF) or (c >= 0xE000 and c <= 0xFFFD) or (c >= 0x10000 and c <= 0xEFFFF);
    }

    fn valueLength(value: []utf.WChar, quote: utf.WChar) !usize {
        var escaped = false;
        return for (value, 0..) |c, i| {
            if (!isValueChar(c) or (c == quote and !escaped)) {
                break i;
            }

            if (c == '\\') {
                escaped = true;
            } else if (escaped) {
                escaped = false;
            }
        } else {
            std.debug.print("Value length issue: ", .{});
            utf.printWStringLine(value);
            return XmlError.InvalidAttribute;
        };
    }

    fn isWhitespace(c: utf.WChar) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }

    fn whiteSpaceCount(element: []utf.WChar) usize {
        return for (element, 0..) |c, i| {
            if (!isWhitespace(c)) {
                break i;
            }
        } else 0;
    }

    fn parseAttribute(self: *Self, element: []utf.WChar) !?struct { XmlAttribute, []utf.WChar } {
        var result_element = element;

        // Expect at least one whitespace character before any attribute
        const whitespace_count = Self.whiteSpaceCount(result_element);

        if (whitespace_count == 0) {
            return null;
        }

        // Read the attribute name
        result_element = result_element[whitespace_count..];
        const name_length = try nameLength(result_element);

        if (name_length == 0) {
            return null;
        }

        const name = try self.alloc.alloc(utf.WChar, name_length + 1);
        std.mem.copyForwards(utf.WChar, name, result_element[0..name_length]);
        name[name_length] = 0; // Null-terminate the string
        errdefer self.alloc.free(name);

        utf.printWStringLine(name);

        result_element = result_element[name_length..];

        // Skip any leading whitespace before the '=' character
        var offset = whiteSpaceCount(result_element);
        if (result_element.len < offset + 1) {
            return XmlError.IncompleteTag;
        }
        result_element = result_element[offset..];

        // Read the '=' character
        if (result_element[0] != '=') {
            std.debug.print("Invalid attribute equals: ", .{});
            utf.printWStringLine(name);
            utf.printWStringLine(result_element);
            return XmlError.InvalidAttributeEquals;
        }

        offset = whiteSpaceCount(result_element[1..]);

        if (result_element.len < offset + 2) {
            return XmlError.IncompleteTag;
        }
        result_element = result_element[offset + 1 ..];

        // Read the opening quote
        if (result_element[0] != '"' and result_element[0] != '\'') {
            std.debug.print("Invalid attribute quote: ", .{});
            utf.printWStringLine(name);
            return XmlError.InvalidAttributeQuote;
        }

        const quote_type = result_element[0];

        // Read the attribute value
        result_element = result_element[1..];

        const value_length = try valueLength(result_element, quote_type);
        const value = try self.alloc.alloc(utf.WChar, value_length + 1);
        std.mem.copyForwards(utf.WChar, value, result_element[0..value_length]);
        value[value_length] = 0; // Null-terminate the string
        errdefer self.alloc.free(value);

        // Check the closing quote
        if (result_element[value_length] != quote_type) {
            std.debug.print("Invalid attribute quote: {}\n", .{result_element[value_length]});
            utf.printWStringLine(name);
            utf.printWStringLine(result_element);
            return XmlError.InvalidAttributeQuote;
        }

        result_element = result_element[value_length + 1 ..];

        return .{ XmlAttribute.init(name, value, self.alloc), result_element };
    }

    fn readCommentPartial(self: *Self) !bool {
        const comment = try self.reader.readUntilAlloc(self.alloc, '>', 1024);
        defer self.alloc.free(comment);

        // Check for the closing '-->'
        if (comment.len < 3) {
            return false;
        }

        if (comment[comment.len - 3] == '-' and comment[comment.len - 2] == '-') {
            // Valid comment
            return true;
        }

        return false;
    }

    fn parseNode(self: *Self) !?XmlNode {
        var node: ?XmlNode = null;

        // Skip until the start of some XML content
        try self.reader.skipUntil('<');

        const char = try self.reader.read();

        var temp = [_]utf.WChar{ char, 0 };

        utf.printWStringLine(&temp);

        if (isNameStartChar(char)) {
            // Element
            // Unread the first character which is part of the element name
            self.reader.unread(char);
            const element = try self.reader.readUntilAlloc(self.alloc, '>', 1024);
            defer self.alloc.free(element);

            // Check if this element is a self closing tag
            const self_closing = element[element.len - 1] == '/';

            // Get the length of the name of this tag
            const name_length = try nameLength(element);

            // Allocate memory for the name and copy it
            const name = try self.alloc.alloc(utf.WChar, name_length + 1);
            std.mem.copyForwards(utf.WChar, name, element[0..name_length]);
            name[name_length] = 0; // Null-terminate the string

            std.debug.print("Element: ", .{});
            utf.printWStringLine(name);

            // Create a new node with the name
            var new_node = XmlNode.element(name, self_closing, self.alloc);
            errdefer new_node.deinit();

            var attribute = element[name_length..];

            if (!self_closing) {
                // Parse the attributes
                while (try self.parseAttribute(attribute)) |attr| {
                    const new_attr, attribute = attr;
                    try new_node.attributes.append(new_attr);
                }
            }

            return new_node;
        } else if (char == '?') {
            // Processing instruction
            const instruction = try self.reader.readUntilAlloc(self.alloc, '>', 1024);
            defer self.alloc.free(instruction);

            const name_length = try nameLength(instruction);

            const name = try self.alloc.alloc(utf.WChar, name_length + 1);
            std.mem.copyForwards(utf.WChar, name, instruction[0..name_length]);
            name[name_length] = 0; // Null-terminate the string

            std.debug.print("Processing instruction: ", .{});
            utf.printWStringLine(name);

            var new_node = XmlNode.processing_instruction(name, self.alloc);
            errdefer new_node.deinit();

            var attribute = instruction[name_length..];

            while (try self.parseAttribute(attribute)) |attr| {
                const new_attr, attribute = attr;
                try new_node.attributes.append(new_attr);
            }

            return new_node;
        } else if (char == '!') {
            node = XmlNode.comment(self.alloc);
            if (try self.reader.read() == '-') {
                // Continue reading until we find the closing '-->'
                while (!try self.readCommentPartial()) {}
            } else {
                try self.reader.skipUntil('>');
            }

            return node;
        } else if (char == '/') {
            // Closing tag
            const closing_tag = try self.reader.readUntilAlloc(self.alloc, '>', 1024);
            defer self.alloc.free(closing_tag);

            // Check if this is a valid closing tag
            if (closing_tag.len < 2) {
                return XmlError.IncompleteTag;
            }
            const name_length = try nameLength(closing_tag);

            const name = closing_tag[0..name_length];

            std.debug.print("Closing tag: ", .{});
            utf.printWStringLine(name);

            return null;
        } else {
            return XmlError.InvalidCharacter;
        }

        return null;
    }

    pub fn parse(self: *Self) !?XmlNode {
        const node: ?XmlNode = undefined;

        while (try self.parseNode()) |new_node| {
            //new_node.debug();
            defer new_node.deinit();
        }

        return node;
    }
};
