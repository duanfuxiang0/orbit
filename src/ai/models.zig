const std = @import("std");
const types = @import("types.zig");

pub const ApiProtocol = enum {
    anthropic_messages,
    openai_completions,
};

pub const Model = struct {
    id: []const u8,
    name: []const u8,
    protocol: ApiProtocol,
    provider: []const u8,
    base_url: ?[]const u8,
    context_window: u32,
    max_output: u32,
    supports_vision: bool,
    supports_thinking: bool,
    cost: types.TokenCost,
};

pub const registry = struct {
    pub const claude_sonnet = Model{
        .id = "claude-sonnet-4-20250514",
        .name = "Claude Sonnet 4",
        .protocol = .anthropic_messages,
        .provider = "anthropic",
        .base_url = null,
        .context_window = 200_000,
        .max_output = 8_192,
        .supports_vision = true,
        .supports_thinking = true,
        .cost = .{
            .input_per_million = 3.0,
            .output_per_million = 15.0,
            .cache_read_per_million = 0.3,
            .cache_write_per_million = 3.75,
        },
    };

    pub const gpt4o = Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .protocol = .openai_completions,
        .provider = "openai",
        .base_url = null,
        .context_window = 128_000,
        .max_output = 16_384,
        .supports_vision = true,
        .supports_thinking = false,
        .cost = .{
            .input_per_million = 2.5,
            .output_per_million = 10.0,
        },
    };
};

pub const builtin_models = [_]*const Model{
    &registry.claude_sonnet,
    &registry.gpt4o,
};

pub fn findById(id: []const u8) ?*const Model {
    for (builtin_models) |model| {
        if (std.mem.eql(u8, model.id, id)) return model;
    }
    return null;
}

pub fn findByName(name: []const u8) ?*const Model {
    for (builtin_models) |model| {
        if (std.mem.eql(u8, model.name, name)) return model;
    }
    return null;
}

test "registry lookups by id and name" {
    const by_id = findById("claude-sonnet-4-20250514").?;
    try std.testing.expectEqualStrings("Claude Sonnet 4", by_id.name);
    try std.testing.expectEqual(ApiProtocol.anthropic_messages, by_id.protocol);

    const by_name = findByName("GPT-4o").?;
    try std.testing.expectEqualStrings("gpt-4o", by_name.id);
    try std.testing.expectEqual(ApiProtocol.openai_completions, by_name.protocol);
}

test "unknown model returns null" {
    try std.testing.expect(findById("missing-model") == null);
    try std.testing.expect(findByName("missing-name") == null);
}
