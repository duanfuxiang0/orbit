# orbit-agent: 代理循环层设计

Status: Draft

Authors:

* Orbit Team

Created: 2026-03-18

Last Updated: 2026-03-18

## Summary

设计并实现 orbit-agent（Layer 2），在 orbit-ai 之上构建完整的代理循环：接收用户消息 → 调用 LLM → 执行工具 → 结果喂回 → 循环直到无工具调用。支持消息队列（steering/follow-up）、全链路 abort、事件驱动 UI 更新。

## Motivation

orbit-ai（Layer 1）提供了统一的 LLM 流式补全接口，但它只负责单次请求-响应。一个 coding agent 需要：

1. **多轮工具循环**：LLM 返回工具调用 → 执行 → 结果喂回 → 再次调用 LLM，直到模型认为任务完成
2. **消息队列**：用户在代理工作时可以排队发送新指令（steering），或在代理完成后追加后续任务（follow-up）
3. **事件流**：UI 层需要细粒度的生命周期事件来渲染流式输出、工具执行状态、回合边界
4. **工具抽象**：统一的工具接口，让上层（Layer 4）注册具体工具实现

当前没有这个编排层，orbit-ai 的调用者必须自己实现循环、工具分发、消息管理——这些逻辑应该封装在一个可测试的独立模块中。

## Goals

- 实现完整的代理循环状态机，可独立于 UI 测试
- 事件驱动架构，所有状态变化通过 AgentEvent 通知
- 消息队列支持 steering（回合中注入）和 follow-up（回合结束后追加）
- 全链路 abort：中断 LLM 流 + 中断工具执行，保留部分结果
- 工具结果分离：给 LLM 的文本内容 vs 给 UI 的结构化详情
- 顺序工具执行（Zig 无 async runtime，且 coding agent 工具天然顺序）
- 零分配热路径：事件分发不分配内存

## Non-Goals

- 并行工具执行（Zig 无 async runtime，复杂度不值得）
- beforeToolCall / afterToolCall 钩子（YOLO 模式，无权限检查）
- 上下文压缩 / compaction（后续 RFC）
- 具体工具实现（read/write/edit/bash 属于 Layer 4）
- 重试 / fallback 逻辑（用户手动重试或切换模型）
- 自定义消息类型扩展（不需要 TypeScript 的 declaration merging）

## Background

### pi-mono agent-loop 分析

`references/pi-mono/packages/agent/src/agent-loop.ts` 实现了完整的代理循环：

- **双层循环**：外层处理 follow-up 消息，内层处理工具调用 + steering 消息
- **事件流**：agent_start → turn_start → message_start → message_update → message_end → tool_execution_start → tool_execution_end → turn_end → agent_end
- **消息队列**：`getSteeringMessages()` 在每个 turn 结束后调用，`getFollowUpMessages()` 在代理即将停止时调用
- **工具执行**：支持 sequential 和 parallel 两种模式，有 beforeToolCall/afterToolCall 钩子
- **convertToLlm**：AgentMessage[] → Message[] 转换，支持自定义消息类型过滤

### 对 Zig 实现的简化

| pi-mono 特性 | orbit-agent 决策 | 原因 |
|-------------|-----------------|------|
| async/await 全链路 | 同步循环 + 回调 | Zig 无 async runtime |
| parallel 工具执行 | 仅 sequential | 复杂度不值得，coding 工具天然顺序 |
| beforeToolCall/afterToolCall | 不做 | YOLO 模式，无权限剧场 |
| AgentMessage 自定义类型 | 直接用 ai.Message | Zig 无 declaration merging |
| EventStream 异步迭代器 | EventSink 同步回调 | 与 orbit-ai 一致 |
| convertToLlm 转换层 | 不需要 | 消息类型统一，无需转换 |

### orbit-ai 已有接口

orbit-agent 直接依赖的 Layer 1 类型：

