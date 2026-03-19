const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent/root.zig");
const agent_types = @import("../agent/types.zig");
const config_mod = @import("config.zig");
const model_runtime = @import("model_runtime.zig");
const session_mod = @import("session.zig");
const runtime = @import("../runtime/root.zig");
const stdin_lines = @import("stdin_lines.zig");
const tui = @import("../tui/root.zig");
const ansi = @import("../tui/ansi.zig");
const highlight = @import("../tui/highlight.zig");
const theme = @import("../tui/theme.zig");
const terminal = @import("../tui/terminal.zig");
const lines_util = @import("../tui/lines_util.zig");
const posix = std.posix;
const MIN_RENDER_INTERVAL_NS: i128 = 16_000_000;
const MD_PADDING_X: u16 = 1;
const max_tool_args_chars: usize = 120;

const ToolLineState = enum {
    running,
    done,
    err,
};

const OutputBlock = enum {
    none,
    markdown,
    tool,
};

const ActiveToolLine = struct {
    id: []u8,
    label: []u8,
};

const SlashUsageKind = enum {
    generic,
    new_session,
    resume_cmd,
    model_cmd,
    quit,
};

const SlashCommand = union(enum) {
    not_command,
    quit,
    new_session,
    resume_list,
    resume_id: []const u8,
    show_model,
    set_model: []const u8,
    usage_error: SlashUsageKind,
    unknown: []const u8,
};

pub fn run(
    allocator: std.mem.Allocator,
    agent: *agent_mod.Agent,
    session: *session_mod.Session,
    config: *const config_mod.Config,
    provider_binding: *model_runtime.ProviderBinding,
    verbose: bool,
) !void {
    const stdout_file = std.fs.File.stdout();
    const stdin_file = std.fs.File.stdin();

    var event_loop: runtime.EventLoop = undefined;
    try event_loop.init(allocator);
    defer event_loop.deinit();

    if (!stdin_file.isTty() or !stdout_file.isTty()) {
        const current_theme = theme.forceNoColor();
        return runLineBuffered(
            allocator,
            agent,
            stdout_file,
            stdin_file,
            &event_loop,
            current_theme,
        );
    }

    var raw = try RawMode.init(stdin_file, stdout_file);
    defer raw.deinit();
    const current_theme = theme.detect(stdin_file, stdout_file);

    var ed = tui.Editor.init(allocator, "> ");
    defer ed.deinit();

    var renderer = tui.InlineRenderer.init(allocator, stdout_file);
    defer renderer.deinit();
    var decoder = tui.InputDecoder{};

    try renderEditor(&renderer, &ed, allocator);

    var input_ctx = InputCtx{
        .allocator = allocator,
        .agent = agent,
        .session = session,
        .config = config,
        .provider_binding = provider_binding,
        .verbose = verbose,
        .editor = &ed,
        .renderer = &renderer,
        .writer = stdout_file,
        .event_loop = &event_loop,
        .current_theme = current_theme,
    };
    var byte_buf: [64]u8 = undefined;
    while (true) {
        const chunk = try readInputChunk(stdin_file, &byte_buf);
        if (chunk.len == 0) break;

        input_ctx.needs_render = false;
        input_ctx.should_exit = false;
        try decoder.pushBytes(chunk, &input_ctx, InputCtx.onInput);
        if (input_ctx.should_exit) break;
        if (input_ctx.needs_render) try renderEditor(&renderer, &ed, allocator);
    }
}

/// Handle enter-key: submit prompt to agent, stream response, return true to exit.
fn handleSubmit(
    allocator: std.mem.Allocator,
    agent: *agent_mod.Agent,
    session: *session_mod.Session,
    config: *const config_mod.Config,
    provider_binding: *model_runtime.ProviderBinding,
    verbose: bool,
    ed: *tui.Editor,
    renderer: *tui.InlineRenderer,
    writer: std.fs.File,
    event_loop: *runtime.EventLoop,
    current_theme: theme.Theme,
) !bool {
    const text = ed.getText();
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return false;

    try writer.writeAll("\r\n\r\n");
    renderer.invalidate();

    try ed.pushHistory();
    ed.clear();

    const slash = parseSlashCommand(trimmed);
    if (slash != .not_command) {
        const should_exit = executeSlashCommand(
            allocator,
            agent,
            session,
            config,
            provider_binding,
            verbose,
            writer,
            current_theme,
            slash,
        ) catch |err| blk: {
            try renderSlashError(writer, current_theme, @errorName(err));
            break :blk false;
        };
        renderer.invalidate();
        try renderEditor(renderer, ed, allocator);
        return should_exit;
    }

    var sink_ctx = StreamSinkCtx.init(allocator, writer, event_loop, current_theme);
    defer sink_ctx.deinit();

    const sink: agent_types.AgentEventSink = .{
        .ctx = &sink_ctx,
        .emit = StreamSinkCtx.onEvent,
    };

    agent.prompt(text, &sink, null);

    // After agent turn, flush any remaining markdown content.
    sink_ctx.flushMarkdown();
    try writer.writeAll("\n");
    try saveSessionSnapshot(allocator, config.sessions_dir, session, agent);

    renderer.invalidate();
    try renderEditor(renderer, ed, allocator);
    return false;
}

fn parseSlashCommand(trimmed: []const u8) SlashCommand {
    if (trimmed.len == 0 or trimmed[0] != '/') return .not_command;

    const body = std.mem.trimLeft(u8, trimmed[1..], " \t");
    if (body.len == 0) return .{ .usage_error = .generic };

    var parts = std.mem.tokenizeAny(u8, body, " \t");
    const command = parts.next() orelse return .{ .usage_error = .generic };
    const arg = parts.next();
    const extra = parts.next();

    if (std.mem.eql(u8, command, "exit") or std.mem.eql(u8, command, "quit")) {
        if (arg != null) return .{ .usage_error = .quit };
        return .quit;
    }
    if (std.mem.eql(u8, command, "new")) {
        if (arg != null) return .{ .usage_error = .new_session };
        return .new_session;
    }
    if (std.mem.eql(u8, command, "resume")) {
        if (arg == null) return .resume_list;
        if (extra != null) return .{ .usage_error = .resume_cmd };
        return .{ .resume_id = arg.? };
    }
    if (std.mem.eql(u8, command, "model")) {
        if (arg == null) return .show_model;
        if (extra != null) return .{ .usage_error = .model_cmd };
        return .{ .set_model = arg.? };
    }
    return .{ .unknown = command };
}

