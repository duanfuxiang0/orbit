# orbit-ai: 统一 LLM API 层设计

Status: Draft

Authors:

* Orbit Team

Created: 2026-03-18

Last Updated: 2026-03-18

## Summary

从零构建 orbit-ai（Layer 1），以 nullclaw `root.zig` 核心类型为参考起点，提供统一的多 provider LLM 流式补全接口。不复用 nullclaw 代码，原因是其 curl 子进程 HTTP、平台耦合、缺少 abort/渐进解析等关键能力。

## Motivation

nullclaw provider 层分析结论（详见调研记录）：

- **curl 子进程做 HTTP**：workaround for Zig std.http.Client bugs，每次请求 fork 进程，依赖系统 curl
- **无 abort 支持**：kill curl 进程无法获得精确的部分结果状态
- **无渐进式 JSON 解析**：工具调用参数只能在流结束后获得完整 JSON
- **平台耦合**：config_types.zig 拉入 security/policy、sandbox、audio、tunnel 等 nullclaw 平台概念
- **700KB 代码量**：orbit-ai 目标 ~150KB，只需 Anthropic + OpenAI 两个 provider

nullclaw `root.zig` 的核心类型设计（ContentPart、ChatMessage、Provider vtable）是干净的，值得作为起点。

## Goals

- 统一接口覆盖 Anthropic Messages API 和 OpenAI Completions API
- 全链路 abort 支持（任何阶段可中断，返回部分结果）
- SSE 流式 + 工具调用参数渐进式 JSON 解析
- 跨 provider 上下文交接（thinking traces 转换）
- 类型安全的模型注册表
- Token/cost 追踪
- 零外部依赖（不依赖 curl，用 Zig 原生 HTTP）

## Non-Goals

- Google Generative AI API（Phase 1 不做，后续扩展）
- OpenAI Responses API（先做 Completions，后续加）
- 重试/fallback 逻辑（上层 orbit-agent 处理）
- Provider 自动发现或复杂路由
- 浏览器兼容（Zig 原生二进制，不需要）

## Background

### nullclaw 可参考的类型设计

来自 `references/nullclaw/src/providers/root.zig`：

```zig
// 这些类型设计干净，可作为 orbit-ai 起点
pub const ContentPart = union(enum) {
    text: []const u8,
    image_url: ImageUrl,
    image_base64: ImageBase64,
};

pub const ChatMessage = struct {
    role: Role,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    content_parts: ?[]const ContentPart = null,
};

pub const Provider = struct {  // vtable-based polymorphism
    ptr: *anyopaque,
    vtable: *const VTable,
};
```

### nullclaw 不可复用的部分

| 问题 | 影响 |
|------|------|
| `http_util.zig` 用 curl 子进程 | 每次请求 fork，无法精确 abort |
| `config_types.zig` 耦合平台 | 拉入 AutonomyLevel、SandboxBackend、AudioMediaConfig |
| `api_key.zig` 依赖 `auth.zig` | nullclaw 认证系统 |
| `sse.zig` 绑定 curl stdout | 无法用 Zig 原生 HTTP 流 |
| `compatible.zig` 93KB | 几十个 provider 怪癖，我们不需要 |

### pi-ai 的关键设计（来自 Mario 文章）

- 4 套 API 协议：OpenAI Completions/Responses、Anthropic Messages、Google Generative AI
- Provider 怪癖内部处理（Cerebras 无 `store`、Mistral 用 `max_tokens`）
- AbortController 全链路中断
- 流式中渐进解析工具调用 JSON
- 上下文交接：thinking traces → `<thinking>` 标签
- 结构化分离工具结果（LLM 部分 vs UI 部分）

## Proposal

### 核心类型

基于 nullclaw `root.zig` 精简和扩展：

```zig
// src/ai/types.zig

pub const Role = enum { system, user, assistant, tool };

pub const ContentPart = union(enum) {
    text: []const u8,
    image_url: struct { url: []const u8 },
    image_base64: struct { data: []const u8, media_type: []const u8 },
    tool_call: ToolCall,
    tool_result: ToolResult,
};

pub const Message = struct {
    role: Role,
    content: []const ContentPart,
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,  // JSON string
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
};
```

### 与 nullclaw 类型的关键差异

