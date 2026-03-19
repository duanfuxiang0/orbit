const std = @import("std");
const log = std.log.scoped(.ai_json);

pub const Error = error{
    InvalidJsonFragment,
    OutOfMemory,
};

pub fn appendJsonString(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    raw: []const u8,
) !void {
    try buf.append(allocator, '"');
    for (raw) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 0x20) {
                    var escaped: [6]u8 = undefined;
                    const slice = std.fmt.bufPrint(&escaped, "\\u{x:0>4}", .{ch}) catch unreachable;
                    try buf.appendSlice(allocator, slice);
                } else {
                    try buf.append(allocator, ch);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}

pub fn appendJsonKey(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
) !void {
    try appendJsonString(buf, allocator, key);
    try buf.append(allocator, ':');
}

pub fn appendJsonKeyValue(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
) !void {
    try appendJsonKey(buf, allocator, key);
    try appendJsonString(buf, allocator, value);
}

pub fn appendJsonBool(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    value: bool,
) !void {
    try appendJsonKey(buf, allocator, key);
    try buf.appendSlice(allocator, if (value) "true" else "false");
}

pub fn appendJsonU32(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    value: u32,
) !void {
    try appendJsonKey(buf, allocator, key);
    var local: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&local, "{d}", .{value}) catch unreachable;
    try buf.appendSlice(allocator, text);
}

pub fn appendJsonF64(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    value: f64,
) !void {
    try appendJsonKey(buf, allocator, key);
    var local: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&local, "{d}", .{value});
    try buf.appendSlice(allocator, text);
}

pub fn appendRawJson(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    raw_json: []const u8,
) Error!void {
    std.debug.assert(raw_json.len > 0);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch |err| {
        log.warn("invalid json fragment: {s}", .{@errorName(err)});
        return error.InvalidJsonFragment;
    };
    defer parsed.deinit();

    try buf.appendSlice(allocator, raw_json);
}

pub fn getObjectField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}

pub fn getString(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = getObjectField(value, key) orelse return null;
    if (field != .string) return null;
    return field.string;
}

pub fn getU32(value: std.json.Value, key: []const u8) ?u32 {
    const field = getObjectField(value, key) orelse return null;
    if (field != .integer) return null;
    if (field.integer < 0) return null;
    return @intCast(field.integer);
}

test "append json string escapes control chars" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendJsonString(&buf, std.testing.allocator, "a\tb\nc\r\"d\\e");
    try std.testing.expectEqualStrings("\"a\\tb\\nc\\r\\\"d\\\\e\"", buf.items);
}

test "append key value helpers produce valid fragments" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendJsonKeyValue(&buf, std.testing.allocator, "name", "Orbit");
    try buf.append(std.testing.allocator, ',');
    try appendJsonBool(&buf, std.testing.allocator, "enabled", true);
    try buf.append(std.testing.allocator, ',');
    try appendJsonU32(&buf, std.testing.allocator, "count", 42);

    try std.testing.expectEqualStrings(
        "\"name\":\"Orbit\",\"enabled\":true,\"count\":42",
        buf.items,
    );
}

test "append raw json validates payload" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try appendRawJson(&buf, std.testing.allocator, "{\"type\":\"object\"}");
    try std.testing.expectEqualStrings("{\"type\":\"object\"}", buf.items);
}

test "append raw json rejects invalid payload" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.InvalidJsonFragment,
        appendRawJson(&buf, std.testing.allocator, "{invalid"),
    );
}
