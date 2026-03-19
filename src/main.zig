const std = @import("std");
const cli = @import("cli/root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    try cli.run(gpa.allocator());
}
