const std = @import("std");
const context_mod = @import("../context.zig");
const json_util = @import("../json_util.zig");
const provider_mod = @import("../provider.zig");
const stream_mod = @import("../stream.zig");
const types = @import("../types.zig");

pub const Header = provider_mod.Header;
pub const Transport = provider_mod.Transport;

pub const OpenAIProvider = struct {
    allocator: std.mem.Allocator,
    api_key: []u8,
    base_url: []u8,
    transport: Transport,
    abort_state: provider_mod.AbortState = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        base_url: ?[]const u8,
        transport: Transport,
    ) !OpenAIProvider {
        std.debug.assert(api_key.len > 0);

        return .{
            .allocator = allocator,
            .api_key = try allocator.dupe(u8, api_key),
            .base_url = try allocator.dupe(
                u8,
                base_url orelse "https://api.openai.com/v1/chat/completions",
            ),
            .transport = transport,
        };
    }

    pub fn asProvider(self: *OpenAIProvider) provider_mod.Provider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn streamImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: provider_mod.Request,
        sink: *stream_mod.EventSink,
    ) !void {
        const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
        std.debug.assert(request.model.len > 0);
        self.abort_state.reset();

        // Keep event payload slices valid until stream() returns.
        // This intentionally trades per-stream arena growth for a simple sink contract.
        var event_arena = std.heap.ArenaAllocator.init(allocator);
        defer event_arena.deinit();

        const body = try buildRequestBody(allocator, request);
        defer allocator.free(body);

        const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{self.api_key});
        defer allocator.free(auth);

        const headers = [_]Header{
            .{ .name = "authorization", .value = auth },
            .{ .name = "content-type", .value = "application/json" },
        };
        var stream = try self.transport.open_stream(
            self.transport.ctx,
            allocator,
            self.base_url,
            &headers,
            body,
        );
        defer stream.deinit(allocator);

        var usage: types.TokenUsage = .{};
        var stop_reason: stream_mod.StopReason = .end_turn;
        var slots: std.ArrayListUnmanaged(ToolSlot) = .empty;
        defer deinitToolSlots(&slots, allocator);

        var scratch: [4096]u8 = undefined;
        while (true) {
            if (self.abort_state.isAborted()) {
                stream.abort();
                sink.send(.{
                    .done = .{
                        .usage = usage,
                        .stop_reason = .aborted,
                    },
                });
                return;
            }

            var sse = (try stream.nextEvent(allocator, &scratch)) orelse break;
            defer sse.deinit(allocator);

            const should_stop = handleSseEvent(
                allocator,
                event_arena.allocator(),
                sse.data,
                &usage,
                &stop_reason,
                &slots,
                sink,
            ) catch |err| {
                sink.send(.{
                    .err = .{
                        .kind = .other,
                        .message = @errorName(err),
                    },
                });
                return;
            };
            if (should_stop) break;
        }

        sink.send(.{
            .done = .{
                .usage = usage,
                .stop_reason = stop_reason,
            },
        });
    }

    fn abortImpl(ptr: *anyopaque) void {
        const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
        self.abort_state.abort();
    }

    fn nameImpl(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "openai";
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *OpenAIProvider = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    pub fn deinit(self: *OpenAIProvider) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.base_url);
        self.* = undefined;
    }
};

const vtable: provider_mod.Provider.VTable = .{
    .stream = OpenAIProvider.streamImpl,
    .abort = OpenAIProvider.abortImpl,
    .name = OpenAIProvider.nameImpl,
    .deinit = OpenAIProvider.deinitImpl,
};

const ToolSlot = struct {
    index: u32,
    id: []u8,
    name: []u8,
    args: std.ArrayListUnmanaged(u8) = .empty,
    started: bool = false,
    done_emitted: bool = false,
};

fn deinitToolSlots(slots: *std.ArrayListUnmanaged(ToolSlot), allocator: std.mem.Allocator) void {
    for (slots.items) |*slot| {
        allocator.free(slot.id);
        allocator.free(slot.name);
        slot.args.deinit(allocator);
    }
    slots.deinit(allocator);
}

