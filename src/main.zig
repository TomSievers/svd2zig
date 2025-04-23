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

    defer if (node) |n| n.deinit();

    if (node) |n| {
        n.debug(0);
    } else {
        std.debug.print("No node found\n", .{});
    }
}
