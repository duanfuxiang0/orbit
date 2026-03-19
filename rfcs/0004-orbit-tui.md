# orbit-tui: Inline 终端 UI 层

Status: Draft (v3 — 差分渲染增强)

Authors:

* Orbit Team

Created: 2026-03-18

Last Updated: 2026-03-19

## Summary

orbit-tui（Layer 3）是一组可组合的终端 UI 组件，直接写入 scrollback buffer。
CLI 层组装这些组件来渲染 agent 输出和接收用户输入。

核心能力：
- 组件化渲染（Component 接口 + Container 垂直堆叠）
- Editor 输入组件（具体输入行为现以 `rfcs/0007-terminal-input-editor.md` 为准）
- Markdown 渲染（标题、代码块、ANSI 样式）
- 差分渲染（backbuffer 比较，只重绘变化行，synchronized output 防闪烁）

不包含：事件循环、输入读取、agent 集成。这些由 CLI 层负责。

### Phase 1（已完成）

基础组件库和简单差分渲染已实现并集成到 CLI 层。

### Phase 2（本次更新）

基于 pi-mono/pi-tui 的差分渲染方案，对 InlineRenderer 进行增强：
- 精确 diff：定位 firstChanged/lastChanged，只重绘变化区间
- 渲染节流：dirty flag + 时间节流，合并高频 token 更新
- append-only 快速路径：流式追加场景零光标跳转
- 内容缩短清理：行数减少时显式擦除残影
- 行尾 reset：防止 ANSI 样式泄漏
- viewport 感知：变化在可见区域之上时触发全量重绘

## Motivation

Phase 1 的 InlineRenderer 已能工作，但流式输出体验与 pi-tui 等成熟方案有明显差距：

1. **diff 算法遍历所有行**：即使只有最后一行变化，也要对每行发 `\r\n` 移动光标。
   pi-tui 直接跳到 firstChanged 行，只渲染 firstChanged..lastChanged。

2. **每个 token 触发完整渲染**：`text_delta` 事件每次都执行 markdown 解析 +
   渲染 + diff 全流程。pi-tui 用 `process.nextTick()` 将同一 tick 内的多次
   请求合并为一次渲染。Zig 无 event loop，但可用时间节流达到类似效果。

3. **无 append-only 快速路径**：流式输出的典型模式是已有行不变、末尾追加新行。
   pi-tui 检测此模式后直接从末尾 `\r\n` 追加，无需光标跳转。

4. **无内容缩短处理**：行数减少时不清除多余行，留下残影。

5. **无行尾 reset**：ANSI 样式可能泄漏到下一行。

6. **无 viewport 感知**：不跟踪可见区域，变化在 scrollback 上方时可能渲染错误。

## Goals

- InlineRenderer 精确 diff：只重绘 firstChanged..lastChanged 区间
- 渲染节流：高频更新时合并渲染，≤60fps
- append-only 快速路径：检测纯追加场景，跳过光标回溯
- 内容缩短时清除多余行
- 每行末尾追加 reset 序列防止样式泄漏
- viewport 感知：变化在可见区域之上时全量重绘
- 保持所有已有组件和测试不变
- 保持零外部依赖

## Non-Goals

- Vaxis 集成 / 全屏模式（后续 RFC）
- DECSTBM 滚动区域
- 鼠标支持、图片渲染、语法高亮
- 事件循环、输入读取（CLI 层职责）
- 自定义主题
- Overlay / 弹窗系统

## Design

### 模块结构（不变）

```
src/tui/
├── root.zig           # 模块入口，导出所有公共类型
├── component.zig      # Component 接口、Container、Text
├── editor.zig         # 输入编辑器
├── markdown.zig       # Markdown 渲染
├── ansi.zig           # ANSI 转义码工具
├── lines_util.zig     # 行数组工具函数
├── renderer.zig       # InlineRenderer（本次重点修改）
├── tool_status.zig    # ToolStatus 组件
├── terminal.zig       # 终端尺寸检测
├── viewport.zig       # 基础类型
└── insert_history.zig # 历史记录
```

### InlineRenderer 增强

#### 新增字段

```zig
pub const InlineRenderer = struct {
    allocator: Allocator,
    writer: std.fs.File,
    backbuffer: std.ArrayList([]u8),
    last_cursor_row: u16 = 0,

    // --- Phase 2 新增 ---
    last_width: u16 = 0,              // 上次渲染宽度，变化时全量重绘
    max_lines_rendered: u32 = 0,      // 历史最大行数，用于 viewport 计算
    dirty: bool = false,              // 脏标记，用于渲染节流
    last_render_ns: i128 = 0,         // 上次渲染时间戳（纳秒）
};
```