| nullclaw | orbit-ai | 原因 |
|----------|----------|------|
| `ChatMessage.content: []const u8` + 可选 `content_parts` | `Message.content: []const ContentPart` | 统一表示，不需要两个字段 |
| 无 `tool_call` / `tool_result` 在 ContentPart 中 | ContentPart 包含 tool_call/tool_result | 消息内容统一建模 |
| `TokenUsage` 只有 prompt/completion/total | 加 cache_read/cache_write | 支持 Anthropic prompt caching |
| 无 TokenCost | 加 TokenCost | 支持费用追踪 |
| `StreamChunk` 简单 delta | `StreamEvent` 细分 union | 支持渐进式工具调用解析 |

### 模型注册表

```zig
// src/ai/models.zig

pub const ApiProtocol = enum {
    anthropic_messages,
    openai_completions,
};

pub const Model = struct {
    id: []const u8,           // "claude-sonnet-4-20250514"
    name: []const u8,         // "Claude Sonnet 4"
    protocol: ApiProtocol,
    provider: []const u8,     // "anthropic"
    base_url: ?[]const u8,    // null = 用默认
    context_window: u32,      // 200000
    max_output: u32,          // 8192
    supports_vision: bool,
    supports_thinking: bool,
    cost: TokenCost,
};

/// 内置模型定义
pub const registry = struct {
    pub const claude_sonnet = Model{
        .id = "claude-sonnet-4-20250514",
        .name = "Claude Sonnet 4",
        .protocol = .anthropic_messages,
        .provider = "anthropic",
        .base_url = null,
        .context_window = 200_000,
        .max_output = 8192,
        .supports_vision = true,
        .supports_thinking = true,
        .cost = .{ .input_per_million = 3.0, .output_per_million = 15.0 },
    };

    pub const gpt4o = Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .protocol = .openai_completions,
        .provider = "openai",
        .base_url = null,
        .context_window = 128_000,
        .max_output = 16384,
        .supports_vision = true,
        .supports_thinking = false,
        .cost = .{ .input_per_million = 2.5, .output_per_million = 10.0 },
    };
};
```

### 流式事件（vs nullclaw 的 StreamChunk）

nullclaw 的 `StreamChunk` 只有 `delta: []const u8` + `is_final: bool`，无法区分文本、thinking、工具调用。orbit-ai 用细粒度 union：

```zig
// src/ai/stream.zig

pub const StreamEvent = union(enum) {
    /// 文本内容增量
    text_delta: []const u8,
    /// Thinking/reasoning 增量
    thinking_delta: []const u8,
    /// 工具调用开始（id + name 已知）
    tool_call_start: struct { id: []const u8, name: []const u8 },
    /// 工具调用参数增量（渐进式 JSON）
    tool_call_delta: struct { id: []const u8, args_delta: []const u8 },
    /// 工具调用完成（完整参数）
    tool_call_done: ToolCall,
    /// 流结束
    done: struct { usage: TokenUsage, stop_reason: StopReason },
    /// 错误
    err: StreamError,
};

pub const StopReason = enum {
    end_turn,
    tool_use,
    max_tokens,
    aborted,
};

pub const StreamError = struct {
    kind: ErrorKind,
    message: []const u8,
};

pub const ErrorKind = enum {
    rate_limited,
    context_exhausted,
    auth_failed,
    network,
    timeout,
    other,
};
```

### Provider 接口

简化 nullclaw 的 vtable，去掉不需要的方法：

```zig
// src/ai/provider.zig

pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 流式补全（主要接口）
        stream: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            request: Request,
            sink: *EventSink,
        ) anyerror!void,

        /// 中断当前请求
        abort: *const fn (ptr: *anyopaque) void,

        /// Provider 名称
        name: *const fn (ptr: *anyopaque) []const u8,

        /// 释放资源
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn stream(self: Provider, alloc: std.mem.Allocator, req: Request, sink: *EventSink) !void {
        return self.vtable.stream(self.ptr, alloc, req, sink);
    }
    pub fn abort(self: Provider) void { self.vtable.abort(self.ptr); }
    pub fn name(self: Provider) []const u8 { return self.vtable.name(self.ptr); }
    pub fn deinit(self: Provider) void { self.vtable.deinit(self.ptr); }
};

pub const Request = struct {
    messages: []const Message,
    system: ?[]const u8 = null,
    model: []const u8,
    tools: ?[]const ToolSpec = null,
    max_tokens: ?u32 = null,
    temperature: f64 = 0.0,
};

pub const EventSink = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, event: StreamEvent) void,
};
```

