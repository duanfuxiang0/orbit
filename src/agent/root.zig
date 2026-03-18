const ai = @import("../ai/root.zig");
const std = @import("std");
const stream_collector = @import("stream_collector.zig");
const types = @import("types.zig");

pub const Agent = struct {
    allocator: std.mem.Allocator,
    provider: ai.Provider,
    model: ai.Model,
    system_prompt: []const u8,
    tools: []const types.Tool,
    abort_state: ai.provider.AbortState = .{},
    messages: std.ArrayListUnmanaged(ai.Message) = .empty,
    total_usage: ai.TokenUsage = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        provider: ai.Provider,
        model: ai.Model,
        system_prompt: []const u8,
        tools: []const types.Tool,
    ) Agent {
        std.debug.assert(model.id.len > 0);
        return .{
            .allocator = allocator,
            .provider = provider,
            .model = model,
            .system_prompt = system_prompt,
            .tools = tools,
        };
    }

    pub fn deinit(self: *Agent) void {
        for (self.messages.items) |message| {
            ai.context.freeMessage(self.allocator, message);
        }
        self.messages.deinit(self.allocator);
    }

    pub fn prompt(
        self: *Agent,
        user_message: []const u8,
        sink: *const types.AgentEventSink,
        queue: ?*const types.MessageQueue,
    ) void {
        std.debug.assert(@intFromPtr(sink.ctx) != 0);
        std.debug.assert(user_message.len > 0);
        std.debug.assert(self.model.id.len > 0);

        self.abort_state.reset();
        sink.send(.agent_start);

        self.appendUserMessage(user_message) catch |err| {
            sink.send(.{ .err = @errorName(err) });
            sink.send(.{
                .agent_end = .{
                    .total_usage = self.total_usage,
                    .stop_reason = .err,
                },
            });
            return;
        };

        const reason = self.runLoop(sink, queue);
        sink.send(.{
            .agent_end = .{
                .total_usage = self.total_usage,
                .stop_reason = reason,
            },
        });
    }

    pub fn abort(self: *Agent) void {
        self.abort_state.abort();
        self.provider.abort();
    }

    pub fn setModel(self: *Agent, provider: ai.Provider, model: ai.Model) void {
        std.debug.assert(model.id.len > 0);
        self.provider = provider;
        self.model = model;
        // No in-place history rewrite here. Each provider normalizes request messages via
        // ai.context.normalizeForProvider() right before serialization.
    }

    fn runLoop(
        self: *Agent,
        sink: *const types.AgentEventSink,
        queue: ?*const types.MessageQueue,
    ) types.StopReason {
        std.debug.assert(@intFromPtr(sink.ctx) != 0);
        while (true) {
            std.debug.assert(self.messages.items.len > 0);
            if (self.abort_state.isAborted()) return .aborted;
            sink.send(.turn_start);

            if (queue) |q| {
                _ = self.injectSteeringMessages(q, sink) catch {
                    sink.send(.{ .err = "OutOfMemory" });
                    sink.send(.{ .turn_end = .{ .usage = .{}, .tool_call_count = 0 } });
                    return .err;
                };
            }

            var outcome = self.executeTurn(sink);
            defer outcome.deinit(self.allocator);

            switch (outcome.next) {
                .aborted => return .aborted,
                .err => return .err,
                .execute_tools => {
                    for (outcome.tool_calls.items) |tool_call| {
                        if (self.abort_state.isAborted()) return .aborted;
                        self.executeTool(tool_call, sink) catch {
                            sink.send(.{ .err = "OutOfMemory" });
                            return .err;
                        };
                    }
                },
                .check_queue => {
                    if (queue) |q| {
                        const injected = self.injectSteeringMessages(q, sink) catch {
                            sink.send(.{ .err = "OutOfMemory" });
                            return .err;
                        };
                        if (injected) continue;

                        if (q.get_follow_up(q.ctx)) |follow_up| {
                            self.appendUserMessage(follow_up) catch {
                                sink.send(.{ .err = "OutOfMemory" });
                                return .err;
                            };
                            sink.send(.{ .steering_injected = follow_up });
                            continue;
                        }
                    }
                    return .complete;
                },
            }
        }
    }

    fn injectSteeringMessages(
        self: *Agent,
        queue: *const types.MessageQueue,
        sink: *const types.AgentEventSink,
    ) !bool {
        std.debug.assert(@intFromPtr(queue.ctx) != 0);
        std.debug.assert(@intFromPtr(sink.ctx) != 0);
        var injected = false;
        while (queue.get_steering(queue.ctx)) |message| {
            try self.appendUserMessage(message);
            sink.send(.{ .steering_injected = message });
            injected = true;
        }
        return injected;
    }

    fn executeTurn(self: *Agent, sink: *const types.AgentEventSink) TurnOutcome {
        std.debug.assert(self.messages.items.len > 0);
        std.debug.assert(self.model.id.len > 0);
        var collector = stream_collector.StreamCollector.init(self.allocator, sink);
        defer collector.deinit();

        const tool_specs = self.buildToolSpecs() catch {
            sink.send(.{ .err = "OutOfMemory" });
            sink.send(.{ .turn_end = .{ .usage = .{}, .tool_call_count = 0 } });
            return .{ .next = .err };
        };
        defer if (tool_specs.len > 0) self.allocator.free(tool_specs);

        const request: ai.Request = .{
            .messages = self.messages.items,
            .system = if (self.system_prompt.len > 0) self.system_prompt else null,
            .model = self.model.id,
            .tools = if (tool_specs.len > 0) tool_specs else null,
            .max_tokens = self.model.max_output,
            .temperature = 0.0,
        };

        var ai_sink = collector.eventSink();
        self.provider.stream(self.allocator, request, &ai_sink) catch |err| {
            sink.send(.{ .err = @errorName(err) });
            sink.send(.{ .turn_end = .{ .usage = .{}, .tool_call_count = 0 } });
            if (self.abort_state.isAborted()) return .{ .next = .aborted };
            return .{ .next = .err };
        };

        self.total_usage = addUsage(self.total_usage, collector.usage);
        self.appendAssistantMessage(&collector) catch {
            sink.send(.{ .err = "OutOfMemory" });
            sink.send(.{ .turn_end = .{ .usage = collector.usage, .tool_call_count = 0 } });
            return .{ .next = .err };
        };

        var outcome: TurnOutcome = .{
            .usage = collector.usage,
        };
        // Move ownership out of collector before it deinitializes at scope exit.
        outcome.tool_calls = collector.takeToolCalls();

        sink.send(.{
            .turn_end = .{
                .usage = collector.usage,
                .tool_call_count = @as(u32, @intCast(outcome.tool_calls.items.len)),
            },
        });

        if (self.abort_state.isAborted()) {
            outcome.next = .aborted;
            return outcome;
        }
        if (collector.stop_reason == .aborted) {
            outcome.next = .aborted;
            return outcome;
        }
        if (collector.had_error) {
            outcome.next = .err;
            return outcome;
        }
        if (outcome.tool_calls.items.len == 0) {
            outcome.next = .check_queue;
            return outcome;
        }
        outcome.next = .execute_tools;
        return outcome;
    }

    fn executeTool(
        self: *Agent,
        tool_call: ai.ToolCall,
        sink: *const types.AgentEventSink,
    ) !void {
        std.debug.assert(@intFromPtr(sink.ctx) != 0);
        std.debug.assert(tool_call.id.len > 0);
        std.debug.assert(tool_call.name.len > 0);
        sink.send(.{
            .tool_exec_start = .{
                .id = tool_call.id,
                .name = tool_call.name,
            },
        });

        const result = self.runTool(tool_call);
        try self.appendToolResult(tool_call.id, result);

        sink.send(.{
            .tool_exec_end = .{
                .id = tool_call.id,
                .name = tool_call.name,
                .is_error = result.is_error,
                .ui_details = result.ui_details,
            },
        });
    }

    fn runTool(self: *Agent, tool_call: ai.ToolCall) types.ToolExecResult {
        std.debug.assert(tool_call.id.len > 0);
        std.debug.assert(tool_call.name.len > 0);
        for (self.tools) |tool| {
            if (std.mem.eql(u8, tool.name, tool_call.name)) {
                std.debug.assert(@intFromPtr(tool.ctx) != 0);
                return tool.execute(
                    tool.ctx,
                    tool_call.id,
                    tool_call.arguments,
                    &self.abort_state,
                );
            }
        }
        return .{
            .content = "Tool not found",
            .is_error = true,
        };
    }

    fn buildToolSpecs(self: *const Agent) ![]ai.ToolSpec {
        if (self.tools.len == 0) return &.{};

        const specs = try self.allocator.alloc(ai.ToolSpec, self.tools.len);
        for (self.tools, 0..) |tool, i| {
            specs[i] = tool.toSpec();
        }
        return specs;
    }

    fn appendUserMessage(self: *Agent, user_message: []const u8) !void {
        std.debug.assert(user_message.len > 0);
        const text = try self.allocator.dupe(u8, user_message);
        errdefer self.allocator.free(text);

        const parts = try self.allocator.alloc(ai.ContentPart, 1);
        parts[0] = .{ .text = text };
        try self.appendOwnedMessage(.user, parts);
    }

    fn appendToolResult(
        self: *Agent,
        tool_call_id: []const u8,
        result: types.ToolExecResult,
    ) !void {
        std.debug.assert(tool_call_id.len > 0);
        const id_copy = try self.allocator.dupe(u8, tool_call_id);
        errdefer self.allocator.free(id_copy);
        const content_copy = try self.allocator.dupe(u8, result.content);
        errdefer self.allocator.free(content_copy);

        const parts = try self.allocator.alloc(ai.ContentPart, 1);
        parts[0] = .{
            .tool_result = .{
                .tool_call_id = id_copy,
                .content = content_copy,
                .is_error = result.is_error,
            },
        };
        try self.appendOwnedMessage(.tool, parts);
    }

    fn appendAssistantMessage(
        self: *Agent,
        collector: *const stream_collector.StreamCollector,
    ) !void {
        std.debug.assert(@intFromPtr(collector) != 0);
        const has_text = collector.text.items.len > 0;
        const has_thinking = collector.thinking.items.len > 0;
        if (collector.thinking_signature.items.len > 0) std.debug.assert(has_thinking);
        const tool_count = collector.tool_calls.items.len;
        const part_count = @as(usize, @intFromBool(has_text)) +
            @as(usize, @intFromBool(has_thinking)) + tool_count;
        // Some providers can end a turn without emitting text/thinking/tool calls.
        // We intentionally skip appending an empty assistant message and keep history compact.
        if (part_count == 0) return;

        const parts = try self.allocator.alloc(ai.ContentPart, part_count);
        var initialized: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < initialized) : (i += 1) {
                ai.context.freePart(self.allocator, parts[i]);
            }
            self.allocator.free(parts);
        }

        if (has_text) {
            const text_copy = try self.allocator.dupe(u8, collector.text.items);
            parts[initialized] = .{ .text = text_copy };
            initialized += 1;
        }

        if (has_thinking) {
            const thinking_text = try self.allocator.dupe(u8, collector.thinking.items);
            errdefer self.allocator.free(thinking_text);
            const signature = if (collector.thinking_signature.items.len > 0)
                try self.allocator.dupe(u8, collector.thinking_signature.items)
            else
                null;

            parts[initialized] = .{
                .thinking = .{
                    .text = thinking_text,
                    .signature = signature,
                },
            };
            initialized += 1;
        }

        for (collector.tool_calls.items) |tool_call| {
            parts[initialized] = .{
                .tool_call = try dupeToolCall(self.allocator, tool_call),
            };
            initialized += 1;
        }

        try self.appendOwnedMessage(.assistant, parts);
    }

    fn appendOwnedMessage(self: *Agent, role: ai.Role, parts: []ai.ContentPart) !void {
        std.debug.assert(parts.len > 0);
        self.messages.append(self.allocator, .{
            .role = role,
            .content = parts,
        }) catch |err| {
            for (parts) |part| ai.context.freePart(self.allocator, part);
            self.allocator.free(parts);
            return err;
        };
    }
};

