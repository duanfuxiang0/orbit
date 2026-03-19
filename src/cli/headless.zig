const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent/root.zig");
const agent_types = @import("../agent/types.zig");
const session_mod = @import("session.zig");
const json_util = @import("../ai/json_util.zig");

pub fn run(
    allocator: std.mem.Allocator,
    agent: *agent_mod.Agent,
    session: *session_mod.Session,
) !void {
    // Session ownership stays with cli.root. This loop only drives stdin/stdout and agent events;
    // the caller persists messages, usage, and updated_at after returning.
    _ = session;

    var stdin_buffer: [4096]u8 = undefined;
    var stdout_buffer: [4096]u8 = undefined;
    var reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
    var writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);

    var sink_ctx = SinkCtx{
        .allocator = allocator,
        .writer = &writer.interface,
    };
    const sink: agent_types.AgentEventSink = .{
        .ctx = &sink_ctx,
        .emit = SinkCtx.onEvent,
    };

    while (try reader.interface.takeDelimiter('\n')) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "/exit")) break;

        agent.prompt(line, &sink, null);
        try writer.interface.flush();
    }
}

pub fn runText(
    allocator: std.mem.Allocator,
    agent: *agent_mod.Agent,
    session: *session_mod.Session,
) !void {
    _ = allocator;
    _ = session;

    var stdin_buffer: [4096]u8 = undefined;
    var stdout_buffer: [4096]u8 = undefined;
    var reader = std.fs.File.stdin().readerStreaming(&stdin_buffer);
    var writer = std.fs.File.stdout().writerStreaming(&stdout_buffer);

    var sink_ctx = TextSinkCtx{
        .writer = &writer.interface,
    };
    const sink: agent_types.AgentEventSink = .{
        .ctx = &sink_ctx,
        .emit = TextSinkCtx.onEvent,
    };

    while (try reader.interface.takeDelimiter('\n')) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "/exit")) break;

        try writer.interface.writeAll("> ");
        try writer.interface.writeAll(line);
        try writer.interface.writeAll("\n");
        try writer.interface.flush();

        agent.prompt(line, &sink, null);
        try writer.interface.writeAll("\n");
        try writer.interface.flush();
    }
}

const SinkCtx = struct {
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,

    fn onEvent(raw_ctx: *anyopaque, event: agent_types.AgentEvent) void {
        const self: *SinkCtx = @ptrCast(@alignCast(raw_ctx));
        const line = serializeEvent(self.allocator, event) catch return;
        defer self.allocator.free(line);

        self.writer.writeAll(line) catch return;
        self.writer.flush() catch return;
    }
};

const TextSinkCtx = struct {
    writer: *std.Io.Writer,

    fn onEvent(raw_ctx: *anyopaque, event: agent_types.AgentEvent) void {
        const self: *TextSinkCtx = @ptrCast(@alignCast(raw_ctx));
        switch (event) {
            .text_delta => |text| {
                self.writer.writeAll(text) catch {};
                self.writer.flush() catch {};
            },
            .thinking_delta => {},
            .tool_exec_start => |payload| {
                self.writer.writeAll("\n[tool ") catch {};
                self.writer.writeAll(payload.name) catch {};
                self.writer.writeAll("]\n") catch {};
                self.writer.flush() catch {};
            },
            .err => |message| {
                self.writer.writeAll("\norbit: ") catch {};
                self.writer.writeAll(message) catch {};
                self.writer.flush() catch {};
            },
            else => {},
        }
    }
};

pub fn serializeEvent(
    allocator: std.mem.Allocator,
    event: agent_types.AgentEvent,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.append(allocator, '{');
    switch (event) {
        .agent_start => try json_util.appendJsonKeyValue(&buf, allocator, "type", "agent_start"),
        .turn_start => try json_util.appendJsonKeyValue(&buf, allocator, "type", "turn_start"),
        .text_delta => |text| {
            try json_util.appendJsonKeyValue(&buf, allocator, "type", "text_delta");
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(&buf, allocator, "text", text);
        },
        .thinking_delta => |text| {
            try json_util.appendJsonKeyValue(&buf, allocator, "type", "thinking_delta");
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(&buf, allocator, "text", text);
        },
        .thinking_signature_delta => |text| {
            try json_util.appendJsonKeyValue(
                &buf,
                allocator,
                "type",
                "thinking_signature_delta",
            );
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(&buf, allocator, "text", text);
        },
        .tool_call_start => |payload| {
            try json_util.appendJsonKeyValue(&buf, allocator, "type", "tool_call_start");
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(&buf, allocator, "id", payload.id);
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(&buf, allocator, "name", payload.name);
        },
        .tool_call_delta => |payload| {
            try json_util.appendJsonKeyValue(&buf, allocator, "type", "tool_call_delta");
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(&buf, allocator, "id", payload.id);
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(&buf, allocator, "args_delta", payload.args_delta);
        },
        .tool_exec_start => |payload| {
            try json_util.appendJsonKeyValue(&buf, allocator, "type", "tool_exec_start");
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(&buf, allocator, "id", payload.id);
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(&buf, allocator, "name", payload.name);
        },
        .tool_exec_end => |payload| {
            try json_util.appendJsonKeyValue(&buf, allocator, "type", "tool_exec_end");
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(&buf, allocator, "id", payload.id);
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(&buf, allocator, "name", payload.name);
            try buf.append(allocator, ',');
            try json_util.appendJsonBool(&buf, allocator, "is_error", payload.is_error);
        },
        .turn_end => |payload| {
            try json_util.appendJsonKeyValue(&buf, allocator, "type", "turn_end");
            try buf.append(allocator, ',');
            try json_util.appendJsonU32(&buf, allocator, "input_tokens", payload.usage.input);
            try buf.append(allocator, ',');
            try json_util.appendJsonU32(&buf, allocator, "output_tokens", payload.usage.output);
            try buf.append(allocator, ',');
            try json_util.appendJsonU32(&buf, allocator, "tool_call_count", payload.tool_call_count);
        },
        .agent_end => |payload| {
            try json_util.appendJsonKeyValue(&buf, allocator, "type", "agent_end");
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(
                &buf,
                allocator,
                "stop_reason",
                switch (payload.stop_reason) {
                    .complete => "complete",
                    .aborted => "aborted",
                    .err => "err",
                },
            );
            try buf.append(allocator, ',');
            try json_util.appendJsonU32(
                &buf,
                allocator,
                "total_input_tokens",
                payload.total_usage.input,
            );
            try buf.append(allocator, ',');
            try json_util.appendJsonU32(
                &buf,
                allocator,
                "total_output_tokens",
                payload.total_usage.output,
            );
        },
        .steering_injected => |text| {
            try json_util.appendJsonKeyValue(&buf, allocator, "type", "steering_injected");
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(&buf, allocator, "text", text);
        },
        .err => |message| {
            try json_util.appendJsonKeyValue(&buf, allocator, "type", "err");
            try buf.append(allocator, ',');
            try json_util.appendJsonKeyValue(&buf, allocator, "message", message);
        },
    }
    try buf.appendSlice(allocator, "}\n");
    return buf.toOwnedSlice(allocator);
}

test "serialize event emits valid json line" {
    const allocator = std.testing.allocator;
    const line = try serializeEvent(allocator, .{ .text_delta = "hello" });
    defer allocator.free(line);

    try std.testing.expect(std.mem.endsWith(u8, line, "\n"));
    const trimmed = std.mem.trimRight(u8, line, "\n");
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("text_delta", parsed.value.object.get("type").?.string);
}
