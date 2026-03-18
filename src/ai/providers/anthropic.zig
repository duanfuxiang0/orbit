const std = @import("std");
const context_mod = @import("../context.zig");
const http = @import("../http.zig");
const json_util = @import("../json_util.zig");
const provider_mod = @import("../provider.zig");
const stream_mod = @import("../stream.zig");
const types = @import("../types.zig");

pub const Header = provider_mod.Header;
pub const Transport = provider_mod.Transport;

pub const AnthropicProvider = struct {
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
    ) !AnthropicProvider {
        std.debug.assert(api_key.len > 0);

        return .{
            .allocator = allocator,
            .api_key = try allocator.dupe(u8, api_key),
            .base_url = try allocator.dupe(u8, base_url orelse "https://api.anthropic.com/v1/messages"),
            .transport = transport,
        };
    }

    pub fn asProvider(self: *AnthropicProvider) provider_mod.Provider {
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
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        std.debug.assert(request.model.len > 0);
        self.abort_state.reset();

        // Keep event payload slices valid until stream() returns.
        // This intentionally trades per-stream arena growth for a simple sink contract.
        var event_arena = std.heap.ArenaAllocator.init(allocator);
        defer event_arena.deinit();

        const body = try buildRequestBody(allocator, request);
        defer allocator.free(body);

        const headers = [_]Header{
            .{ .name = "x-api-key", .value = self.api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
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

        var tool_slots: std.ArrayListUnmanaged(ToolSlot) = .empty;
        defer deinitToolSlots(&tool_slots, allocator);

        var usage: types.TokenUsage = .{};
        var stop_reason: stream_mod.StopReason = .end_turn;
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
                sse,
                &usage,
                &stop_reason,
                &tool_slots,
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
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        self.abort_state.abort();
    }

    fn nameImpl(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "anthropic";
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    pub fn deinit(self: *AnthropicProvider) void {
        self.allocator.free(self.api_key);
        self.allocator.free(self.base_url);
        self.* = undefined;
    }
};

const vtable: provider_mod.Provider.VTable = .{
    .stream = AnthropicProvider.streamImpl,
    .abort = AnthropicProvider.abortImpl,
    .name = AnthropicProvider.nameImpl,
    .deinit = AnthropicProvider.deinitImpl,
};

const ToolSlot = struct {
    index: u32,
    id: []u8,
    name: []u8,
    args: std.ArrayListUnmanaged(u8) = .empty,
    emitted_done: bool = false,
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
    id: []const u8,
    name: []const u8,
) !*ToolSlot {
    if (findToolSlot(slots.items, index)) |slot| return slot;

    try slots.append(allocator, .{
        .index = index,
        .id = try allocator.dupe(u8, id),
        .name = try allocator.dupe(u8, name),
    });
    return &slots.items[slots.items.len - 1];
}

fn handleSseEvent(
    allocator: std.mem.Allocator,
    event_allocator: std.mem.Allocator,
    sse: http.SseEvent,
    usage: *types.TokenUsage,
    stop_reason: *stream_mod.StopReason,
    tool_slots: *std.ArrayListUnmanaged(ToolSlot),
    sink: *stream_mod.EventSink,
) !bool {
    if (std.mem.eql(u8, sse.data, "[DONE]")) return true;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, sse.data, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (std.mem.eql(u8, sse.event_type, "message_start")) {
        parseMessageStartUsage(root, usage);
        return false;
    }

    if (std.mem.eql(u8, sse.event_type, "content_block_start")) {
        try onContentBlockStart(root, tool_slots, sink, allocator);
        return false;
    }

    if (std.mem.eql(u8, sse.event_type, "content_block_delta")) {
        try onContentBlockDelta(root, tool_slots, sink, allocator, event_allocator);
        return false;
    }

    if (std.mem.eql(u8, sse.event_type, "content_block_stop")) {
        onContentBlockStop(root, tool_slots, sink);
        return false;
    }

    if (std.mem.eql(u8, sse.event_type, "message_delta")) {
        parseMessageDelta(root, usage, stop_reason);
        return false;
    }

    return std.mem.eql(u8, sse.event_type, "message_stop");
}

fn parseMessageStartUsage(root: std.json.Value, usage: *types.TokenUsage) void {
    const message = json_util.getObjectField(root, "message") orelse return;
    const usage_obj = json_util.getObjectField(message, "usage") orelse return;

    if (json_util.getU32(usage_obj, "input_tokens")) |v| usage.input = v;
    if (json_util.getU32(usage_obj, "cache_creation_input_tokens")) |v| usage.cache_write = v;
    if (json_util.getU32(usage_obj, "cache_read_input_tokens")) |v| usage.cache_read = v;
}

fn parseMessageDelta(
    root: std.json.Value,
    usage: *types.TokenUsage,
    stop_reason: *stream_mod.StopReason,
) void {
    const delta = json_util.getObjectField(root, "delta") orelse return;
    if (json_util.getString(delta, "stop_reason")) |raw| {
        stop_reason.* = mapStopReason(raw);
    }

    const usage_obj = json_util.getObjectField(root, "usage") orelse return;
    if (json_util.getU32(usage_obj, "output_tokens")) |v| usage.output = v;
}

fn onContentBlockStart(
    root: std.json.Value,
    tool_slots: *std.ArrayListUnmanaged(ToolSlot),
    sink: *stream_mod.EventSink,
    allocator: std.mem.Allocator,
) !void {
    const index = json_util.getU32(root, "index") orelse return;
    const block = json_util.getObjectField(root, "content_block") orelse return;
    const block_type = json_util.getString(block, "type") orelse return;
    if (!std.mem.eql(u8, block_type, "tool_use")) return;

    const id = json_util.getString(block, "id") orelse return;
    const name = json_util.getString(block, "name") orelse return;
    const slot = try ensureToolSlot(tool_slots, allocator, index, id, name);

    sink.send(.{
        .tool_call_start = .{
            .id = slot.id,
            .name = slot.name,
        },
    });
}

fn onContentBlockDelta(
    root: std.json.Value,
    tool_slots: *std.ArrayListUnmanaged(ToolSlot),
    sink: *stream_mod.EventSink,
    allocator: std.mem.Allocator,
    event_allocator: std.mem.Allocator,
) !void {
    const index = json_util.getU32(root, "index") orelse return;
    const delta = json_util.getObjectField(root, "delta") orelse return;
    const delta_type = json_util.getString(delta, "type") orelse return;

    if (std.mem.eql(u8, delta_type, "text_delta")) {
        const text = json_util.getString(delta, "text") orelse return;
        const owned = try event_allocator.dupe(u8, text);
        sink.send(.{ .text_delta = owned });
        return;
    }

    if (std.mem.eql(u8, delta_type, "thinking_delta")) {
        const thinking = json_util.getString(delta, "thinking") orelse return;
        const owned = try event_allocator.dupe(u8, thinking);
        sink.send(.{ .thinking_delta = owned });
        return;
    }

    if (std.mem.eql(u8, delta_type, "signature_delta")) {
        const signature = json_util.getString(delta, "signature") orelse return;
        const owned = try event_allocator.dupe(u8, signature);
        sink.send(.{ .thinking_signature_delta = owned });
        return;
    }

    if (!std.mem.eql(u8, delta_type, "input_json_delta")) return;
    const partial = json_util.getString(delta, "partial_json") orelse return;
    const slot = findToolSlot(tool_slots.items, index) orelse return;

    try slot.args.appendSlice(allocator, partial);
    const owned = try event_allocator.dupe(u8, partial);
    sink.send(.{
        .tool_call_delta = .{
            .id = slot.id,
            .args_delta = owned,
        },
    });
}

fn onContentBlockStop(
    root: std.json.Value,
    tool_slots: *std.ArrayListUnmanaged(ToolSlot),
    sink: *stream_mod.EventSink,
) void {
    const index = json_util.getU32(root, "index") orelse return;
    const slot = findToolSlot(tool_slots.items, index) orelse return;
    if (slot.emitted_done) return;
    slot.emitted_done = true;

    sink.send(.{
        .tool_call_done = .{
            .id = slot.id,
            .name = slot.name,
            .arguments = slot.args.items,
        },
    });
}

fn mapStopReason(raw: []const u8) stream_mod.StopReason {
    if (std.mem.eql(u8, raw, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, raw, "max_tokens")) return .max_tokens;
    return .end_turn;
}

pub fn buildRequestBody(allocator: std.mem.Allocator, request: provider_mod.Request) ![]u8 {
    std.debug.assert(request.model.len > 0);
    std.debug.assert(request.max_tokens == null or request.max_tokens.? > 0);

    const normalized = try context_mod.normalizeForProvider(
        request.messages,
        .anthropic_messages,
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
    try json_util.appendJsonU32(&buf, allocator, "max_tokens", request.max_tokens orelse 4096);
    try buf.append(allocator, ',');
    try json_util.appendJsonF64(&buf, allocator, "temperature", request.temperature);

    if (request.system) |system| {
        std.debug.assert(system.len > 0);
        try buf.append(allocator, ',');
        try json_util.appendJsonKeyValue(&buf, allocator, "system", system);
    }

    try buf.append(allocator, ',');
    try json_util.appendJsonKey(&buf, allocator, "messages");
    try appendMessages(&buf, allocator, normalized);

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
) !void {
    try buf.append(allocator, '[');
    for (messages, 0..) |message, i| {
        if (i > 0) try buf.append(allocator, ',');
        try appendMessage(buf, allocator, message);
    }
    try buf.append(allocator, ']');
}

fn appendMessage(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    message: types.Message,
) !void {
    try buf.append(allocator, '{');
    try json_util.appendJsonKeyValue(buf, allocator, "role", message.role.toSlice());
    try buf.append(allocator, ',');
    try json_util.appendJsonKey(buf, allocator, "content");
    try appendContentParts(buf, allocator, message.content);
    try buf.append(allocator, '}');
}

fn appendContentParts(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    parts: []const types.ContentPart,
) !void {
    try buf.append(allocator, '[');
    for (parts, 0..) |part, i| {
        if (i > 0) try buf.append(allocator, ',');
        try appendContentPart(buf, allocator, part);
    }
    try buf.append(allocator, ']');
}

fn appendContentPart(
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
            try json_util.appendJsonKeyValue(buf, allocator, "type", "thinking");
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(buf, allocator, "thinking", thinking.text);
            if (thinking.signature) |signature| {
                try buf.append(allocator, ',');
                try json_util.appendJsonKeyValue(buf, allocator, "signature", signature);
            }
            try buf.append(allocator, '}');
        },
        .image_url => |image| {
            try buf.appendSlice(allocator, "{\"type\":\"image\",\"source\":{");
            try json_util.appendJsonKeyValue(buf, allocator, "type", "url");
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(buf, allocator, "url", image.url);
            try buf.appendSlice(allocator, "}}");
        },
        .image_base64 => |image| {
            try buf.appendSlice(allocator, "{\"type\":\"image\",\"source\":{");
            try json_util.appendJsonKeyValue(buf, allocator, "type", "base64");
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(buf, allocator, "media_type", image.media_type);
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(buf, allocator, "data", image.data);
            try buf.appendSlice(allocator, "}}");
        },
        .tool_call => |tool_call| {
            try buf.append(allocator, '{');
            try json_util.appendJsonKeyValue(buf, allocator, "type", "tool_use");
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(buf, allocator, "id", tool_call.id);
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(buf, allocator, "name", tool_call.name);
            try buf.append(allocator, ',');
            try json_util.appendJsonKey(buf, allocator, "input");
            try json_util.appendRawJson(buf, allocator, tool_call.arguments);
            try buf.append(allocator, '}');
        },
        .tool_result => |tool_result| {
            try buf.append(allocator, '{');
            try json_util.appendJsonKeyValue(buf, allocator, "type", "tool_result");
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(buf, allocator, "tool_use_id", tool_result.tool_call_id);
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(buf, allocator, "content", tool_result.content);
            try buf.append(allocator, ',');
            try json_util.appendJsonBool(buf, allocator, "is_error", tool_result.is_error);
            try buf.append(allocator, '}');
        },
    }
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
        try json_util.appendJsonKeyValue(buf, allocator, "name", tool.name);
        try buf.append(allocator, ',');
        try json_util.appendJsonKeyValue(buf, allocator, "description", tool.description);
        try buf.append(allocator, ',');
        try json_util.appendJsonKey(buf, allocator, "input_schema");
        try json_util.appendRawJson(buf, allocator, tool.parameters_json);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
}

test "build anthropic request body keeps native thinking blocks" {
    const parts = [_]types.ContentPart{
        .{ .thinking = .{ .text = "trace", .signature = "sig_abc" } },
    };
    const messages = [_]types.Message{
        .{ .role = .assistant, .content = &parts },
    };
    const body = try buildRequestBody(std.testing.allocator, .{
        .messages = &messages,
        .model = "claude-sonnet-4-20250514",
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"thinking\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":\"trace\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"signature\":\"sig_abc\"") != null);
}

test "anthropic delta payload remains valid after parser teardown" {
    const payload =
        \\{"index":0,"delta":{"type":"text_delta","text":"hello"}}
    ;

    const SinkCtx = struct {
        text: ?[]const u8 = null,
    };
    const callbacks = struct {
        fn onEvent(ctx: *anyopaque, event: stream_mod.StreamEvent) void {
            const typed: *SinkCtx = @ptrCast(@alignCast(ctx));
            if (event == .text_delta) typed.text = event.text_delta;
        }
    };

    var ctx: SinkCtx = .{};
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

    var sse = http.SseEvent{
        .event_type = try std.testing.allocator.dupe(u8, "content_block_delta"),
        .data = try std.testing.allocator.dupe(u8, payload),
    };
    defer sse.deinit(std.testing.allocator);

    const should_stop = try handleSseEvent(
        std.testing.allocator,
        arena.allocator(),
        sse,
        &usage,
        &stop_reason,
        &slots,
        &sink,
    );

    try std.testing.expect(!should_stop);
    try std.testing.expect(ctx.text != null);
    try std.testing.expectEqualStrings("hello", ctx.text.?);
}

test "anthropic signature delta is surfaced to the sink" {
    const payload =
        \\{"index":0,"delta":{"type":"signature_delta","signature":"sig_chunk"}}
    ;

    const SinkCtx = struct {
        signature: ?[]const u8 = null,
    };
    const callbacks = struct {
        fn onEvent(ctx: *anyopaque, event: stream_mod.StreamEvent) void {
            const typed: *SinkCtx = @ptrCast(@alignCast(ctx));
            if (event == .thinking_signature_delta) typed.signature = event.thinking_signature_delta;
        }
    };

    var ctx: SinkCtx = .{};
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

    var sse = http.SseEvent{
        .event_type = try std.testing.allocator.dupe(u8, "content_block_delta"),
        .data = try std.testing.allocator.dupe(u8, payload),
    };
    defer sse.deinit(std.testing.allocator);

    const should_stop = try handleSseEvent(
        std.testing.allocator,
        arena.allocator(),
        sse,
        &usage,
        &stop_reason,
        &slots,
        &sink,
    );

    try std.testing.expect(!should_stop);
    try std.testing.expect(ctx.signature != null);
    try std.testing.expectEqualStrings("sig_chunk", ctx.signature.?);
}