- `ai.Provider` — vtable 多态 LLM provider
- `ai.Request` — LLM 请求（messages, system, model, tools, max_tokens, temperature）
- `ai.StreamEvent` — 流式事件（text_delta, tool_call_start/delta/done, done, err）
- `ai.EventSink` — 事件回调接口
- `ai.Message` / `ai.ContentPart` — 统一消息格式
- `ai.ToolCall` / `ai.ToolResult` / `ai.ToolSpec` — 工具类型
- `ai.TokenUsage` / `ai.TokenCost` — token 追踪
- `provider.AbortState` — 原子 abort 标志

## Proposal

### 核心循环状态机

```
                    ┌──────────────┐
                    │  idle        │
                    └──────┬───────┘
                           │ prompt() / continueLoop()
                    ┌──────▼───────┐
              ┌────►│  turn_start  │◄──── steering 消息注入
              │     └──────┬───────┘
              │            │ 构建 Request, 调用 Provider.stream()
              │     ┌──────▼───────┐
              │     │  streaming   │──── abort() ──► done(aborted)
              │     └──────┬───────┘
              │            │ stream 结束
              │     ┌──────▼───────┐
              │     │  check_tools │
              │     └──┬───────┬───┘
              │        │       │
              │   有工具调用  无工具调用
              │        │       │
              │  ┌─────▼────┐  │
              │  │ exec_tool │  │
              │  └─────┬────┘  │
              │        │       │
              │  结果喂回ctx   检查 steering 队列
              │        │       │
              └────────┘  ┌────▼─────┐
                          │check_queue│
                          └──┬────┬──┘
                    有消息   │    │ 无消息
                    ┌───────┘    └───────┐
                    │                    │
              回到 turn_start      检查 follow-up
                                        │
                                  ┌─────▼──────┐
                                  │check_followup│
                                  └──┬──────┬──┘
                            有消息   │      │ 无消息
                                     │      │
                              回到 turn_start │
                                        ┌────▼───┐
                                        │  idle  │
                                        └────────┘
```

### 核心类型

```zig
// src/agent/types.zig

const ai = @import("../ai/root.zig");
const std = @import("std");

/// 工具执行结果——分离 LLM 内容和 UI 详情
/// 参考 pi-mono AgentToolResult 的 content/details 分离设计
pub const ToolExecResult = struct {
    /// 喂回 LLM 的文本内容
    content: []const u8,
    /// 是否为错误结果
    is_error: bool = false,
    /// 给 UI 的结构化详情（JSON 字符串，可选）
    /// 例如 edit 工具可以返回 diff 详情供 UI 渲染
    ui_details: ?[]const u8 = null,
};

/// 工具定义——上层注册，agent 循环调用
pub const Tool = struct {
    /// 工具名称（与 ai.ToolSpec.name 对应）
    name: []const u8,
    /// LLM 可见的描述
    description: []const u8,
    /// JSON Schema 字符串，描述参数格式
    parameters_json: []const u8,
    /// 执行函数指针
    execute: *const fn (
        ctx: *anyopaque,
        tool_call_id: []const u8,
        arguments: []const u8,
        abort: *const ai.provider.AbortState,
    ) ToolExecResult,
    /// 执行上下文（闭包捕获）
    ctx: *anyopaque,

    /// 转为 ai.ToolSpec 供 LLM 请求使用
    pub fn toSpec(self: Tool) ai.ToolSpec {
        return .{
            .name = self.name,
            .description = self.description,
            .parameters_json = self.parameters_json,
        };
    }
};

/// 代理事件——驱动 UI 更新
pub const AgentEvent = union(enum) {
    // 代理生命周期
    agent_start,
    agent_end: AgentEndInfo,

    // 回合生命周期
    turn_start,
    turn_end: TurnEndInfo,

    // LLM 流式事件（透传 ai.StreamEvent 的关键部分）
    text_delta: []const u8,
    thinking_delta: []const u8,
    tool_call_start: struct { id: []const u8, name: []const u8 },
    tool_call_delta: struct { id: []const u8, args_delta: []const u8 },

    // 工具执行生命周期
    tool_exec_start: struct { id: []const u8, name: []const u8 },
    tool_exec_end: ToolExecEndInfo,

    // 消息注入
    steering_injected: []const u8,

    // 错误
    err: []const u8,
};

pub const AgentEndInfo = struct {
    total_usage: ai.TokenUsage,
    stop_reason: StopReason,
};

pub const StopReason = enum {
    complete,   // 模型自然结束
    aborted,    // 用户中断
    err,        // 错误终止
};

pub const TurnEndInfo = struct {
    usage: ai.TokenUsage,
    tool_call_count: u32,
};

pub const ToolExecEndInfo = struct {
    id: []const u8,
    name: []const u8,
    is_error: bool,
    ui_details: ?[]const u8,
};

/// 代理事件接收器（与 ai.EventSink 同模式）
pub const AgentEventSink = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, event: AgentEvent) void,

    pub fn send(self: *const AgentEventSink, event: AgentEvent) void {
        self.emit(self.ctx, event);
    }
};

/// 消息队列回调——上层提供，agent 循环在适当时机调用
pub const MessageQueue = struct {
    ctx: *anyopaque,
    /// 回合结束后调用，返回 steering 消息（用户在代理工作时输入的）
    get_steering: *const fn (ctx: *anyopaque) ?[]const u8,
    /// 代理即将停止时调用，返回 follow-up 消息
    get_follow_up: *const fn (ctx: *anyopaque) ?[]const u8,
};
```