#### 精确 diff 算法

当前实现遍历所有行，对每行发 `\r\n`：

```zig
// 当前（Phase 1）— 遍历所有行
var row: usize = 0;
while (row < max_len) : (row += 1) {
    if (row > 0) try out.appendSlice(allocator, "\r\n");
    if (std.mem.eql(u8, old_line, new_line)) continue;
    try out.appendSlice(allocator, "\r");
    try out.appendSlice(allocator, new_line);
    try out.appendSlice(allocator, "\x1b[K");
}
```

改为定位 firstChanged/lastChanged，直接跳转：

```zig
// Phase 2 — 精确 diff
// 1. 找 firstChanged 和 lastChanged
var first_changed: ?usize = null;
var last_changed: usize = 0;
for (0..max_len) |i| {
    const old = if (i < old_len) backbuffer[i] else "";
    const new = if (i < new_len) lines[i] else "";
    if (!std.mem.eql(u8, old, new)) {
        if (first_changed == null) first_changed = i;
        last_changed = i;
    }
}

// 2. 无变化 → 只调整光标
if (first_changed == null) { ... return; }

// 3. 用 \x1b[{n}A / \x1b[{n}B 跳到 first_changed
// 4. 只渲染 first_changed..last_changed
// 5. 如果 old_len > new_len，清除多余行
```

参考：`references/pi-mono/packages/tui/src/tui.ts` doRender() 第 957-1070 行。

#### append-only 快速路径

当 firstChanged == old_len（所有旧行不变，只有新行追加）时：

```zig
const append_only = first_changed.? == old_len;
if (append_only) {
    // 光标已在末尾，直接 \r\n 追加新行
    for (lines[old_len..]) |line| {
        try out.appendSlice(allocator, "\r\n");
        try out.appendSlice(allocator, line);
        try out.appendSlice(allocator, LINE_RESET);
    }
}
```

这是流式输出最常见的路径：markdown 渲染后新增了行，已有行内容不变。

#### 内容缩短清理

当 new_len < old_len 时，在渲染完变化行后清除多余行：

```zig
if (old_len > new_len) {
    // 移动到 new_len 行之后
    for (0..(old_len - new_len)) |_| {
        try out.appendSlice(allocator, "\r\n\x1b[2K");
    }
    // 移回 new_len - 1
    try out.writer(allocator).print(
        "\x1b[{d}A", .{old_len - new_len}
    );
}
```

#### 行尾 reset

每行输出后追加 reset 序列，防止样式泄漏到下一行：

```zig
const LINE_RESET = "\x1b[0m";

// 在输出每行内容后追加
try out.appendSlice(allocator, line);
try out.appendSlice(allocator, LINE_RESET);
try out.appendSlice(allocator, "\x1b[K");
```

参考：pi-tui 使用 `\x1b[0m\x1b]8;;\x07`（含超链接关闭），
我们暂不支持超链接，只需 `\x1b[0m`。

#### viewport 感知

跟踪终端高度和历史最大行数，判断变化是否在可见区域内：

```zig
const term_height = terminal.getTerminalSize().height;
const viewport_top = if (self.max_lines_rendered > term_height)
    self.max_lines_rendered - term_height
else
    0;

// 变化在 viewport 之上 → 全量重绘
if (first_changed.? < viewport_top) {
    self.invalidate();
    // 全量重绘路径 ...
}
```

#### 宽度变化检测

终端宽度变化时 soft wrapping 会改变，需要全量重绘：

```zig
if (self.last_width != 0 and self.last_width != current_width) {
    self.invalidate();
    // 全量重绘 ...
}
self.last_width = current_width;
```

宽度由调用方传入或从 `terminal.getTerminalSize()` 获取。

### 渲染节流（CLI 层）

渲染节流不在 InlineRenderer 内部实现（它是无状态的渲染器），
而是在 CLI 层的 `StreamSinkCtx` 中控制调用频率：

```zig
// src/cli/interactive.zig StreamSinkCtx
const MIN_RENDER_INTERVAL_NS = 16_000_000; // ~60fps

fn renderMd(self: *StreamSinkCtx) void {
    const now = std.time.nanoTimestamp();
    if (now - self.last_render_ns < MIN_RENDER_INTERVAL_NS) {
        self.render_pending = true;
        return;  // 跳过本次渲染，等下次 token 到来时再检查
    }
    self.last_render_ns = now;
    self.render_pending = false;
    self.doRenderMd();
}
```