fn findToolSlot(slots: []ToolSlot, index: u32) ?*ToolSlot {
    for (slots) |*slot| {
        if (slot.index == index) return slot;
    }
    return null;
}

fn ensureToolSlot(
    slots: *std.ArrayListUnmanaged(ToolSlot),
    allocator: std.mem.Allocator,
    index: u32,
) !*ToolSlot {
    if (findToolSlot(slots.items, index)) |slot| return slot;

    const default_id = try std.fmt.allocPrint(allocator, "tool-{d}", .{index});
    errdefer allocator.free(default_id);
    const default_name = try allocator.dupe(u8, "tool");
    errdefer allocator.free(default_name);

    try slots.append(allocator, .{
        .index = index,
        .id = default_id,
        .name = default_name,
    });
    return &slots.items[slots.items.len - 1];
}

fn handleSseEvent(
    allocator: std.mem.Allocator,
    event_allocator: std.mem.Allocator,
    data: []const u8,
    usage: *types.TokenUsage,
    stop_reason: *stream_mod.StopReason,
    slots: *std.ArrayListUnmanaged(ToolSlot),
    sink: *stream_mod.EventSink,
) !bool {
    if (std.mem.eql(u8, data, "[DONE]")) {
        emitToolDoneForAll(slots.items, sink);
        return true;
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const root = parsed.value;

    parseUsage(root, usage);

    const choices = json_util.getObjectField(root, "choices") orelse return false;
    if (choices != .array) return false;
    if (choices.array.items.len == 0) return false;

    const choice = choices.array.items[0];
    if (json_util.getObjectField(choice, "delta")) |delta| {
        try parseDelta(delta, slots, sink, allocator, event_allocator);
    }

    if (json_util.getString(choice, "finish_reason")) |finish_reason| {
        stop_reason.* = mapFinishReason(finish_reason);
        if (stop_reason.* == .tool_use) emitToolDoneForAll(slots.items, sink);
        return true;
    }
    return false;
}

fn parseUsage(root: std.json.Value, usage: *types.TokenUsage) void {
    const usage_obj = json_util.getObjectField(root, "usage") orelse return;
    if (json_util.getU32(usage_obj, "prompt_tokens")) |v| usage.input = v;
    if (json_util.getU32(usage_obj, "completion_tokens")) |v| usage.output = v;
}

fn parseDelta(
    delta: std.json.Value,
    slots: *std.ArrayListUnmanaged(ToolSlot),
    sink: *stream_mod.EventSink,
    allocator: std.mem.Allocator,
    event_allocator: std.mem.Allocator,
) !void {
    if (json_util.getString(delta, "content")) |content| {
        if (content.len > 0) {
            const owned = try event_allocator.dupe(u8, content);
            sink.send(.{ .text_delta = owned });
        }
    }

    if (json_util.getString(delta, "reasoning")) |reasoning| {
        if (reasoning.len > 0) {
            const owned = try event_allocator.dupe(u8, reasoning);
            sink.send(.{ .thinking_delta = owned });
        }
    }

    const tool_calls = json_util.getObjectField(delta, "tool_calls") orelse return;
    if (tool_calls != .array) return;

    for (tool_calls.array.items) |tool_call| {
        const index = json_util.getU32(tool_call, "index") orelse 0;
        const slot = try ensureToolSlot(slots, allocator, index);

        if (json_util.getString(tool_call, "id")) |id| {
            allocator.free(slot.id);
            slot.id = try allocator.dupe(u8, id);
        }

        if (json_util.getObjectField(tool_call, "function")) |function_obj| {
            if (json_util.getString(function_obj, "name")) |name| {
                allocator.free(slot.name);
                slot.name = try allocator.dupe(u8, name);
            }

            if (!slot.started) {
                slot.started = true;
                sink.send(.{
                    .tool_call_start = .{
                        .id = slot.id,
                        .name = slot.name,
                    },
                });
            }

            if (json_util.getString(function_obj, "arguments")) |arguments| {
                if (arguments.len > 0) {
                    try slot.args.appendSlice(allocator, arguments);
                    const owned = try event_allocator.dupe(u8, arguments);
                    sink.send(.{
                        .tool_call_delta = .{
                            .id = slot.id,
                            .args_delta = owned,
                        },
                    });
                }
            }
        }
    }
}

fn emitToolDoneForAll(slots: []ToolSlot, sink: *stream_mod.EventSink) void {
    for (slots) |*slot| {
        if (!slot.started) continue;
        if (slot.done_emitted) continue;
        slot.done_emitted = true;
        sink.send(.{
            .tool_call_done = .{
                .id = slot.id,
                .name = slot.name,
                .arguments = slot.args.items,
            },
        });
    }
}

fn mapFinishReason(reason: []const u8) stream_mod.StopReason {
    if (std.mem.eql(u8, reason, "tool_calls")) return .tool_use;
    if (std.mem.eql(u8, reason, "length")) return .max_tokens;
    return .end_turn;
}

pub fn buildRequestBody(allocator: std.mem.Allocator, request: provider_mod.Request) ![]u8 {
    std.debug.assert(request.model.len > 0);

    const normalized = try context_mod.normalizeForProvider(
        request.messages,
        .openai_completions,
        allocator,
    );
    defer context_mod.freeMessages(allocator, normalized);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '{');
    try json_util.appendJsonKeyValue(&buf, allocator, "model", request.model);
    try buf.append(allocator, ',');
    try json_util.appendJsonBool(&buf, allocator, "stream", true);
    try buf.append(allocator, ',');
    try json_util.appendJsonF64(&buf, allocator, "temperature", request.temperature);
    try buf.append(allocator, ',');
    try json_util.appendJsonKey(&buf, allocator, "stream_options");
    try buf.appendSlice(allocator, "{\"include_usage\":true}");

    if (request.max_tokens) |max_tokens| {
        std.debug.assert(max_tokens > 0);
        try buf.append(allocator, ',');
        try json_util.appendJsonU32(&buf, allocator, "max_tokens", max_tokens);
    }

    try buf.append(allocator, ',');
    try json_util.appendJsonKey(&buf, allocator, "messages");
    try appendMessages(&buf, allocator, normalized, request.system);

    if (request.tools) |tools| {
        try buf.append(allocator, ',');
        try json_util.appendJsonKey(&buf, allocator, "tools");
        try appendTools(&buf, allocator, tools);
    }

    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

fn appendMessages(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    messages: []const types.Message,
    system: ?[]const u8,
) !void {
    try buf.append(allocator, '[');

    var wrote_message = false;
    if (system) |system_text| {
        std.debug.assert(system_text.len > 0);
        try appendSystemMessage(buf, allocator, system_text);
        wrote_message = true;
    }

    for (messages) |message| {
        if (wrote_message) try buf.append(allocator, ',');
        try appendMessage(buf, allocator, message);
        wrote_message = true;
    }

    try buf.append(allocator, ']');
}

fn appendSystemMessage(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    system: []const u8,
) !void {
    try buf.append(allocator, '{');
    try json_util.appendJsonKeyValue(buf, allocator, "role", "system");
    try buf.append(allocator, ',');
    try json_util.appendJsonKeyValue(buf, allocator, "content", system);
    try buf.append(allocator, '}');
}

fn appendMessage(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    message: types.Message,
) !void {
    if (message.role == .tool) {
        try appendToolMessage(buf, allocator, message);
        return;
    }

    try buf.append(allocator, '{');
    try json_util.appendJsonKeyValue(buf, allocator, "role", message.role.toSlice());
    try buf.append(allocator, ',');
    try json_util.appendJsonKey(buf, allocator, "content");

    if (messageHasImages(message.content)) {
        try appendVisualContent(buf, allocator, message.content);
    } else {
        try appendTextContent(buf, allocator, message.content);
    }

    var first_tool_call = true;
    for (message.content) |part| {
        if (part != .tool_call) continue;
        if (first_tool_call) {
            first_tool_call = false;
            try buf.append(allocator, ',');
            try json_util.appendJsonKey(buf, allocator, "tool_calls");
            try buf.append(allocator, '[');
        } else {
            try buf.append(allocator, ',');
        }
        try appendToolCall(buf, allocator, part.tool_call);
    }
    if (!first_tool_call) try buf.append(allocator, ']');

    try buf.append(allocator, '}');
}

fn appendToolMessage(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    message: types.Message,
) !void {
    var content = std.ArrayListUnmanaged(u8).empty;
    defer content.deinit(allocator);

    var tool_call_id: ?[]const u8 = null;
    for (message.content) |part| {
        switch (part) {
            .tool_result => |tool_result| {
                if (tool_call_id == null) tool_call_id = tool_result.tool_call_id;
                try content.appendSlice(allocator, tool_result.content);
            },
            .text => |text| try content.appendSlice(allocator, text),
            else => {},
        }
    }

    std.debug.assert(tool_call_id != null);

    try buf.append(allocator, '{');
    try json_util.appendJsonKeyValue(buf, allocator, "role", "tool");
    try buf.append(allocator, ',');
    try json_util.appendJsonKeyValue(buf, allocator, "tool_call_id", tool_call_id.?);
    try buf.append(allocator, ',');
    try json_util.appendJsonKeyValue(buf, allocator, "content", content.items);
    try buf.append(allocator, '}');
}

fn messageHasImages(parts: []const types.ContentPart) bool {
    for (parts) |part| {
        switch (part) {
            .image_url, .image_base64 => return true,
            else => {},
        }
    }
    return false;
}

fn appendTextContent(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    parts: []const types.ContentPart,
) !void {
    var text = std.ArrayListUnmanaged(u8).empty;
    defer text.deinit(allocator);

    for (parts) |part| {
        switch (part) {
            .text => |segment| try text.appendSlice(allocator, segment),
            .thinking => |thinking| try text.appendSlice(allocator, thinking.text),
            else => {},
        }
    }

    try json_util.appendJsonString(buf, allocator, text.items);
}

fn appendVisualContent(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    parts: []const types.ContentPart,
) !void {
    try buf.append(allocator, '[');

    var first = true;
    for (parts) |part| {
        switch (part) {
            .text, .thinking, .image_url, .image_base64 => {
                if (!first) try buf.append(allocator, ',');
                try appendVisualPart(buf, allocator, part);
                first = false;
            },
            else => {},
        }
    }

    try buf.append(allocator, ']');
}

fn appendVisualPart(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    part: types.ContentPart,
) !void {
    switch (part) {
        .text => |text| {
            try buf.append(allocator, '{');
            try json_util.appendJsonKeyValue(buf, allocator, "type", "text");
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(buf, allocator, "text", text);
            try buf.append(allocator, '}');
        },
        .thinking => |thinking| {
            try buf.append(allocator, '{');
            try json_util.appendJsonKeyValue(buf, allocator, "type", "text");
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(buf, allocator, "text", thinking.text);
            try buf.append(allocator, '}');
        },
        .image_url => |image| {
            try buf.append(allocator, '{');
            try json_util.appendJsonKeyValue(buf, allocator, "type", "image_url");
            try buf.append(allocator, ',');
            try json_util.appendJsonKey(buf, allocator, "image_url");
            try buf.append(allocator, '{');
            try json_util.appendJsonKeyValue(buf, allocator, "url", image.url);
            try buf.appendSlice(allocator, "}}");
        },
        .image_base64 => |image| {
            const data_url = try std.fmt.allocPrint(
                allocator,
                "data:{s};base64,{s}",
                .{ image.media_type, image.data },
            );
            defer allocator.free(data_url);

            try buf.append(allocator, '{');
            try json_util.appendJsonKeyValue(buf, allocator, "type", "image_url");
            try buf.append(allocator, ',');
            try json_util.appendJsonKey(buf, allocator, "image_url");
            try buf.append(allocator, '{');
            try json_util.appendJsonKeyValue(buf, allocator, "url", data_url);
            try buf.appendSlice(allocator, "}}");
        },
        else => unreachable,
    }
}

fn appendToolCall(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    tool_call: types.ToolCall,
) !void {
    try buf.append(allocator, '{');
    try json_util.appendJsonKeyValue(buf, allocator, "id", tool_call.id);
    try buf.append(allocator, ',');
    try json_util.appendJsonKeyValue(buf, allocator, "type", "function");
    try buf.append(allocator, ',');
    try json_util.appendJsonKey(buf, allocator, "function");
    try buf.append(allocator, '{');
    try json_util.appendJsonKeyValue(buf, allocator, "name", tool_call.name);
    try buf.append(allocator, ',');
    try json_util.appendJsonKeyValue(buf, allocator, "arguments", tool_call.arguments);
    try buf.appendSlice(allocator, "}}");
}

fn appendTools(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    tools: []const types.ToolSpec,
) !void {
    try buf.append(allocator, '[');
    for (tools, 0..) |tool, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '{');
        try json_util.appendJsonKeyValue(buf, allocator, "type", "function");
        try buf.append(allocator, ',');
        try json_util.appendJsonKey(buf, allocator, "function");
        try buf.append(allocator, '{');
        try json_util.appendJsonKeyValue(buf, allocator, "name", tool.name);
        try buf.append(allocator, ',');
        try json_util.appendJsonKeyValue(buf, allocator, "description", tool.description);
        try buf.append(allocator, ',');
        try json_util.appendJsonKey(buf, allocator, "parameters");
        try json_util.appendRawJson(buf, allocator, tool.parameters_json);
        try buf.appendSlice(allocator, "}}");
    }
    try buf.append(allocator, ']');
}