### Agent 结构体

```zig
// src/agent/root.zig

const ai = @import("../ai/root.zig");
const types = @import("types.zig");
const std = @import("std");

pub const Agent = struct {
    allocator: std.mem.Allocator,
    provider: ai.Provider,
    model: ai.Model,
    system_prompt: []const u8,
    tools: []const types.Tool,
    abort_state: ai.provider.AbortState,

    // 消息历史（agent 拥有，动态增长）
    messages: std.ArrayList(ai.Message),
    // 累计 token 使用
    total_usage: ai.TokenUsage,

    pub fn init(
        allocator: std.mem.Allocator,
        provider: ai.Provider,
        model: ai.Model,
        system_prompt: []const u8,
        tools: []const types.Tool,
    ) Agent {
        return .{
            .allocator = allocator,
            .provider = provider,
            .model = model,
            .system_prompt = system_prompt,
            .tools = tools,
            .abort_state = .{},
            .messages = std.ArrayList(ai.Message).init(allocator),
            .total_usage = .{},
        };
    }

    /// 发送用户消息，启动代理循环
    pub fn prompt(
        self: *Agent,
        user_message: []const u8,
        sink: *const types.AgentEventSink,
        queue: ?*const types.MessageQueue,
    ) void {
        // 1. 将用户消息追加到 messages
        // 2. 调用 runLoop
        self.appendUserMessage(user_message);
        sink.send(.agent_start);
        self.runLoop(sink, queue);
        sink.send(.{ .agent_end = .{
            .total_usage = self.total_usage,
            .stop_reason = if (self.abort_state.isAborted())
                .aborted
            else
                .complete,
        } });
    }

    /// 中断当前操作
    pub fn abort(self: *Agent) void {
        self.abort_state.abort();
        self.provider.abort();
    }

    /// 切换模型（会话中途）
    pub fn setModel(self: *Agent, provider: ai.Provider, model: ai.Model) void {
        self.provider = provider;
        self.model = model;
    }

    fn runLoop(
        self: *Agent,
        sink: *const types.AgentEventSink,
        queue: ?*const types.MessageQueue,
    ) void {
        while (!self.abort_state.isAborted()) {
            sink.send(.turn_start);

            // 注入 steering 消息
            if (queue) |q| {
                while (q.get_steering(q.ctx)) |steering| {
                    self.appendUserMessage(steering);
                    sink.send(.{ .steering_injected = steering });
                }
            }

            // 构建请求，调用 LLM
            const tool_specs = self.buildToolSpecs();
            const request: ai.Request = .{
                .messages = self.messages.items,
                .system = self.system_prompt,
                .model = self.model.id,
                .tools = if (tool_specs.len > 0) tool_specs else null,
                .max_tokens = self.model.max_output,
            };

            // 收集流式响应
            var collector = StreamCollector.init(sink);
            var ai_sink = collector.eventSink();
            self.provider.stream(
                self.allocator,
                request,
                &ai_sink,
            ) catch |e| {
                sink.send(.{ .err = @errorName(e) });
                sink.send(.{ .turn_end = .{
                    .usage = .{},
                    .tool_call_count = 0,
                } });
                return;
            };

            // 累计 usage
            self.total_usage = addUsage(self.total_usage, collector.usage);

            // 将 assistant 响应追加到消息历史
            self.appendAssistantMessage(collector);

            const tool_calls = collector.tool_calls.items;
            sink.send(.{ .turn_end = .{
                .usage = collector.usage,
                .tool_call_count = @intCast(tool_calls.len),
            } });

            if (tool_calls.len == 0) {
                // 无工具调用——检查队列
                if (queue) |q| {
                    if (q.get_steering(q.ctx)) |steering| {
                        self.appendUserMessage(steering);
                        sink.send(.{ .steering_injected = steering });
                        continue;
                    }
                    if (q.get_follow_up(q.ctx)) |follow_up| {
                        self.appendUserMessage(follow_up);
                        sink.send(.{ .steering_injected = follow_up });
                        continue;
                    }
                }
                break; // 回合结束，无更多消息
            }

            // 顺序执行工具调用
            for (tool_calls) |tool_call| {
                if (self.abort_state.isAborted()) break;
                self.executeTool(tool_call, sink);
            }
        }
    }

    fn executeTool(
        self: *Agent,
        tool_call: ai.ToolCall,
        sink: *const types.AgentEventSink,
    ) void {
        sink.send(.{ .tool_exec_start = .{
            .id = tool_call.id,
            .name = tool_call.name,
        } });

        const result = blk: {
            for (self.tools) |tool| {
                if (std.mem.eql(u8, tool.name, tool_call.name)) {
                    break :blk tool.execute(
                        tool.ctx,
                        tool_call.id,
                        tool_call.arguments,
                        &self.abort_state,
                    );
                }
            }
            break :blk types.ToolExecResult{
                .content = "Tool not found",
                .is_error = true,
            };
        };

        // 将工具结果追加到消息历史
        self.appendToolResult(tool_call.id, result);

        sink.send(.{ .tool_exec_end = .{
            .id = tool_call.id,
            .name = tool_call.name,
            .is_error = result.is_error,
            .ui_details = result.ui_details,
        } });
    }

    // ... appendUserMessage, appendAssistantMessage, appendToolResult,
    //     buildToolSpecs, StreamCollector 等辅助方法
};
```