const TurnNext = enum {
    execute_tools,
    check_queue,
    aborted,
    err,
};

const TurnOutcome = struct {
    next: TurnNext = .check_queue,
    usage: ai.TokenUsage = .{},
    tool_calls: std.ArrayListUnmanaged(ai.ToolCall) = .empty,

    fn deinit(self: *TurnOutcome, allocator: std.mem.Allocator) void {
        for (self.tool_calls.items) |tool_call| {
            stream_collector.freeToolCall(allocator, tool_call);
        }
        self.tool_calls.deinit(allocator);
    }
};

pub fn addUsage(a: ai.TokenUsage, b: ai.TokenUsage) ai.TokenUsage {
    return .{
        .input = a.input + b.input,
        .output = a.output + b.output,
        .cache_read = a.cache_read + b.cache_read,
        .cache_write = a.cache_write + b.cache_write,
    };
}

fn dupeToolCall(allocator: std.mem.Allocator, tool_call: ai.ToolCall) !ai.ToolCall {
    const id = try allocator.dupe(u8, tool_call.id);
    errdefer allocator.free(id);

    const name = try allocator.dupe(u8, tool_call.name);
    errdefer allocator.free(name);

    const arguments = try allocator.dupe(u8, tool_call.arguments);
    errdefer allocator.free(arguments);

    return .{
        .id = id,
        .name = name,
        .arguments = arguments,
    };
}

