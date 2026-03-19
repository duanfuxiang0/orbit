# orbit-tui: Inline 终端 UI 层

Status: Draft (v2 — 简化重写)

Authors:

* Orbit Team

Created: 2026-03-18

Last Updated: 2026-03-19

## Summary

orbit-tui（Layer 3）是一组可组合的终端 UI 组件，直接写入 scrollback buffer。
CLI 层组装这些组件来渲染 agent 输出和接收用户输入。

核心能力：
- 组件化渲染（Component 接口 + Container 垂直堆叠）
- Editor 输入组件（光标移动、退格、历史记录、Emacs 快捷键）
- Markdown 渲染（标题、代码块、ANSI 样式）
- 差分渲染（backbuffer 比较，只重绘变化行，synchronized output 防闪烁）

不包含：事件循环、输入读取、agent 集成。这些由 CLI 层负责。

## Motivation

当前 CLI 的交互模式（`headless.zig` 的 `runTextInteractive`）绕过了 `src/tui/`
的所有组件，用一个 ~30 行的 `PromptInput` 结构体处理输入：

- 不支持光标移动（方向键被丢弃）
- 不支持历史记录
- LLM 输出直接 dump 原始文本，无 markdown 渲染
- Tool 执行只显示 `[tool name]`，无参数/结果展示

同时 `src/tui/` 已有可用的组件（editor、markdown、component），但 `tui/root.zig`
依赖三个不存在的模块（`state.zig`、`runtime/renderer.zig`、`ui/root.zig`），
导致整个 TUI 层无法编译，成为死代码。

修复方向：删除 `tui/root.zig` 对不存在模块的依赖，让 TUI 层成为纯组件库，
由 CLI 层直接使用。

## Goals

- TUI 层是纯组件库，无外部依赖（不依赖 vaxis、state、runtime）
- Component 接口：render → `[][]const u8`（行数组），handle_input → bool
- Editor 组件：光标左右移动、退格、Ctrl+A/E、上下箭头历史
- Markdown 组件：标题加粗、代码块灰底、自动换行、渲染缓存
- InlineRenderer：backbuffer 差分渲染 + synchronized output
- ToolStatus 组件：显示 tool 名称、执行状态、结果摘要
- 所有组件可独立测试（`std.testing.allocator` 检测泄漏）

## Non-Goals

- Vaxis 集成 / 全屏模式（后续 RFC）
- DECSTBM 滚动区域 / viewport 管理（后续 RFC）
- 鼠标支持、图片渲染、语法高亮
- 事件循环、输入读取（CLI 层职责）
- 自定义主题

## Design

### 模块结构

```
src/tui/
├── root.zig           # 模块入口，导出所有公共类型
├── component.zig      # Component 接口、Container、Text（已实现，保持不变）
├── editor.zig         # 输入编辑器（已实现，保持不变）
├── markdown.zig       # Markdown 渲染（已实现，保持不变）
├── ansi.zig           # ANSI 转义码工具（已实现，保持不变）
├── lines_util.zig     # 行数组工具函数（已实现，保持不变）
├── renderer.zig       # InlineRenderer：差分渲染引擎（新建）
├── tool_status.zig    # ToolStatus 组件（新建）
├── terminal.zig       # 终端尺寸检测（简化，删除未用功能）
├── viewport.zig       # 保留基础类型（简化）
└── insert_history.zig # 保留（已实现，暂不使用）
```

### root.zig 重写

当前 `root.zig` 依赖不存在的模块，需要重写为纯模块入口：

```zig
// src/tui/root.zig — 仅导出公共类型
pub const component = @import("component.zig");
pub const editor = @import("editor.zig");
pub const markdown = @import("markdown.zig");
pub const ansi = @import("ansi.zig");
pub const lines_util = @import("lines_util.zig");
pub const renderer = @import("renderer.zig");
pub const tool_status = @import("tool_status.zig");

pub const Component = component.Component;
pub const Container = component.Container;
pub const Text = component.Text;
pub const Editor = editor.Editor;
pub const Markdown = markdown.Markdown;
pub const InlineRenderer = renderer.InlineRenderer;
pub const ToolStatus = tool_status.ToolStatus;
```

### InlineRenderer（新建）