### StreamCollector——桥接 ai.StreamEvent 到 AgentEvent

```zig
/// 收集 LLM 流式响应，同时转发事件给 AgentEventSink
const StreamCollector = struct {
    agent_sink: *const types.AgentEventSink,
    text_parts: std.ArrayList([]const u8),
    thinking_parts: std.ArrayList([]const u8),
    tool_calls: std.ArrayList(ai.ToolCall),
    usage: ai.TokenUsage,
    stop_reason: ai.StopReason,

    fn init(agent_sink: *const types.AgentEventSink) StreamCollector {
        // ...
    }

    fn eventSink(self: *StreamCollector) ai.EventSink {
        return .{ .ctx = self, .emit = onStreamEvent };
    }

    fn onStreamEvent(ctx: *anyopaque, event: ai.StreamEvent) void {
        const self: *StreamCollector = @ptrCast(@alignCast(ctx));
        switch (event) {
            .text_delta => |d| {
                self.text_parts.append(d) catch {};
                self.agent_sink.send(.{ .text_delta = d });
            },
            .thinking_delta => |d| {
                self.thinking_parts.append(d) catch {};
                self.agent_sink.send(.{ .thinking_delta = d });
            },
            .tool_call_start => |tc| {
                self.agent_sink.send(.{ .tool_call_start = .{
                    .id = tc.id, .name = tc.name,
                } });
            },
            .tool_call_delta => |d| {
                self.agent_sink.send(.{ .tool_call_delta = .{
                    .id = d.id, .args_delta = d.args_delta,
                } });
            },
            .tool_call_done => |tc| {
                self.tool_calls.append(tc) catch {};
            },
            .done => |d| {
                self.usage = d.usage;
                self.stop_reason = d.stop_reason;
            },
            .err => |e| {
                self.agent_sink.send(.{ .err = e.message });
            },
            else => {},
        }
    }
};
```