test "agent completes plain text turn" {
    const done = ai.StreamEvent{
        .done = .{
            .usage = .{ .input = 10, .output = 4 },
            .stop_reason = .end_turn,
        },
    };
    const turn_events = [_]ai.StreamEvent{
        .{ .text_delta = "hello" },
        done,
    };
    const turns = [_]FakeTurn{
        .{ .events = &turn_events },
    };

    var provider = FakeProvider.init(&turns);
    var agent = Agent.init(
        std.testing.allocator,
        provider.asProvider(),
        ai.models.registry.gpt4o,
        "system",
        &.{},
    );
    defer agent.deinit();

    var events: EventCapture = .{};
    const sink = events.sink();
    agent.prompt("hi", &sink, null);

    try std.testing.expectEqual(@as(u32, 1), events.agent_start_count);
    try std.testing.expectEqual(@as(u32, 1), events.agent_end_count);
    try std.testing.expectEqual(types.StopReason.complete, events.last_reason.?);
    try std.testing.expectEqual(@as(u32, 1), events.turn_start_count);
    try std.testing.expectEqual(@as(u32, 1), events.turn_end_count);
    try std.testing.expectEqual(@as(usize, 2), agent.messages.items.len);
    try std.testing.expectEqualStrings("hello", agent.messages.items[1].content[0].text);
    try std.testing.expectEqual(@as(u32, 10), agent.total_usage.input);
    try std.testing.expectEqual(@as(u32, 4), agent.total_usage.output);
}

