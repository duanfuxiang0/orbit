const std = @import("std");
const ai = @import("../ai/root.zig");
const config_mod = @import("config.zig");

pub const ResolvedModel = struct {
    model: ai.Model,
    owned_id: ?[]const u8 = null,
    owned_provider: ?[]const u8 = null,

    pub fn deinit(self: *ResolvedModel, allocator: std.mem.Allocator) void {
        if (self.owned_id) |value| allocator.free(value);
        if (self.owned_provider) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn resolveModel(
    allocator: std.mem.Allocator,
    default_model: []const u8,
    override: ?[]const u8,
) !ResolvedModel {
    const selected = override orelse default_model;
    std.debug.assert(selected.len > 0);

    if (ai.models.findById(selected)) |builtin_model| {
        return .{ .model = builtin_model.* };
    }

    const slash = std.mem.indexOfScalar(u8, selected, '/') orelse return error.UnknownModel;
    const provider = selected[0..slash];
    const model_id = selected[slash + 1 ..];
    if (provider.len == 0) return error.UnknownModel;
    if (model_id.len == 0) return error.UnknownModel;

    const protocol: ai.ApiProtocol = if (std.mem.eql(u8, provider, "anthropic"))
        .anthropic_messages
    else if (std.mem.eql(u8, provider, "openai"))
        .openai_completions
    else if (std.mem.eql(u8, provider, "zhipu"))
        .openai_completions
    else
        return error.UnknownProvider;

    if (ai.models.findById(model_id)) |builtin_model| {
        if (std.mem.eql(u8, builtin_model.provider, provider)) {
            return .{ .model = builtin_model.* };
        }
    }

    const owned_id = try allocator.dupe(u8, model_id);
    errdefer allocator.free(owned_id);
    const owned_provider = try allocator.dupe(u8, provider);
    return .{
        .model = .{
            .id = owned_id,
            .name = owned_id,
            .protocol = protocol,
            .provider = owned_provider,
            .base_url = null,
            .context_window = 128_000,
            .max_output = 8_192,
            .supports_vision = true,
            .supports_thinking = protocol == .anthropic_messages,
            .cost = .{
                .input_per_million = 0.0,
                .output_per_million = 0.0,
            },
        },
        .owned_id = owned_id,
        .owned_provider = owned_provider,
    };
}

pub const ProviderBinding = union(enum) {
    anthropic: struct {
        transport: *ai.http.StdHttpTransport,
        provider: ai.providers.anthropic.AnthropicProvider,
        model: ai.Model,
    },
    openai: struct {
        transport: *ai.http.StdHttpTransport,
        provider: ai.providers.openai.OpenAIProvider,
        model: ai.Model,
    },
    zhipu: struct {
        transport: *ai.http.StdHttpTransport,
        provider: ai.providers.zhipu.ZhipuProvider,
        model: ai.Model,
    },

    pub fn init(
        allocator: std.mem.Allocator,
        config: *const config_mod.Config,
        model: ai.Model,
        verbose: bool,
    ) !ProviderBinding {
        const transport = try allocator.create(ai.http.StdHttpTransport);
        errdefer allocator.destroy(transport);
        transport.* = .{ .verbose = verbose or config.verbose };

        if (std.mem.eql(u8, model.provider, "anthropic")) {
            const api_key = config.anthropic_api_key orelse return error.MissingAnthropicApiKey;
            const base_url = config.anthropic_base_url orelse model.base_url;
            return .{
                .anthropic = .{
                    .transport = transport,
                    .provider = try ai.providers.anthropic.AnthropicProvider.init(
                        allocator,
                        api_key,
                        base_url,
                        transport.asTransport(),
                    ),
                    .model = model,
                },
            };
        }
        if (std.mem.eql(u8, model.provider, "openai")) {
            const api_key = config.openai_api_key orelse return error.MissingOpenAIApiKey;
            return .{
                .openai = .{
                    .transport = transport,
                    .provider = try ai.providers.openai.OpenAIProvider.init(
                        allocator,
                        api_key,
                        model.base_url,
                        transport.asTransport(),
                    ),
                    .model = model,
                },
            };
        }
        if (std.mem.eql(u8, model.provider, "zhipu")) {
            const api_key = config.zhipu_api_key orelse return error.MissingZhipuApiKey;
            const base_url = config.zhipu_base_url orelse model.base_url;
            return .{
                .zhipu = .{
                    .transport = transport,
                    .provider = try ai.providers.zhipu.ZhipuProvider.init(
                        allocator,
                        api_key,
                        base_url,
                        transport.asTransport(),
                    ),
                    .model = model,
                },
            };
        }
        allocator.destroy(transport);
        return error.UnknownProvider;
    }

    pub fn deinit(self: *ProviderBinding) void {
        switch (self.*) {
            .anthropic => |*binding| {
                const allocator = binding.provider.allocator;
                binding.provider.deinit();
                allocator.destroy(binding.transport);
            },
            .openai => |*binding| {
                const allocator = binding.provider.allocator;
                binding.provider.deinit();
                allocator.destroy(binding.transport);
            },
            .zhipu => |*binding| {
                const allocator = binding.provider.allocator;
                binding.provider.deinit();
                allocator.destroy(binding.transport);
            },
        }
        self.* = undefined;
    }

    pub fn provider(self: *ProviderBinding) ai.Provider {
        return switch (self.*) {
            .anthropic => |*binding| binding.provider.asProvider(),
            .openai => |*binding| binding.provider.asProvider(),
            .zhipu => |*binding| binding.provider.asProvider(),
        };
    }

    pub fn currentModel(self: *ProviderBinding) ai.Model {
        return switch (self.*) {
            .anthropic => |binding| binding.model,
            .openai => |binding| binding.model,
            .zhipu => |binding| binding.model,
        };
    }
};

test "resolve model accepts qualified builtin anthropic id" {
    const allocator = std.testing.allocator;
    var resolved = try resolveModel(allocator, "anthropic/claude-sonnet-4-20250514", null);
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", resolved.model.id);
    try std.testing.expectEqualStrings("anthropic", resolved.model.provider);
    try std.testing.expect(resolved.owned_id == null);
    try std.testing.expect(resolved.owned_provider == null);
}

test "resolve model keeps dynamic qualified ids" {
    const allocator = std.testing.allocator;
    var resolved = try resolveModel(allocator, "anthropic/glm-5", null);
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("glm-5", resolved.model.id);
    try std.testing.expectEqualStrings("anthropic", resolved.model.provider);
    try std.testing.expect(resolved.owned_id != null);
    try std.testing.expect(resolved.owned_provider != null);
}

test "resolve model keeps dynamic qualified zhipu ids" {
    const allocator = std.testing.allocator;
    var resolved = try resolveModel(allocator, "zhipu/glm-4.5", null);
    defer resolved.deinit(allocator);

    try std.testing.expectEqualStrings("glm-4.5", resolved.model.id);
    try std.testing.expectEqualStrings("zhipu", resolved.model.provider);
    try std.testing.expectEqual(ai.ApiProtocol.openai_completions, resolved.model.protocol);
    try std.testing.expect(resolved.owned_id != null);
    try std.testing.expect(resolved.owned_provider != null);
}