fn executeSlashCommand(
    allocator: std.mem.Allocator,
    agent: *agent_mod.Agent,
    session: *session_mod.Session,
    config: *const config_mod.Config,
    provider_binding: *model_runtime.ProviderBinding,
    verbose: bool,
    writer: std.fs.File,
    current_theme: theme.Theme,
    command: SlashCommand,
) !bool {
    switch (command) {
        .not_command => return false,
        .quit => return true,
        .new_session => {
            try commandNewSession(allocator, agent, session, config.sessions_dir, provider_binding);
            const msg = try std.fmt.allocPrint(allocator, "new session: {s}", .{session.id.slice()});
            defer allocator.free(msg);
            try renderSlashInfo(writer, current_theme, msg);
            return false;
        },
        .resume_list => {
            try commandResumeList(allocator, writer, current_theme, config.sessions_dir, session);
            return false;
        },
        .resume_id => |id| {
            try commandResumeId(
                allocator,
                agent,
                session,
                config,
                provider_binding,
                verbose,
                id,
            );
            const current_model = provider_binding.currentModel();
            const msg = try std.fmt.allocPrint(
                allocator,
                "resumed {s} ({s}/{s})",
                .{ session.id.slice(), current_model.provider, current_model.id },
            );
            defer allocator.free(msg);
            try renderSlashInfo(writer, current_theme, msg);
            return false;
        },
        .show_model => {
            try commandShowModel(writer, current_theme, provider_binding);
            return false;
        },
        .set_model => |model_spec| {
            try commandSetModel(
                allocator,
                agent,
                session,
                config,
                provider_binding,
                verbose,
                model_spec,
            );
            const current_model = provider_binding.currentModel();
            const msg = try std.fmt.allocPrint(
                allocator,
                "model set: {s}/{s}",
                .{ current_model.provider, current_model.id },
            );
            defer allocator.free(msg);
            try renderSlashInfo(writer, current_theme, msg);
            return false;
        },
        .usage_error => |kind| {
            try renderSlashError(writer, current_theme, usageText(kind));
            return false;
        },
        .unknown => |name| {
            const msg = try std.fmt.allocPrint(allocator, "unknown command: /{s}", .{name});
            defer allocator.free(msg);
            try renderSlashError(writer, current_theme, msg);
            try renderSlashInfo(writer, current_theme, usageText(.generic));
            return false;
        },
    }
}

fn usageText(kind: SlashUsageKind) []const u8 {
    return switch (kind) {
        .generic => "commands: /new, /resume [id], /model [provider/id], /quit",
        .new_session => "usage: /new",
        .resume_cmd => "usage: /resume [session-id]",
        .model_cmd => "usage: /model [provider/id|builtin-id]",
        .quit => "usage: /quit",
    };
}

fn commandNewSession(
    allocator: std.mem.Allocator,
    agent: *agent_mod.Agent,
    session: *session_mod.Session,
    sessions_dir: []const u8,
    provider_binding: *model_runtime.ProviderBinding,
) !void {
    try saveSessionSnapshot(allocator, sessions_dir, session, agent);

    var new_session = try session_mod.Session.init(
        allocator,
        provider_binding.currentModel(),
        session.cwd,
    );
    var new_session_owned = true;
    errdefer if (new_session_owned) new_session.deinit();

    clearAgentMessages(allocator, agent);
    agent.total_usage = .{};

    session.deinit();
    session.* = new_session;
    new_session_owned = false;

    try saveSessionSnapshot(allocator, sessions_dir, session, agent);
}

fn commandResumeList(
    allocator: std.mem.Allocator,
    writer: std.fs.File,
    current_theme: theme.Theme,
    sessions_dir: []const u8,
    session: *const session_mod.Session,
) !void {
    const summaries = try session_mod.list(allocator, sessions_dir);
    defer session_mod.freeSummaryList(allocator, summaries);

    if (summaries.len == 0) {
        try renderSlashInfo(writer, current_theme, "no saved sessions");
        return;
    }

    try renderSlashInfo(writer, current_theme, "recent sessions:");
    for (summaries) |summary| {
        const marker = if (std.mem.eql(u8, summary.id.slice(), session.id.slice())) "*" else " ";
        const line = try std.fmt.allocPrint(
            allocator,
            "{s} {s}  model={s}  messages={d}",
            .{ marker, summary.id.slice(), summary.model_id, summary.message_count },
        );
        try writer.writeAll(line);
        try writer.writeAll("\n");
        allocator.free(line);
    }
}

fn commandResumeId(
    allocator: std.mem.Allocator,
    agent: *agent_mod.Agent,
    session: *session_mod.Session,
    config: *const config_mod.Config,
    provider_binding: *model_runtime.ProviderBinding,
    verbose: bool,
    id: []const u8,
) !void {
    if (std.mem.eql(u8, id, session.id.slice())) return;

    try saveSessionSnapshot(allocator, config.sessions_dir, session, agent);

    var loaded = try session_mod.load(allocator, config.sessions_dir, id);
    var loaded_owned = true;
    errdefer if (loaded_owned) loaded.deinit();

    const qualified_model = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ loaded.provider, loaded.model_id },
    );
    defer allocator.free(qualified_model);

    var resolved = try model_runtime.resolveModel(
        allocator,
        config.default_model,
        qualified_model,
    );
    defer resolved.deinit(allocator);

    const new_binding = try model_runtime.ProviderBinding.init(
        allocator,
        config,
        resolved.model,
        verbose,
    );

    var old_binding = provider_binding.*;
    provider_binding.* = new_binding;
    agent.setModel(provider_binding.provider(), provider_binding.currentModel());
    old_binding.deinit();

    clearAgentMessages(allocator, agent);
    agent.messages = loaded.messages;
    loaded.messages = .empty;
    agent.total_usage = loaded.total_usage;

    session.deinit();
    session.* = loaded;
    loaded_owned = false;

    try saveSessionSnapshot(allocator, config.sessions_dir, session, agent);
}

fn commandShowModel(
    writer: std.fs.File,
    current_theme: theme.Theme,
    provider_binding: *model_runtime.ProviderBinding,
) !void {
    const current = provider_binding.currentModel();
    var line_buf: [256]u8 = undefined;
    const current_line = try std.fmt.bufPrint(
        &line_buf,
        "current model: {s}/{s}",
        .{ current.provider, current.id },
    );
    try renderSlashInfo(writer, current_theme, current_line);
    try renderSlashInfo(writer, current_theme, "available models:");

    for (ai.models.builtin_models) |entry| {
        var model_buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &model_buf,
            "  - {s}/{s}",
            .{ entry.provider, entry.id },
        );
        try writer.writeAll(line);
        try writer.writeAll("\n");
    }
}

fn commandSetModel(
    allocator: std.mem.Allocator,
    agent: *agent_mod.Agent,
    session: *session_mod.Session,
    config: *const config_mod.Config,
    provider_binding: *model_runtime.ProviderBinding,
    verbose: bool,
    model_spec: []const u8,
) !void {
    var resolved = try model_runtime.resolveModel(allocator, config.default_model, model_spec);
    defer resolved.deinit(allocator);

    const next_model_id = try allocator.dupe(u8, resolved.model.id);
    var model_owned = true;
    errdefer if (model_owned) allocator.free(next_model_id);

    const next_provider = try allocator.dupe(u8, resolved.model.provider);
    errdefer if (model_owned) allocator.free(next_provider);

    var new_binding = try model_runtime.ProviderBinding.init(
        allocator,
        config,
        resolved.model,
        verbose,
    );
    var binding_owned = true;
    errdefer if (binding_owned) new_binding.deinit();

    try saveSessionSnapshot(allocator, config.sessions_dir, session, agent);

    allocator.free(session.model_id);
    allocator.free(session.provider);
    session.model_id = next_model_id;
    session.provider = next_provider;
    model_owned = false;

    var old_binding = provider_binding.*;
    provider_binding.* = new_binding;
    binding_owned = false;
    agent.setModel(provider_binding.provider(), provider_binding.currentModel());
    old_binding.deinit();

    try saveSessionSnapshot(allocator, config.sessions_dir, session, agent);
}