当 token 流结束（`turn_end` 事件）时，如果 `render_pending` 为 true，
执行最后一次渲染确保最终状态正确。

这比 pi-tui 的 `process.nextTick()` 更简单，但效果类似：
高频 token 到达时每 ~16ms 渲染一帧，而不是每个 token 渲染一次。

### 已有组件（保持不变）

以下组件已实现且测试通过，不需要修改：

- `component.zig` — Component 接口（vtable）、Container（垂直堆叠）、Text
- `editor.zig` — 行编辑器：光标移动、退格、Ctrl+A/E、上下箭头历史、渲染缓存
- `markdown.zig` — Markdown 渲染：标题加粗、代码块灰底、自动换行、padding、缓存
- `ansi.zig` — ANSI 工具：colored、boldText、dimText、bgGray
- `lines_util.zig` — 行数组工具：cloneLines、freeLines、appendOwnedLines
- `tool_status.zig` — Tool 执行状态显示

## Testing

所有组件使用 `std.testing.allocator` 测试，检测内存泄漏。

### Phase 1 测试（已通过）

- InlineRenderer：首次渲染、backbuffer 跟踪、invalidate 清空
- Component/Container：垂直堆叠、行输出
- Editor：光标移动、退格、历史
- Markdown：标题、代码块、缓存
- ToolStatus：状态渲染

### Phase 2 新增测试

- `renderer.zig`：
  - 精确 diff：单行变化 → 只输出该行（验证无多余 `\r\n`）
  - append-only：新行追加 → 输出以 `\r\n` 开头，无 `\x1b[A` 回溯
  - 内容缩短：行数减少 → 输出包含 `\x1b[2K` 清除多余行
  - 行尾 reset：每行输出包含 `\x1b[0m`
  - 宽度变化：宽度改变 → backbuffer 清空（全量重绘）
  - viewport 感知：变化在 viewport 之上 → 全量重绘

- `interactive.zig`（渲染节流）：
  - 手动验证：高频 token 流不卡顿
  - 验证 turn_end 后 pending 渲染被执行

## Implementation

分三步：

### Step 1：InlineRenderer 精确 diff

修改 `renderer.zig` 的 `render()` 方法：
- 计算 firstChanged/lastChanged
- 用 ANSI 光标跳转直达变化行
- 只渲染变化区间
- 处理 append-only 和内容缩短
- 追加行尾 reset
- 添加宽度变化检测

### Step 2：渲染节流

修改 `src/cli/interactive.zig` 的 `StreamSinkCtx`：
- 添加 `last_render_ns` 和 `render_pending` 字段
- `renderMd()` 中加入时间节流
- `flushMarkdown()` 和 `turn_end` 中处理 pending 渲染

### Step 3：viewport 感知

在 InlineRenderer 中添加：
- `max_lines_rendered` 跟踪
- viewport top 计算
- 变化在 viewport 之上时的全量重绘路径

## Alternatives Considered

1. **全屏模式（vaxis）**：接管整个 viewport，像 amp/opencode 那样。
   放弃了 scrollback buffer 和原生滚动，实现复杂度高。
   当前阶段 inline 模式更适合。

2. **不做节流，依赖 synchronized output**：synchronized output 防闪烁，
   但不减少 CPU 开销。每个 token 触发完整 markdown 解析 + diff 仍然浪费。

3. **event loop + 异步渲染**：类似 pi-tui 的 `process.nextTick()`。
   Zig 无内置 event loop，引入 io_uring/epoll 复杂度过高。
   时间节流更简单且效果足够。

## References

- `references/pi-mono/packages/tui/src/tui.ts` — pi-tui 差分渲染实现
  - `doRender()` 方法：firstChanged/lastChanged diff 算法
  - `requestRender()`：process.nextTick() 渲染合并
  - `applyLineResets()`：行尾 reset 序列
- [What I learned building a coding agent — Differential rendering](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/#toc_7)
- `references/pi-mono/packages/tui/src/components/markdown.ts` — 渲染缓存模式

## Updates

- v1 (2026-03-18): 初始设计，组件库 + 基础差分渲染
- v2 (2026-03-19): 简化重写，删除 vaxis 依赖，纯组件库
- v3 (2026-03-19): 差分渲染增强，基于 pi-tui 差距分析