### 与 pi-mono 的关键差异

| pi-mono agent-loop | orbit-agent | 原因 |
|-------------------|-------------|------|
| `EventStream` 异步迭代器 | `AgentEventSink` 同步回调 | Zig 无 async，与 ai.EventSink 一致 |
| `convertToLlm()` 消息转换 | 直接用 `ai.Message` | 无自定义消息类型，不需要转换层 |
| `transformContext()` 上下文变换 | 不做（后续 compaction RFC） | 保持简单，先不做上下文压缩 |
| `getApiKey()` 动态 key | 不做 | Zig 二进制，key 在启动时确定 |
| parallel 工具执行 | sequential only | Zig 无 async runtime |
| `beforeToolCall` / `afterToolCall` | 不做 | YOLO 模式 |
| `steeringMode: "all" \| "one-at-a-time"` | 全部取出 | 简化，一次取完所有 steering |
| `AgentState` 类 + subscribe | `Agent` struct + EventSink | Zig 风格，无观察者模式 |

### Architecture and Module Ownership

```
src/agent/
├── root.zig       # Agent struct, runLoop, prompt/abort/setModel
├── types.zig      # AgentEvent, Tool, ToolExecResult, MessageQueue, AgentEventSink
└── stream_collector.zig  # StreamCollector: ai.StreamEvent → AgentEvent 桥接
```

边界规则：
- `agent/` 依赖 `ai/`（向下依赖）
- `agent/` 不依赖 `tui/` 或 `cli/`（不向上依赖）
- `agent/` 不做网络 I/O（通过 ai.Provider 间接）
- `agent/` 不做终端 I/O
- 工具执行函数由上层注入，agent 只负责调度

### State and Data Model

**消息历史所有权**：

Agent 拥有 `messages: ArrayList(ai.Message)`。每次 LLM 调用后，assistant 响应被追加；每次工具执行后，tool result 被追加。消息历史在 Agent 生命周期内持续增长。

**不变量**：
- `messages` 中 role 交替：user → assistant → (tool → assistant)* → user → ...
- 每个 `tool_call_done` 事件后一定有对应的 `tool_exec_start` → `tool_exec_end`
- `agent_start` 和 `agent_end` 严格配对
- `turn_start` 和 `turn_end` 严格配对
- abort 后 `agent_end.stop_reason == .aborted`
- `total_usage` 是所有回合 usage 的累加

**Token 追踪**：

```zig
fn addUsage(a: ai.TokenUsage, b: ai.TokenUsage) ai.TokenUsage {
    return .{
        .input = a.input + b.input,
        .output = a.output + b.output,
        .cache_read = a.cache_read + b.cache_read,
        .cache_write = a.cache_write + b.cache_write,
    };
}
```

### Failure Modes and Safety

1. **LLM 请求失败**：`Provider.stream()` 返回 error 或 emit `StreamEvent.err` → 通过 `AgentEvent.err` 通知 UI → 当前回合结束，不自动重试
2. **工具未找到**：返回 `ToolExecResult{ .content = "Tool not found", .is_error = true }` 喂回 LLM，让模型自行修正
3. **工具执行失败**：工具内部捕获错误，返回 `is_error = true` 的结果喂回 LLM
4. **Abort**：
   - `Agent.abort()` 设置 `abort_state` + 调用 `provider.abort()`
   - `runLoop` 每次迭代检查 `abort_state`
   - 工具执行函数接收 `abort_state` 指针，可自行检查
   - abort 后已收集的消息历史保留，`agent_end` 标记 `stop_reason = .aborted`