fn saveSessionSnapshot(
    allocator: std.mem.Allocator,
    sessions_dir: []const u8,
    session: *session_mod.Session,
    agent: *agent_mod.Agent,
) !void {
    std.debug.assert(session.messages.items.len == 0);
    session.updated_at = std.time.timestamp();
    session.total_usage = agent.total_usage;
    session.messages = agent.messages;
    agent.messages = .empty;
    errdefer {
        agent.messages = session.messages;
        session.messages = .empty;
    }
    try session_mod.save(allocator, sessions_dir, session);
    agent.messages = session.messages;
    session.messages = .empty;
}

fn clearAgentMessages(allocator: std.mem.Allocator, agent: *agent_mod.Agent) void {
    for (agent.messages.items) |message| {
        ai.context.freeMessage(allocator, message);
    }
    agent.messages.deinit(allocator);
    agent.messages = .empty;
}

fn renderSlashInfo(
    writer: std.fs.File,
    current_theme: theme.Theme,
    message: []const u8,
) !void {
    if (ansi.isEnabled(current_theme)) {
        var fg_buf: [24]u8 = undefined;
        try writer.writeAll(ansi.fgPrefix(&fg_buf, current_theme, current_theme.palette.dim));
    }
    try writer.writeAll(message);
    if (ansi.isEnabled(current_theme)) {
        try writer.writeAll(ansi.resetCode(current_theme));
    }
    try writer.writeAll("\n");
}

fn renderSlashError(
    writer: std.fs.File,
    current_theme: theme.Theme,
    message: []const u8,
) !void {
    if (ansi.isEnabled(current_theme)) {
        var fg_buf: [24]u8 = undefined;
        try writer.writeAll(
            ansi.fgPrefix(&fg_buf, current_theme, current_theme.palette.tool_error),
        );
    }
    try writer.writeAll("error: ");
    try writer.writeAll(message);
    if (ansi.isEnabled(current_theme)) {
        try writer.writeAll(ansi.resetCode(current_theme));
    }
    try writer.writeAll("\n");
}

fn renderEditor(
    renderer: *tui.InlineRenderer,
    ed: *tui.Editor,
    allocator: std.mem.Allocator,
) !void {
    const size = terminal.getTerminalSize();
    const width = if (size.width > 0) size.width else 80;
    const lines = try ed.component().render(width, allocator);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }
    const cursor = try ed.cursorPosition(width);
    try renderer.render(lines, cursor.y, cursor.x);
}

const InputCtx = struct {
    allocator: std.mem.Allocator,
    agent: *agent_mod.Agent,
    session: *session_mod.Session,
    config: *const config_mod.Config,
    provider_binding: *model_runtime.ProviderBinding,
    verbose: bool,
    editor: *tui.Editor,
    renderer: *tui.InlineRenderer,
    writer: std.fs.File,
    event_loop: *runtime.EventLoop,
    current_theme: theme.Theme,
    needs_render: bool = false,
    should_exit: bool = false,

    fn onInput(self: *InputCtx, event: tui.InputEvent) !void {
        switch (event) {
            .action => |action| switch (action) {
                .submit => {
                    self.should_exit = try handleSubmit(
                        self.allocator,
                        self.agent,
                        self.session,
                        self.config,
                        self.provider_binding,
                        self.verbose,
                        self.editor,
                        self.renderer,
                        self.writer,
                        self.event_loop,
                        self.current_theme,
                    );
                },
                .end_of_transmission => {
                    if (self.editor.getText().len == 0) {
                        try self.writer.writeAll("\r\n");
                        self.should_exit = true;
                    }
                },
                else => {
                    if (try self.editor.handleInput(event)) self.needs_render = true;
                },
            },
            else => {
                if (try self.editor.handleInput(event)) self.needs_render = true;
            },
        }
    }
};