test "agent executes tool call and continues loop" {
    const turn1_events = [_]ai.StreamEvent{
        .{ .tool_call_start = .{ .id = "call_1", .name = "echo" } },
        .{ .tool_call_delta = .{ .id = "call_1", .args_delta = "{\"q\":" } },
        .{
            .tool_call_done = .{
                .id = "call_1",
                .name = "echo",
                .arguments = "{\"q\":\"x\"}",
            },
        },
        .{
            .done = .{
                .usage = .{ .input = 5, .output = 3 },
                .stop_reason = .tool_use,
            },
        },
    };
    const turn2_events = [_]ai.StreamEvent{
        .{ .text_delta = "done" },
        .{
            .done = .{
                .usage = .{ .input = 6, .output = 2 },
                .stop_reason = .end_turn,
            },
        },
    };
    const turns = [_]FakeTurn{
        .{ .events = &turn1_events },
        .{ .events = &turn2_events },
    };

    var tool_ctx = EchoToolCtx{};
    const tools = [_]types.Tool{
        .{
            .name = "echo",
            .description = "Echo tool",
            .parameters_json = "{\"type\":\"object\"}",
            .execute = EchoToolCtx.execute,
            .ctx = &tool_ctx,
        },
    };

    var provider = FakeProvider.init(&turns);
    var agent = Agent.init(
        std.testing.allocator,
        provider.asProvider(),
        ai.models.registry.gpt4o,
        "system",
        &tools,
    );
    defer agent.deinit();

    var events: EventCapture = .{};
    const sink = events.sink();
    agent.prompt("run tool", &sink, null);

    try std.testing.expectEqual(@as(u32, 1), tool_ctx.calls);
    try std.testing.expectEqual(@as(u32, 2), events.turn_start_count);
    try std.testing.expectEqual(@as(u32, 2), events.turn_end_count);
    try std.testing.expectEqual(@as(u32, 1), events.tool_exec_start_count);
    try std.testing.expectEqual(@as(u32, 1), events.tool_exec_end_count);
    try std.testing.expectEqual(types.StopReason.complete, events.last_reason.?);
    try std.testing.expectEqual(@as(u32, 11), agent.total_usage.input);
    try std.testing.expectEqual(@as(u32, 5), agent.total_usage.output);

    try std.testing.expectEqual(@as(usize, 4), agent.messages.items.len);
    try std.testing.expect(agent.messages.items[1].content[0] == .tool_call);
    try std.testing.expect(agent.messages.items[2].content[0] == .tool_result);
    try std.testing.expectEqualStrings("tool-ok", agent.messages.items[2].content[0].tool_result.content);
}

