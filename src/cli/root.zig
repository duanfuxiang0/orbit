const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent/root.zig");
const coding_tools = @import("coding_tools.zig");
const config_mod = @import("config.zig");
const context_files = @import("context_files.zig");
const headless = @import("headless.zig");
const interactive = @import("interactive.zig");
const session_mod = @import("session.zig");

pub const CliArgs = struct {
    continue_last: bool = false,
    session_id: ?[]const u8 = null,
    headless: bool = false,
    model: ?[]const u8 = null,
    verbose: bool = false,
    help: bool = false,

    fn deinit(self: *CliArgs, allocator: std.mem.Allocator) void {
        if (self.session_id) |value| allocator.free(value);
        if (self.model) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn run(allocator: std.mem.Allocator) !void {
    var args = try parseCliArgs(allocator);
    defer args.deinit(allocator);

    if (args.help) {
        try printHelp();
        return;
    }

    var config = try config_mod.load(allocator);
    defer config.deinit(allocator);

    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    var resolved_model = try resolveModel(allocator, config.default_model, args.model);
    defer resolved_model.deinit(allocator);

    const agents_md = try context_files.loadContextFiles(allocator, cwd);
    defer if (agents_md) |value| allocator.free(value);

    const system_prompt = try buildSystemPrompt(allocator, agents_md);
    defer allocator.free(system_prompt);

    var session = try loadOrCreateSession(allocator, &config, &args, resolved_model.model, cwd);
    defer session.deinit();

    var provider_binding = try ProviderBinding.init(allocator, &config, resolved_model.model, args.verbose);
    defer provider_binding.deinit();

    const tools = try coding_tools.register(allocator, cwd);
    defer coding_tools.unregister(allocator, tools);

    var agent = agent_mod.Agent.init(
        allocator,
        provider_binding.provider(),
        provider_binding.currentModel(),
        system_prompt,
        tools,
    );
    defer agent.deinit();

    agent.messages = session.messages;
    session.messages = .empty;

    if (args.headless) {
        try headless.run(allocator, &agent, &session);
    } else {
        try interactive.run(allocator, &agent, &session);
    }

    session.updated_at = std.time.timestamp();
    session.total_usage = agent.total_usage;
    session.messages = agent.messages;
    agent.messages = .empty;
    try session_mod.save(allocator, config.sessions_dir, &session);
}

fn parseCliArgs(allocator: std.mem.Allocator) !CliArgs {
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var args: CliArgs = .{};
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--continue")) {
            args.continue_last = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--headless")) {
            args.headless = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--verbose")) {
            args.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            args.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--session") and index + 1 < argv.len) {
            args.session_id = try allocator.dupe(u8, argv[index + 1]);
            index += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "--model") and index + 1 < argv.len) {
            args.model = try allocator.dupe(u8, argv[index + 1]);
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) return error.UnknownArgument;
    }
    return args;
}

fn loadOrCreateSession(
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    args: *const CliArgs,
    model: ai.Model,
    cwd: []const u8,
) !session_mod.Session {
    if (args.session_id) |id| {
        return session_mod.load(allocator, config.sessions_dir, id);
    }
    if (args.continue_last) {
        if (try session_mod.loadLatest(allocator, config.sessions_dir)) |session| return session;
    }
    return session_mod.Session.init(allocator, model, cwd);
}

fn buildSystemPrompt(
    allocator: std.mem.Allocator,
    agents_md: ?[]const u8,
) ![]const u8 {
    const base =
        \\You are an expert coding assistant. You help users with coding tasks
        \\by reading files, executing commands, editing code, and writing new files.
        \\
        \\Available tools:
        \\- read: Read file contents. Supports offset and limit for large files.
        \\- bash: Execute bash commands. Use for file listing, search, compilation, testing.
        \\- edit: Make precise text replacements in files. The old_text must match exactly.
        \\- write: Create or overwrite files. Automatically creates parent directories.
        \\
        \\Guidelines:
        \\- Use bash for exploration: ls, grep, find, cat for quick checks
        \\- Use read for examining files before editing
        \\- Use edit for surgical changes; prefer edit over write for existing files
        \\- Use write only for new files or complete rewrites
        \\- Be concise in your responses; show code, not lengthy explanations
        \\- Run tests after making changes when a test command is available
    ;

    if (agents_md) |content| {
        return std.fmt.allocPrint(allocator, "{s}\n\n---\n{s}", .{ base, content });
    }
    return allocator.dupe(u8, base);
}

const ResolvedModel = struct {
    model: ai.Model,
    owned_id: ?[]const u8 = null,
    owned_provider: ?[]const u8 = null,

    fn deinit(self: *ResolvedModel, allocator: std.mem.Allocator) void {
        if (self.owned_id) |value| allocator.free(value);
        if (self.owned_provider) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn resolveModel(
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

const ProviderBinding = union(enum) {
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

    fn init(
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

    fn deinit(self: *ProviderBinding) void {
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

    fn provider(self: *ProviderBinding) ai.Provider {
        return switch (self.*) {
            .anthropic => |*binding| binding.provider.asProvider(),
            .openai => |*binding| binding.provider.asProvider(),
            .zhipu => |*binding| binding.provider.asProvider(),
        };
    }

    fn currentModel(self: *ProviderBinding) ai.Model {
        return switch (self.*) {
            .anthropic => |binding| binding.model,
            .openai => |binding| binding.model,
            .zhipu => |binding| binding.model,
        };
    }
};

fn printHelp() !void {
    const text =
        \\orbit
        \\
        \\Usage:
        \\  orbit [--continue] [--session <id>] [--model <provider/id>] [--headless]
        \\
        \\Options:
        \\  --continue        Continue the most recent session
        \\  --session <id>    Resume a specific session
        \\  --model <id>      Override configured model
        \\  --headless        Emit JSON lines events to stdout
        \\  --verbose         Print verbose HTTP diagnostics
        \\  --help            Show this help
        \\
        \\Input:
        \\  Read one prompt per stdin line. Use /exit to stop.
    ;
    try std.fs.File.stdout().writeAll(text ++ "\n");
}

test "build system prompt appends agents md" {
    const allocator = std.testing.allocator;
    const prompt = try buildSystemPrompt(allocator, "Project rules");
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Project rules") != null);
}

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