/// Streaming sink that accumulates text and renders markdown incrementally.
const StreamSinkCtx = struct {
    allocator: std.mem.Allocator,
    writer: std.fs.File,
    current_theme: theme.Theme,
    text_buf: std.ArrayList(u8),
    md: tui.Markdown,
    md_renderer: tui.InlineRenderer,
    render_timer: runtime.Timer,
    mutex: std.Thread.Mutex = .{},
    has_md_content: bool,
    last_render_ns: i128,
    render_pending: bool,
    last_rendered_text_len: usize,
    last_render_width: u16,
    fenced_code_open: bool,
    active_tool: ?ActiveToolLine,
    last_output_block: OutputBlock,

    fn init(
        allocator: std.mem.Allocator,
        writer: std.fs.File,
        event_loop: *runtime.EventLoop,
        current_theme: theme.Theme,
    ) StreamSinkCtx {
        std.debug.assert(event_loop.worker != null);
        return .{
            .allocator = allocator,
            .writer = writer,
            .current_theme = current_theme,
            .text_buf = .{},
            .md = tui.Markdown.init(allocator, "", 1, 0, current_theme),
            .md_renderer = tui.InlineRenderer.init(allocator, writer),
            .render_timer = runtime.Timer.init(event_loop),
            .has_md_content = false,
            .last_render_ns = 0,
            .render_pending = false,
            .last_rendered_text_len = 0,
            .last_render_width = 0,
            .fenced_code_open = false,
            .active_tool = null,
            .last_output_block = .none,
        };
    }

    fn deinit(self: *StreamSinkCtx) void {
        self.clearActiveToolState();
        self.render_timer.deinit();
        self.text_buf.deinit(self.allocator);
        self.md.deinit();
        self.md_renderer.deinit();
    }

    fn flushMarkdown(self: *StreamSinkCtx) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.flushMarkdownLocked();
    }

    fn flushMarkdownLocked(self: *StreamSinkCtx) void {
        self.render_timer.cancel();
        self.flushPendingRenderLocked();
        if (!self.has_md_content) return;
        // Move past the rendered markdown area so it becomes scrollback.
        const line_count = self.md_renderer.backbuffer.items.len;
        if (line_count > 0) {
            // Cursor is at last_cursor_row; move to bottom and newline.
            const bottom = line_count - 1;
            if (bottom > self.md_renderer.last_cursor_row) {
                var buf: [32]u8 = undefined;
                const seq = std.fmt.bufPrint(&buf, "\x1b[{d}B", .{
                    bottom - self.md_renderer.last_cursor_row,
                }) catch return;
                self.writer.writeAll(seq) catch {};
            }
            self.writer.writeAll("\r\n") catch {};
        }
        self.md_renderer.invalidate();
        self.text_buf.clearRetainingCapacity();
        self.has_md_content = false;
        self.render_pending = false;
        self.last_rendered_text_len = 0;
        self.last_render_width = 0;
        self.fenced_code_open = false;
        self.last_output_block = .markdown;
    }

    fn renderMdLocked(self: *StreamSinkCtx) void {
        const now = std.time.nanoTimestamp();
        if (!shouldThrottleRender(self.last_render_ns, now)) {
            self.render_timer.cancel();
            self.last_render_ns = now;
            self.render_pending = false;
            self.doRenderMdLocked();
            return;
        }

        self.render_pending = true;
        self.schedulePendingRenderLocked(now);
    }

    fn schedulePendingRenderLocked(self: *StreamSinkCtx, now_ns: i128) void {
        const wait_ns = remainingRenderWaitNs(self.last_render_ns, now_ns) orelse return;
        if (wait_ns == 0) {
            self.flushPendingRenderLocked();
            return;
        }
        self.render_timer.armAfter(wait_ns, onRenderDeadline, self) catch {
            self.flushPendingRenderLocked();
        };
    }

    fn doRenderMd(self: *StreamSinkCtx) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.doRenderMdLocked();
    }

    fn doRenderMdLocked(self: *StreamSinkCtx) void {
        const width = markdownRenderWidth();
        if (self.tryRenderMdAppendFastPathLocked(width)) return;

        self.md.setText(self.text_buf.items) catch return;
        const lines = self.md.component().render(width, self.allocator) catch return;
        defer {
            for (lines) |line| self.allocator.free(line);
            self.allocator.free(lines);
        }
        const row: u16 = if (lines.len > 0) @intCast(lines.len - 1) else 0;
        self.md_renderer.render(lines, row, 0) catch {};
        self.has_md_content = true;
        self.last_rendered_text_len = self.text_buf.items.len;
        self.last_render_width = width;
    }

    fn flushPendingRenderLocked(self: *StreamSinkCtx) void {
        if (!self.render_pending) return;
        self.last_render_ns = std.time.nanoTimestamp();
        self.render_pending = false;
        self.doRenderMdLocked();
    }

    fn tryRenderMdAppendFastPath(self: *StreamSinkCtx, width: u16) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.tryRenderMdAppendFastPathLocked(width);
    }

    fn tryRenderMdAppendFastPathLocked(self: *StreamSinkCtx, width: u16) bool {
        if (!self.has_md_content) return false;
        if (self.fenced_code_open) return false;
        if (self.last_render_width == 0 or self.last_render_width != width) return false;
        if (self.last_rendered_text_len > self.text_buf.items.len) return false;

        const delta = self.text_buf.items[self.last_rendered_text_len..];
        if (delta.len == 0) return true;
        if (!isFastPathMarkdownDelta(delta)) return false;

        const prev_lines = self.md_renderer.backbuffer.items;
        if (prev_lines.len == 0) return false;
        if (lineHasAnsi(prev_lines[prev_lines.len - 1])) return false;

        const updated_lines = appendDeltaToRenderedLines(
            self.allocator,
            prev_lines,
            delta,
            width,
        ) catch return false;
        defer lines_util.freeLines(self.allocator, updated_lines);

        const row: u16 = if (updated_lines.len > 0) @intCast(updated_lines.len - 1) else 0;
        self.md_renderer.render(updated_lines, row, 0) catch return false;
        self.has_md_content = true;
        self.last_rendered_text_len = self.text_buf.items.len;
        self.last_render_width = width;
        return true;
    }

    fn onRenderDeadline(raw_ctx: *anyopaque) void {
        const self: *StreamSinkCtx = @ptrCast(@alignCast(raw_ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.flushPendingRenderLocked();
    }

    fn clearActiveToolState(self: *StreamSinkCtx) void {
        if (self.active_tool) |active| {
            self.allocator.free(active.id);
            self.allocator.free(active.label);
            self.active_tool = null;
        }
    }

    fn endDanglingToolLine(self: *StreamSinkCtx) void {
        if (self.active_tool == null) return;
        self.writer.writeAll("\n") catch {};
        self.clearActiveToolState();
        self.last_output_block = .tool;
    }

    fn writeBlockSeparator(self: *StreamSinkCtx) void {
        if (self.last_output_block == .none) return;
        self.writer.writeAll("\n") catch {};
    }

    fn beginMarkdownBlockLocked(self: *StreamSinkCtx) void {
        if (self.has_md_content) return;
        if (self.text_buf.items.len != 0) return;
        if (self.last_output_block != .tool) return;
        self.writer.writeAll("\n") catch {};
        self.last_output_block = .none;
    }

    fn onEvent(raw_ctx: *anyopaque, event: agent_types.AgentEvent) void {
        const self: *StreamSinkCtx = @ptrCast(@alignCast(raw_ctx));
        switch (event) {
            .text_delta => |text| {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.beginMarkdownBlockLocked();
                self.text_buf.appendSlice(self.allocator, text) catch return;
                self.fenced_code_open = hasOpenFencedCodeBlock(self.text_buf.items);
                self.renderMdLocked();
            },
            .thinking_delta => |text| {
                self.writer.writeAll(ansi.dimCode(self.current_theme)) catch {};
                self.writer.writeAll(text) catch {};
                self.writer.writeAll(ansi.resetCode(self.current_theme)) catch {};
            },
            .tool_exec_start => |payload| {
                self.flushMarkdown();
                self.endDanglingToolLine();
                self.writeBlockSeparator();

                const label = formatToolLabel(
                    self.allocator,
                    self.current_theme,
                    payload.name,
                    payload.arguments,
                    max_tool_args_chars,
                ) catch return;
                errdefer self.allocator.free(label);

                const id = self.allocator.dupe(u8, payload.id) catch return;
                self.active_tool = .{
                    .id = id,
                    .label = label,
                };
                const running_newline = !ansi.isEnabled(self.current_theme);
                renderToolLine(self.writer, self.current_theme, label, .running, running_newline);
                self.last_output_block = .tool;
            },
            .tool_exec_end => |payload| {
                if (self.active_tool) |active| {
                    if (!std.mem.eql(u8, active.id, payload.id)) {
                        self.endDanglingToolLine();
                    } else {
                        const state: ToolLineState = if (payload.is_error) .err else .done;
                        renderToolLine(self.writer, self.current_theme, active.label, state, true);
                        self.clearActiveToolState();
                        self.last_output_block = .tool;
                        return;
                    }
                }

                const fallback_label = formatToolLabel(
                    self.allocator,
                    self.current_theme,
                    payload.name,
                    "{}",
                    max_tool_args_chars,
                ) catch return;
                defer self.allocator.free(fallback_label);
                const fallback_state: ToolLineState = if (payload.is_error) .err else .done;
                renderToolLine(
                    self.writer,
                    self.current_theme,
                    fallback_label,
                    fallback_state,
                    true,
                );
                self.last_output_block = .tool;
            },
            .turn_end => |payload| {
                _ = payload;
                self.flushMarkdown();
                self.endDanglingToolLine();
            },
            .agent_end => |payload| {
                self.flushMarkdown();
                self.endDanglingToolLine();
                var buf: [160]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "{s}tokens: {d} in / {d} out{s}\n", .{
                    ansi.dimCode(self.current_theme),
                    payload.total_usage.input,
                    payload.total_usage.output,
                    ansi.resetCode(self.current_theme),
                }) catch return;
                self.writer.writeAll(msg) catch {};
            },
            .err => |message| {
                self.flushMarkdown();
                self.endDanglingToolLine();
                var fg_buf: [24]u8 = undefined;
                self.writer.writeAll(
                    ansi.fgPrefix(&fg_buf, self.current_theme, self.current_theme.palette.tool_error),
                ) catch {};
                self.writer.writeAll("error: ") catch {};
                self.writer.writeAll(message) catch {};
                self.writer.writeAll(ansi.resetCode(self.current_theme)) catch {};
                self.writer.writeAll("\n") catch {};
            },
            else => {},
        }
    }
};