test "missing tool produces error tool_result" {
    const turn1_events = [_]ai.StreamEvent{
        .{ .tool_call_start = .{ .id = "call_2", .name = "missing_tool" } },
        .{
            .tool_call_done = .{
                .id = "call_2",
                .name = "missing_tool",
                .arguments = "{}",
            },
        },
        .{
            .done = .{
                .usage = .{},
                .stop_reason = .tool_use,
            },
        },
    };
    const turn2_events = [_]ai.StreamEvent{
        .{
            .done = .{
                .usage = .{},
                .stop_reason = .end_turn,
            },
        },
    };
    const turns = [_]FakeTurn{
        .{ .events = &turn1_events },
        .{ .events = &turn2_events },
    };

    var provider = FakeProvider.init(&turns);
    var agent = Agent.init(
        std.testing.allocator,
        provider.asProvider(),
        ai.models.registry.gpt4o,
        "system",
        &.{},
    );
    defer agent.deinit();

    var events: EventCapture = .{};
    const sink = events.sink();
    agent.prompt("run unknown", &sink, null);

    try std.testing.expectEqual(@as(usize, 3), agent.messages.items.len);
    try std.testing.expect(agent.messages.items[2].content[0] == .tool_result);
    const result = agent.messages.items[2].content[0].tool_result;
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("Tool not found", result.content);
}

test "abort during stream stops provider emission and marks aborted end" {
    const turn_events = [_]ai.StreamEvent{
        .{ .text_delta = "in-flight" },
        .{
            .done = .{
                .usage = .{},
                .stop_reason = .end_turn,
            },
        },
    };
    const turns = [_]FakeTurn{
        .{ .events = &turn_events },
    };

    var provider = FakeProvider.init(&turns);
    var agent = Agent.init(
        std.testing.allocator,
        provider.asProvider(),
        ai.models.registry.gpt4o,
        "system",
        &.{},
    );
    defer agent.deinit();

    var events = AbortOnTextCapture{
        .agent = &agent,
    };
    const sink = events.sink();
    agent.prompt("abort me", &sink, null);

    try std.testing.expectEqual(types.StopReason.aborted, events.last_reason.?);
    try std.testing.expectEqual(@as(u32, 1), provider.abort_calls);
}

test "follow up queue message triggers another turn" {
    const turn_events = [_]ai.StreamEvent{
        .{
            .done = .{
                .usage = .{},
                .stop_reason = .end_turn,
            },
        },
    };
    const turns = [_]FakeTurn{
        .{ .events = &turn_events },
        .{ .events = &turn_events },
    };

    var queue_ctx = QueueCtx{
        .follow_up_messages = &.{"next task"},
    };
    const queue: types.MessageQueue = .{
        .ctx = &queue_ctx,
        .get_steering = QueueCtx.getSteering,
        .get_follow_up = QueueCtx.getFollowUp,
    };

    var provider = FakeProvider.init(&turns);
    var agent = Agent.init(
        std.testing.allocator,
        provider.asProvider(),
        ai.models.registry.gpt4o,
        "system",
        &.{},
    );
    defer agent.deinit();

    var events: EventCapture = .{};
    const sink = events.sink();
    agent.prompt("start", &sink, &queue);

    try std.testing.expectEqual(@as(u32, 2), events.turn_start_count);
    try std.testing.expectEqual(@as(u32, 2), events.turn_end_count);
    try std.testing.expectEqual(@as(u32, 1), events.steering_injected_count);
    try std.testing.expectEqual(@as(usize, 2), agent.messages.items.len);
    try std.testing.expectEqualStrings("start", agent.messages.items[0].content[0].text);
    try std.testing.expectEqualStrings("next task", agent.messages.items[1].content[0].text);
}

const FakeTurn = struct {
    events: []const ai.StreamEvent,
    fail: ?anyerror = null,
};