**与 nullclaw Provider vtable 的差异**：

| nullclaw | orbit-ai | 原因 |
|----------|----------|------|
| `chatWithSystem` + `chat` + `stream_chat` 三个方法 | 只有 `stream` | 统一为流式，非流式是 stream 收集完整结果的特例 |
| 无 `abort` | 有 `abort` | 全链路中断是核心需求 |
| `StreamCallback` 回调 | `EventSink` | 语义更清晰，支持细粒度事件 |
| `supportsNativeTools` / `supportsVision` / `supportsStreaming` | 去掉 | 通过 Model 注册表查询能力，不问 provider |

### HTTP 传输层

不用 curl，用 Zig 原生 HTTP：

```zig
// src/ai/http.zig

pub const HttpStream = struct {
    connection: std.http.Client.Request,
    aborted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// 读取下一个 SSE 事件，abort 时返回 null
    pub fn nextEvent(self: *HttpStream, buf: []u8) ?SseEvent { ... }

    /// 中断 HTTP 连接
    pub fn abort(self: *HttpStream) void {
        self.aborted.store(true, .release);
    }
};

pub const SseEvent = struct {
    event_type: []const u8,  // "message_start", "content_block_delta", etc.
    data: []const u8,        // JSON payload
};
```

### 上下文交接

切换 provider 时转换消息格式：

```zig
// src/ai/context.zig

/// 将 thinking traces 转为 <thinking> 标签文本
/// 用于从支持 thinking 的 provider 切换到不支持的 provider
pub fn convertThinkingToText(messages: []Message, allocator: Allocator) ![]Message { ... }

/// 将 provider 特有的 content 格式标准化
pub fn normalizeForProvider(messages: []Message, protocol: ApiProtocol, allocator: Allocator) ![]Message { ... }
```

### Architecture and Module Ownership

```
src/ai/
├── root.zig          # 公共 API：re-export types, stream(), abort()
├── types.zig         # 核心类型：Message, ContentPart, ToolCall, TokenUsage
├── models.zig        # 模型注册表
├── stream.zig        # StreamEvent, EventSink
├── provider.zig      # Provider vtable 接口, Request
├── http.zig          # Zig 原生 HTTP + SSE 解析
├── context.zig       # 上下文交接和格式转换
├── json_util.zig     # JSON 字符串工具（参考 nullclaw json_util.zig）
└── providers/
    ├── anthropic.zig # Anthropic Messages API 实现
    └── openai.zig    # OpenAI Completions API 实现
```

每个 provider 文件职责：
- 将 `Request` 序列化为 provider 特定的 JSON body
- 解析 SSE 事件为统一的 `StreamEvent`
- 处理 provider 怪癖（内部消化，不暴露）

### Failure Modes and Safety

1. **网络错误**：通过 `StreamEvent.err` 报告，kind 区分 rate_limited / auth_failed / network / timeout
2. **Abort**：`Provider.abort()` → 设置 atomic flag → HTTP 连接中断 → stream 返回 `StreamEvent.done` with `stop_reason = .aborted`
3. **部分结果**：abort 后已收到的 text_delta 和 tool_call_delta 仍然有效，上层可以保存
4. **JSON 解析失败**：provider 返回非预期格式时，报 `StreamEvent.err` with kind = .other

**不变量**：
- stream 调用最终一定会产生 `done` 或 `err` 事件（包括 abort 场景）
- `tool_call_start` 之后一定有对应的 `tool_call_done` 或 `err`
- `EventSink.emit` 在同一线程调用，无并发

## Impact Analysis

### Application Flow and Runtime

- [x] Background work, subprocesses, or async task handling

### UI and Interaction

- [x] Streaming output or incremental updates

### State and Domain Model

- [x] Session, message, or task model

### Agent Capabilities

- [ ] （orbit-ai 不直接涉及 agent 能力，由 Layer 2 使用）

