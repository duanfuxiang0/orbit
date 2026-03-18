# Orbit 四层架构重设计

Status: Draft

Authors:

* Orbit Team

Created: 2026-03-18

Last Updated: 2026-03-18

## Summary

受 Mario Zechner（libGDX 作者）构建 pi-coding-agent 的经验启发，将 Orbit 重新架构为四个清晰分层的模块：`orbit-ai`（统一 LLM API）、`orbit-agent`（代理循环）、`orbit-tui`（非全屏终端 UI）、`orbit-cli`（最终 CLI）。每层职责单一、边界明确、可独立测试。

## Motivation

当前 Orbit 代码库继承自 opencode-zig 原型，存在以下问题：

1. LLM 通信、代理逻辑、UI 渲染耦合在一起，无法独立演进
2. 全屏 Vaxis TUI 模式丢失了终端原生滚动和搜索能力
3. 没有统一的多 provider LLM 抽象层
4. 没有独立的代理循环，无法支持 headless 模式或替代 UI

Mario 在文章中验证了一个关键洞察：极简主义方法（<1000 token 系统提示、4 个工具、无 MCP、无子代理）在 Terminal-Bench 2.0 上与复杂方案表现相当。这证明了"不需要就不构建"的哲学是可行的。

## Goals

- 四层解耦：ai / agent / tui / cli 各自独立编译和测试
- 非全屏 TUI：保留终端原生滚动和搜索
- 多 provider 支持：Anthropic、OpenAI、Google、OpenAI-compatible 端点
- 跨 provider 上下文交接：会话中途切换模型
- 极简工具集：read、write、edit、bash 四个工具
- 流式响应：SSE 流式 + 工具调用参数的渐进式 JSON 解析
- 完整可中断：任何阶段都可以 abort

## Non-Goals

- MCP 支持（用 CLI 工具 + README 替代）
- 内置子代理（通过 bash 自启动替代）
- 内置 plan mode（写文件替代）
- 内置 TODO 管理（写文件替代）
- 后台 bash（用 tmux 替代）
- 权限检查 / 安全剧场（默认 YOLO 模式）
- Web UI（未来可通过 headless JSON 模式支持）

## Background

### Mario 的核心经验

Mario 把 pi-coding-agent 拆成四个 npm 包，每层职责清晰：

- **pi-ai**：抹平 OpenAI Completions/Responses API、Anthropic Messages API、Google Generative AI API 四套 API 差异。处理 provider 怪癖（Cerebras 不支持 `store`、Mistral 用 `max_tokens`、各家 reasoning trace 格式不同）。支持跨 provider 上下文交接（thinking traces 转 `<thinking>` 标签）。
- **pi-agent-core**：代理循环编排——处理用户消息 → 执行工具调用 → 结果喂回 LLM → 循环直到无工具调用。支持消息队列。
- **pi-tui**：非全屏模式，写入 scrollback buffer。Retained mode UI + 差分渲染 + synchronized output 消除闪烁。
- **pi-coding-agent**：串联以上三层，加会话管理、AGENTS.md 上下文、主题。

### nullclaw 的 provider 实现

`references/nullclaw/src/providers/` 已有完整的 Zig LLM provider 实现：

- `anthropic.zig` — Anthropic Messages API
- `openai.zig` — OpenAI API
- `gemini.zig` / `vertex.zig` — Google API
- `ollama.zig` — 本地模型
- `openrouter.zig` — OpenRouter 聚合
- `compatible.zig` — 通用 OpenAI-compatible 端点
- `sse.zig` — SSE 流式解析
- `router.zig` — provider 路由
- `factory.zig` — provider 工厂

nullclaw 是一个大型聊天机器人平台，其 provider 层与平台深度耦合。我们需要评估能否提取和简化其核心抽象（类型定义、SSE 解析、请求构建），而非直接复用。

## Proposal

### 总体架构

```
┌─────────────────────────────────────────────┐
│  orbit-cli (Layer 4)                        │
│  会话管理 · AGENTS.md · 主题 · CLI 入口        │
├─────────────────────────────────────────────┤
│  orbit-tui (Layer 3)                        │
│  非全屏渲染 · 差分更新 · 编辑器 · Markdown      │
├─────────────────────────────────────────────┤
│  orbit-agent (Layer 2)                      │
│  代理循环 · 工具执行 · 消息队列 · 事件流         │
├─────────────────────────────────────────────┤
│  orbit-ai (Layer 1)                         │
│  统一 LLM API · 多 provider · 流式 · 交接     │
└─────────────────────────────────────────────┘
```