const FakeProvider = struct {
    turns: []const FakeTurn,
    index: usize = 0,
    abort_calls: u32 = 0,
    aborted: bool = false,

    fn init(turns: []const FakeTurn) FakeProvider {
        return .{ .turns = turns };
    }

    fn asProvider(self: *FakeProvider) ai.Provider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn streamImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ai.Request,
        sink: *ai.EventSink,
    ) !void {
        _ = allocator;
        std.debug.assert(request.model.len > 0);

        const self: *FakeProvider = @ptrCast(@alignCast(ptr));
        if (self.index >= self.turns.len) return error.NoMoreTurns;
        const turn = self.turns[self.index];
        self.index += 1;

        if (turn.fail) |err| return err;
        for (turn.events) |event| {
            if (self.aborted) return;
            sink.send(event);
        }
    }

    fn abortImpl(ptr: *anyopaque) void {
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));
        self.abort_calls += 1;
        self.aborted = true;
    }

    fn nameImpl(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "fake";
    }

    fn deinitImpl(ptr: *anyopaque) void {
        _ = ptr;
    }

    const vtable: ai.Provider.VTable = .{
        .stream = streamImpl,
        .abort = abortImpl,
        .name = nameImpl,
        .deinit = deinitImpl,
    };
};

const EchoToolCtx = struct {
    calls: u32 = 0,

    fn execute(
        ctx: *anyopaque,
        tool_call_id: []const u8,
        arguments: []const u8,
        abort: *const ai.provider.AbortState,
    ) types.ToolExecResult {
        _ = tool_call_id;
        _ = arguments;
        _ = abort;
        const self: *EchoToolCtx = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return .{
            .content = "tool-ok",
            .is_error = false,
        };
    }
};

const EventCapture = struct {
    agent_start_count: u32 = 0,
    agent_end_count: u32 = 0,
    turn_start_count: u32 = 0,
    turn_end_count: u32 = 0,
    tool_exec_start_count: u32 = 0,
    tool_exec_end_count: u32 = 0,
    steering_injected_count: u32 = 0,
    last_reason: ?types.StopReason = null,

    fn sink(self: *EventCapture) types.AgentEventSink {
        return .{
            .ctx = self,
            .emit = onEvent,
        };
    }

    fn onEvent(ctx: *anyopaque, event: types.AgentEvent) void {
        const self: *EventCapture = @ptrCast(@alignCast(ctx));
        switch (event) {
            .agent_start => self.agent_start_count += 1,
            .agent_end => |info| {
                self.agent_end_count += 1;
                self.last_reason = info.stop_reason;
            },
            .turn_start => self.turn_start_count += 1,
            .turn_end => self.turn_end_count += 1,
            .tool_exec_start => self.tool_exec_start_count += 1,
            .tool_exec_end => self.tool_exec_end_count += 1,
            .steering_injected => self.steering_injected_count += 1,
            else => {},
        }
    }
};

const AbortOnTextCapture = struct {
    agent: *Agent,
    aborted_once: bool = false,
    last_reason: ?types.StopReason = null,

    fn sink(self: *AbortOnTextCapture) types.AgentEventSink {
        return .{
            .ctx = self,
            .emit = onEvent,
        };
    }

    fn onEvent(ctx: *anyopaque, event: types.AgentEvent) void {
        const self: *AbortOnTextCapture = @ptrCast(@alignCast(ctx));
        switch (event) {
            .text_delta => {
                if (!self.aborted_once) {
                    self.aborted_once = true;
                    self.agent.abort();
                }
            },
            .agent_end => |info| self.last_reason = info.stop_reason,
            else => {},
        }
    }
};

const QueueCtx = struct {
    steering_messages: []const []const u8 = &.{},
    follow_up_messages: []const []const u8 = &.{},
    steering_index: usize = 0,
    follow_up_index: usize = 0,

    fn getSteering(ctx: *anyopaque) ?[]const u8 {
        const self: *QueueCtx = @ptrCast(@alignCast(ctx));
        if (self.steering_index >= self.steering_messages.len) return null;
        const message = self.steering_messages[self.steering_index];
        self.steering_index += 1;
        return message;
    }

    fn getFollowUp(ctx: *anyopaque) ?[]const u8 {
        const self: *QueueCtx = @ptrCast(@alignCast(ctx));
        if (self.follow_up_index >= self.follow_up_messages.len) return null;
        const message = self.follow_up_messages[self.follow_up_index];
        self.follow_up_index += 1;
        return message;
    }
};