5. **上下文溢出**：当前不做自动处理。`total_usage.input` 可供上层检查并警告用户

**安全不变量**：
- `runLoop` 无递归，是 `while` 循环
- 工具执行是同步的，不会并发
- `abort_state` 使用 atomic 操作，线程安全
- 所有事件在调用线程同步 emit，无并发竞争

## Impact Analysis

### Application Flow and Runtime

- [x] Process lifecycle (`src/main.zig`) — agent 循环在主线程运行
- [x] Event definitions and routing — AgentEvent 替代旧事件
- [ ] Renderer abstraction
- [x] App-level coordination — 调用 Agent.prompt()
- [x] Background work, subprocesses, or async task handling — 工具可能执行 bash

### UI and Interaction

- [x] Streaming output or incremental updates — AgentEvent 驱动流式渲染
- [ ] Screen layout or rendering
- [ ] Keyboard input or keymaps
- [ ] Navigation, focus, or modal flows
- [ ] Accessibility or readability

### State and Domain Model

- [x] State shape or ownership — Agent 拥有消息历史
- [x] State transitions or invariants — 循环状态机
- [x] Session, message, or task model — ai.Message 消息模型
- [ ] Persistence, serialization, or replay behavior — 属于 Layer 4

### Agent Capabilities

- [x] File system operations — 通过工具间接
- [x] Command execution — 通过 bash 工具间接
- [x] Prompting, planning, or conversation flow — 代理循环核心
- [ ] Tool permissions or safety policy — YOLO 模式
- [ ] Multi-agent or task orchestration

### Reliability and Diagnostics

- [x] Error model and surfaced failures — AgentEvent.err
- [x] Assertions or defensive checks — 循环不变量
- [x] Logging, tracing, or debug views — 事件流可 dump
- [ ] Crash recovery or resume behavior — 属于 Layer 4

### Developer Experience

- [x] Build/test workflow — `zig build test` 覆盖 agent 循环
- [x] Documentation — 本 RFC
- [ ] Configuration or CLI flags — 属于 Layer 4
- [x] Migration away from legacy opencode-zig behavior — 替代旧的 api.zig

## Operational Considerations

### Performance and Resource Use

- **零分配事件路径**：AgentEvent union 内的 slice 指向 StreamCollector 或工具结果拥有的内存，emit 不分配
- **消息历史增长**：ArrayList 动态扩容，长会话可能达到几 MB。上层可通过 `total_usage.input` 监控
- **工具执行开销**：取决于具体工具（bash 可能耗时），agent 循环本身无额外开销
- **循环无上限**：无 max_steps，依赖模型自行停止。Mario 的经验是从未需要限制

### Observability and Debuggability

- AgentEvent 流是完整的执行日志，上层可序列化为 JSON 用于调试
- `total_usage` 提供累计 token 消耗
- 每个 `turn_end` 包含该回合的 usage 和工具调用数
- `tool_exec_end.ui_details` 提供工具执行的结构化详情

### Compatibility and Migration

- 新建模块，不影响现有代码
- 历史上的 `src/api.zig` LLM 调用逻辑已被 agent 循环取代
- 历史上的 `src/state.zig` 消息管理已迁移到 `Agent.messages`
- 历史上的 `src/app_controller.zig` 已从当前仓库移除；会话驱动入口现在由 CLI 层承担

## Testing

- **循环状态机测试**：mock Provider 返回预设响应序列，验证循环正确终止
  - 纯文本响应 → 单回合结束
  - 一次工具调用 → 执行 → 喂回 → 第二回合纯文本 → 结束
  - 多次工具调用 → 顺序执行 → 循环
  - 工具未找到 → 错误结果喂回 LLM
- **Abort 测试**：在流式中 abort → 验证 agent_end.stop_reason == .aborted
- **消息队列测试**：
  - steering 消息在回合间注入
  - follow-up 消息在代理即将停止时注入
  - 无队列时正常结束
