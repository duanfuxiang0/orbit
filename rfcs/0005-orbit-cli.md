# orbit-cli: Layer 4 CLI 入口与交互模式

Status: Draft (v2 — 集成 TUI 组件)

Authors:

* Orbit Team

Created: 2026-03-19

Last Updated: 2026-03-19

## Summary

orbit-cli 是四层架构的第四层，将 orbit-ai、orbit-agent、orbit-tui 串联成完整的
编码代理体验。职责：解析 CLI 参数、加载配置、构造系统提示、管理会话持久化、
注册编码工具、驱动交互模式或 headless 模式。

v2 变更：明确定义交互模式如何使用 TUI 组件，替代当前 `headless.zig` 中的
最简 `PromptInput` 实现。

## Motivation

当前 `src/cli/headless.zig` 同时承担两个职责：

1. **Headless JSON 模式**（`run()`）— 正确实现，输出 JSON lines
2. **交互文本模式**（`runText()` / `runTextInteractive()`）— 用 ~30 行的
   `PromptInput` 凑合，绕过了 `src/tui/` 的所有组件

结果：
- 输入不支持光标移动、历史记录（方向键被 `consumeEscapeSequence` 丢弃）
- LLM 输出直接 dump 原始文本，无 markdown 渲染
- Tool 执行只显示 `[tool name]`，无参数/结果/错误展示
- 流式输出虽然通过 `text_delta` 事件逐块写入，但无格式化

修复：将交互模式提取为独立模块 `interactive.zig`，使用 TUI 组件。

## Goals

- 交互模式使用 `tui.Editor` 处理用户输入
- 交互模式使用 `tui.Markdown` 渲染 LLM 文本输出
- 交互模式使用 `tui.ToolStatus` 渲染 tool 执行状态
- 交互模式使用 `tui.InlineRenderer` 做差分渲染
- Headless JSON 模式保持不变（`headless.zig` 的 `run()` 函数）
- 流式渲染：`text_delta` 事件实时追加到 Markdown 组件并重绘
- 清晰的模块边界：headless.zig 只管 JSON，interactive.zig 只管 TUI

## Non-Goals

- 全屏模式 / Vaxis 集成（后续 RFC）
- 多面板布局
- 鼠标交互
- 内置 undo / 版本控制
- 插件系统 / MCP 支持

## Design

### 模块结构变更

```
src/cli/
├── root.zig           # CLI 入口（已有，修改输出模式分发）
├── config.zig         # 配置加载（已有，不变）
├── session.zig        # 会话管理（已有，不变）
├── context_files.zig  # AGENTS.md 加载（已有，不变）
├── coding_tools.zig   # 四个编码工具（已有，不变）
├── headless.zig       # Headless JSON 模式（已有，删除 runText/PromptInput）
└── interactive.zig    # 交互 TUI 模式（新建，替代 headless.runText）
```

### root.zig 变更

当前 `root.zig` 的输出模式分发：

```zig
// 当前代码
if (args.headless) {
    try headless.run(allocator, &agent, &session);
} else {
    try headless.runText(allocator, &agent, &session);  // ← 问题所在
}
```

改为：

```zig
// 修改后
if (args.headless) {
    try headless.run(allocator, &agent, &session);
} else {
    try interactive.run(allocator, &agent, &session);
}
```

### interactive.zig（新建）

交互模式的核心模块。职责：
- 管理 raw mode 终端
- 使用 TUI Editor 接收用户输入
- 使用 TUI InlineRenderer 渲染输出
- 将 AgentEvent 转换为 TUI 组件更新

```zig
// src/cli/interactive.zig

pub fn run(
    allocator: std.mem.Allocator,
    agent: *agent_mod.Agent,
    session: *session_mod.Session,
) !void;
```

#### 交互循环

```
初始化:
  1. 进入 raw mode
  2. 创建 Editor（prompt: "> "）
  3. 创建 InlineRenderer（写入 stdout）

主循环:
  1. 渲染 Editor 到 InlineRenderer
  2. 读取 stdin 字节
  3. 如果是 Enter:
     a. 获取 Editor 文本
     b. 如果是 /exit → 退出
     c. 将文本推入 Editor 历史
     d. 清空 Editor
     e. 调用 agent.prompt(text, &sink, null)
        - sink 将 text_delta 追加到 Markdown 组件
        - sink 将 tool 事件更新 ToolStatus 组件
        - 每次事件触发 InlineRenderer.render()
     f. 回到步骤 1
  4. 如果是 Ctrl+D（空行）→ 退出
  5. 否则：传递给 Editor.handleInput()，重新渲染
```