依赖方向严格向下：cli → tui + agent，agent → ai，tui 不依赖 agent 或 ai。

### Layer 1: orbit-ai — 统一 LLM API

**职责**：与 LLM provider 通信，抹平 API 差异，提供统一的流式补全接口。

**核心类型**：

```zig
/// 支持的 API 协议
const ApiProtocol = enum {
    openai_completions,  // OpenAI + 兼容端点
    openai_responses,    // OpenAI Responses API
    anthropic_messages,  // Anthropic Messages API
    google_generative,   // Google Generative AI API
};

/// 模型定义
const Model = struct {
    id: []const u8,
    name: []const u8,
    api: ApiProtocol,
    provider: []const u8,
    base_url: ?[]const u8,
    reasoning: bool,
    context_window: u32,
    max_tokens: u32,
    cost: TokenCost,
};

/// 统一消息格式
const Message = struct {
    role: Role,              // user / assistant / system
    content: []ContentPart,  // text / image / tool_call / tool_result
};

/// 上下文 = 消息历史
const Context = struct {
    messages: []Message,
    system: ?[]const u8,
};

/// 流式事件
const StreamEvent = union(enum) {
    text_delta: []const u8,
    thinking_delta: []const u8,
    tool_call_delta: ToolCallDelta,
    tool_call_complete: ToolCall,
    done: CompletionResult,
    error: StreamError,
};

/// 核心 API
fn stream(model: Model, context: Context, options: Options) StreamIterator;
fn complete(model: Model, context: Context, options: Options) CompletionResult;
fn abort(iterator: *StreamIterator) void;
```

**关键设计决策**：

1. **Provider 怪癖处理**：每个 provider 模块内部处理自己的怪癖，对外暴露统一接口。参考 pi-ai 处理的已知问题：
   - Cerebras/xAI/Mistral 不支持 `store` 字段
   - Mistral 用 `max_tokens` 而非 `max_completion_tokens`
   - 各家 reasoning trace 字段名不同
   - Google 不支持工具调用流式

2. **上下文交接**：切换 provider 时，将前一个 provider 的 thinking traces 转为 `<thinking>` 标签包裹的文本块。provider 特有的签名 blob 需要在序列化时处理。

3. **Abort 支持**：全链路可中断。中断后返回部分结果。

4. **渐进式 JSON 解析**：工具调用参数在流式传输中渐进解析，UI 可以在调用完成前展示部分参数（如文件 diff 流式显示）。

5. **nullclaw 复用评估**：nullclaw 的 `sse.zig`（SSE 解析）和基础类型定义（`ContentPart`、`ImageDetail` 等）可作为参考。但其 provider 实现与 nullclaw 平台耦合较深（依赖 config 系统、channel 系统等），需要重写而非直接提取。建议：学习其类型设计和 API 怪癖处理，自行实现精简版。

### Layer 2: orbit-agent — 代理循环

**职责**：编排 LLM 调用和工具执行的完整循环。

**核心循环**（参考 `references/pi-mono/packages/agent/`）：

```
用户消息 → 发送给 LLM → 收到响应
  ├─ 响应包含工具调用 → 执行工具 → 结果喂回 LLM → 继续循环
  ├─ 响应是纯文本 → 检查消息队列 → 有排队消息则继续
  └─ 响应是纯文本且队列为空 → 回合结束
```

**核心类型**：

```zig
/// 工具定义
const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters: JsonSchema,
    execute: *const fn (args: JsonValue) ToolResult,
};

/// 代理事件（驱动 UI 更新）
const AgentEvent = union(enum) {
    turn_start,
    text_delta: []const u8,
    thinking_delta: []const u8,
    tool_call_start: ToolCall,
    tool_call_delta: ToolCallDelta,
    tool_result: ToolResult,
    turn_end: TurnSummary,
    error: AgentError,
};

/// 代理配置
const AgentConfig = struct {
    model: ai.Model,
    tools: []const Tool,
    system_prompt: []const u8,
    context: ai.Context,
};

/// 核心 API
fn runLoop(config: AgentConfig, event_sink: EventSink) void;
fn queueMessage(agent: *Agent, message: []const u8) void;
fn abort(agent: *Agent) void;
```