test "build openai request body preserves system tool result and image content" {
    const user_parts = [_]types.ContentPart{
        .{ .text = "Hello" },
        .{ .image_url = .{ .url = "https://example.com/a.png" } },
    };
    const tool_parts = [_]types.ContentPart{
        .{
            .tool_result = .{
                .tool_call_id = "call_1",
                .content = "tool output",
            },
        },
    };
    const messages = [_]types.Message{
        .{ .role = .user, .content = &user_parts },
        .{ .role = .tool, .content = &tool_parts },
    };
    const tools = [_]types.ToolSpec{
        .{
            .name = "read_file",
            .description = "Read file",
            .parameters_json = "{\"type\":\"object\",\"properties\":{}}",
        },
    };

    const body = try buildRequestBody(std.testing.allocator, .{
        .messages = &messages,
        .system = "system prompt",
        .model = "gpt-4o",
        .tools = &tools,
        .temperature = 0.0,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"system prompt\"") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, body, "\"stream_options\":{\"include_usage\":true}") != null,
    );
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"tool output\"") != null);
    try std.testing.expect(
        std.mem.indexOf(u8, body, "\"image_url\":{\"url\":\"https://example.com/a.png\"}") != null,
    );
}

test "openai delta emits tool start before tool delta" {
    const payload =
        \\{
        \\  "choices": [{
        \\    "delta": {
        \\      "tool_calls": [{
        \\        "index": 0,
        \\        "id": "call_1",
        \\        "function": {
        \\          "name": "read_file",
        \\          "arguments": "{\"path\":\"a\"}"
        \\        }
        \\      }]
        \\    },
        \\    "finish_reason": null
        \\  }]
        \\}
    ;

    const SinkCtx = struct {
        events: [4]stream_mod.StreamEvent = undefined,
        len: usize = 0,
    };
    const callbacks = struct {
        fn onEvent(ctx: *anyopaque, event: stream_mod.StreamEvent) void {
            const typed: *SinkCtx = @ptrCast(@alignCast(ctx));
            typed.events[typed.len] = event;
            typed.len += 1;
        }
    };

    var ctx: SinkCtx = .{ .events = undefined, .len = 0 };
    var sink: stream_mod.EventSink = .{
        .ctx = &ctx,
        .emit = callbacks.onEvent,
    };
    var slots: std.ArrayListUnmanaged(ToolSlot) = .empty;
    defer deinitToolSlots(&slots, std.testing.allocator);
    var usage: types.TokenUsage = .{};
    var stop_reason: stream_mod.StopReason = .end_turn;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const should_stop = try handleSseEvent(
        std.testing.allocator,
        arena.allocator(),
        payload,
        &usage,
        &stop_reason,
        &slots,
        &sink,
    );

    try std.testing.expect(!should_stop);
    try std.testing.expectEqual(@as(usize, 2), ctx.len);
    try std.testing.expect(ctx.events[0] == .tool_call_start);
    try std.testing.expect(ctx.events[1] == .tool_call_delta);
}