fn formatToolLabel(
    allocator: std.mem.Allocator,
    current_theme: theme.Theme,
    tool_name: []const u8,
    arguments: []const u8,
    max_args_len: usize,
) ![]u8 {
    const args = try summarizeToolArguments(allocator, tool_name, arguments, max_args_len);
    defer allocator.free(args);

    var styled_bash_args: ?[]u8 = null;
    defer if (styled_bash_args) |buf| allocator.free(buf);

    const rendered_args = blk: {
        if (!std.mem.eql(u8, tool_name, "bash")) break :blk args;
        if (std.mem.eql(u8, args, "{}")) break :blk args;
        styled_bash_args = highlight.renderLine(allocator, args, .bash, current_theme) catch null;
        break :blk styled_bash_args orelse args;
    };

    const display_name = toolDisplayName(tool_name);
    var fg_buf: [24]u8 = undefined;
    const label_color = ansi.fgPrefix(&fg_buf, current_theme, current_theme.palette.link);
    const reset_code = ansi.resetCode(current_theme);
    if (std.mem.eql(u8, rendered_args, "{}")) {
        return std.fmt.allocPrint(
            allocator,
            "• {s}{s}{s}",
            .{ label_color, display_name, reset_code },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "• {s}{s}{s} {s}",
        .{ label_color, display_name, reset_code, rendered_args },
    );
}

fn summarizeToolArguments(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    arguments: []const u8,
    max_len: usize,
) ![]u8 {
    if (std.mem.eql(u8, tool_name, "read")) {
        const ReadArgs = struct {
            path: ?[]const u8 = null,
            offset: ?u32 = null,
            limit: ?u32 = null,
        };
        const parsed = std.json.parseFromSlice(ReadArgs, allocator, arguments, .{
            .ignore_unknown_fields = true,
        }) catch return summarizeToolText(allocator, arguments, max_len);
        defer parsed.deinit();
        if (parsed.value.path) |path| {
            if (parsed.value.offset) |offset| {
                if (parsed.value.limit) |limit| {
                    const raw = try std.fmt.allocPrint(
                        allocator,
                        "{s} (offset={d}, limit={d})",
                        .{ path, offset, limit },
                    );
                    defer allocator.free(raw);
                    return summarizeToolText(allocator, raw, max_len);
                }
                const raw = try std.fmt.allocPrint(allocator, "{s} (offset={d})", .{ path, offset });
                defer allocator.free(raw);
                return summarizeToolText(allocator, raw, max_len);
            }
            return summarizeToolText(allocator, path, max_len);
        }
    }
    if (std.mem.eql(u8, tool_name, "bash")) {
        const BashArgs = struct {
            command: ?[]const u8 = null,
            timeout: ?u32 = null,
        };
        const parsed = std.json.parseFromSlice(BashArgs, allocator, arguments, .{
            .ignore_unknown_fields = true,
        }) catch return summarizeToolText(allocator, arguments, max_len);
        defer parsed.deinit();
        if (parsed.value.command) |command| {
            return summarizeToolText(allocator, command, max_len);
        }
    }
    if (std.mem.eql(u8, tool_name, "write")) {
        const WriteArgs = struct { path: ?[]const u8 = null };
        const parsed = std.json.parseFromSlice(WriteArgs, allocator, arguments, .{
            .ignore_unknown_fields = true,
        }) catch return summarizeToolText(allocator, arguments, max_len);
        defer parsed.deinit();
        if (parsed.value.path) |path| {
            return summarizeToolText(allocator, path, max_len);
        }
    }
    if (std.mem.eql(u8, tool_name, "edit")) {
        const EditArgs = struct { path: ?[]const u8 = null };
        const parsed = std.json.parseFromSlice(EditArgs, allocator, arguments, .{
            .ignore_unknown_fields = true,
        }) catch return summarizeToolText(allocator, arguments, max_len);
        defer parsed.deinit();
        if (parsed.value.path) |path| {
            return summarizeToolText(allocator, path, max_len);
        }
    }

    if (try summarizeJsonObjectFields(allocator, arguments, max_len)) |summary| {
        return summary;
    }
    return summarizeToolText(allocator, arguments, max_len);
}

fn toolDisplayName(tool_name: []const u8) []const u8 {
    if (std.mem.eql(u8, tool_name, "read")) return "Read";
    if (std.mem.eql(u8, tool_name, "write")) return "Write";
    if (std.mem.eql(u8, tool_name, "edit")) return "Edit";
    if (std.mem.eql(u8, tool_name, "bash")) return "Bash";
    return tool_name;
}

fn summarizeJsonObjectFields(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_len: usize,
) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);

    var fields: usize = 0;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        if (fields > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, entry.key_ptr.*);
        try out.append(allocator, '=');
        try appendJsonScalarSummary(allocator, &out, entry.value_ptr.*, max_len);
        fields += 1;
        if (out.items.len >= max_len) break;
    }
    if (fields == 0) {
        return @as(?[]u8, try allocator.dupe(u8, "{}"));
    }
    return @as(?[]u8, try summarizeToolText(allocator, out.items, max_len));
}

fn appendJsonScalarSummary(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: std.json.Value,
    max_len: usize,
) !void {
    switch (value) {
        .string => {
            const text = try summarizeToolText(allocator, value.string, max_len);
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
        },
        .integer => |v| try std.fmt.format(out.writer(allocator), "{d}", .{v}),
        .float => |v| try std.fmt.format(out.writer(allocator), "{d}", .{v}),
        .bool => |v| try out.appendSlice(allocator, if (v) "true" else "false"),
        .null => try out.appendSlice(allocator, "null"),
        else => try out.appendSlice(allocator, "..."),
    }
}

fn summarizeToolText(allocator: std.mem.Allocator, text: []const u8, max_len: usize) ![]u8 {
    std.debug.assert(max_len > 3);
    var compact: std.ArrayList(u8) = .{};
    errdefer compact.deinit(allocator);

    var saw_non_space = false;
    var pending_space = false;
    for (text) |byte| {
        const is_space = byte == ' ' or byte == '\n' or byte == '\r' or byte == '\t';
        if (is_space) {
            if (saw_non_space) pending_space = true;
            continue;
        }
        if (pending_space) {
            try compact.append(allocator, ' ');
            pending_space = false;
        }
        try compact.append(allocator, byte);
        saw_non_space = true;
    }
    if (!saw_non_space) {
        return allocator.dupe(u8, "{}");
    }
    if (compact.items.len <= max_len) {
        return compact.toOwnedSlice(allocator);
    }
    compact.shrinkRetainingCapacity(max_len - 3);
    try compact.appendSlice(allocator, "...");
    return compact.toOwnedSlice(allocator);
}