**关键设计决策**：

1. **无 max steps**：循环直到模型不再调用工具。Mario 的经验是从未需要这个限制。
2. **消息队列**：代理工作时用户可以排队发送新消息，在当前回合结束后注入。
3. **事件驱动**：所有状态变化通过事件通知，UI 层订阅事件进行渲染。
4. **工具结果分离**：工具返回两部分——给 LLM 的文本内容和给 UI 的结构化数据（参考 pi-ai 的 structured split tool results）。

### Layer 3: orbit-tui — 非全屏终端 UI

**职责**：终端渲染和用户输入，不包含业务逻辑。

**核心设计**——从全屏 Vaxis 切换到非全屏 scrollback 模式：

| 特性 | 全屏模式（当前） | 非全屏模式（目标） |
|------|-----------------|-------------------|
| 滚动 | 自行模拟 | 终端原生 |
| 搜索 | 自行实现 | 终端原生 |
| 渲染 | 整个 viewport | 只重绘变化行 |
| 复杂度 | 高 | 低 |

**渲染模型**——Retained mode + 差分渲染：

```zig
/// 组件接口
const Component = struct {
    render: *const fn (self: *anyopaque, width: u16) []const []const u8,
    handle_input: ?*const fn (self: *anyopaque, data: []const u8) bool,
};

/// 容器：垂直排列子组件
const Container = struct {
    children: []Component,
    fn collectLines(self: *Container, width: u16) []const []const u8;
};

/// TUI 核心：差分渲染引擎
const Tui = struct {
    backbuffer: [][]const u8,  // 上一帧的所有行

    fn render(self: *Tui, lines: []const []const u8) void {
        // 1. 首次渲染：直接输出所有行
        // 2. 宽度变化：清屏重绘
        // 3. 正常更新：找到第一个差异行，从该行开始重绘到末尾
        // 4. 差异行在 viewport 上方：全量清屏重绘
        // 用 synchronized output (CSI ?2026h / CSI ?2026l) 包裹，消除闪烁
    }
};
```

**关键设计决策**：

1. **放弃 Vaxis 全屏**：改为直接写 scrollback buffer。保留 Vaxis 仅用于终端能力检测和输入解析（如果有用的话），或完全不依赖 Vaxis。
2. **组件缓存**：已完成流式传输的消息缓存渲染结果，不重复计算。
3. **Synchronized output**：用 `CSI ?2026h` / `CSI ?2026l` 转义序列包裹渲染输出，让终端原子化显示。
4. **Markdown 渲染**：将 Markdown 转为带 ANSI 转义码的文本行。

### Layer 4: orbit-cli — 最终 CLI

**职责**：串联以上三层，提供完整的编码代理体验。

**核心功能**：

1. **极简系统提示**（<1000 tokens）：
   ```
   You are an expert coding assistant. You help users with coding tasks
   by reading files, executing commands, editing code, and writing new files.

   Available tools:
   - read: Read file contents
   - bash: Execute bash commands
   - edit: Make surgical edits to files
   - write: Create or overwrite files

   Guidelines:
   - Use bash for file operations like ls, grep, find
   - Use read to examine files before editing
   - Use edit for precise changes (old text must match exactly)
   - Use write only for new files or complete rewrites
   - Be concise in your responses
   ```

2. **四个工具**：
   - `read` — 读取文件内容（支持图片、支持 offset/limit）
   - `write` — 创建或覆盖文件（自动创建父目录）
   - `edit` — 精确文本替换（oldText 必须精确匹配）
   - `bash` — 执行 bash 命令（可选 timeout）

3. **会话管理**：会话序列化为 JSON，支持 continue / resume / branch。

4. **项目上下文**：层级加载 AGENTS.md（全局 → 项目级），注入系统提示末尾。

5. **Headless 模式**：JSON streaming 输出，支持构建替代 UI 或自动化管道。

### 模块目录结构

