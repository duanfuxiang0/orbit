# System Prompt 实用化改造：对齐 Pi 架构

Table of Contents:

<!-- TOC start (generate with https://bitdowntoc.derlin.ch) -->

- [Summary](#summary)
- [Motivation](#motivation)
- [Goals](#goals)
- [Non-Goals](#non-goals)
- [Background](#background)
  - [Orbit 现状](#orbit-现状)
  - [Pi 最新架构](#pi-最新架构)
- [Proposal](#proposal)
  - [1. Tool 自描述 — prompt_snippet 与 prompt_guidelines](#1-tool-自描述--prompt_snippet-与-prompt_guidelines)
  - [2. 动态 System Prompt 构建](#2-动态-system-prompt-构建)
  - [3. 结构化 Context Files](#3-结构化-context-files)
  - [4. 日期获取](#4-日期获取)
  - [5. 调用点变更](#5-调用点变更)
  - [6. Skills 系统（预留接口，暂不实现）](#6-skills-系统预留接口暂不实现)
  - [完整 Prompt 输出示例](#完整-prompt-输出示例)
- [User-Facing Behavior](#user-facing-behavior)
- [Architecture and Module Ownership](#architecture-and-module-ownership)
- [State and Data Model](#state-and-data-model)
- [Failure Modes and Safety](#failure-modes-and-safety)
- [Impact Analysis](#impact-analysis)
- [Operational Considerations](#operational-considerations)
- [Testing](#testing)
- [Rollout Plan](#rollout-plan)
- [Alternatives Considered](#alternatives-considered)
- [Open Questions](#open-questions)
- [References](#references)

<!-- TOC end -->

Status: Draft

Authors:

* Orbit Team

Created: 2026-03-19

Last Updated: 2026-04-10

## Summary

Orbit 当前的 `buildSystemPrompt` 是一段静态硬编码字符串：工具列表、使用指南、
项目上下文全部写死，不传递运行时上下文（cwd、日期），若干关键行为指南缺失，
项目文件的拼接格式简陋。

Pi（pi-mono）采用了模块化的提示词架构：每个工具自带 `promptSnippet`（一行描述）和
`promptGuidelines`（使用指南），system prompt 在运行时根据实际注册的工具动态组装，
context files 以 `{path, content}` 结构化传递，cwd 和日期注入 prompt 末尾。

本 RFC 提出一次性改造：让工具自描述提示词片段，`buildSystemPrompt` 动态拼接，
注入 cwd 和日期，context files 改为结构化列表，补全缺失指南，为未来 skills 系统预留接口。

## Motivation

### 1. 模型不知道自己在哪里

当前 prompt 不传递当前工作目录和日期，模型在需要构造路径或判断时效性时只能猜测。
Pi 的 `buildSystemPrompt` 始终将这两个字段注入 prompt 末尾：

```
Current date: 2026-03-19
Current working directory: /home/ubuntu/orbit
```

实际上 `cwd` 已经通过 `loadOrCreateSession` 传入，但 `buildSystemPrompt` 没有接收它。

### 2. 工具与提示词的耦合

当前 `buildSystemPrompt` 硬编码了 4 个工具的名称和描述：

```zig
\\Available tools:
\\- read: Read file contents. Supports offset and limit for large files.
\\- bash: Execute bash commands. Use for file listing, search, compilation, testing.
\\- edit: Make precise text replacements in files. The old_text must match exactly.
\\- write: Create or overwrite files. Automatically creates parent directories.
```

如果新增工具（如 `grep`、`find`、`ls`），必须同时修改 `buildSystemPrompt` 和工具注册
两处代码。Pi 的做法是：工具定义时就声明自己的 `promptSnippet` 和 `promptGuidelines`，
system prompt 构建器只需遍历已注册工具即可。

### 3. Guidelines 无法按工具条件化

当前 6 条 guidelines 是静态的。Pi 的 guidelines 是动态的：

```typescript
// 只有同时有 bash 且无 grep/find/ls 时才添加
if (hasBash && !hasGrep && !hasFind && !hasLs) {
  addGuideline("Use bash for file operations like ls, rg, find");
} else if (hasBash && (hasGrep || hasFind || hasLs)) {
  addGuideline("Prefer grep/find/ls tools over bash for file exploration");
}
```

当 Orbit 未来添加专用的 grep/find 工具时，当前的 "Use bash for exploration: ls, grep,
find, cat for quick checks" 指南会与专用工具的指南矛盾。

### 4. 若干关键行为指南缺失

当前指南有 6 条，但以下几条在实践中重要却缺失：

- **禁止用 `cat`/`sed` 读文件**：模型常倾向于用 `bash` + `cat` 读文件，而不用 `read` 工具。
  `read` 工具提供行号、支持 offset/limit，更适合大文件。
- **摘要用纯文本输出**：模型在总结自己的操作时常用 `bash -c 'echo ...'` 或代码块包裹，
  导致 TUI 输出混乱。Pi 明确要求 "output plain text directly - do NOT use cat or bash
  to display what you did"。
- **`edit` 失败时的处理建议**：当 `old_text` 匹配失败时，应先 `read` 确认文件当前内容再重试，
  而不是直接 `write` 覆盖整个文件。

采用工具自描述架构后，这些指南自然由各工具的 `prompt_guidelines` 字段声明。

### 5. Context Files 信息丢失

当前 `context_files.zig` 可以从三个位置加载 AGENTS.md（global、project、local），
但传给 `buildSystemPrompt` 时已被合并为单一字符串，文件来源信息丢失。Pi 传递的是
`Array<{ path: string; content: string }>`，每个文件在 prompt 中有独立的路径标题。
这在未来支持多个上下文文件（如同时加载 `AGENTS.md` 和 `STYLE.md`）时尤为重要。

### 6. 项目上下文格式不规范

当前拼接用 `---` 分隔符，无标题标注：

```
<base prompt>

---
<agents_md 的原始内容>
```

Pi 的格式有显式的节标题和文件路径标注：

```
# Project Context

Project-specific instructions and guidelines:

## /path/to/AGENTS.md

<content>
```

### 7. Prompt Cache 效率

Anthropic 和 OpenAI 的 prompt cache 均基于前缀匹配。`cwd` 和日期每次运行都不同，
若放在 prompt 开头，会导致 cache miss 增加。放在末尾可以最大化稳定前缀的长度。

### 8. 与 Pi 保持架构对齐

Orbit 的四层架构（ai → agent → tui → cli）直接参考 Pi。提示词是编码代理的核心，
保持架构对齐可以持续从 Pi 的迭代中获益，降低参考和移植的心智负担。

## Goals

- **Tool 自描述**：`Tool` 类型新增 `prompt_snippet` 和 `prompt_guidelines` 可选字段，
  工具注册时声明自己在 system prompt 中的描述和使用指南。
- **动态构建**：`buildSystemPrompt` 接收工具列表，从中提取 snippet 和 guidelines，
  动态拼接 "Available tools" 和 "Guidelines" 段落。
- **条件化 Guidelines**：根据已注册工具集合，生成上下文相关的探索指南（如有 grep 则
  优先 grep，无 grep 则建议 bash）。自动去重，避免多个工具声明相同指南导致重复。
- **补全缺失指南**：禁用 `cat`/`sed`、纯文本摘要、`edit` 失败处理——通过各工具的
  `prompt_guidelines` 声明，而非硬编码在 `buildSystemPrompt` 中。
- **注入运行时上下文**：`buildSystemPrompt` 接收 `cwd` 参数，注入当前日期（UTC，
  `YYYY-MM-DD`）和工作目录到 prompt 末尾，最大化 prompt cache 前缀命中率。
- **结构化 Context Files**：`buildSystemPrompt` 接收 `[]ContextFile`（path + content），
  每个文件在 prompt 中有 `## /path/to/file` 标题，为多文件扩展做好准备。

## Non-Goals

- 不在本 RFC 中实现多上下文文件支持（仅为其预留格式）。
- 不实现完整的 Skills 系统（仅预留接口形状）。
- 不实现 SYSTEM.md / APPEND_SYSTEM.md 自定义 prompt 替换（Pi 的高级特性，Orbit 暂不需要）。
- 不引入 extension/hook 系统修改 prompt（属于更大的扩展架构讨论）。
- 不改变工具注册逻辑或工具的执行逻辑、参数 schema，仅增加 prompt 元数据字段。
- 不修改 session 持久化格式。

## Background

### Orbit 现状

当前实现位于 `src/cli/root.zig` 的 `buildSystemPrompt` 函数（约第 152 行）：

```zig
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
```

问题清单：

- 硬编码角色声明、4 个工具描述、6 条 guidelines
- `agents_md` 为可选的合并字符串，以 `---` 分隔符拼接，文件来源信息丢失
- 不接收 cwd 或日期
- 不接收工具列表——新增工具需改两处代码

`src/agent/types.zig` 的 `Tool` 结构无 prompt 相关字段：

```zig
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
    execute: *const fn (...) ToolExecResult,
    ctx: *anyopaque,
};
```

调用点在 `run()` 函数中（约第 48 行），此时 `cwd` 已可用但未传入：

```zig
const system_prompt = try buildSystemPrompt(allocator, agents_md);
```

### Pi 最新架构

Pi 的 `buildSystemPrompt`（`packages/coding-agent/src/core/system-prompt.ts`）接收：

```typescript
interface BuildSystemPromptOptions {
    customPrompt?: string;
    selectedTools?: string[];
    toolSnippets?: Record<string, string>;      // 工具名 → 一行描述
    promptGuidelines?: string[];                 // 工具贡献的指南
    appendSystemPrompt?: string;
    cwd?: string;
    contextFiles?: Array<{ path: string; content: string }>;
    skills?: Skill[];
}
```

工具定义时声明 prompt 元数据（`ToolDefinition` 接口）：

| 工具 | promptSnippet | promptGuidelines |
|------|--------------|-----------------|
| read | "Read file contents" | "Use read to examine files instead of cat or sed." |
| bash | "Execute bash commands (ls, grep, find, etc.)" | _(无)_ |
| edit | "Make precise file edits with exact text replacement, including multiple disjoint edits in one call" | "Use edit for precise changes (edits[].oldText must match exactly)", "When changing multiple separate locations in one file, use one edit call with multiple entries...", "Each edits[].oldText is matched against the original file, not after earlier edits are applied...", "Keep edits[].oldText as small as possible while still being unique..." |
| write | "Create or overwrite files" | "Use write only for new files or complete rewrites." |
| grep | "Search file contents for patterns (respects .gitignore)" | _(无)_ |
| find | "Find files by glob pattern (respects .gitignore)" | _(无)_ |
| ls | "List directory contents" | _(无)_ |

动态 Guidelines 逻辑：

1. 收集所有已注册工具的 `promptGuidelines`，去重
2. 根据工具组合添加条件化指南（bash-only vs bash+grep/find/ls）
3. 追加全局指南："Be concise in your responses"、"Show file paths clearly when working with files"

Prompt 最终结构（按段落顺序）：

```
[1] 角色声明
[2] Available tools（仅有 promptSnippet 的工具出现）
[3] Guidelines（动态收集 + 条件化 + 全局）
[4] Documentation 引用（Pi 特有，Orbit 不需要）
[5] Append section（可选）
[6] Project Context（结构化 path+content）
[7] Skills（XML 格式，可选）
[8] Current date + Current working directory
```

`[8]` 始终在最末尾，保证 prompt cache 前缀最大化。

## Proposal

### 1. Tool 自描述 — prompt_snippet 与 prompt_guidelines

#### 修改 `src/agent/types.zig` 的 `Tool` 结构

```zig
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
    execute: *const fn (...) ToolExecResult,
    ctx: *anyopaque,

    // ---- 新增 ----
    /// 一行描述，用于 system prompt 的 "Available tools" 列表。
    /// 若为 null，该工具不出现在 prompt 的工具列表中（但仍可被模型调用）。
    prompt_snippet: ?[]const u8 = null,

    /// 该工具贡献的使用指南，拼接到 "Guidelines" 段落。
    /// 使用 comptime 已知长度的 slice。
    prompt_guidelines: []const []const u8 = &.{},
};
```

`prompt_snippet` 和 `prompt_guidelines` 均为 `comptime` 已知的字符串字面量引用，
与现有的 `name`、`description` 生命周期一致（进程全局静态），无额外分配。

`toSpec()` 不变——prompt 字段不传给 AI provider（它们是 CLI 层概念，不属于 API schema）。

#### 各工具的声明值

对齐 Pi 的最新定义，同时适配 Orbit 的工具语义差异：

**read 工具**：

```zig
.prompt_snippet = "Read file contents. Supports offset and limit for large files.",
.prompt_guidelines = &.{
    "Use read to examine files before editing. Do not use bash with cat or sed to read file contents.",
},
```

**bash 工具**：

```zig
.prompt_snippet = "Execute bash commands. Use for file operations, search, compilation, and testing.",
.prompt_guidelines = &.{},  // 条件化指南由 buildSystemPrompt 根据工具组合生成
```

**edit 工具**：

```zig
.prompt_snippet = "Make precise text replacements in files. The old_text must match exactly.",
.prompt_guidelines = &.{
    "Use edit for surgical changes; prefer edit over write for existing files.",
    "If edit fails due to old_text mismatch, use read to verify the current file content before retrying. Do not fall back to write for existing files.",
},
```

**write 工具**：

```zig
.prompt_snippet = "Create or overwrite files. Automatically creates parent directories.",
.prompt_guidelines = &.{
    "Use write only for new files or complete rewrites.",
},
```

> 未来添加 `grep`、`find`、`ls` 工具时，只需在各自注册处声明 snippet 和 guidelines，
> `buildSystemPrompt` 无需修改。

### 2. 动态 System Prompt 构建

#### 新增 ContextFile 类型

在 `src/cli/root.zig`（或独立文件 `src/cli/prompt.zig`，如代码量超过 ~100 行）：

```zig
pub const ContextFile = struct {
    path: []const u8,
    content: []const u8,
};
```

#### 修改 buildSystemPrompt 签名

```zig
fn buildSystemPrompt(
    allocator: std.mem.Allocator,
    tools: []const agent_types.Tool,
    context_files: []const ContextFile,
    cwd: []const u8,
) ![]const u8
```

#### 构建逻辑（伪代码）

```zig
fn buildSystemPrompt(...) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const w = buf.writer();

    // [1] 角色声明
    try w.writeAll(
        "You are an expert coding assistant operating inside orbit, a coding agent. " ++
        "You help users by reading files, executing commands, editing code, and writing new files."
    );

    // [2] Available tools — 仅包含有 prompt_snippet 的工具
    try w.writeAll("\n\nAvailable tools:\n");
    var has_any_tool = false;
    for (tools) |tool| {
        if (tool.prompt_snippet) |snippet| {
            try w.print("- {s}: {s}\n", .{ tool.name, snippet });
            has_any_tool = true;
        }
    }
    if (!has_any_tool) try w.writeAll("(none)\n");

    // [3] Guidelines — 收集工具贡献 + 条件化 + 全局
    try w.writeAll("\nGuidelines:\n");

    // 3a. 收集各工具的 prompt_guidelines（去重）
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (tools) |tool| {
        for (tool.prompt_guidelines) |guideline| {
            const gop = try seen.getOrPut(guideline);
            if (!gop.found_existing) {
                try w.print("- {s}\n", .{guideline});
            }
        }
    }

    // 3b. 条件化探索指南
    const has_bash = hasToolNamed(tools, "bash");
    const has_grep = hasToolNamed(tools, "grep");
    const has_find = hasToolNamed(tools, "find");
    const has_ls   = hasToolNamed(tools, "ls");

    if (has_bash and !(has_grep or has_find or has_ls)) {
        try addGuidelineIfNew(&seen, w, "Use bash for file exploration: ls, grep, find.");
    } else if (has_bash and (has_grep or has_find or has_ls)) {
        try addGuidelineIfNew(&seen, w,
            "Prefer grep/find/ls tools over bash for file exploration (faster, respects .gitignore).");
    }

    // 3c. 全局指南
    try addGuidelineIfNew(&seen, w,
        "When summarizing your actions, output plain text directly. Do not use bash or code blocks to display what you did.");
    try addGuidelineIfNew(&seen, w,
        "Be concise in your responses. Show code, not lengthy explanations.");
    try addGuidelineIfNew(&seen, w,
        "Run tests after making changes when a test command is available.");

    // [4] Project Context（结构化）
    if (context_files.len > 0) {
        try w.writeAll("\n# Project Context\n\n");
        try w.writeAll("Project-specific instructions and guidelines:\n\n");
        for (context_files) |cf| {
            try w.print("## {s}\n\n{s}\n\n", .{ cf.path, cf.content });
        }
    }

    // [5] 日期和 CWD（始终在末尾，最大化 prompt cache 前缀）
    const date = try currentDateUtc(allocator);
    defer allocator.free(date);
    try w.print("\nCurrent date: {s}", .{date});
    try w.print("\nCurrent working directory: {s}", .{cwd});

    return buf.toOwnedSlice();
}
```

#### 辅助函数

```zig
fn hasToolNamed(tools: []const agent_types.Tool, name: []const u8) bool {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return true;
    }
    return false;
}

fn addGuidelineIfNew(
    seen: *std.StringHashMap(void),
    writer: anytype,
    guideline: []const u8,
) !void {
    const gop = try seen.getOrPut(guideline);
    if (!gop.found_existing) {
        try writer.print("- {s}\n", .{guideline});
    }
}
```

### 3. 结构化 Context Files

#### 修改 `src/cli/context_files.zig` 的返回类型

当前 `loadContextFiles` 返回 `?[]const u8`（合并后的字符串）。改为返回结构化列表：

```zig
pub const ContextFile = struct {
    path: []const u8,
    content: []const u8,
};

pub fn loadContextFiles(
    allocator: std.mem.Allocator,
    cwd: []const u8,
) ![]ContextFile
```

内部逻辑不变——仍然从 global、project、local 三个位置搜索 AGENTS.md——但不再合并为
单一字符串，而是返回各自的 `{path, content}` 对。

### 4. 日期获取

Zig 标准库通过 `std.time.timestamp()` 获取 Unix 时间戳，再手动换算为 `YYYY-MM-DD`。
封装为小型 helper：

```zig
/// Returns "YYYY-MM-DD" for the current UTC date.
/// Caller owns the returned slice.
fn currentDateUtc(allocator: std.mem.Allocator) ![]const u8 {
    const secs: i64 = std.time.timestamp();
    // days since Unix epoch
    const days = @divTrunc(secs, 86400);
    // Gregorian calendar calculation (standard algorithm)
    // ... (see Implementation Notes below)
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day });
}
```

此 helper 应与 `buildSystemPrompt` 同在 `src/cli/root.zig`（或 `prompt.zig`），
单一职责，小于 30 行。使用 UTC，不依赖时区环境变量，结果确定性强。

### 5. 调用点变更

`run()` 中：

```zig
// 旧
const agents_md = try context_files.loadContextFiles(allocator, cwd);
const system_prompt = try buildSystemPrompt(allocator, agents_md);

// 新
const ctx_files = try context_files.loadContextFiles(allocator, cwd);
const system_prompt = try buildSystemPrompt(allocator, registered_tools, ctx_files, cwd);
```

### 6. Skills 系统（预留接口，暂不实现）

Pi 的 Skills 以 XML 格式注入 system prompt：

```xml
<available_skills>
  <skill>
    <name>commit</name>
    <description>Create git commits with conventional format</description>
    <location>/home/user/.pi/agent/skills/commit/SKILL.md</location>
  </skill>
</available_skills>
```

本 RFC 不实现 skills，但在 `buildSystemPrompt` 签名中以注释预留接口：

```zig
fn buildSystemPrompt(
    allocator: std.mem.Allocator,
    tools: []const agent_types.Tool,
    context_files: []const ContextFile,
    cwd: []const u8,
    // 未来扩展：
    // skills: []const Skill,
    // append_prompt: ?[]const u8,
) ![]const u8
```

### 完整 Prompt 输出示例

以当前 4 个工具、一个 AGENTS.md 为例，最终输出：

```
You are an expert coding assistant operating inside orbit, a coding agent. You help users by reading files, executing commands, editing code, and writing new files.

Available tools:
- read: Read file contents. Supports offset and limit for large files.
- bash: Execute bash commands. Use for file operations, search, compilation, and testing.
- edit: Make precise text replacements in files. The old_text must match exactly.
- write: Create or overwrite files. Automatically creates parent directories.

Guidelines:
- Use read to examine files before editing. Do not use bash with cat or sed to read file contents.
- Use edit for surgical changes; prefer edit over write for existing files.
- If edit fails due to old_text mismatch, use read to verify the current file content before retrying. Do not fall back to write for existing files.
- Use write only for new files or complete rewrites.
- Use bash for file exploration: ls, grep, find.
- When summarizing your actions, output plain text directly. Do not use bash or code blocks to display what you did.
- Be concise in your responses. Show code, not lengthy explanations.
- Run tests after making changes when a test command is available.

# Project Context

Project-specific instructions and guidelines:

## /home/ubuntu/orbit/AGENTS.md

<AGENTS.md content>

Current date: 2026-04-10
Current working directory: /home/ubuntu/orbit
```

未来添加 `grep` 和 `find` 工具后，prompt 自动适应：

```diff
 Available tools:
  ...
+ - grep: Search file contents for patterns (respects .gitignore).
+ - find: Find files by glob pattern (respects .gitignore).

 Guidelines:
  ...
- - Use bash for file exploration: ls, grep, find.
+ - Prefer grep/find/ls tools over bash for file exploration (faster, respects .gitignore).
```

无需修改 `buildSystemPrompt`——条件化指南自动切换。

## User-Facing Behavior

无可见 TUI 变化。模型行为改善：

- 模型不再用 `cat` 读文件，改用 `read`（read 工具的 `prompt_guidelines` 明确禁止）。
- 模型在总结操作时输出纯文本，减少 TUI 中多余的代码块。
- `edit` 失败时先 `read` 再重试，而非直接 `write` 覆盖。
- 工具描述更精确（来自工具自身定义而非硬编码摘要）。
- Guidelines 与实际可用工具匹配，减少矛盾指令。
- Context files 标注来源路径，模型可区分 global vs project 指令。
- `--verbose` 模式下可观察到 system prompt 包含日期、CWD 和完整结构。

## Architecture and Module Ownership

| 变更 | 模块 | 说明 |
|------|------|------|
| `Tool` 新增 `prompt_snippet` / `prompt_guidelines` | `src/agent/types.zig` | 可选字段，默认值为 null/空，不破坏现有代码 |
| `ContextFile` 类型 | `src/cli/root.zig` 或新文件 `src/cli/prompt.zig` | 简单 struct |
| `buildSystemPrompt` 重写 | `src/cli/root.zig` 或 `src/cli/prompt.zig` | 核心变更：接收工具列表、context files、cwd |
| `currentDateUtc` helper | 同上 | 新增私有 helper，返回 caller-owned `[]const u8` |
| `loadContextFiles` 返回类型 | `src/cli/context_files.zig` | `?[]const u8` → `[]ContextFile` |
| 各工具注册处 | `src/cli/root.zig` 的 `run()` | 添加 snippet/guidelines 字段 |
| `toSpec()` | `src/agent/types.zig` | 不变——prompt 字段不传给 AI provider |

跨模块影响：`src/agent/types.zig`（Layer 2）新增字段，但该字段仅被 Layer 4（cli）消费。
Layer 2 的 `Agent` 不使用这些字段——它只关心 `toSpec()` 生成的 `ToolSpec`（name +
description + parameters_json）。无其他跨模块边界变更。

## State and Data Model

无持久化状态变更。System prompt 在每次进程启动时重新生成，不存储到 session 文件中。
`session.zig` 中的 `Session` 结构不变。`Tool` 的新字段为静态字面量，不影响内存生命周期。

## Failure Modes and Safety

- **分配失败**：`buildSystemPrompt` 使用 `ArrayList(u8)` 动态拼接，OOM 通过
  `![]const u8` 返回类型向上传播，与现有策略一致。`currentDateUtc` 同理。
- **空工具列表**：若所有工具都没有 `prompt_snippet`，"Available tools" 段显示
  `(none)`，与 Pi 行为一致。不会导致崩溃。
- **Guidelines 去重**：使用 `StringHashMap` 基于字符串内容去重。comptime 字面量
  指针稳定，效率高。即使指针不同但内容相同，最差情况是轻微重复，不影响正确性。
- **ContextFile 为空**：`context_files.len == 0` 时跳过 "# Project Context" 段，
  与现有 `agents_md == null` 行为等价。
- **时间戳换算**：使用 UTC，不依赖时区环境变量，结果确定性强。
- **`cwd` 生命周期**：`cwd` 由 `run()` 拥有，`buildSystemPrompt` 只读引用，无所有权转移。

## Impact Analysis

### Application Flow and Runtime

- [ ] Process lifecycle (`src/main.zig`)
- [ ] Event definitions and routing (`src/runtime/`)
- [x] CLI entry and config (`src/cli/`) — `buildSystemPrompt` 重写，调用点变更
- [ ] Agent loop (`src/agent/`) — `Tool` 结构新增字段，但 agent 逻辑不受影响
- [ ] AI provider layer (`src/ai/`)
- [ ] TUI (`src/tui/`)

### State and Domain Model

- [ ] State shape or ownership
- [ ] Session, message, or task model
- [ ] Persistence, serialization

### Agent Capabilities

- [x] Prompting, planning, or conversation flow — system prompt 结构变更
- [x] Tool permissions or safety policy — 工具自带 guidelines 影响模型行为

### Developer Experience

- [x] Build/test workflow — 需更新现有测试
- [x] Documentation — AGENTS.md 中 Tool 注册示例需更新

## Operational Considerations

### Performance and Resource Use

- **Startup cost**：`buildSystemPrompt` 从字符串字面量拼接改为 `ArrayList` 动态构建，
  差异在微秒级，可忽略。
- **内存**：`ArrayList(u8)` 比 `allocPrint` 更高效（避免多次格式化分配），
  最终 `toOwnedSlice` 后释放多余容量。
- **Prompt cache**：date/cwd 在末尾，最大化稳定前缀。
  工具顺序由注册顺序决定——只要注册顺序不变，prompt 前缀就稳定。

### Observability and Debuggability

- `--verbose` 模式下 system prompt 包含完整结构，可验证工具列表和 guidelines 正确。
- 新增测试覆盖各种工具组合。

## Testing

### 更新现有测试

- `"build system prompt appends agents md"` → 改为传入 `[]ContextFile` 和工具列表，
  验证输出仍包含 agents_md 内容。

### 新增测试

- `"system prompt lists tools with snippets"`：注册两个工具（一个有 snippet，一个无），
  验证仅有 snippet 的出现在 "Available tools" 中。
- `"system prompt collects tool guidelines"`：注册带 guidelines 的工具，
  验证 guidelines 出现在 "Guidelines" 段。
- `"system prompt deduplicates guidelines"`：两个工具声明相同 guideline，
  验证只出现一次。
- `"system prompt conditional bash guideline without grep"`：
  仅注册 bash，验证出现 "Use bash for file exploration"。
- `"system prompt conditional bash guideline with grep"`：
  注册 bash + grep，验证出现 "Prefer grep/find/ls tools over bash"。
- `"system prompt structured context files"`：传入两个 ContextFile，
  验证各自有 `## /path` 标题，不包含旧的 `---` 分隔符。
- `"system prompt contains cwd and date"`：验证传入的 cwd 字符串出现在输出中，
  验证输出包含格式为 `YYYY-MM-DD` 的日期字符串。
- `"system prompt empty tools"`：空工具列表，验证 "(none)" 出现。
- `"current date utc returns valid format"`：
  验证 `currentDateUtc` 返回长度为 10、格式为 `XXXX-XX-XX` 的字符串。

所有测试使用 `std.testing.allocator` 检测内存泄漏。

## Rollout Plan

- **Phase 1**：
  - 实现 `currentDateUtc` helper 并单独测试。
  - `Tool` 结构新增 `prompt_snippet` 和 `prompt_guidelines` 字段（带默认值，不破坏现有代码）。

- **Phase 2**：
  - 重写 `buildSystemPrompt`，接收工具列表和结构化 context files。
  - 各工具注册处添加 snippet 和 guidelines 值。
  - 更新 `loadContextFiles` 返回 `[]ContextFile`。

- **Phase 3**：
  - 更新 `run()` 调用点，传入完整参数。
  - 删除旧的硬编码 prompt。
  - 运行 `zig build test` 确认全部通过，运行 `zig fmt` 格式化。

单次 PR 即可完成。无需 feature flag——`prompt_snippet` 和 `prompt_guidelines` 的默认值
保证未设置这些字段的工具不受影响。

## Alternatives Considered

### A. 保持现状

拒绝理由：模型不知道 CWD，路径错误率高；`cat` 使用问题持续出现；工具-prompt 耦合导致
每新增一个工具都需改两处代码；guidelines 无法条件化；prompt cache 效率次优。

### B. 仅注入 cwd/日期，不改架构

即只做最小改动：`buildSystemPrompt` 接收 cwd，补全缺失指南，改格式。
拒绝理由：解决了 cwd/日期问题和当前的 guidelines 缺失，但工具-prompt 耦合仍在。
短期可行，但随着工具数量增长（grep、find、ls 等），维护成本线性上升，
且无法实现条件化 guidelines。

### C. 完全移植 Pi 的所有 prompt 特性

包括 Skills 系统、SYSTEM.md / APPEND_SYSTEM.md 自定义 prompt 替换、extension hooks。
拒绝理由：过度工程化。Orbit 当前只有 4 个工具，无 extension 系统，无 skills。
这些特性应在各自需要时以独立 RFC 引入。本 RFC 聚焦核心架构：
工具自描述 + 动态构建 + 运行时上下文注入。

### D. 将 prompt 元数据放在 ToolSpec 而非 Tool

即让 `ToolSpec`（传给 AI provider 的结构）也包含 snippet/guidelines。
拒绝理由：`ToolSpec` 是 API 层概念（Layer 1），对应 LLM API 的 tool schema。
Prompt snippet 是 CLI 层概念（Layer 4），用于构建 system prompt。
混在一起违反层级边界。Pi 也是在 `ToolDefinition`（应用层）而非 API schema 中定义这些字段。

### E. 将日期/CWD 作为 user 消息的前缀注入

即每条用户消息开头加上上下文。缺点：每轮对话重复注入，污染消息历史，增加 token 消耗。
System prompt 注入一次即可。

### F. Guidelines 作为独立配置而非工具字段

即一个集中式的 guidelines map，而非分散在各工具定义中。
拒绝理由：Pi 的实践证明，将 guidelines 与工具共置更易维护——新增工具时可以一站式声明
名称、描述、schema、prompt snippet、guidelines，无需跨文件协调。

### G. 将 Project Context 放在 prompt 开头

部分框架将项目规则放在角色声明之前。缺点：若 agents_md 变化（如用户切换项目），
prompt cache 前缀失效，且模型通常对系统指令的处理顺序不敏感。
保持当前顺序（角色 → 工具 → 指南 → 上下文 → 日期/CWD）。

## Open Questions

- **`currentDateUtc` 应返回 UTC 还是本地时区日期？**
  当前提案选 UTC，行为确定，不依赖 `TZ` 环境变量。如需本地时区，
  需要额外的时区偏移处理，复杂度显著增加，暂不考虑。

- **是否抽取 `src/cli/prompt.zig`？**
  如果 `buildSystemPrompt` + helpers + ContextFile + currentDateUtc
  超过 ~80 行，是否应从 `root.zig` 抽取为独立文件？这取决于实现后的实际行数。

- **Guidelines 去重策略**：当前提案用字符串内容比较去重。
  是否需要更精细的去重（如 normalize whitespace 后比较）？
  考虑到所有 guidelines 都是 comptime 字面量，简单相等比较应该足够。

- **agents_md 的路径标题**（`## /path/AGENTS.md`）是否应精确反映实际加载路径？
  当前 `context_files.zig` 已知道各文件路径，改为返回 `[]ContextFile` 后可精确标注。

## References

- `src/cli/root.zig` — 当前 `buildSystemPrompt` 实现（第 152-179 行）
- `src/agent/types.zig` — `Tool` 结构定义
- `src/cli/context_files.zig` — AGENTS.md 加载逻辑
- `references/pi-mono/packages/coding-agent/src/core/system-prompt.ts` — Pi 的
  `buildSystemPrompt` 参考实现（动态工具列表、条件化指南、日期/CWD 末尾注入、结构化上下文）
- `references/pi-mono/packages/coding-agent/src/core/skills.ts` — Pi 的 Skills 系统
- `references/pi-mono/packages/coding-agent/src/core/agent-session.ts` — Pi 的
  tool snippet/guidelines 收集逻辑（`_rebuildSystemPrompt`、`_normalizePromptSnippet`）
- `references/pi-mono/packages/coding-agent/src/core/tools/read.ts` — read 工具 prompt 声明
- `references/pi-mono/packages/coding-agent/src/core/tools/edit.ts` — edit 工具 prompt 声明
- `references/pi-mono/packages/coding-agent/src/core/tools/write.ts` — write 工具 prompt 声明
- `references/pi-mono/packages/coding-agent/src/core/tools/bash.ts` — bash 工具 prompt 声明
- `references/pi-mono/packages/coding-agent/src/core/extensions/types.ts` — Pi 的
  `ToolDefinition` 接口（promptSnippet、promptGuidelines 字段定义）
- `rfcs/0005-orbit-cli.md` — CLI 层职责边界

## Updates

- 2026-03-19: 初稿创建（cwd/日期注入、缺失指南补全、上下文格式规范化）。
- 2026-04-10: 合并 Pi 架构迁移方案——工具自描述、动态 prompt 构建、条件化 guidelines、
  结构化 context files。统一为一次性改造。