fn renderToolLine(
    writer: std.fs.File,
    current_theme: theme.Theme,
    label: []const u8,
    state: ToolLineState,
    newline: bool,
) void {
    const ToolStyle = struct {
        color_value: theme.ColorValue,
        icon: []const u8,
    };
    const style: ToolStyle = switch (state) {
        .running => .{ .color_value = current_theme.palette.tool_running, .icon = "⟳" },
        .done => .{ .color_value = current_theme.palette.tool_success, .icon = "✓" },
        .err => .{ .color_value = current_theme.palette.tool_error, .icon = "✗" },
    };
    if (!ansi.isEnabled(current_theme)) {
        writer.writeAll(label) catch {};
        writer.writeAll(" ") catch {};
        writer.writeAll(style.icon) catch {};
        if (newline) writer.writeAll("\n") catch {};
        return;
    }

    var fg_buf: [24]u8 = undefined;
    writer.writeAll("\r\x1b[2K") catch {};
    writer.writeAll(label) catch {};
    writer.writeAll(" ") catch {};
    writer.writeAll(ansi.fgPrefix(&fg_buf, current_theme, style.color_value)) catch {};
    writer.writeAll(style.icon) catch {};
    writer.writeAll(ansi.resetCode(current_theme)) catch {};
    if (newline) writer.writeAll("\n") catch {};
}

fn shouldThrottleRender(last_render_ns: i128, now_ns: i128) bool {
    if (last_render_ns == 0) return false;
    if (now_ns < last_render_ns) return true;
    return now_ns - last_render_ns < MIN_RENDER_INTERVAL_NS;
}

fn remainingRenderWaitNs(last_render_ns: i128, now_ns: i128) ?u64 {
    if (last_render_ns == 0) return 0;
    if (now_ns < last_render_ns) return null;
    const elapsed = now_ns - last_render_ns;
    if (elapsed >= MIN_RENDER_INTERVAL_NS) return 0;
    return std.math.cast(u64, MIN_RENDER_INTERVAL_NS - elapsed);
}

fn markdownRenderWidth() u16 {
    const size = terminal.getTerminalSize();
    return if (size.width > 2) size.width else 80;
}

fn isFastPathMarkdownDelta(delta: []const u8) bool {
    for (delta) |byte| {
        if (byte == '\r') return false;
        if (byte == '`') return false;
        if (byte == '#') return false;
        if (byte == 0x1b) return false;
    }
    return true;
}

fn hasOpenFencedCodeBlock(text: []const u8) bool {
    var in_code_block = false;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| {
        if (std.mem.startsWith(u8, line, "```")) {
            in_code_block = !in_code_block;
        }
    }
    return in_code_block;
}

fn lineHasAnsi(line: []const u8) bool {
    return std.mem.indexOfScalar(u8, line, 0x1b) != null;
}

fn appendDeltaToRenderedLines(
    allocator: std.mem.Allocator,
    previous_lines: []const []const u8,
    delta: []const u8,
    width: u16,
) ![][]const u8 {
    std.debug.assert(previous_lines.len > 0);

    const max_line_len = markdownMaxLineLen(width);
    var lines: std.ArrayList([]const u8) = .{};
    errdefer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }

    const cloned = try lines_util.cloneLines(allocator, previous_lines);
    try lines_util.appendOwnedLines(&lines, allocator, cloned);
    std.debug.assert(lines.items.len > 0);

    var start: usize = 0;
    while (start <= delta.len) {
        const next_newline = std.mem.indexOfScalarPos(u8, delta, start, '\n') orelse delta.len;
        if (next_newline > start) {
            try appendPlainTextChunk(
                &lines,
                allocator,
                delta[start..next_newline],
                max_line_len,
            );
        }
        if (next_newline == delta.len) break;
        if (!lastRenderedLineIsBlank(lines.items)) {
            try lines.append(allocator, try allocator.dupe(u8, " "));
        }
        start = next_newline + 1;
    }

    return lines.toOwnedSlice(allocator);
}

fn appendPlainTextChunk(
    lines: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    chunk: []const u8,
    max_line_len: usize,
) !void {
    std.debug.assert(max_line_len > 0);
    if (chunk.len == 0) return;

    var remaining = chunk;
    while (remaining.len > 0) {
        const last_index = lines.items.len - 1;
        const last_line = lines.items[last_index];
        if (lineHasAnsi(last_line)) return error.FastPathAnsiLine;

        const room = if (last_line.len < max_line_len) max_line_len - last_line.len else 0;
        if (room == 0) {
            try lines.append(allocator, try allocator.dupe(u8, " "));
            continue;
        }

        const take = @min(room, remaining.len);
        const merged = try std.fmt.allocPrint(allocator, "{s}{s}", .{
            last_line,
            remaining[0..take],
        });
        allocator.free(last_line);
        lines.items[last_index] = merged;
        remaining = remaining[take..];
    }
}

fn lastRenderedLineIsBlank(lines: []const []const u8) bool {
    if (lines.len == 0) return false;
    const last = lines[lines.len - 1];
    if (lineHasAnsi(last)) return false;
    return std.mem.trim(u8, last, " ").len == 0;
}

fn markdownMaxLineLen(width: u16) usize {
    const content_width = markdownContentWidth(width, MD_PADDING_X);
    return content_width + MD_PADDING_X;
}

fn markdownContentWidth(width: u16, padding_x: u16) usize {
    if (padding_x == 0) return @as(usize, width);
    const total_padding = @as(u32, padding_x) * 2;
    if (total_padding >= width) return 1;
    return @as(usize, width - @as(u16, @intCast(total_padding)));
}

fn readInputChunk(stdin_file: std.fs.File, buf: *[64]u8) ![]const u8 {
    const first_read = try stdin_file.read(buf[0..1]);
    if (first_read == 0) return buf[0..0];

    var len: usize = first_read;
    while (len < buf.len) {
        const timeout_ms: i32 = if (len == 1 and buf[0] == 0x1b) 10 else 0;
        if (!pollReadable(stdin_file.handle, timeout_ms)) break;
        const next_read = try stdin_file.read(buf[len .. len + 1]);
        if (next_read == 0) break;
        len += next_read;
    }
    return buf[0..len];
}

fn pollReadable(handle: posix.fd_t, timeout_ms: i32) bool {
    var fds = [_]posix.pollfd{.{
        .fd = handle,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    const ready = posix.poll(fds[0..], timeout_ms) catch return false;
    if (ready == 0) return false;
    return (fds[0].revents & posix.POLL.IN) != 0;
}

fn runLineBuffered(
    allocator: std.mem.Allocator,
    agent: *agent_mod.Agent,
    stdout_file: std.fs.File,
    stdin_file: std.fs.File,
    event_loop: *runtime.EventLoop,
    current_theme: theme.Theme,
) !void {
    var stdin_buffer: [4096]u8 = undefined;
    var reader = stdin_file.readerStreaming(&stdin_buffer);

    var sink_ctx = StreamSinkCtx.init(allocator, stdout_file, event_loop, current_theme);
    defer sink_ctx.deinit();

    const sink: agent_types.AgentEventSink = .{
        .ctx = &sink_ctx,
        .emit = StreamSinkCtx.onEvent,
    };

    while (try stdin_lines.takeLine(&reader.interface)) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "/exit")) break;

        try stdout_file.writeAll("> ");
        try stdout_file.writeAll(line);
        try stdout_file.writeAll("\n\n");

        agent.prompt(line, &sink, null);
        sink_ctx.flushMarkdown();
        try stdout_file.writeAll("\n");
    }
}

