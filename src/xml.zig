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
    content: ?[]utf.WChar,
    children: ?*XmlNode,
    next: ?*XmlNode,
    parent: ?*XmlNode,
    allocator: std.mem.Allocator,
    node_type: XmlNodeType,
    closed: bool,

    pub fn element(name: []utf.WChar, closed: bool, alloc: std.mem.Allocator) XmlNode {
        return XmlNode{
            .name = name,
            .attributes = AttributesList.init(alloc),
            .content = null,
            .children = null,
            .next = null,
            .parent = null,
            .allocator = alloc,
            .node_type = XmlNodeType.Element,
            .closed = closed,
        };
    }

    pub fn processing_instruction(name: []utf.WChar, alloc: std.mem.Allocator) XmlNode {
        return XmlNode{
            .name = name,
            .attributes = AttributesList.init(alloc),
            .content = null,
            .children = null,
            .next = null,
            .parent = null,
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
            .content = null,
            .children = null,
            .next = null,
            .parent = null,
            .allocator = alloc,
            .node_type = XmlNodeType.Comment,
            .closed = true,
        };
    }

    pub fn debug(self: *const XmlNode, depth: u8) void {
        const indent = self.allocator.alloc(u8, depth + 1) catch unreachable;
        for (0..depth) |i| {
            indent[i] = '\t';
        }
        indent[depth] = 0; // Null-terminate the string
        defer self.allocator.free(indent);
        std.debug.print("{s}", .{indent});
        utf.printWString(self.name);
        if (self.content) |content| {
            std.debug.print(" = ", .{});
            utf.printWString(content);
        }
        std.debug.print(" (", .{});

        for (self.attributes.items, 0..) |entry, i| {
            utf.printWString(entry.name);
            std.debug.print(" = ", .{});
            utf.printWString(entry.value);
            if (i < self.attributes.items.len - 1) {
                std.debug.print(", ", .{});
            }
        }

        std.debug.print(")\n", .{});

        var node = self.children;
        while (node) |child| {
            child.debug(depth + 1);
            node = child.next;
        }
    }

    pub fn add_child(self: *XmlNode, child: *XmlNode) void {
        // Add the child to the end of the list of children
        if (self.children) |c| {
            var node = c;
            // Traverse to the end of the list
            while (node.next) |n| {
                node = n;
            }
            node.next = child;
        } else {
            // If there are no children, set the first child
            self.children = child;
        }
    }

    pub fn deinit(self: *XmlNode) void {
        for (self.attributes.items) |attr| {
            attr.deinit();
        }

        self.attributes.deinit();
        self.allocator.free(self.name);

        if (self.content) |content| {
            self.allocator.free(content);
        }

        var node = self.children;

        while (node) |child| {
            child.deinit();
            node = child.next;
            self.allocator.destroy(child);
        }

        if (self.parent == null) {
            self.allocator.destroy(self);
        }
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
        } else element.len;
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

    fn parseNode(self: *Self, parent: ?*XmlNode) !?*XmlNode {

        // Skip until the start of some XML content

        if (parent) |p| {
            var content = try self.reader.readUntilAlloc(self.alloc, '<', 1024);
            content = content[0 .. content.len - 1]; // Remove the last character
            const whites = whiteSpaceCount(content);
            if (whites < content.len) {
                p.content = content;
            } else {
                self.alloc.free(content);
            }
        } else {
            try self.reader.skipUntil('<');
        }

        const char = try self.reader.read();

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
            errdefer self.alloc.free(name);

            std.mem.copyForwards(utf.WChar, name, element[0..name_length]);
            name[name_length] = 0; // Null-terminate the string

            var node = try self.alloc.create(XmlNode);
            errdefer {
                node.deinit();
            }
            node.* = XmlNode.element(name, self_closing, self.alloc);

            node.parent = parent;

            var attribute = element[name_length..];

            if (!self_closing) {
                // Parse the attributes
                while (try self.parseAttribute(attribute)) |attr| {
                    const new_attr, attribute = attr;
                    try node.attributes.append(new_attr);
                }
            }

            if (parent) |p| {
                p.add_child(node);
            }

            return node;
        } else if (char == '?') {
            // Processing instruction
            const instruction = try self.reader.readUntilAlloc(self.alloc, '>', 1024);
            defer self.alloc.free(instruction);

            const name_length = try nameLength(instruction);

            const name = try self.alloc.alloc(utf.WChar, name_length + 1);
            errdefer self.alloc.free(name);

            std.mem.copyForwards(utf.WChar, name, instruction[0..name_length]);
            name[name_length] = 0; // Null-terminate the string

            var node = try self.alloc.create(XmlNode);
            errdefer {
                node.deinit();
            }
            node.* = XmlNode.processing_instruction(name, self.alloc);

            var attribute = instruction[name_length..];

            while (try self.parseAttribute(attribute)) |attr| {
                const new_attr, attribute = attr;
                try node.attributes.append(new_attr);
            }

            return node;
        } else if (char == '!') {
            if (try self.reader.read() == '-') {
                // Continue reading until we find the closing '-->'
                while (!try self.readCommentPartial()) {}
            } else {
                try self.reader.skipUntil('>');
            }

            var node = try self.alloc.create(XmlNode);
            errdefer {
                node.deinit();
            }
            node.* = XmlNode.comment(self.alloc);

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

            if (parent) |p| {
                // Check if the closing tag matches the parent node
                if (utf.eql(name, p.name)) {
                    // Valid closing tag
                    p.closed = true;
                    return p;
                } else {
                    std.debug.print("Invalid closing tag: ", .{});
                    utf.printWStringLine(name);
                    utf.printWStringLine(p.name);
                    return XmlError.InvaildClosingTag;
                }
            } else {
                // No parent node, so this is an invalid closing tag
                std.debug.print("Invalid closing tag (no parent): ", .{});
                utf.printWStringLine(name);
                return XmlError.MissingClosingTag;
            }
        } else {
            return XmlError.InvalidCharacter;
        }

        return null;
    }

    pub fn parse(self: *Self) !?*XmlNode {
        var root: ?*XmlNode = null;
        var node: ?*XmlNode = null;

        while (try self.parseNode(node)) |new_node| {
            if (new_node.node_type == XmlNodeType.Element) {
                if (root == null) {
                    root = new_node;
                }

                if (new_node.closed) {
                    node = new_node.parent;
                } else {
                    node = new_node;
                }

                // We tried to move up but there is no parent, end of root node.
                if (node == null) {
                    break;
                }
            } else {
                new_node.deinit();
            }
        }

        return root;
    }
};
