const std = @import("std");
const ai = @import("../ai/root.zig");
const json_util = @import("../ai/json_util.zig");

const max_session_bytes: usize = 50 * 1024 * 1024;

pub const SessionId = struct {
    buf: [20]u8,

    pub fn slice(self: *const SessionId) []const u8 {
        return self.buf[0..];
    }

    pub fn generate() SessionId {
        const now = std.time.timestamp();
        const seconds: u64 = if (now < 0) 0 else @intCast(now);
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
        const day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = day.calculateMonthDay();
        const daytime = epoch_seconds.getDaySeconds();
        const hours = daytime.getHoursIntoDay();
        const minutes = daytime.getMinutesIntoHour();
        const secs = daytime.getSecondsIntoMinute();

        var random: [2]u8 = undefined;
        std.crypto.random.bytes(&random);

        var id: SessionId = undefined;
        _ = std.fmt.bufPrint(
            &id.buf,
            "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}-{x:0>4}",
            .{
                day.year,
                month_day.month.numeric(),
                month_day.day_index + 1,
                hours,
                minutes,
                secs,
                std.mem.readInt(u16, &random, .big),
            },
        ) catch unreachable;
        return id;
    }
};

pub const SessionSummary = struct {
    id: SessionId,
    updated_at: i64,
    model_id: []const u8,
    message_count: u32,

    pub fn deinit(self: *SessionSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.model_id);
        self.* = undefined;
    }
};

pub const Session = struct {
    id: SessionId,
    created_at: i64,
    updated_at: i64,
    model_id: []const u8,
    provider: []const u8,
    cwd: []const u8,
    total_usage: ai.TokenUsage,
    messages: std.ArrayListUnmanaged(ai.Message),
    allocator: std.mem.Allocator,

    pub fn init(
        allocator: std.mem.Allocator,
        model: ai.Model,
        cwd: []const u8,
    ) !Session {
        std.debug.assert(model.id.len > 0);
        std.debug.assert(model.provider.len > 0);
        std.debug.assert(cwd.len > 0);

        const now = std.time.timestamp();
        const model_id = try allocator.dupe(u8, model.id);
        errdefer allocator.free(model_id);
        const provider = try allocator.dupe(u8, model.provider);
        errdefer allocator.free(provider);
        const cwd_owned = try allocator.dupe(u8, cwd);
        errdefer allocator.free(cwd_owned);

        return .{
            .id = SessionId.generate(),
            .created_at = now,
            .updated_at = now,
            .model_id = model_id,
            .provider = provider,
            .cwd = cwd_owned,
            .total_usage = .{},
            .messages = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Session) void {
        self.allocator.free(self.model_id);
        self.allocator.free(self.provider);
        self.allocator.free(self.cwd);
        for (self.messages.items) |message| {
            ai.context.freeMessage(self.allocator, message);
        }
        self.messages.deinit(self.allocator);
        self.* = undefined;
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    sessions_dir: []const u8,
    id: []const u8,
) !Session {
    const path = try sessionPath(allocator, sessions_dir, id);
    defer allocator.free(path);
    return loadFromPath(allocator, path);
}

pub fn loadLatest(
    allocator: std.mem.Allocator,
    sessions_dir: []const u8,
) !?Session {
    const summaries = try list(allocator, sessions_dir);
    defer freeSummaryList(allocator, summaries);
    if (summaries.len == 0) return null;
    return try load(allocator, sessions_dir, summaries[0].id.slice());
}

pub fn save(
    allocator: std.mem.Allocator,
    sessions_dir: []const u8,
    session: *const Session,
) !void {
    std.debug.assert(session.model_id.len > 0);
    try std.fs.cwd().makePath(sessions_dir);

    const path = try sessionPath(allocator, sessions_dir, session.id.slice());
    defer allocator.free(path);

    const serialized = try serializeSession(allocator, session);
    defer allocator.free(serialized);

    var write_buffer: [4096]u8 = undefined;
    var atomic_file = try std.fs.cwd().atomicFile(path, .{
        .make_path = true,
        .write_buffer = &write_buffer,
    });
    defer atomic_file.deinit();

    try atomic_file.file_writer.interface.writeAll(serialized);
    try atomic_file.finish();
}

pub fn list(
    allocator: std.mem.Allocator,
    sessions_dir: []const u8,
) ![]SessionSummary {
    var dir = std.fs.openDirAbsolute(sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(SessionSummary, 0),
        else => return err,
    };
    defer dir.close();

    var iter = dir.iterate();
    var summaries: std.ArrayList(SessionSummary) = .empty;
    defer summaries.deinit(allocator);

    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const sub_path = try std.fs.path.join(allocator, &.{ sessions_dir, entry.name });
        defer allocator.free(sub_path);

        const session = loadFromPath(allocator, sub_path) catch continue;
        defer {
            var mutable = session;
            mutable.deinit();
        }

        try summaries.append(allocator, .{
            .id = session.id,
            .updated_at = session.updated_at,
            .model_id = try allocator.dupe(u8, session.model_id),
            .message_count = @intCast(session.messages.items.len),
        });
    }

    std.mem.sort(SessionSummary, summaries.items, {}, compareSummaryDesc);
    return summaries.toOwnedSlice(allocator);
}

fn compareSummaryDesc(_: void, lhs: SessionSummary, rhs: SessionSummary) bool {
    return lhs.updated_at > rhs.updated_at;
}

pub fn freeSummaryList(allocator: std.mem.Allocator, summaries: []SessionSummary) void {
    for (summaries) |*summary| summary.deinit(allocator);
    allocator.free(summaries);
}

fn sessionPath(
    allocator: std.mem.Allocator,
    sessions_dir: []const u8,
    id: []const u8,
) ![]const u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{id});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ sessions_dir, filename });
}

fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Session {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.size > max_session_bytes) return error.SessionTooLarge;

    const raw = try file.readToEndAlloc(allocator, @intCast(stat.size));
    defer allocator.free(raw);
    return parseSession(allocator, raw);
}

fn serializeSession(allocator: std.mem.Allocator, session: *const Session) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '{');
    try json_util.appendJsonU32(&buf, allocator, "version", 1);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "id", session.id.slice());
    try buf.appendSlice(allocator, ",");
    try appendJsonI64(&buf, allocator, "created_at", session.created_at);
    try buf.appendSlice(allocator, ",");
    try appendJsonI64(&buf, allocator, "updated_at", session.updated_at);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "model_id", session.model_id);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "provider", session.provider);
    try buf.appendSlice(allocator, ",");
    try json_util.appendJsonKeyValue(&buf, allocator, "cwd", session.cwd);
    try buf.appendSlice(allocator, ",\"total_usage\":");
    try appendUsage(&buf, allocator, session.total_usage);
    try buf.appendSlice(allocator, ",\"messages\":[");
    for (session.messages.items, 0..) |message, index| {
        if (index > 0) try buf.append(allocator, ',');
        try appendMessage(&buf, allocator, message);
    }
    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

fn appendUsage(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    usage: ai.TokenUsage,
) !void {
    try buf.append(allocator, '{');
    try json_util.appendJsonU32(buf, allocator, "input_tokens", usage.input);
    try buf.append(allocator, ',');
    try json_util.appendJsonU32(buf, allocator, "output_tokens", usage.output);
    try buf.append(allocator, ',');
    try json_util.appendJsonU32(buf, allocator, "cache_read_tokens", usage.cache_read);
    try buf.append(allocator, ',');
    try json_util.appendJsonU32(buf, allocator, "cache_write_tokens", usage.cache_write);
    try buf.append(allocator, '}');
}

fn appendMessage(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    message: ai.Message,
) !void {
    try buf.appendSlice(allocator, "{\"role\":");
    try json_util.appendJsonString(buf, allocator, message.role.toSlice());
    try buf.appendSlice(allocator, ",\"content\":[");
    for (message.content, 0..) |part, index| {
        if (index > 0) try buf.append(allocator, ',');
        try appendPart(buf, allocator, part);
    }
    try buf.appendSlice(allocator, "]}");
}

fn appendPart(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    part: ai.ContentPart,
) !void {
    switch (part) {
        .text => |text| {
            try buf.appendSlice(allocator, "{\"type\":\"text\",\"text\":");
            try json_util.appendJsonString(buf, allocator, text);
            try buf.append(allocator, '}');
        },
        .thinking => |thinking| {
            try buf.appendSlice(allocator, "{\"type\":\"thinking\",\"text\":");
            try json_util.appendJsonString(buf, allocator, thinking.text);
            if (thinking.signature) |signature| {
                try buf.appendSlice(allocator, ",\"signature\":");
                try json_util.appendJsonString(buf, allocator, signature);
            }
            try buf.append(allocator, '}');
        },
        .image_url => |image| {
            try buf.appendSlice(allocator, "{\"type\":\"image_url\",\"url\":");
            try json_util.appendJsonString(buf, allocator, image.url);
            try buf.append(allocator, '}');
        },
        .image_base64 => |image| {
            try buf.appendSlice(allocator, "{\"type\":\"image_base64\",\"data\":");
            try json_util.appendJsonString(buf, allocator, image.data);
            try buf.appendSlice(allocator, ",\"media_type\":");
            try json_util.appendJsonString(buf, allocator, image.media_type);
            try buf.append(allocator, '}');
        },
        .tool_call => |call| {
            try buf.appendSlice(allocator, "{\"type\":\"tool_call\",\"id\":");
            try json_util.appendJsonString(buf, allocator, call.id);
            try buf.appendSlice(allocator, ",\"name\":");
            try json_util.appendJsonString(buf, allocator, call.name);
            try buf.appendSlice(allocator, ",\"input\":");
            try json_util.appendRawJson(buf, allocator, call.arguments);
            try buf.append(allocator, '}');
        },
        .tool_result => |result| {
            try buf.appendSlice(allocator, "{\"type\":\"tool_result\",\"tool_use_id\":");
            try json_util.appendJsonString(buf, allocator, result.tool_call_id);
            try buf.appendSlice(allocator, ",\"content\":");
            try json_util.appendJsonString(buf, allocator, result.content);
            try buf.appendSlice(allocator, ",\"is_error\":");
            try buf.appendSlice(allocator, if (result.is_error) "true" else "false");
            try buf.append(allocator, '}');
        },
    }
}