- **事件序列测试**：验证事件严格配对（agent_start/end, turn_start/end）
- **Token 累加测试**：多回合 usage 正确累加
- **StreamCollector 测试**：ai.StreamEvent → AgentEvent 映射正确

## Rollout Plan

分三步，每步独立可测试：

1. **Step 1: types.zig** — 纯类型定义（AgentEvent, Tool, ToolExecResult, MessageQueue, AgentEventSink）。可编译，可写类型测试。
2. **Step 2: stream_collector.zig** — StreamCollector 桥接 ai.StreamEvent → AgentEvent。用 mock sink 测试事件映射。
3. **Step 3: root.zig** — Agent struct + runLoop + prompt/abort。用 mock Provider + mock Tool 测试完整循环。

每步完成后运行 `zig build test` 验证。Step 3 完成后，orbit-agent 可在 headless 模式下运行完整代理（配合 Layer 1 的真实 Provider 和 Layer 4 的工具实现）。

## Alternatives Considered

1. **异步代理循环**：放弃。Zig 没有成熟的 async runtime，用 io_uring 或线程池增加大量复杂度，且 coding agent 的工具天然顺序执行（read → edit → test），并行收益极小。

2. **复用 pi-mono 的 EventStream 模式**：放弃。pi-mono 用 async iterator 是因为 TypeScript 的 async/await 生态。Zig 中同步回调（EventSink）更自然，且与 orbit-ai 的 EventSink 模式一致。

3. **加入 beforeToolCall/afterToolCall 钩子**：放弃。0001 RFC 明确 YOLO 模式，不做权限检查。如果未来需要，可以在工具执行函数内部实现，不需要 agent 循环层的钩子。

4. **Agent 作为独立线程运行**：放弃。增加线程同步复杂度。当前设计中 agent 循环在调用线程同步运行，abort 通过 atomic flag 从另一个线程触发。这足够简单且安全。

5. **消息历史由上层管理**：放弃。agent 循环需要在工具执行后追加结果并继续调用 LLM，消息历史必须由 agent 拥有才能保证一致性。上层通过 `Agent.messages` 只读访问。

## Open Questions

1. **消息历史内存管理**：Agent 的 `messages: ArrayList(ai.Message)` 中的 ContentPart slice 谁拥有？StreamCollector 收集的文本需要 dupe 到 Agent 的 allocator 吗？需要明确所有权边界。

2. **工具执行超时**：当前设计中工具执行无超时。bash 工具可能挂起。是否在 agent 层加超时，还是让工具自己处理？倾向于工具自己处理（bash 工具接受 timeout 参数）。

3. **上下文窗口管理**：当 `total_usage.input` 接近 `model.context_window` 时，agent 应该怎么做？当前不做自动处理，但需要设计扩展点。可能的方案：在 `runLoop` 开头检查并 emit 警告事件，让上层决定。

4. **模型切换时的上下文交接**：`setModel()` 切换 provider 后，消息历史中的 thinking traces 需要转换。是否在 `runLoop` 构建 Request 时自动调用 `ai.context.normalizeForProvider()`？

## References

- pi-mono agent-loop 实现：`references/pi-mono/packages/agent/src/agent-loop.ts`
- pi-mono agent 类型定义：`references/pi-mono/packages/agent/src/types.ts`
- pi-mono Agent 类：`references/pi-mono/packages/agent/src/agent.ts`
- orbit-ai 类型：`src/ai/types.zig`
- orbit-ai Provider 接口：`src/ai/provider.zig`
- orbit-ai StreamEvent：`src/ai/stream.zig`
- orbit-ai 上下文交接：`src/ai/context.zig`
- 四层架构 RFC：`rfcs/0001-four-layer-architecture.md`
- orbit-ai RFC：`rfcs/0002-orbit-ai-layer.md`
- Mario Zechner 文章：https://mariozechner.at/posts/2025-11-30-pi-coding-agent/