```
src/
├── ai/                    # Layer 1: orbit-ai
│   ├── root.zig           # 公共 API 和类型
│   ├── stream.zig         # 流式迭代器
│   ├── context.zig        # 上下文管理和交接
│   ├── models.zig         # 模型注册表
│   └── providers/
│       ├── anthropic.zig
│       ├── openai.zig
│       ├── google.zig
│       └── compatible.zig # OpenAI-compatible 端点
├── agent/                 # Layer 2: orbit-agent
│   ├── root.zig           # Agent 和 agent loop
│   ├── tools.zig          # 工具接口和验证
│   └── events.zig         # 事件类型
├── tui/                   # Layer 3: orbit-tui
│   ├── root.zig           # TUI 引擎和差分渲染
│   ├── component.zig      # 组件接口
│   ├── editor.zig         # 输入编辑器
│   └── markdown.zig       # Markdown → ANSI 渲染
├── cli/                   # Layer 4: orbit-cli
│   ├── root.zig           # CLI 入口和配置
│   ├── session.zig        # 会话管理
│   ├── context_files.zig  # AGENTS.md 加载
│   └── coding_tools.zig   # read/write/edit/bash 实现
└── main.zig               # 进程入口，仅 wiring
```

### User-Facing Behavior

用户体验类似 Claude Code / pi：

```
$ orbit
> 帮我重构 auth 模块

◐ Thinking...

I'll start by reading the current auth module.

  read src/auth.zig

[文件内容显示]

I see several issues. Let me fix the token validation:

  edit src/auth.zig
  - oldText: "if (token.len == 0) return error.Invalid;"
  + newText: "if (token.len == 0 or token.len > max_token_len) return error.Invalid;"

  bash zig build test

[测试输出]

All tests pass. I've added a length upper bound check to prevent...

> /model anthropic claude-sonnet-4  (会话中途切换模型)
> 继续优化错误处理
```

### State and Data Model

**会话状态**：

```zig
const Session = struct {
    id: []const u8,
    created_at: i64,
    model: ai.Model,
    context: ai.Context,       // 完整消息历史
    cost: TokenCost,           // 累计 token 消耗
    branch_parent: ?[]const u8, // 分支来源
};
```

会话序列化为 JSON 文件存储在 `~/.orbit/sessions/` 下。

**不变量**：
- Context.messages 始终是 user/assistant 交替（工具调用/结果嵌入 assistant/user 消息中）
- 每个 Session 有唯一 ID
- abort 后 context 包含部分响应，标记 stop_reason = .aborted

### Failure Modes and Safety

1. **网络错误**：provider 返回错误时，通过 AgentEvent.error 通知 UI，用户决定重试或切换模型
2. **工具执行失败**：bash 超时或 edit 匹配失败时，错误作为工具结果喂回 LLM，让模型自行修正
3. **Abort**：全链路支持。中断 HTTP 流 → 中断工具执行 → 保存部分结果
4. **上下文溢出**：跟踪 token 使用量，接近 context_window 时警告用户（未来可加 compaction）

## Impact Analysis

### Application Flow and Runtime

- [x] Process lifecycle (`src/main.zig`)
- [x] Event definitions and routing (`src/runtime/`)
- [x] Renderer abstraction
- [x] App-level coordination (`src/app_controller.zig`)
- [x] Background work, subprocesses, or async task handling

### UI and Interaction

- [x] Screen layout or rendering (`src/ui/` or legacy `src/ui.zig`)
- [x] Keyboard input or keymaps (`src/input/`)
- [x] Navigation, focus, or modal flows
- [x] Streaming output or incremental updates
- [x] Accessibility or readability in terminal environments

### State and Domain Model

- [x] State shape or ownership (`src/state.zig`)
- [x] State transitions or invariants
- [x] Session, message, or task model
- [x] Persistence, serialization, or replay behavior

### Agent Capabilities

- [x] File system operations
- [x] Command execution
- [x] Tool permissions or safety policy
- [x] Prompting, planning, or conversation flow
- [ ] Multi-agent or task orchestration

### Reliability and Diagnostics

- [x] Error model and surfaced failures
- [x] Assertions or defensive checks
- [x] Logging, tracing, or debug views
- [x] Crash recovery or resume behavior

### Developer Experience

- [x] Build/test workflow
- [x] Configuration or CLI flags
- [x] Documentation
- [x] Migration away from legacy opencode-zig behavior

## Operational Considerations

### Performance and Resource Use

- **启动**：无 runtime 依赖，Zig 原生二进制，冷启动 <50ms
- **输入延迟**：非全屏模式下输入直接处理，无 viewport 重算
- **渲染**：差分渲染只重绘变化行，内存开销为 backbuffer（几百 KB）
- **流式**：SSE chunk 到达即渲染，无缓冲延迟
- **内存**：会话历史是主要内存消耗，长会话可能达到几 MB