const RawMode = struct {
    handle: posix.fd_t,
    original: posix.termios,
    writer: std.fs.File,

    const enable_input_modes = "\x1b[?2004h\x1b[>7u\x1b[>4;2m";
    const disable_input_modes = "\x1b[>4;0m\x1b[<u\x1b[?2004l";

    fn init(file: std.fs.File, writer: std.fs.File) !RawMode {
        std.debug.assert(file.isTty());
        const original = try posix.tcgetattr(file.handle);
        var raw = original;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(file.handle, .FLUSH, raw);
        writer.writeAll(enable_input_modes) catch {};
        return .{ .handle = file.handle, .original = original, .writer = writer };
    }

    fn deinit(self: *const RawMode) void {
        self.writer.writeAll(disable_input_modes) catch {};
        posix.tcsetattr(self.handle, .FLUSH, self.original) catch {};
    }
};

fn waitForMarkdownRender(sink: *StreamSinkCtx, timeout_ms: u32) bool {
    const start_ns = std.time.nanoTimestamp();
    const timeout_ns = @as(i128, timeout_ms) * std.time.ns_per_ms;

    while (true) {
        sink.mutex.lock();
        const ready = sink.has_md_content and !sink.render_pending;
        sink.mutex.unlock();
        if (ready) return true;

        const now_ns = std.time.nanoTimestamp();
        if (now_ns - start_ns >= timeout_ns) return false;
        std.Thread.sleep(std.time.ns_per_ms);
    }
}

test "parse slash command handles quit and new" {
    try std.testing.expect(parseSlashCommand("/quit") == .quit);
    try std.testing.expect(parseSlashCommand("/exit") == .quit);
    try std.testing.expect(parseSlashCommand("/new") == .new_session);
}

test "parse slash command handles resume and model args" {
    try std.testing.expect(parseSlashCommand("/resume") == .resume_list);
    const resume_cmd = parseSlashCommand("/resume 20260319-010203-abcd");
    switch (resume_cmd) {
        .resume_id => |id| try std.testing.expectEqualStrings("20260319-010203-abcd", id),
        else => return error.TestUnexpectedResult,
    }

    const model = parseSlashCommand("/model openai/gpt-4o");
    switch (model) {
        .set_model => |id| try std.testing.expectEqualStrings("openai/gpt-4o", id),
        else => return error.TestUnexpectedResult,
    }
}

test "parse slash command validates usage and unknown names" {
    const bad_model = parseSlashCommand("/model a b");
    try std.testing.expect(bad_model == .usage_error);

    const unknown = parseSlashCommand("/wat");
    switch (unknown) {
        .unknown => |name| try std.testing.expectEqualStrings("wat", name),
        else => return error.TestUnexpectedResult,
    }
}

test "render throttling blocks updates inside frame interval" {
    const now: i128 = 100_000_000;
    try std.testing.expect(shouldThrottleRender(now, now + 1));
    try std.testing.expect(shouldThrottleRender(now, now + MIN_RENDER_INTERVAL_NS - 1));
    try std.testing.expect(!shouldThrottleRender(now, now + MIN_RENDER_INTERVAL_NS));
}

test "remaining render wait computes frame delay" {
    const now: i128 = 200_000_000;
    try std.testing.expectEqual(@as(?u64, 0), remainingRenderWaitNs(0, now));
    try std.testing.expectEqual(@as(?u64, null), remainingRenderWaitNs(now + 1, now));
    try std.testing.expectEqual(@as(?u64, 1), remainingRenderWaitNs(now, now + MIN_RENDER_INTERVAL_NS - 1));
    try std.testing.expectEqual(@as(?u64, 0), remainingRenderWaitNs(now, now + MIN_RENDER_INTERVAL_NS));
}

test "fast path markdown delta filter rejects markdown control bytes" {
    try std.testing.expect(isFastPathMarkdownDelta("plain text"));
    try std.testing.expect(!isFastPathMarkdownDelta("with `fence"));
    try std.testing.expect(!isFastPathMarkdownDelta("with # heading"));
    try std.testing.expect(!isFastPathMarkdownDelta("line\rbreak"));
}

test "open fenced code block is detected" {
    try std.testing.expect(hasOpenFencedCodeBlock("```zig\nconst x = 1\n"));
    try std.testing.expect(!hasOpenFencedCodeBlock("```zig\nconst x = 1\n```"));
}

test "append delta to rendered lines wraps and appends" {
    const allocator = std.testing.allocator;
    const previous = [_][]const u8{" hello"};
    const updated = try appendDeltaToRenderedLines(allocator, &previous, " world", 12);
    defer lines_util.freeLines(allocator, updated);

    try std.testing.expectEqual(@as(usize, 2), updated.len);
    try std.testing.expectEqualStrings(" hello worl", updated[0]);
    try std.testing.expectEqualStrings(" d", updated[1]);
}

test "append delta to rendered lines collapses repeated blank lines" {
    const allocator = std.testing.allocator;
    const previous = [_][]const u8{" hello"};
    const updated = try appendDeltaToRenderedLines(allocator, &previous, "\n\nworld", 12);
    defer lines_util.freeLines(allocator, updated);

    try std.testing.expectEqual(@as(usize, 2), updated.len);
    try std.testing.expectEqualStrings(" world", updated[1]);
}

test "tool summary compacts whitespace and truncates" {
    const allocator = std.testing.allocator;

    const compact = try summarizeToolText(
        allocator,
        "{\n  \"command\": \"echo hi\"\n}",
        64,
    );
    defer allocator.free(compact);
    try std.testing.expectEqualStrings("{ \"command\": \"echo hi\" }", compact);

    const truncated = try summarizeToolText(
        allocator,
        "{\"path\":\"very/long/path/that/needs/truncation\"}",
        20,
    );
    defer allocator.free(truncated);
    try std.testing.expect(std.mem.endsWith(u8, truncated, "..."));
    try std.testing.expectEqual(@as(usize, 20), truncated.len);
}