fn appendJsonI64(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    key: []const u8,
    value: i64,
) !void {
    try json_util.appendJsonKey(buf, allocator, key);
    var temp: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&temp, "{d}", .{value});
    try buf.appendSlice(allocator, text);
}

fn parseSession(allocator: std.mem.Allocator, raw: []const u8) !Session {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidSession;

    var session: Session = .{
        .id = undefined,
        .created_at = try getI64(root, "created_at"),
        .updated_at = try getI64(root, "updated_at"),
        .model_id = try dupField(allocator, root, "model_id"),
        .provider = try dupField(allocator, root, "provider"),
        .cwd = try dupField(allocator, root, "cwd"),
        .total_usage = parseUsage(root),
        .messages = .empty,
        .allocator = allocator,
    };
    errdefer session.deinit();

    const id_text = try dupField(allocator, root, "id");
    defer allocator.free(id_text);
    if (id_text.len != session.id.buf.len) return error.InvalidSession;
    @memcpy(session.id.buf[0..], id_text);

    const messages_value = root.object.get("messages") orelse return error.InvalidSession;
    if (messages_value != .array) return error.InvalidSession;

    for (messages_value.array.items) |value| {
        try session.messages.append(allocator, try parseMessage(allocator, value));
    }
    return session;
}

fn parseUsage(root: std.json.Value) ai.TokenUsage {
    const usage = root.object.get("total_usage") orelse return .{};
    if (usage != .object) return .{};
    return .{
        .input = getU32Default(usage, "input_tokens"),
        .output = getU32Default(usage, "output_tokens"),
        .cache_read = getU32Default(usage, "cache_read_tokens"),
        .cache_write = getU32Default(usage, "cache_write_tokens"),
    };
}

fn parseMessage(allocator: std.mem.Allocator, value: std.json.Value) !ai.Message {
    if (value != .object) return error.InvalidSession;
    const role_text = try dupField(allocator, value, "role");
    defer allocator.free(role_text);

    const role = ai.Role.fromSlice(role_text) orelse return error.InvalidSession;
    const parts_value = value.object.get("content") orelse return error.InvalidSession;
    if (parts_value != .array) return error.InvalidSession;

    var parts = try allocator.alloc(ai.ContentPart, parts_value.array.items.len);
    var initialized: usize = 0;
    errdefer {
        var index: usize = 0;
        while (index < initialized) : (index += 1) {
            ai.context.freePart(allocator, parts[index]);
        }
        allocator.free(parts);
    }

    for (parts_value.array.items, 0..) |part_value, index| {
        parts[index] = try parsePart(allocator, part_value);
        initialized += 1;
    }
    return .{ .role = role, .content = parts };
}

fn parsePart(allocator: std.mem.Allocator, value: std.json.Value) !ai.ContentPart {
    if (value != .object) return error.InvalidSession;
    const part_type = try dupField(allocator, value, "type");
    defer allocator.free(part_type);

    if (std.mem.eql(u8, part_type, "text")) {
        return .{ .text = try dupField(allocator, value, "text") };
    }
    if (std.mem.eql(u8, part_type, "thinking")) {
        return .{
            .thinking = .{
                .text = try dupField(allocator, value, "text"),
                .signature = try dupOptionalField(allocator, value, "signature"),
            },
        };
    }
    if (std.mem.eql(u8, part_type, "image_url")) {
        return .{ .image_url = .{ .url = try dupField(allocator, value, "url") } };
    }
    if (std.mem.eql(u8, part_type, "image_base64")) {
        return .{
            .image_base64 = .{
                .data = try dupField(allocator, value, "data"),
                .media_type = try dupField(allocator, value, "media_type"),
            },
        };
    }
    if (std.mem.eql(u8, part_type, "tool_call")) {
        const input = value.object.get("input") orelse return error.InvalidSession;
        return .{
            .tool_call = .{
                .id = try dupField(allocator, value, "id"),
                .name = try dupField(allocator, value, "name"),
                .arguments = try stringifyValue(allocator, input),
            },
        };
    }
    if (std.mem.eql(u8, part_type, "tool_result")) {
        return .{
            .tool_result = .{
                .tool_call_id = try dupField(allocator, value, "tool_use_id"),
                .content = try dupField(allocator, value, "content"),
                .is_error = getBoolDefault(value, "is_error"),
            },
        };
    }
    return error.InvalidSession;
}