### Observability and Debuggability

- 所有 LLM 交互通过事件流暴露，UI 完整展示
- 无隐藏的子代理或后台注入
- 会话 JSON 可离线检查和 post-process
- `--verbose` 模式输出原始 HTTP 请求/响应

### Compatibility and Migration

- 现有 opencode-zig 代码将被逐步替换，不做兼容
- 现有 `src/ui.zig`、`src/api.zig`、`src/state.zig` 将被新的分层模块取代
- `src/runtime/` 的事件路由概念保留，但重新实现

## Testing

- **orbit-ai**：每个 provider 的请求构建和响应解析单元测试；mock HTTP 测试流式解析；上下文交接转换测试
- **orbit-agent**：代理循环状态机测试（mock LLM 返回预设响应）；工具参数验证测试；消息队列测试；abort 语义测试
- **orbit-tui**：差分渲染算法测试（给定 old/new lines，验证输出的转义序列）；组件渲染测试
- **orbit-cli**：会话序列化/反序列化测试；AGENTS.md 层级加载测试；工具执行集成测试

## Rollout Plan

分四个阶段，每阶段可独立交付：

1. **Phase 1: orbit-ai** — 实现 Anthropic + OpenAI provider，流式补全，基础类型系统。可用 `zig build test` 独立验证。
2. **Phase 2: orbit-agent** — 实现代理循环 + 四个工具。配合 Phase 1 可在 headless 模式下运行完整代理。
3. **Phase 3: orbit-tui** — 实现非全屏渲染引擎 + 差分更新 + 输入编辑器。
4. **Phase 4: orbit-cli** — 串联所有层，加会话管理和 AGENTS.md 支持。

每个 phase 完成后更新 AGENTS.md 中的架构边界描述。

## Alternatives Considered

1. **继续使用 Vaxis 全屏模式**：放弃。全屏模式丢失原生滚动/搜索，增加实现复杂度，且 coding agent 的线性对话模式天然适合 scrollback buffer。

2. **直接复用 nullclaw provider 代码**：放弃。nullclaw 的 provider 与其平台深度耦合（config 系统、channel 系统、daemon 模式），提取成本高于重写。但其类型设计和 API 怪癖处理经验值得学习。

3. **使用 Vercel AI SDK 风格的抽象**：不适用。我们是 Zig 项目，且 Mario 的经验表明直接对接 provider SDK 能获得更好的控制力和更小的表面积。

4. **保留复杂工具集和系统提示**：放弃。Mario 的 benchmark 证明 4 个工具 + <1000 token 提示在 Terminal-Bench 上表现与复杂方案相当。前沿模型已经通过 RL 训练理解了 coding agent 的工作方式。

5. **加入 MCP 支持**：放弃。MCP server 的工具描述会消耗大量 context（如 Playwright MCP 21 个工具占 13.7k tokens）。用 CLI 工具 + README 的方式更节省 token，且按需加载。

## Open Questions

1. **Vaxis 保留程度**：是否保留 Vaxis 用于终端能力检测和输入解析，还是完全自行处理？需要评估 Vaxis 在非全屏模式下的适用性。

2. **Compaction 策略**：Mario 尚未实现 compaction。我们是否在 Phase 1 就设计 compaction 接口，还是后续再加？

3. **Google provider 优先级**：Google 不支持工具调用流式，是否在 Phase 1 就支持 Google，还是先做 Anthropic + OpenAI？

4. **会话格式**：是否与 pi 的会话 JSON 格式兼容，以便复用其 HTML 导出等工具？

5. **nullclaw SSE 解析器**：nullclaw 的 `sse.zig` 是否足够独立可以直接提取使用？需要详细评估其依赖关系。

## References

- Mario Zechner, "What I learned building an opinionated and minimal coding agent", 2025-11-30: https://mariozechner.at/posts/2025-11-30-pi-coding-agent/
- pi-mono 源码: `references/pi-mono/` (特别是 `packages/agent/`, `packages/ai/`, `packages/tui/`, `packages/coding-agent/`)
- nullclaw provider 实现: `references/nullclaw/src/providers/`
- nullclaw 流式处理: `references/nullclaw/src/streaming.zig`
- Armin Ronacher, "Agents are Hard": https://lucumr.pocoo.org/2025/11/21/agents-are-hard/
- Terminal-Bench 2.0: https://github.com/laude-institute/terminal-bench
