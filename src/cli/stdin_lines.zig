const std = @import("std");

pub fn takeLine(reader: anytype) !?[]const u8 {
    return try reader.takeDelimiter('\n');
}

test "takeLine returns null on empty input EOF" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("empty.txt", .{ .read = true });
    defer file.close();

    var buffer: [32]u8 = undefined;
    var reader = file.readerStreaming(&buffer);

    try std.testing.expectEqual(@as(?[]const u8, null), try takeLine(&reader.interface));
}

test "takeLine reads newline-terminated input and then returns null" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "one-line.txt", .data = "hello\n" });
    const file = try tmp.dir.openFile("one-line.txt", .{});
    defer file.close();

    var buffer: [32]u8 = undefined;
    var reader = file.readerStreaming(&buffer);

    const first = (try takeLine(&reader.interface)).?;
    try std.testing.expectEqualStrings("hello", first);
    try std.testing.expectEqual(@as(?[]const u8, null), try takeLine(&reader.interface));
}