从当前 `root.zig` 的 `Tui` 结构体中提取差分渲染逻辑，去掉对 vaxis/state/runtime
的依赖。只负责：给定一组行，与上一帧比较，输出最小 ANSI 序列。

```zig
// src/tui/renderer.zig
pub const InlineRenderer = struct {
    allocator: Allocator,
    writer: std.fs.File,
    backbuffer: std.ArrayList([]u8),
    cursor_row: u16,
    cursor_col: u16,

    pub fn init(allocator: Allocator, writer: std.fs.File) InlineRenderer;
    pub fn deinit(self: *InlineRenderer) void;

    /// 渲染一组行到终端。与 backbuffer 比较，只输出变化部分。
    /// cursor_row/cursor_col 指定渲染后光标位置。
    pub fn render(
        self: *InlineRenderer,
        lines: []const []const u8,
        cursor_row: u16,
        cursor_col: u16,
    ) !void;

    /// 清空 backbuffer，下次 render 强制全量重绘。
    pub fn invalidate(self: *InlineRenderer) void;
};
```

渲染流程：
1. `\x1b[?2026h` 开始 synchronized output
2. 移动光标到第一行（`\x1b[<N>A\r`）
3. 遍历行，跳过与 backbuffer 相同的行，只重绘变化行（`\r` + 内容 + `\x1b[K`）
4. 处理行数增减（追加新行 / 清除多余行）
5. 定位光标到指定位置
6. `\x1b[?2026l` 结束 synchronized output
7. 更新 backbuffer

### ToolStatus 组件（新建）

显示 tool 执行的状态信息：

```zig
// src/tui/tool_status.zig
pub const ToolStatus = struct {
    allocator: Allocator,
    name: []u8,
    state: State,
    detail: ?[]u8,

    pub const State = enum { running, done, err };

    pub fn init(allocator: Allocator, name: []const u8) !ToolStatus;
    pub fn deinit(self: *ToolStatus) void;
    pub fn setDone(self: *ToolStatus, detail: ?[]const u8) !void;
    pub fn setError(self: *ToolStatus, detail: ?[]const u8) !void;
    pub fn component(self: *ToolStatus) Component;
};
```

渲染输出示例：
```
⟳ bash                    （running 状态，黄色）
✓ read src/main.zig       （done 状态，绿色）
✗ edit not_found.zig      （error 状态，红色）
```

### 已有组件（保持不变）

以下组件已实现且测试通过，不需要修改：

- `component.zig` — Component 接口（vtable）、Container（垂直堆叠）、Text
- `editor.zig` — 行编辑器：光标移动、退格、Ctrl+A/E、上下箭头历史、渲染缓存
- `markdown.zig` — Markdown 渲染：标题加粗、代码块灰底、自动换行、padding、缓存
- `ansi.zig` — ANSI 工具：colored、boldText、dimText、bgGray
- `lines_util.zig` — 行数组工具：cloneLines、freeLines、appendOwnedLines

### 删除 / 简化

- `terminal.zig` — 保留 `Size` 结构体和尺寸检测，删除 `moveTo`/`setScrollRegion`
  等未使用的方法
- `viewport.zig` — 保留基础类型定义
- `insert_history.zig` — 保留代码（已测试），但当前不集成
- `vaxis_bridge.zig` — 删除（依赖不存在的 `runtime/renderer.zig`）

## Testing

所有组件使用 `std.testing.allocator` 测试，检测内存泄漏。

- `renderer.zig`：
  - 首次渲染 → 全量输出
  - 无变化 → 无输出（除光标移动）
  - 单行变化 → 只重绘该行
  - 行数增加 → 追加新行
  - 行数减少 → 清除多余行
  - `invalidate()` 后 → 全量重绘

- `tool_status.zig`：
  - running 状态渲染包含工具名
  - done 状态渲染包含 detail
  - error 状态渲染包含 detail

已有组件的测试已通过，不需要新增。

## Implementation

两步完成：

1. 重写 `root.zig` 为纯导出模块，删除 `vaxis_bridge.zig`，简化 `terminal.zig`
2. 新建 `renderer.zig`（从当前 root.zig 的差分渲染逻辑提取）和 `tool_status.zig`

完成后 `src/tui/` 成为无外部依赖的纯组件库，CLI 层可直接 import 使用。