test "tool label renders human-readable args" {
    const allocator = std.testing.allocator;
    const current_theme = theme.themeFor(.ansi16, .dark);

    const read_label = try formatToolLabel(
        allocator,
        current_theme,
        "read",
        "{\"path\":\"AGENTS.md\"}",
        120,
    );
    defer allocator.free(read_label);
    try std.testing.expect(std.mem.indexOf(u8, read_label, "• ") == 0);
    try std.testing.expect(std.mem.indexOf(u8, read_label, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_label, "Read") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_label, "AGENTS.md") != null);

    const bash_label = try formatToolLabel(
        allocator,
        current_theme,
        "bash",
        "{\"command\":\"echo hi\"}",
        120,
    );
    defer allocator.free(bash_label);
    try std.testing.expect(std.mem.indexOf(u8, bash_label, "Bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash_label, "echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash_label, "hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, bash_label, " echo hi") == null);
}

test "tool execution status rewrites same line with args" {
    const allocator = std.testing.allocator;
    const current_theme = theme.themeFor(.ansi16, .dark);

    var event_loop: runtime.EventLoop = undefined;
    try event_loop.init(allocator);
    defer event_loop.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("stream_sink_tool_line", .{ .read = true });
    defer file.close();

    var sink = StreamSinkCtx.init(allocator, file, &event_loop, current_theme);
    defer sink.deinit();

    StreamSinkCtx.onEvent(&sink, .{
        .tool_exec_start = .{
            .id = "toolu_1",
            .name = "bash",
            .arguments = "{\"command\":\"echo hi\"}",
        },
    });
    StreamSinkCtx.onEvent(&sink, .{
        .tool_exec_end = .{
            .id = "toolu_1",
            .name = "bash",
            .is_error = false,
            .ui_details = "{\"exit_code\":0,\"duration_ms\":50}",
        },
    });

    try file.seekTo(0);
    const stat = try file.stat();
    const output = try file.readToEndAlloc(allocator, @intCast(stat.size));
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "• ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, " echo hi") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "exit=0") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "duration_ms") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "✓") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "\n"));
}

test "tool output inserts blank line between tool blocks" {
    const allocator = std.testing.allocator;
    const current_theme = theme.themeFor(.ansi16, .dark);

    var event_loop: runtime.EventLoop = undefined;
    try event_loop.init(allocator);
    defer event_loop.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("stream_sink_tool_spacing", .{ .read = true });
    defer file.close();

    var sink = StreamSinkCtx.init(allocator, file, &event_loop, current_theme);
    defer sink.deinit();

    StreamSinkCtx.onEvent(&sink, .{
        .tool_exec_start = .{
            .id = "toolu_1",
            .name = "read",
            .arguments = "{\"path\":\"a.txt\"}",
        },
    });
    StreamSinkCtx.onEvent(&sink, .{
        .tool_exec_end = .{
            .id = "toolu_1",
            .name = "read",
            .is_error = false,
            .ui_details = "{}",
        },
    });
    StreamSinkCtx.onEvent(&sink, .{
        .tool_exec_start = .{
            .id = "toolu_2",
            .name = "bash",
            .arguments = "{\"command\":\"echo hi\"}",
        },
    });
    StreamSinkCtx.onEvent(&sink, .{
        .tool_exec_end = .{
            .id = "toolu_2",
            .name = "bash",
            .is_error = false,
            .ui_details = "{}",
        },
    });

    try file.seekTo(0);
    const stat = try file.stat();
    const output = try file.readToEndAlloc(allocator, @intCast(stat.size));
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\n\n\r\x1b[2K") != null);
}

test "markdown output inserts blank line after tool block" {
    const allocator = std.testing.allocator;
    const current_theme = theme.themeFor(.ansi16, .dark);

    var event_loop: runtime.EventLoop = undefined;
    try event_loop.init(allocator);
    defer event_loop.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("stream_sink_markdown_spacing", .{ .read = true });
    defer file.close();

    var sink = StreamSinkCtx.init(allocator, file, &event_loop, current_theme);
    defer sink.deinit();

    StreamSinkCtx.onEvent(&sink, .{
        .tool_exec_start = .{
            .id = "toolu_1",
            .name = "bash",
            .arguments = "{\"command\":\"echo hi\"}",
        },
    });
    StreamSinkCtx.onEvent(&sink, .{
        .tool_exec_end = .{
            .id = "toolu_1",
            .name = "bash",
            .is_error = false,
            .ui_details = "{}",
        },
    });
    StreamSinkCtx.onEvent(&sink, .{ .text_delta = "hello" });
    sink.flushMarkdown();

    try file.seekTo(0);
    const stat = try file.stat();
    const output = try file.readToEndAlloc(allocator, @intCast(stat.size));
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "✓\x1b[0m\n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "hello") != null);
}

test "streaming code block is highlighted before closing fence" {
    const allocator = std.testing.allocator;
    const current_theme = theme.themeFor(.ansi256, .dark);

    var event_loop: runtime.EventLoop = undefined;
    try event_loop.init(allocator);
    defer event_loop.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("stream_sink_code_fence", .{ .read = true });
    defer file.close();

    var sink = StreamSinkCtx.init(allocator, file, &event_loop, current_theme);
    defer sink.deinit();

    StreamSinkCtx.onEvent(&sink, .{ .text_delta = "```zig\n" });
    StreamSinkCtx.onEvent(&sink, .{ .text_delta = "const x: u32 = 1;\n" });
    sink.flushMarkdown();

    try file.seekTo(0);
    const stat = try file.stat();
    const output = try file.readToEndAlloc(allocator, @intCast(stat.size));
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[38;5;") != null);
}

test "throttled text delta flushes at frame deadline" {
    const allocator = std.testing.allocator;
    const current_theme = theme.themeFor(.ansi16, .dark);

    var event_loop: runtime.EventLoop = undefined;
    try event_loop.init(allocator);
    defer event_loop.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("stream_sink_deadline", .{ .read = true });
    defer file.close();

    var sink = StreamSinkCtx.init(allocator, file, &event_loop, current_theme);
    defer sink.deinit();

    sink.last_render_ns = std.time.nanoTimestamp();
    StreamSinkCtx.onEvent(&sink, .{ .text_delta = "deadline flush" });

    try std.testing.expect(waitForMarkdownRender(&sink, 300));
}

test "append-only markdown path updates renderer backbuffer" {
    const allocator = std.testing.allocator;
    const current_theme = theme.themeFor(.ansi16, .dark);

    var event_loop: runtime.EventLoop = undefined;
    try event_loop.init(allocator);
    defer event_loop.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("stream_sink_append", .{ .read = true });
    defer file.close();

    var sink = StreamSinkCtx.init(allocator, file, &event_loop, current_theme);
    defer sink.deinit();

    sink.text_buf.appendSlice(allocator, "hello") catch return error.OutOfMemory;
    sink.doRenderMd();
    const width = markdownRenderWidth();
    try std.testing.expect(sink.has_md_content);
    try std.testing.expectEqual(@as(usize, 5), sink.last_rendered_text_len);

    sink.text_buf.appendSlice(allocator, " world") catch return error.OutOfMemory;
    const used_fast_path = sink.tryRenderMdAppendFastPath(width);
    try std.testing.expect(used_fast_path);
    try std.testing.expectEqualStrings(" hello world", sink.md_renderer.backbuffer.items[0]);
}

test "turn_end flushes markdown and usage prints once on agent_end" {
    const allocator = std.testing.allocator;
    const current_theme = theme.themeFor(.ansi16, .dark);

    var event_loop: runtime.EventLoop = undefined;
    try event_loop.init(allocator);
    defer event_loop.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile("stream_sink_out", .{ .read = true });
    defer file.close();

    var sink = StreamSinkCtx.init(allocator, file, &event_loop, current_theme);
    defer sink.deinit();

    sink.last_render_ns = std.time.nanoTimestamp() + MIN_RENDER_INTERVAL_NS;
    StreamSinkCtx.onEvent(&sink, .{ .text_delta = "hello throttled markdown" });
    try std.testing.expect(sink.render_pending);
    try std.testing.expect(!sink.has_md_content);

    StreamSinkCtx.onEvent(&sink, .{
        .turn_end = .{
            .usage = .{},
            .tool_call_count = 0,
        },
    });
    StreamSinkCtx.onEvent(&sink, .{
        .turn_end = .{
            .usage = .{ .input = 10, .output = 5 },
            .tool_call_count = 1,
        },
    });
    StreamSinkCtx.onEvent(&sink, .{
        .agent_end = .{
            .total_usage = .{ .input = 10, .output = 5 },
            .stop_reason = .complete,
        },
    });

    try std.testing.expect(!sink.render_pending);
    try std.testing.expect(!sink.has_md_content);

    try file.seekTo(0);
    const stat = try file.stat();
    const output = try file.readToEndAlloc(allocator, @intCast(stat.size));
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "hello throttled markdown") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "tokens: 10 in / 5 out") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output, "tokens: "));
}
