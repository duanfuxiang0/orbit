# orbit-cli: Layer 4 最终 CLI 设计

Table of Contents:

- [Summary](#summary)
- [Motivation](#motivation)
- [Goals](#goals)
- [Non-Goals](#non-goals)
- [Background](#background)
- [Design](#design)
  - [模块目录结构](#模块目录结构)
  - [CLI 入口与启动流程](#cli-入口与启动流程)
  - [配置系统](#配置系统)
  - [系统提示构造](#系统提示构造)
  - [AGENTS.md 层级加载](#agentsmd-层级加载)
  - [四个编码工具实现](#四个编码工具实现)
  - [会话管理](#会话管理)
  - [Headless 模式](#headless-模式)
  - [错误处理与用户反馈](#错误处理与用户反馈)
  - [核心类型与 API](#核心类型与-api)
- [Checklist](#checklist)
- [Operational Considerations](#operational-considerations)
- [Testing](#testing)
- [Rollout Plan](#rollout-plan)
- [Alternatives Considered](#alternatives-considered)
- [Open Questions](#open-questions)
- [References](#references)

Status: Draft

Authors:

* Orbit Team

Created: 2026-03-19

Last Updated: 2026-03-19

## Summary

orbit-cli 是四层架构的第四层，也是最终的用户入口。它负责将 orbit-ai（Layer 1）、
orbit-agent（Layer 2）、orbit-tui（Layer 3）串联成一个完整的编码代理体验。
orbit-cli 自身不包含 LLM 通信逻辑、代理循环逻辑或渲染逻辑，其职责是：解析 CLI
参数、加载配置、构造系统提示（含 AGENTS.md 上下文）、管理会话持久化、注册四个
编码工具（read/write/edit/bash）、以及选择 TUI 或 headless 输出模式。

## Motivation

前三层（orbit-ai、orbit-agent、orbit-tui）均已有独立的 RFC 设计，但它们只是构件。
用户运行 `orbit` 命令时，需要一个胶水层来：

1. **解析意图**：用户到底是开新会话、继续上次会话、还是恢复某个历史会话？
2. **组装上下文**：项目里有 AGENTS.md 吗？全局配置里有默认模型吗？
3. **注册工具**：四个编码工具（read/write/edit/bash）的具体实现在哪里？
4. **持久化历史**：会话结束后，对话历史保存到哪里？格式是什么？
5. **支持非交互场景**：CI/CD 管道、编辑器插件需要 JSON 流式输出，而不是 TUI 渲染。

没有 orbit-cli，前三层就像没有 main 函数的库——功能完整但无法独立运行。

## Goals

- 极简 CLI 接口：`orbit` 启动新会话，`--continue` 续上次，`--session <id>` 指定历史
- 四个编码工具的完整实现：read、write、edit、bash（含 timeout、abort 支持）
- 系统提示构造：基础提示 < 500 tokens，加 AGENTS.md 后总量 < 2000 tokens
- AGENTS.md 层级加载：全局（`~/.orbit/AGENTS.md`）→ 项目级（从 CWD 向上查找）
- 会话序列化为 JSON，存储在 `~/.orbit/sessions/`，支持离线检查
- Headless 模式：JSON lines 输出，支持自动化管道和替代 UI
- 配置系统：`~/.orbit/config.toml` + 环境变量（环境变量优先）
- 与 orbit-agent 的 Tool 接口完全兼容，不引入新的工具抽象

## Non-Goals

- 工具权限检查 / 沙箱（默认 YOLO 模式，用户自行决定）
- 内置 undo / 版本控制（用 git 替代）
- 内置任务计划 / TODO 管理（让代理写文件替代）
- 插件系统 / MCP 支持（Phase N 问题）
- Windows 原生支持（当前目标：Linux + macOS，WSL 可用）
- 内置 API key 管理 UI（用环境变量和编辑器替代）
- Web UI 后端（headless JSON 模式已足够作为桥梁）

## Background

### pi-coding-agent 的 CLI 层经验

Mario Zechner 的 `pi-coding-agent`（`references/pi-mono/packages/coding-agent/`）
验证了以下设计决策：

- **极简系统提示有效**：< 1000 tokens 的系统提示在 Terminal-Bench 2.0 上与复杂
  提示表现相当，不需要复杂的 prompt engineering。
- **AGENTS.md 是关键上下文机制**：项目级 AGENTS.md 注入系统提示，避免将
  所有领域知识硬编码到代理本身。这是 Cursor Rules 和 Claude CLAUDE.md 的同类实践。
- **四个工具已足够**：read/write/edit/bash 可以完成几乎所有编码任务。bash 工具
  可以调用任何 CLI 工具，无需 MCP 这类复杂扩展机制。
- **会话持久化需要认真对待**：长会话是编码代理的核心使用场景，JSON 格式序列化
  可以支持 resume、branch 以及离线分析。

### 现有代码库状态

- `src/agent/root.zig`：Agent 结构体和 runTurn 已实现，接受 `[]const types.Tool`
- `src/agent/types.zig`：Tool、AgentEvent、ToolExecResult 类型已定义
- `src/ai/models.zig`：builtin_models 注册表已有 claude_sonnet 和 gpt4o
- `src/cli/`：本 RFC 所定义的 CLI 目录现已存在并承担当前运行入口
- `src/tui/`：先前实验性实现已被移除；RFC 0004 仍只代表未来设计方向

## Design

### 模块目录结构

```
src/cli/
├── root.zig           # CLI 入口：arg 解析、启动流程、主事件循环
├── config.zig         # 配置加载：~/.orbit/config.toml + 环境变量
├── session.zig        # 会话序列化/反序列化、~/.orbit/sessions/ 管理
├── context_files.zig  # AGENTS.md 层级加载和内容合并
├── coding_tools.zig   # read/write/edit/bash 四个工具实现
└── headless.zig       # Headless JSON lines 输出模式
```

### CLI 入口与启动流程

`src/cli/root.zig` 是 `src/main.zig` 的直接调用目标，负责所有启动逻辑。
`src/main.zig` 只做内存分配器初始化和 `cli.run()` 调用，不包含任何业务逻辑。

**启动流程**：

```
main()
  └── cli.run(allocator)
        ├── 1. parseCliArgs()          → CliArgs
        ├── 2. config.load(allocator)  → Config（读 ~/.orbit/config.toml + 环境变量）
        ├── 3. resolveModel(config, args) → ai.Model + ai.Provider
        ├── 4. context_files.load(allocator, cwd) → []const u8（合并后的 AGENTS.md 内容）
        ├── 5. buildSystemPrompt(base_prompt, agents_md_content) → []const u8
        ├── 6. session.loadOrCreate(allocator, config, args) → Session
        ├── 7. coding_tools.register(allocator, cwd) → []agent.Tool
        ├── 8. 选择输出模式：
        │     ├── args.headless → headless.run(agent, session)
        │     └── 默认 → tui.run(agent, session)
        └── 9. session.save(allocator, session)  → 持久化到 ~/.orbit/sessions/
```

**CLI 参数**：

```zig
/// src/cli/root.zig
pub const CliArgs = struct {
    /// 继续上次会话（等价于 --session <最新会话 ID>）
    continue_last: bool = false,
    /// 指定会话 ID 恢复
    session_id: ?[]const u8 = null,
    /// Headless 模式：JSON lines 输出到 stdout，不启动 TUI
    headless: bool = false,
    /// 覆盖配置中的模型（格式："provider/model-id"，如 "anthropic/claude-opus-4"）
    model: ?[]const u8 = null,
    /// 详细模式：输出原始 HTTP 请求/响应到 stderr
    verbose: bool = false,
    /// 打印帮助
    help: bool = false,
};
```

**不变量**：
- `continue_last` 和 `session_id` 互斥；同时指定时 `session_id` 优先，记录警告
- `run()` 函数不超过 70 行；子步骤全部委托给各子模块
- 启动期间任何错误（配置缺失、API key 未设置）直接打印用户可读错误并退出，
  不 panic

### 配置系统

`src/cli/config.zig`

配置来源（优先级从高到低）：

1. **CLI 参数**（如 `--model`）
2. **环境变量**（`ANTHROPIC_API_KEY`、`OPENAI_API_KEY`、`ORBIT_MODEL` 等）
3. **用户配置文件**（`~/.orbit/config.toml`）
4. **内置默认值**（默认模型：`claude-sonnet-4-20250514`）

```zig
/// src/cli/config.zig
pub const Config = struct {
    /// 默认模型 ID（如 "claude-sonnet-4-20250514"）
    default_model: []const u8,
    /// Anthropic API key（优先从 ANTHROPIC_API_KEY 环境变量读取）
    anthropic_api_key: ?[]const u8,
    /// OpenAI API key（优先从 OPENAI_API_KEY 环境变量读取）
    openai_api_key: ?[]const u8,
    /// 会话存储目录（默认 ~/.orbit/sessions/）
    sessions_dir: []const u8,
    /// 是否输出详细日志
    verbose: bool,

    pub fn load(allocator: std.mem.Allocator) !Config;
    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void;
};
```

**`~/.orbit/config.toml` 格式**（所有字段可选）：

```toml
[llm]
default_model = "claude-sonnet-4-20250514"
anthropic_api_key = "sk-ant-..."
openai_api_key = "sk-..."
sessions_dir = "~/.orbit/sessions"
```

**不变量**：
- 配置文件不存在时使用默认值，不报错
- API key 若在环境变量和配置文件中均未找到，启动时打印可读错误并退出
- `sessions_dir` 路径中的 `~` 在加载时展开为实际 home 目录
- 配置文件解析错误（非法 JSON）打印具体行列号错误后退出

### 系统提示构造

`src/cli/root.zig` 中的 `buildSystemPrompt()` 函数。

**基础系统提示**（硬编码，< 500 tokens）：

```
You are an expert coding assistant. You help users with coding tasks
by reading files, executing commands, editing code, and writing new files.

Available tools:
- read: Read file contents. Supports offset and limit for large files.
- bash: Execute bash commands. Use for file listing, search, compilation, testing.
- edit: Make precise text replacements in files. The old_text must match exactly.
- write: Create or overwrite files. Automatically creates parent directories.

Guidelines:
- Use bash for exploration: ls, grep, find, cat for quick checks
- Use read for examining files before editing
- Use edit for surgical changes; prefer edit over write for existing files
- Use write only for new files or complete rewrites
- Be concise in your responses; show code, not lengthy explanations
- Run tests after making changes when a test command is available
```

**AGENTS.md 追加规则**：

```zig
fn buildSystemPrompt(
    allocator: std.mem.Allocator,
    agents_md: ?[]const u8,
) ![]const u8 {
    // 如果没有 AGENTS.md，直接返回 base_prompt
    // 如果有，拼接：base_prompt + "\n\n---\n" + agents_md
    // 调用方负责 free 返回值
}
```

**不变量**：
- 基础提示永远是系统提示的第一部分，AGENTS.md 内容追加在末尾
- 系统提示总长度不做截断（截断是 compaction 的职责，属于后续 RFC）
- 基础提示硬编码为编译期常量，不从文件或配置读取

### AGENTS.md 层级加载

`src/cli/context_files.zig`

**加载顺序**（从宽泛到具体，后者内容追加在前者之后）：

```
1. ~/.orbit/AGENTS.md        （全局级，用户通用规则）
2. <git_root>/AGENTS.md      （项目级，从 CWD 向上找到 .git 所在目录）
3. <cwd>/AGENTS.md           （当前目录级，仅当 cwd != git_root 时加载）
```

```zig
/// src/cli/context_files.zig

/// 加载并合并所有 AGENTS.md，返回合并后的内容（调用方 free）
/// 如果所有路径均不存在，返回 null
pub fn loadContextFiles(
    allocator: std.mem.Allocator,
    cwd: []const u8,
) !?[]const u8;

/// 从 start_dir 向上查找 .git 目录，返回包含 .git 的目录路径
/// 找不到则返回 null
fn findGitRoot(
    allocator: std.mem.Allocator,
    start_dir: []const u8,
) !?[]const u8;
```

**合并格式**：

```
# Global AGENTS.md
<全局内容>

# Project AGENTS.md
<项目内容>

# Local AGENTS.md
<本地内容>
```

**不变量**：
- 每个 AGENTS.md 文件大小上限：64 KB（超出截断并记录警告）
- 同一路径不加载两次（git_root == cwd 时只加载一次）
- 加载失败（权限问题等）记录日志但不中止启动
- 向上查找 `.git` 的最大深度：16 层，防止无限循环

### 四个编码工具实现

`src/cli/coding_tools.zig`

每个工具实现 `agent.types.Tool` 接口：

```zig
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
    execute: *const fn (
        ctx: *anyopaque,
        tool_call_id: []const u8,
        arguments: []const u8,
        abort: *const ai.provider.AbortState,
    ) ToolExecResult,
    ctx: *anyopaque,
};
```

#### Tool: read

**参数 schema**：
```json
{
  "type": "object",
  "properties": {
    "path":   { "type": "string", "description": "File path to read" },
    "offset": { "type": "integer", "description": "Starting line (0-indexed)" },
    "limit":  { "type": "integer", "description": "Max lines to return" }
  },
  "required": ["path"]
}
```

**行为**：
- 读取文件内容，返回 `<line_number>: <line>` 格式的带行号文本
- `offset`/`limit` 支持大文件分页；默认读取全部（上限 2000 行）
- 路径不存在：返回 `is_error=true`，内容为可读错误信息
- 二进制文件检测：首 512 字节含 `\x00` 则返回错误提示，拒绝输出乱码

**不变量**：
- 路径必须是相对路径或绝对路径；`~` 不展开（让 bash 处理）
- 单文件读取不分配超过 4 MB 的缓冲区（超出报错）

#### Tool: write

**参数 schema**：
```json
{
  "type": "object",
  "properties": {
    "path":    { "type": "string", "description": "File path to write" },
    "content": { "type": "string", "description": "File content" }
  },
  "required": ["path", "content"]
}
```

**行为**：
- 自动创建所有父目录（`std.fs.makePath`）
- 原子写入：先写临时文件，再 rename，防止写入中途崩溃导致文件损坏
- 成功返回：`"Wrote <N> bytes to <path>"`
- `ui_details`：包含写入的行数和文件大小，供 TUI 展示

**不变量**：
- `content` 为空字符串时也执行写入（允许创建空文件），不报错
- 不限制可写路径（YOLO 模式）

#### Tool: edit

**参数 schema**：
```json
{
  "type": "object",
  "properties": {
    "path":     { "type": "string", "description": "File path to edit" },
    "old_text": { "type": "string", "description": "Exact text to replace" },
    "new_text": { "type": "string", "description": "Replacement text" }
  },
  "required": ["path", "old_text", "new_text"]
}
```

**行为**：
- 在文件内容中查找 `old_text` 的**精确**匹配（区分大小写、空白符敏感）
- 找到则替换为 `new_text`，写回文件
- 找不到：返回 `is_error=true`，内容为：`"old_text not found in <path>"`
- 多次出现：只替换第一次匹配（与 pi-agent 行为一致；如需全替换，让模型多次调用）
- 成功返回：`"Edited <path>"`
- `ui_details`：包含替换前后的 diff（unified diff 格式，3 行上下文），供 TUI 展示

**不变量**：
- `old_text` 和 `new_text` 均可为多行字符串
- 文件不存在：返回 `is_error=true`
- 读取文件上限与 read 工具相同（4 MB）

#### Tool: bash

**参数 schema**：
```json
{
  "type": "object",
  "properties": {
    "command": { "type": "string", "description": "Bash command to execute" },
    "timeout": {
      "type": "integer",
      "description": "Timeout in seconds (default: 30, max: 300)"
    }
  },
  "required": ["command"]
}
```

**行为**：
- 通过 `std.process.Child` 执行 `bash -c <command>`
- 合并 stdout + stderr 输出（两者都给 LLM）
- 输出超过 32 KB 时截断，末尾追加 `"\n[output truncated]"`
- `ui_details`：包含退出码和执行时长（毫秒）
- abort 触发时：向子进程发送 SIGTERM，等待最多 2 秒后发送 SIGKILL
- timeout 超时时：发送 SIGTERM，返回 `is_error=true`，内容说明超时

**不变量**：
- 工作目录固定为启动时的 CWD，不随 `cd` 命令改变（每次 bash 调用是独立子进程）
- `timeout` 参数上限 300 秒，超过则截断至 300
- 默认 timeout 30 秒
- 退出码非 0 时 `is_error=false`（退出码信息已包含在输出中，LLM 可以判断）

**工具注册**：

```zig
/// src/cli/coding_tools.zig

const ToolCtx = struct {
    allocator: std.mem.Allocator,
    cwd: []const u8,
};

/// 创建四个工具的 slice，调用方负责 free（工具本身是栈上常量，ctx 需 heap）
pub fn register(
    allocator: std.mem.Allocator,
    cwd: []const u8,
) ![]agent.types.Tool;

pub fn unregister(
    allocator: std.mem.Allocator,
    tools: []agent.types.Tool,
) void;
```

### 会话管理

`src/cli/session.zig`

**会话 JSON 格式**（存储在 `~/.orbit/sessions/<id>.json`）：

```json
{
  "version": 1,
  "id": "20260319-143022-a3f7",
  "created_at": 1742389822,
  "updated_at": 1742390100,
  "model_id": "claude-sonnet-4-20250514",
  "provider": "anthropic",
  "cwd": "/home/user/myproject",
  "total_usage": {
    "input_tokens": 12400,
    "output_tokens": 3200,
    "cache_read_tokens": 8000,
    "cache_write_tokens": 4400
  },
  "messages": [
    {
      "role": "user",
      "content": [{"type": "text", "text": "帮我重构 auth 模块"}]
    },
    {
      "role": "assistant",
      "content": [
        {"type": "text", "text": "我来看一下当前的 auth 模块..."},
        {"type": "tool_use", "id": "toolu_01", "name": "read",
         "input": {"path": "src/auth.zig"}}
      ]
    },
    {
      "role": "user",
      "content": [{"type": "tool_result", "tool_use_id": "toolu_01",
                   "content": "1: const std = ...\n"}]
    }
  ]
}
```

**核心 API**：

```zig
/// src/cli/session.zig

pub const SessionId = struct {
    /// 格式：YYYYMMDD-HHMMSS-<4位随机十六进制>
    buf: [20]u8,

    pub fn slice(self: *const SessionId) []const u8;
    pub fn generate() SessionId;  // 使用当前时间 + std.crypto.random
};

pub const Session = struct {
    id: SessionId,
    created_at: i64,
    updated_at: i64,
    model_id: []const u8,          // 拥有，需 free
    provider: []const u8,          // 拥有，需 free
    cwd: []const u8,               // 拥有，需 free
    total_usage: ai.TokenUsage,
    messages: std.ArrayListUnmanaged(ai.Message),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, model: ai.Model, cwd: []const u8) !Session;
    pub fn deinit(self: *Session) void;
};

/// 从 ~/.orbit/sessions/<id>.json 加载会话
pub fn load(
    allocator: std.mem.Allocator,
    sessions_dir: []const u8,
    id: []const u8,
) !Session;

/// 加载最新会话（按 updated_at 排序）
pub fn loadLatest(
    allocator: std.mem.Allocator,
    sessions_dir: []const u8,
) !?Session;

/// 保存会话到 ~/.orbit/sessions/<id>.json
pub fn save(
    allocator: std.mem.Allocator,
    sessions_dir: []const u8,
    session: *const Session,
) !void;

/// 列出所有会话（按 updated_at 降序），调用方负责 free
pub fn list(
    allocator: std.mem.Allocator,
    sessions_dir: []const u8,
) ![]SessionSummary;

pub const SessionSummary = struct {
    id: SessionId,
    updated_at: i64,
    model_id: []const u8,
    message_count: u32,
};
```

**不变量**：
- 会话 ID 格式：`YYYYMMDD-HHMMSS-XXXX`（20 字节定长，无堆分配）
- 保存使用原子写入（写临时文件 + rename）
- 消息序列化/反序列化使用 `ai.context` 模块的类型，保持与 orbit-ai 一致
- 会话文件大小超过 50 MB 时，`load()` 返回错误（防止意外加载损坏大文件）
- `sessions_dir` 不存在时自动创建（包含所有父目录）

### Headless 模式

`src/cli/headless.zig`

当 `--headless` 参数存在时，不启动 TUI，改为向 stdout 输出 JSON lines。
每个 AgentEvent 序列化为一行 JSON，适合管道和脚本消费。

**输出格式**（每行一个 JSON 对象，以 `\n` 结尾）：

```json
{"type":"agent_start"}
{"type":"turn_start"}
{"type":"text_delta","text":"我来看一下当前的 auth 模块..."}
{"type":"tool_exec_start","id":"toolu_01","name":"read"}
{"type":"tool_exec_end","id":"toolu_01","name":"read","is_error":false}
{"type":"turn_end","input_tokens":1200,"output_tokens":340}
{"type":"agent_end","stop_reason":"complete",
 "total_input_tokens":1200,"total_output_tokens":340}
```

**输入**：从 stdin 读取用户消息，每行一条（适合管道输入）。
若 stdin 是 TTY，则从标准输入读取一行后发送，然后等待 agent_end，循环。

```zig
/// src/cli/headless.zig

/// 在 headless 模式下运行完整的代理循环
/// 从 stdin 读取用户消息，向 stdout 输出 JSON lines
pub fn run(
    allocator: std.mem.Allocator,
    agent: *agent_mod.Agent,
    session: *session_mod.Session,
) !void;

/// 将 AgentEvent 序列化为 JSON line（调用方 free）
fn serializeEvent(
    allocator: std.mem.Allocator,
    event: agent_types.AgentEvent,
) ![]const u8;
```

**不变量**：
- stdout 输出使用 `BufferedWriter`（4 KB 缓冲），每个 JSON line 后 flush
- 每个 JSON line 必须是完整的 JSON 对象，不能跨行
- 错误事件（`is_error: true`）仍然输出到 stdout，不输出到 stderr
  （调用方通过 `is_error` 字段判断，保持 stdout 的可解析性）
- 进程退出码：`0` 代表 `stop_reason=complete`，`1` 代表 `stop_reason=aborted`，
  `2` 代表 `stop_reason=err`

### 错误处理与用户反馈

**错误分类**：

| 错误类型 | 处理方式 |
|---------|----------|
| API key 未配置 | 启动时检测，打印明确提示后退出（不 panic）|
| 配置文件格式错误 | 打印行列号和错误描述后退出 |
| LLM API 错误（4xx/5xx）| 通过 AgentEvent.err 传递，TUI/headless 展示 |
| 工具执行错误 | 通过 ToolExecResult.is_error=true 传递给 LLM |
| 会话文件损坏 | 打印错误，提示用户 `--session` 指定其他会话或不传参开新会话 |
| OOM | 返回 error.OutOfMemory，main 打印通用错误后退出 |

**不变量**：
- 所有用户可见错误消息以 `orbit: ` 前缀开头，打印到 stderr
- `--verbose` 模式下，HTTP 请求/响应头输出到 stderr（不影响 headless stdout）
- 工具执行错误（`is_error=true`）不中止代理循环，LLM 会根据错误信息决策下一步

### 核心类型与 API

`src/cli/root.zig` 对外暴露的主要入口：

```zig
/// src/cli/root.zig

/// orbit-cli 的唯一公共入口，由 src/main.zig 调用
/// 包含完整的启动、运行、清理流程
pub fn run(allocator: std.mem.Allocator) !void;
```

`src/main.zig` 在新架构下极度简化：

```zig
/// src/main.zig（新架构目标形态）
const std = @import("std");
const cli = @import("cli/root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    try cli.run(gpa.allocator());
}
```

## Checklist

### Architecture Boundaries（来自 AGENTS.md）

- [x] `src/cli/` 不包含 LLM 通信逻辑（属于 `src/ai/`）
- [x] `src/cli/` 不包含代理循环逻辑（属于 `src/agent/`）
- [x] `src/cli/` 不包含渲染逻辑（未来如重建 TUI，将属于独立渲染层）
- [x] `src/main.zig` 只做分配器初始化和 `cli.run()` 调用
- [x] 工具实现通过 `agent.types.Tool` 接口注册，不绕过 agent 层

### Memory Safety

- [x] `register()` 返回的 tools slice 由 `unregister()` 负责 free
- [x] `Session.deinit()` 释放所有拥有的字段（model_id、provider、cwd、messages）
- [x] `Config.deinit()` 释放所有从 heap 分配的字段
- [x] bash 工具的子进程输出 buffer 在 execute() 返回前 free 或转移所有权
- [x] `loadContextFiles()` 返回的合并内容由调用方 free
- [x] `errdefer` 不用于 `catch` 后的 normal return 路径（见 STYLE.md 警告）

### User-Facing Behavior

- [x] `orbit --help` 打印用法说明后退出 0
- [x] `orbit` 开新会话
- [x] `orbit --continue` 续最新会话
- [x] `orbit --session <id>` 恢复指定会话
- [x] `orbit --model anthropic/claude-opus-4` 覆盖默认模型
- [x] `orbit --headless` 输出 JSON lines
- [x] `orbit --verbose` 输出原始 HTTP 交互到 stderr
- [x] `/model <provider>/<model-id>` 斜杠命令：会话中途切换模型
- [x] `/exit` 或 Ctrl-C 干净退出，保存当前会话
- [x] 无 API key 时打印可读错误并退出，不 panic
- [x] 配置文件不存在时静默使用默认值

### Impact Analysis

#### Application Flow and Runtime

- [x] Process lifecycle (`src/main.zig`) — 简化为 GPA 初始化 + `cli.run()`
- [x] Background work, subprocesses — bash 工具的子进程管理

#### State and Domain Model

- [x] Session, message, or task model — 会话 JSON 序列化
- [x] Persistence, serialization, or replay behavior — `~/.orbit/sessions/`

#### Agent Capabilities

- [x] File system operations — read/write/edit 工具
- [x] Command execution — bash 工具
- [x] Tool permissions or safety policy — YOLO 模式，无权限检查
- [x] Prompting, planning, or conversation flow — 系统提示构造 + AGENTS.md 注入

#### Reliability and Diagnostics

- [x] Error model and surfaced failures — 分层错误处理表
- [x] Assertions or defensive checks — 参数互斥、文件大小上限
- [x] Logging, tracing, or debug views — `--verbose` 模式

#### Developer Experience

- [x] Build/test workflow — `zig build test` 覆盖所有子模块
- [x] Configuration or CLI flags — `--model`、`--headless`、`--verbose` 等
- [x] Documentation — 本 RFC
- [x] Migration away from legacy opencode-zig behavior — 替代现有 `src/main.zig` 的启动逻辑

## Operational Considerations

### Performance and Resource Use

- **启动延迟**：配置加载（读 1 个 JSON 文件）+ AGENTS.md 加载（最多 3 个文件，
  每个 ≤ 64 KB）+ 会话加载（1 个 JSON 文件）。总计 < 5 次文件 I/O，目标 < 50ms
- **内存占用**：主要来自会话历史。单条消息平均 ~2 KB，1000 条消息 ≈ 2 MB。
  加上工具输出缓冲（bash 32 KB、read 4 MB 上限），峰值内存 < 10 MB（不含 LLM 响应流）
- **会话保存开销**：原子写入（写临时文件 + rename）。50 MB 上限保证单次写入 < 100ms
- **bash 工具子进程**：每次调用 fork + exec，开销由命令本身决定。timeout 机制防止挂起
- **热路径无隐藏分配**：工具 execute 函数的返回值（`ToolExecResult`）中的 `content`
  由工具分配，所有权转移给 agent 层。execute 内部不保留引用

### Observability and Debuggability

- `--verbose` 模式输出原始 HTTP 请求/响应头到 stderr，用于调试 API 问题
- Headless JSON lines 输出本身就是完整的执行日志，可用 `jq` 过滤分析
- 会话 JSON 文件可离线检查：`cat ~/.orbit/sessions/<id>.json | jq .total_usage`
- 工具执行的 `ui_details` 字段提供结构化详情（diff、退出码、执行时长）
- 所有错误消息以 `orbit: ` 前缀打印到 stderr，便于管道中区分

### Compatibility and Migration

- **新建模块**：`src/cli/` 是全新目录，不影响现有代码的编译
- **main.zig 迁移**：`src/main.zig` 现在已经直接调用 `cli.run()`，旧的事件循环入口已移除
- **历史状态模型迁移**：旧的会话消息状态已经由 `Session` 取代，重复逻辑已删除
- **历史命令分发迁移**：旧的命令分发入口已移除；当前命令入口由 CLI 层直接负责

## Testing

### 单元测试

- **config.zig**：
  - 配置文件不存在 → 返回默认值
  - 配置文件存在但为空 JSON `{}` → 返回默认值
  - 配置文件含非法 JSON → 返回解析错误
  - 环境变量覆盖配置文件值
  - `~` 路径展开正确
  - `Config.deinit()` 后无内存泄漏（使用 `std.testing.allocator`）

- **context_files.zig**：
  - 无任何 AGENTS.md → 返回 null
  - 仅全局 AGENTS.md → 返回全局内容
  - 全局 + 项目级 → 正确合并，带标题分隔
  - 文件超过 64 KB → 截断并返回（不报错）
  - git_root == cwd → 不重复加载
  - `findGitRoot` 向上查找 `.git` 目录，最大 16 层
  - `findGitRoot` 无 `.git` → 返回 null

- **session.zig**：
  - `SessionId.generate()` 格式正确（`YYYYMMDD-HHMMSS-XXXX`，20 字节）
  - Session 序列化 → 反序列化 round-trip 一致
  - 空消息列表的 Session 可正确序列化/反序列化
  - 会话文件超过 50 MB → `load()` 返回错误
  - `sessions_dir` 不存在 → `save()` 自动创建
  - `loadLatest` 在空目录 → 返回 null
  - `Session.deinit()` 后无内存泄漏

- **coding_tools.zig**：
  - read：正常文件 → 带行号输出
  - read：文件不存在 → `is_error=true`
  - read：二进制文件（含 `\x00`）→ `is_error=true`
  - read：offset/limit 分页正确
  - read：超过 4 MB → 报错
  - write：创建新文件 + 自动创建父目录
  - write：空内容 → 创建空文件
  - write：原子写入（中途崩溃不损坏原文件）
  - edit：精确匹配替换
  - edit：`old_text` 不存在 → `is_error=true`
  - edit：多次出现 → 只替换第一次
  - edit：文件不存在 → `is_error=true`
  - bash：正常命令 → 返回 stdout+stderr
  - bash：退出码非 0 → `is_error=false`，输出含退出码
  - bash：输出超过 32 KB → 截断
  - bash：timeout 超时 → `is_error=true`
  - bash：CWD 固定为启动目录

- **headless.zig**：
  - `serializeEvent` 对每种 AgentEvent 变体输出正确 JSON
  - 每行输出是完整 JSON 对象（可被 `std.json.parseFromSlice` 解析）

### 集成测试

- **完整启动流程**（使用 mock Provider）：
  - `cli.run()` → 加载配置 → 构造系统提示 → 创建 Agent → 保存会话
  - `--continue` → 加载最新会话 → Agent.messages 包含历史消息
  - `--session <id>` → 加载指定会话

- **工具 + Agent 循环**（使用 mock Provider）：
  - Provider 返回 tool_use → 工具执行 → 结果喂回 → Provider 返回文本 → 结束
  - 验证会话保存后包含完整的工具调用和结果

### 手动验证

- TUI 模式下完整对话流程（read → edit → bash 测试）
- Headless 模式输出可被 `jq` 解析
- `--verbose` 输出 HTTP 头到 stderr
- 会话 resume 后上下文正确恢复

## Rollout Plan

分四步，每步独立可测试：

1. **Step 1: config.zig + context_files.zig**
   纯文件 I/O 模块，无外部依赖。可独立编译和测试。

2. **Step 2: session.zig**
   会话序列化/反序列化，依赖 `ai.types.Message` 和 `ai.context`。
   用 `std.testing.allocator` 验证 round-trip 和内存安全。

3. **Step 3: coding_tools.zig**
   四个工具实现，依赖 `agent.types.Tool` 接口。
   每个工具可独立测试（创建临时文件/目录）。

4. **Step 4: root.zig + headless.zig**
   串联所有模块，替换 `src/main.zig`。
   用 mock Provider 做集成测试，最后接入真实 API 做端到端验证。

每步完成后运行 `zig build test` 验证。Step 4 完成后 orbit 可作为完整的编码代理运行。

## Alternatives Considered

### 1. TOML/YAML 配置格式 vs JSON

**考虑**：TOML 对人类更友好，YAML 更灵活。

**决策**：拒绝。Zig 标准库内置 `std.json`，无需额外依赖。配置字段极少（5 个），
JSON 的可读性足够。保持零外部依赖原则。

### 2. SQLite 会话存储 vs JSON 文件

**考虑**：SQLite 支持查询、索引、事务，适合大量会话。

**决策**：拒绝。引入 SQLite C 依赖违反零依赖原则。JSON 文件可直接用 `cat`/`jq`
检查，调试友好。会话数量预期 < 1000，文件系统遍历性能足够。

### 3. 工具实现放在 agent 层 vs CLI 层

**考虑**：agent 层直接包含工具实现，减少一层间接。

**决策**：拒绝。工具实现涉及文件系统和子进程操作，属于"具体环境绑定"。
agent 层应保持环境无关（只知道 Tool 接口），便于测试和未来扩展（如远程执行）。
这与 pi-mono 的分层一致：`agent` 包定义接口，`coding-agent` 包提供实现。

### 4. 初始消息通过 CLI 参数传入（`orbit "帮我重构"`）

**考虑**：pi-mono 支持 `pi "message"` 直接传入初始消息。

**决策**：延迟到 Phase 2。当前优先保证交互式流程正确。初始消息支持只需在
`parseCliArgs` 中收集位置参数，在 `run()` 中调用 `agent.prompt()` 前注入，
改动量小，可后续添加。

### 5. 使用 Zig 的 `std.process.ArgIterator` vs 手写解析

**考虑**：标准库提供了参数迭代器。

**决策**：采纳。使用 `std.process.argsWithAllocator()` 获取参数，手写简单的
flag 匹配（参数数量少，不需要完整的 arg parsing 库）。

## Open Questions

1. **会话清理策略**
   - 会话文件会无限积累。是否需要自动清理（如保留最近 100 个）？
   - 还是提供 `orbit sessions --prune` 子命令让用户手动清理？
   - **倾向**：暂不自动清理，后续根据用户反馈决定

2. **自定义模型支持**
   - 当前 `resolveModel` 只查找 `builtin_models` 注册表。用户如何使用未注册的模型？
   - 是否支持 `--model openai/gpt-4o-mini` 格式自动推断 provider 和 protocol？
   - **倾向**：支持 `provider/model-id` 格式，provider 决定 protocol，未知 model-id
     使用默认参数（context_window=128K, max_output=8K）

3. **Headless 模式的初始消息输入**
   - 当前设计从 stdin 逐行读取。是否支持 `orbit --headless "初始消息"` 的 CLI 参数形式？
   - 管道场景（`echo "帮我重构" | orbit --headless`）是否需要特殊处理？
   - **倾向**：与 Open Question 4（初始消息 CLI 参数）一起解决

4. **会话 fork/branch**
   - pi-mono 支持 `--fork <session-id>` 从历史会话分叉。是否需要？
   - **倾向**：Phase 2 考虑。当前 `--session <id>` 加载后继续即可，
     fork 语义（复制消息到新 ID）可后续添加

5. **AGENTS.md 文件名变体**
   - 是否支持 `.agents.md`（隐藏文件）或 `CLAUDE.md`（兼容 Claude Code）？
   - **倾向**：只支持 `AGENTS.md`，保持简单。用户可在 AGENTS.md 中 include 其他文件

6. **配置热重载**
   - 长会话中修改了 `~/.orbit/config.toml`，是否需要自动重载？
   - **倾向**：不需要。重启 orbit 即可。热重载增加复杂度，收益极小

## References

- pi-mono coding-agent CLI 入口：`references/pi-mono/packages/coding-agent/src/cli.ts`
- pi-mono CLI 参数解析：`references/pi-mono/packages/coding-agent/src/cli/args.ts`
- pi-mono 配置系统：`references/pi-mono/packages/coding-agent/src/config.ts`
- pi-mono 会话管理：`references/pi-mono/packages/coding-agent/src/cli/session-picker.ts`
- pi-mono 工具实现：`references/pi-mono/packages/coding-agent/src/core/tools/`
- orbit-agent 类型：`src/agent/types.zig`
- orbit-agent Agent 结构体：`src/agent/root.zig`
- orbit-ai 消息类型：`src/ai/types.zig`
- orbit-ai 模型注册表：`src/ai/models.zig`
- orbit-ai 上下文管理：`src/ai/context.zig`
- 四层架构 RFC：`rfcs/0001-four-layer-architecture.md`
- orbit-ai RFC：`rfcs/0002-orbit-ai-layer.md`
- orbit-agent RFC：`rfcs/0003-orbit-agent-layer.md`
- orbit-tui RFC：`rfcs/0004-orbit-tui.md`
- Mario Zechner 文章：https://mariozechner.at/posts/2025-11-30-pi-coding-agent/
