//! By convention, main.zig is where your main function lives in the case that
//! you are building an executable. If you are making a library, the convention
//! is to delete this file and start with root.zig instead.

const std = @import("std");
const lib = @import("zig2svd_lib");
const utf = @import("utf.zig");
const xml = @import("xml.zig");

pub fn main() !void {
    const file_dir = std.fs.cwd();
    var file = file_dir.openFile("ARM_Sample.svd", std.fs.File.OpenFlags{}) catch |err| {
        std.debug.print("Error opening file: {}\n", .{err});
        return err;
    };
    defer file.close(); // Ensure the file is closed when done

    const reader = file.reader().any();

    const alloc = std.heap.page_allocator;

    var root = xml.Xml.init(reader, alloc);

    const node = root.parse() catch |err| {
        std.debug.print("Error parsing XML: {}\n", .{err});
        return err;
    };

    if (node) |n| {
        n.debug();
    } else {
        std.debug.print("No node found\n", .{});
    }
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "use other module" {
    try std.testing.expectEqual(@as(i32, 150), lib.add(100, 50));
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