fn stringifyValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return allocator.dupe(u8, out.written());
}

fn dupField(allocator: std.mem.Allocator, value: std.json.Value, key: []const u8) ![]const u8 {
    const field = value.object.get(key) orelse return error.InvalidSession;
    if (field != .string) return error.InvalidSession;
    const duped = try allocator.dupe(u8, field.string);
    return duped;
}

fn dupOptionalField(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key: []const u8,
) !?[]const u8 {
    const field = value.object.get(key) orelse return null;
    if (field != .string) return error.InvalidSession;
    const duped = try allocator.dupe(u8, field.string);
    return duped;
}

fn getI64(value: std.json.Value, key: []const u8) !i64 {
    const field = value.object.get(key) orelse return error.InvalidSession;
    if (field != .integer) return error.InvalidSession;
    return field.integer;
}

fn getU32Default(value: std.json.Value, key: []const u8) u32 {
    const field = value.object.get(key) orelse return 0;
    if (field != .integer) return 0;
    if (field.integer < 0) return 0;
    return @intCast(field.integer);
}

fn getBoolDefault(value: std.json.Value, key: []const u8) bool {
    const field = value.object.get(key) orelse return false;
    if (field != .bool) return false;
    return field.bool;
}

test "session id generate format is stable" {
    const id = SessionId.generate();
    try std.testing.expectEqual(@as(usize, 20), id.slice().len);
    try std.testing.expect(id.slice()[8] == '-');
    try std.testing.expect(id.slice()[15] == '-');
}

test "session serialize and parse round trip" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator, ai.models.registry.claude_sonnet, "/tmp/orbit");
    defer session.deinit();

    const parts = try allocator.alloc(ai.ContentPart, 2);
    parts[0] = .{ .text = try allocator.dupe(u8, "hello") };
    parts[1] = .{
        .tool_call = .{
            .id = try allocator.dupe(u8, "toolu_01"),
            .name = try allocator.dupe(u8, "read"),
            .arguments = try allocator.dupe(u8, "{\"path\":\"src/main.zig\"}"),
        },
    };
    try session.messages.append(allocator, .{ .role = .assistant, .content = parts });

    const raw = try serializeSession(allocator, &session);
    defer allocator.free(raw);

    var loaded = try parseSession(allocator, raw);
    defer loaded.deinit();

    try std.testing.expectEqualStrings(session.model_id, loaded.model_id);
    try std.testing.expectEqual(@as(usize, 1), loaded.messages.items.len);
    try std.testing.expectEqualStrings("hello", loaded.messages.items[0].content[0].text);
    try std.testing.expectEqualStrings(
        "{\"path\":\"src/main.zig\"}",
        loaded.messages.items[0].content[1].tool_call.arguments,
    );
}

test "session handles empty message list" {
    const allocator = std.testing.allocator;
    var session = try Session.init(allocator, ai.models.registry.gpt4o, "/tmp/orbit");
    defer session.deinit();

    const raw = try serializeSession(allocator, &session);
    defer allocator.free(raw);

    var loaded = try parseSession(allocator, raw);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 0), loaded.messages.items.len);
}

test "session save creates directory and load latest returns newest" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    const root = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(root);
    const sessions_dir = try std.fs.path.join(allocator, &.{ root, "sessions" });
    defer allocator.free(sessions_dir);

    var first = try Session.init(allocator, ai.models.registry.gpt4o, "/tmp/a");
    defer first.deinit();
    first.updated_at = 10;
    try save(allocator, sessions_dir, &first);

    var second = try Session.init(allocator, ai.models.registry.claude_sonnet, "/tmp/b");
    defer second.deinit();
    second.updated_at = 20;
    try save(allocator, sessions_dir, &second);

    var latest = (try loadLatest(allocator, sessions_dir)).?;
    defer latest.deinit();

    try std.testing.expectEqualStrings(second.id.slice(), latest.id.slice());
    try std.testing.expectEqualStrings(second.model_id, latest.model_id);
}
