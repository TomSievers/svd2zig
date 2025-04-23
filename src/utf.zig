const std = @import("std");

pub const UtfError = error{
    InvalidEncoding,
    ReadError,
};

pub const WChar = u21;

pub fn printWStringLine(wstr: []WChar) void {
    const stdout = std.io.getStdOut().writer();
    printWString(wstr);
    stdout.print("\n", .{}) catch {};
}

pub fn printWString(wstr: []WChar) void {
    const stdout = std.io.getStdOut().writer();
    for (wstr) |wchar| {
        if (wchar == 0) break;
        const char: u8 = @truncate(wchar);
        stdout.print("{c}", .{char}) catch {};
    }
}

pub fn strlen(wstr: []WChar) usize {
    return for (wstr, 0..) |wchar, i| {
        if (wchar == 0) break i;
    } else wstr.len;
}

pub fn eql(a: []WChar, b: []WChar) bool {
    const len = strlen(a);
    if (len != strlen(b)) return false;
    for (0..len) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

pub const UtfReader = struct {
    pub const Type = enum {
        UTF8,
        UTF16BE,
        UTF16LE,
        NONE,
    };
    const Self = @This();
    reader: std.io.AnyReader,
    utf_type: Type,
    unread_char: ?WChar,

    pub fn init(reader: std.io.AnyReader) UtfReader {
        return UtfReader{
            .reader = reader,
            .utf_type = Type.NONE,
            .unread_char = null,
        };
    }

    fn utf8DetermineLen(byte: u8) anyerror!usize {
        var byte_cp = byte;
        switch (byte) {
            0xC2...0xF4 => {
                // Valid UTF-8 byte
                for (0..4) |i| {
                    byte_cp = byte_cp << 1;
                    if ((byte_cp & 0x80) == 0) {
                        return i + 1;
                    }
                }

                return UtfError.InvalidEncoding;
            },
            0x80...0xBF => {
                // Continuation bytes are not allowed at the start
                return UtfError.InvalidEncoding;
            },
            else => {
                return 1;
            },
        }
    }

    fn utf8ReadChar(self: *Self, first_byte: u8) anyerror!WChar {
        // Read the UTF-8 character based on the first byte
        const len = try UtfReader.utf8DetermineLen(first_byte);
        var buf: [4]u8 = undefined;
        buf[0] = first_byte;

        if (len == 1) {
            // Single byte character
            return @as(WChar, first_byte);
        }

        const bytes_read = try self.reader.read(buf[1..len]);
        if (bytes_read != len - 1) {
            return UtfError.ReadError;
        }

        // Convert to WChar (u21)
        var char: WChar = 0;
        for (0..len) |i| {
            char = (char << 8) | @as(WChar, buf[i]);
        }

        return char;
    }

    pub fn read(self: *Self) anyerror!WChar {
        // Process the read bytes based on the UTF type
        switch (self.utf_type) {
            Type.UTF8 => {
                const first_byte = try self.reader.readByte();

                return self.utf8ReadChar(first_byte);
            },
            Type.UTF16BE => {
                // Handle UTF-16 Big Endian processing
            },
            Type.UTF16LE => {
                // Handle UTF-16 Little Endian processing
            },
            Type.NONE => {
                // We have no encoding, read the first byte to check for a BOM.
                const first_byte = try self.reader.readByte();

                switch (first_byte) {
                    0xEF => {
                        // UTF-8 BOM
                        var buf = [2]u8{ 0, 0 };
                        const bytes_read = try self.reader.read(&buf);
                        if (bytes_read != 2) {
                            return UtfError.InvalidEncoding;
                        }

                        if (buf[0] != 0xBB or buf[1] != 0xBF) {
                            return UtfError.InvalidEncoding;
                        }

                        self.utf_type = Type.UTF8;

                        return self.read();
                    },
                    0xFE | 0xFF => {
                        // UTF-16 BOM
                        const second_byte = try self.reader.readByte();
                        if (second_byte == 0xFF) {
                            self.utf_type = Type.UTF16BE;
                        } else if (second_byte == 0xFE) {
                            self.utf_type = Type.UTF16LE;
                        } else {
                            return UtfError.InvalidEncoding;
                        }

                        return self.read();
                    },
                    else => {
                        // No BOM, treat as UTF-8 by default
                        self.utf_type = Type.UTF8;

                        return self.utf8ReadChar(first_byte);
                    },
                }
            },
        }
        return error.ReadError;
    }

    pub fn unread(self: *Self, char: WChar) void {
        self.unread_char = char;
    }

    pub fn readUntil(self: *Self, buffer: []WChar, terminator: WChar) anyerror![]WChar {
        var index: usize = 0;

        if (self.unread_char) |unread_char| {
            buffer[index] = unread_char;
            index += 1;
            self.unread_char = null;
        }

        while (true) {
            const char = try self.read();
            buffer[index] = char;
            index += 1;
            if (char == terminator) {
                break;
            }
        }

        return buffer[0..index];
    }

    pub fn skipUntil(self: *Self, terminator: WChar) anyerror!void {
        while (true) {
            const char = try self.read();
            if (char == terminator) {
                break;
            }
        }
    }

    pub fn readUntilAlloc(self: *Self, allocator: std.mem.Allocator, terminator: WChar, max_size: usize) anyerror![]WChar {
        const buffer = try allocator.alloc(WChar, max_size);
        errdefer allocator.free(buffer);

        const result = try self.readUntil(buffer, terminator);
        return result;
    }
};