### Reliability and Diagnostics

- [x] Error model and surfaced failures
- [x] Assertions or defensive checks
- [x] Logging, tracing, or debug views

### Developer Experience

- [x] Build/test workflow
- [x] Configuration or CLI flags
- [x] Documentation

## Operational Considerations

### Performance and Resource Use

- **无 fork 开销**：Zig 原生 HTTP，不 spawn curl 进程
- **流式零缓冲**：SSE chunk 到达即解析即 emit，无中间缓冲
- **内存**：每个请求的内存 = 请求 body + 响应累积，无额外开销
- **连接复用**：std.http.Client 支持 keep-alive

### Observability and Debuggability

- `--verbose` 模式输出原始 HTTP 请求/响应 body
- 每次补全记录 TokenUsage 和耗时
- StreamEvent 序列可以 dump 为 JSON 用于调试

### Compatibility and Migration

- 完全新建模块，不影响现有代码
- 历史上的 `src/api.zig` 已移除；orbit-ai 直接承担 provider 与传输层职责

## Testing

- **类型测试**：Message 构造、ContentPart union 操作
- **JSON 序列化测试**：每个 provider 的请求 body 构建，用 golden file 对比
- **SSE 解析测试**：给定原始 SSE 文本，验证解析出的 SseEvent 序列
- **StreamEvent 映射测试**：给定 provider SSE 事件，验证映射到正确的 StreamEvent
- **上下文交接测试**：thinking traces 转换、消息格式标准化
- **Mock HTTP 测试**：用预录的 SSE 响应测试完整 stream 流程
- **Abort 测试**：验证 abort 后产生 done 事件且部分结果可用

## Rollout Plan

1. **Step 1**：types.zig + models.zig + stream.zig + provider.zig — 纯类型定义，可编译可测试
2. **Step 2**：http.zig + json_util.zig — HTTP 传输和 SSE 解析
3. **Step 3**：providers/anthropic.zig — 第一个可用 provider
4. **Step 4**：providers/openai.zig — 第二个 provider
5. **Step 5**：context.zig — 上下文交接
6. **Step 6**：root.zig 整合 — 对外统一 API

每步独立可测试，不依赖后续步骤。

## Alternatives Considered

1. **直接提取 nullclaw provider 代码**：放弃。700KB 代码量，curl 子进程 HTTP，平台耦合深，缺少 abort/渐进解析。提取成本高于重写。

2. **包装 nullclaw 为库**：放弃。nullclaw 不是设计为库的，其 build.zig 和模块结构假设完整应用。

3. **用 nullclaw 的 SSE 解析器**：放弃。`sse.zig` 绑定 curl stdout 管道读取，无法用于 Zig 原生 HTTP 流。SSE 协议本身很简单（按 `\n\n` 分事件），自己写 ~200 行。

4. **先用 curl 子进程，后续迁移**：放弃。abort 支持是核心需求，curl 子进程模式下无法干净实现。不值得建立在错误的基础上。

## Open Questions

1. **Zig std.http.Client 稳定性**：nullclaw 因为 segfault 才用 curl。需要验证当前 Zig 版本的 HTTP client 是否可靠，如果不行需要评估替代方案（如 libcurl binding 而非子进程）。

2. **渐进式 JSON 解析策略**：工具调用参数在流式中逐 chunk 到达，需要一个能处理不完整 JSON 的解析器。是自己写还是用现有 Zig JSON 库？

3. **模型注册表更新机制**：内置的模型定义会过时。是否支持运行时从配置文件加载自定义模型？

## References

- nullclaw provider 核心类型：`references/nullclaw/src/providers/root.zig`
- nullclaw SSE 实现：`references/nullclaw/src/providers/sse.zig`
- nullclaw HTTP 工具：`references/nullclaw/src/http_util.zig`
- nullclaw JSON 工具：`references/nullclaw/src/json_util.zig`
- nullclaw Anthropic provider：`references/nullclaw/src/providers/anthropic.zig`
- nullclaw OpenAI provider：`references/nullclaw/src/providers/openai.zig`
- pi-ai 设计理念：https://mariozechner.at/posts/2025-11-30-pi-coding-agent/
- 四层架构 RFC：`rfcs/0001-four-layer-architecture.md`
