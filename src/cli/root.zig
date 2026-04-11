const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent/root.zig");
const coding_tools = @import("coding_tools.zig");
const config_mod = @import("config.zig");
const context_files = @import("context_files.zig");
const prompt_mod = @import("prompt.zig");
const headless = @import("headless.zig");
const interactive = @import("interactive.zig");
const model_runtime = @import("model_runtime.zig");
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

    var resolved_model = try model_runtime.resolveModel(allocator, config.default_model, args.model);
    defer resolved_model.deinit(allocator);

    const ctx_files = try context_files.loadContextFiles(
        allocator,
        cwd,
    );
    defer context_files.freeContextFiles(allocator, ctx_files);

    var session = try loadOrCreateSession(
        allocator,
        &config,
        &args,
        resolved_model.model,
        cwd,
    );
    defer session.deinit();

    var provider_binding = try model_runtime.ProviderBinding.init(
        allocator,
        &config,
        resolved_model.model,
        args.verbose,
    );
    defer provider_binding.deinit();

    const tools = try coding_tools.register(allocator, cwd);
    defer coding_tools.unregister(allocator, tools);

    const system_prompt = try prompt_mod.buildSystemPrompt(
        allocator,
        tools,
        ctx_files,
        cwd,
    );
    defer allocator.free(system_prompt);

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
        try interactive.run(
            allocator,
            &agent,
            &session,
            &config,
            &provider_binding,
            args.verbose,
        );
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
        \\  Interactive mode slash commands:
        \\    /new, /resume [id], /model [provider/id], /quit
        \\  /exit is kept as a /quit alias.
        \\  Headless mode reads one prompt per stdin line. Use /exit to stop.
    ;
    try std.fs.File.stdout().writeAll(text ++ "\n");
}

test {
    _ = prompt_mod;
}
