const std = @import("std");

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn toSlice(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }

    pub fn fromSlice(raw: []const u8) ?Role {
        if (std.mem.eql(u8, raw, "system")) return .system;
        if (std.mem.eql(u8, raw, "user")) return .user;
        if (std.mem.eql(u8, raw, "assistant")) return .assistant;
        if (std.mem.eql(u8, raw, "tool")) return .tool;
        return null;
    }
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const ToolResult = struct {
    tool_call_id: []const u8,
    content: []const u8,
    is_error: bool = false,
};

pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

pub const Thinking = struct {
    text: []const u8,
    signature: ?[]const u8 = null,
};

pub const ContentPart = union(enum) {
    text: []const u8,
    thinking: Thinking,
    image_url: struct { url: []const u8 },
    image_base64: struct { data: []const u8, media_type: []const u8 },
    tool_call: ToolCall,
    tool_result: ToolResult,
};

pub const Message = struct {
    role: Role,
    content: []const ContentPart,
};

pub const TokenUsage = struct {
    input: u32 = 0,
    output: u32 = 0,
    cache_read: u32 = 0,
    cache_write: u32 = 0,
};

pub const TokenCost = struct {
    input_per_million: f64,
    output_per_million: f64,
    cache_read_per_million: f64 = 0,
    cache_write_per_million: f64 = 0,
};

pub fn estimateCostUsd(usage: TokenUsage, cost: TokenCost) f64 {
    const million = 1_000_000.0;
    const input_cost = (@as(f64, @floatFromInt(usage.input)) / million) * cost.input_per_million;
    const output_cost = (@as(f64, @floatFromInt(usage.output)) / million) * cost.output_per_million;
    const cache_read_cost = (@as(f64, @floatFromInt(usage.cache_read)) / million) *
        cost.cache_read_per_million;
    const cache_write_cost = (@as(f64, @floatFromInt(usage.cache_write)) / million) *
        cost.cache_write_per_million;
    return input_cost + output_cost + cache_read_cost + cache_write_cost;
}

test "role conversions are stable" {
    try std.testing.expectEqual(Role.system, Role.fromSlice("system").?);
    try std.testing.expectEqual(Role.user, Role.fromSlice("user").?);
    try std.testing.expectEqual(Role.assistant, Role.fromSlice("assistant").?);
    try std.testing.expectEqual(Role.tool, Role.fromSlice("tool").?);
    try std.testing.expect(Role.fromSlice("invalid") == null);
    try std.testing.expectEqualStrings("assistant", Role.assistant.toSlice());
}

test "estimate cost includes input output and cache read" {
    const usage: TokenUsage = .{
        .input = 1_000_000,
        .output = 2_000_000,
        .cache_read = 500_000,
        .cache_write = 250_000,
    };
    const cost: TokenCost = .{
        .input_per_million = 3.0,
        .output_per_million = 15.0,
        .cache_read_per_million = 0.3,
        .cache_write_per_million = 3.75,
    };

    const total = estimateCostUsd(usage, cost);
    try std.testing.expectApproxEqAbs(@as(f64, 34.0875), total, 0.0001);
}

test "content part supports tool payloads" {
    const part = ContentPart{
        .tool_call = .{
            .id = "call_1",
            .name = "read_file",
            .arguments = "{\"path\":\"/tmp/a.txt\"}",
        },
    };

    try std.testing.expectEqualStrings("call_1", part.tool_call.id);
    try std.testing.expectEqualStrings("read_file", part.tool_call.name);
}

test "thinking content stores text and optional signature" {
    const part = ContentPart{
        .thinking = .{
            .text = "reasoning",
            .signature = "sig_123",
        },
    };

    try std.testing.expectEqualStrings("reasoning", part.thinking.text);
    try std.testing.expectEqualStrings("sig_123", part.thinking.signature.?);
}