#### AgentEvent → TUI 组件映射

| AgentEvent | TUI 动作 |
|------------|----------|
| `text_delta` | 追加文本到当前 Markdown 组件，触发渲染 |
| `thinking_delta` | 追加到 thinking Markdown（dim 样式），触发渲染 |
| `tool_exec_start` | 创建 ToolStatus（running），添加到 Container |
| `tool_exec_end` | 更新 ToolStatus 为 done/error |
| `tool_call_start` | 忽略（tool_exec_start 已足够） |
| `tool_call_delta` | 忽略（参数在 exec 时已完整） |
| `turn_end` | 显示 token 用量摘要（dim 文本） |
| `err` | 显示错误信息（红色） |
| `agent_start/end` | 无可见动作 |

#### 渲染布局

交互模式的屏幕布局是纯垂直堆叠，每轮对话追加到 scrollback：

```
> 用户输入的消息                          ← 已提交的输入（普通文本）
                                          
assistant:                                ← 角色标签（dim）
  这是 LLM 的回复，支持 **markdown**      ← Markdown 组件渲染
  ```zig                                  
  const x = 42;                           ← 代码块（灰底）
  ```                                     
                                          
✓ read src/main.zig                       ← ToolStatus（绿色）
✓ edit src/foo.zig                        ← ToolStatus（绿色）
✗ bash make test                          ← ToolStatus（红色，如果失败）
                                          
tokens: 1.2k in / 340 out                ← 用量摘要（dim）
                                          
> _                                       ← Editor 组件（等待输入）
```

每轮对话完成后，上方内容成为终端 scrollback 历史（用户可用终端原生滚动查看）。
只有最底部的 Editor 行需要差分渲染（用户打字时实时更新）。

#### 流式渲染策略

`text_delta` 事件是逐块到达的（通常几个字到几十个字）。渲染策略：

1. 每个 `text_delta` 追加到一个 `std.ArrayList(u8)` 缓冲区
2. 直接将 delta 文本写入 stdout（无需差分渲染，因为是追加）
3. 当 turn 结束时，用完整文本创建 Markdown 组件做最终渲染（可选优化）

这避免了每个 delta 都做完整 markdown 解析和差分渲染的开销。

### headless.zig 变更

删除以下内容（移到 interactive.zig）：
- `runText()` 函数
- `runTextInteractive()` 函数
- `runTextLineBuffered()` 函数
- `PromptInput` 结构体
- `RawMode` 结构体
- `readPromptLine()` 函数
- `renderPrompt()` 函数
- `consumeEscapeSequence()` 函数
- `isPromptPrintable()` 函数
- `TextSinkCtx` 结构体

保留：
- `run()` 函数（headless JSON 模式）
- `SinkCtx` 结构体（JSON 序列化 sink）
- `serializeEvent()` 函数
- 相关测试

### 其余模块不变

`config.zig`、`session.zig`、`context_files.zig`、`coding_tools.zig` 保持不变。
它们的设计和实现已经正确。

## Testing

### interactive.zig 测试

交互模式涉及终端 I/O，难以完全自动化测试。策略：

- 事件到组件的映射逻辑提取为纯函数，可单元测试
- InlineRenderer 的差分逻辑在 `tui/renderer.zig` 中测试
- Editor 和 Markdown 的渲染在 `tui/` 中已有测试
- 端到端手动测试：验证输入编辑、流式输出、tool 渲染

### 回归测试

- headless.zig 的 `serializeEvent` 测试保持不变
- `PromptInput` 测试删除（被 `tui/editor.zig` 的测试替代）

## Implementation

三步完成：

1. **TUI 层就绪**（RFC 0004 实现）：重写 `tui/root.zig`，新建 `renderer.zig`
   和 `tool_status.zig`
2. **新建 `interactive.zig`**：实现交互循环，使用 TUI 组件
3. **清理 `headless.zig`**：删除交互模式代码，修改 `root.zig` 分发

步骤 2 和 3 可以同时进行（先新建 interactive.zig，再删除 headless.zig 中的旧代码）。

## Appendix: 保留的 CLI 设计（v1 不变部分）

以下 v1 RFC 的设计保持不变，此处不再重复：

- CLI 参数定义（`CliArgs`）
- 配置系统（`config.zig`）
- 系统提示构造（`buildSystemPrompt`）
- AGENTS.md 层级加载（`context_files.zig`）
- 四个编码工具（`coding_tools.zig`）
- 会话管理（`session.zig`）
- Headless JSON 模式（`headless.zig` 的 `run()` 函数）
- 错误处理策略

详见 v1 RFC 原文或直接参考对应源文件。
