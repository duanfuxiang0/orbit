   # orbit-tui: 混合模式终端 UI 层设计

   Status: Draft

   Note:
   先前仓库里短暂存在过一版实验性的 `src/tui/` 实现，但已在遗留代码清理时移除。
   本 RFC 仍然描述未来可能重建的 TUI 设计，不代表当前仓库里已有这些模块。

   Authors:

   * Orbit Team

   Created: 2026-03-18

   Last Updated: 2026-03-18

   ## Summary

   设计并实现 orbit-tui（Layer 3），采用混合模式策略：
   - **默认 inline 模式**：直接写入终端 scrollback buffer，保留终端原生滚动和搜索能力
   - **按需全屏模式**：使用 Vaxis 进入 alternate screen 查看 diff、日志等交互式内容
   - **保留 Vaxis**：作为工具库使用，而非完全放弃
   
   核心技术：viewport 管理 + 滚动区域控制（DECSTBM）+ synchronized output + 差分渲染。

   ## Motivation

   当前 Orbit 使用 Vaxis 全屏 TUI 模式，存在以下问题：

   1. **丢失终端原生能力**：全屏模式接管整个
 viewport，用户无法使用终端的原生滚动、搜索、复制功能
   2. **实现复杂度高**：需要自行模拟滚动、处理 viewport 边界、管理光标位置
   3. **不适合线性对话**：coding agent 的对话是线性增长的，天然适合 scrollback
 buffer，而非固定 viewport
   4. **调试困难**：全屏模式下无法看到历史输出，调试时需要额外的日志文件

   然而，**完全放弃 Vaxis 也不是最优解**：
   
   - Vaxis 提供了成熟的全屏 TUI 能力，适合查看 diff、日志、文件树等交互式内容
   - Vaxis 已经处理了终端能力检测、键盘协议、图片渲染等复杂问题
   - 重新实现这些功能会增加维护负担

   **混合模式策略**结合了两者的优势：

   - **日常对话使用 inline 模式**：保留终端历史，用户可以自由滚动查看
   - **特定场景使用全屏模式**：查看 diff、浏览日志、选择文件等需要交互的场景
   - **保留 Vaxis 作为工具**：按需进入/退出 alternate screen，而非完全依赖它

   参考实现：
   
   - **Codex TUI**（`references/codex/codex-rs/tui`）验证了 inline 模式的可行性：
     - 使用 viewport + DECSTBM（滚动区域）实现历史行插入
     - Reverse Index (ESC M) 向下滚动 viewport
     - 差分渲染 + synchronized output 消除闪烁
   - **Vaxis**（`references/libvaxis`）提供了成熟的全屏 TUI 框架：
     - 完整的终端能力检测和查询系统
     - Kitty keyboard protocol、图片协议等高级特性
   - 经过验证的跨平台支持

   ## Goals

   - **Inline 模式渲染**：写入 scrollback buffer，保留终端原生滚动和搜索
   - **Viewport 管理**：使用 DECSTBM 滚动区域控制，在 viewport 上方插入历史行
   - **差分渲染**：retained mode 组件模型，只重绘变化的行
   - **无闪烁**：用 synchronized output 包裹渲染输出
   - **组件化**：Container、Text、Markdown、Editor 等可组合组件
   - **Markdown 渲染**：将 Markdown 转为带 ANSI 转义码的文本行
   - **输入编辑器**：支持多行输入、Emacs 风格快捷键、历史记录
   - **流式更新**：支持流式文本追加，缓存已完成的消息
   - **混合模式切换**：提供 API 进入/退出 Vaxis 全屏模式
   - **保留 Vaxis 集成**：用于 diff 查看、日志浏览等交互式场景

   ## Non-Goals

   - 完全放弃 Vaxis（保留作为工具使用）
   - 复杂布局（不需要 flexbox/grid，只需垂直堆叠）
   - 鼠标支持（键盘优先，但 Vaxis 全屏模式可以有鼠标）
   - 图片渲染（后续 RFC，当前只需文本；Vaxis 已支持）
   - 语法高亮（后续 RFC，当前 Markdown 代码块用单色）
   - Overlay/Modal（后续 RFC，当前不需要弹窗）
   - 自定义主题系统（后续 RFC，当前硬编码颜色）
   - 重新实现终端能力检测（使用 Vaxis 的能力检测）

   ## Background

   ### Codex TUI Inline 模式核心设计

   `references/codex/codex-rs/tui/src/insert_history.rs` 和 `custom_terminal.rs` 的关键设计：

   1. **Viewport 管理**：
      ```rust
      pub struct Terminal<B> {
        pub viewport_area: Rect,  // 当前 UI 占用的区域
          pub last_known_cursor_pos: Position,  // 光标位置
          visible_history_rows: u16,  // 可见历史行数
      }
      
      // 初始化时，viewport 从当前光标位置开始
      viewport_area: Rect::new(0, cursor_pos.y, 0, 0)
      ```

   2. **历史行插入机制**（`insert_history_lines`）：
      - 使用 ANSI 滚动区域控制（DECSTBM）：
        ```rust
     // 设置滚动区域为 viewport 上方的区域
        SetScrollRegion(1..area.top())
        ```
      - 在 viewport 上方插入新行：
     ```rust
        // 移动到 viewport 顶部上方
        MoveTo(0, cursor_top)
        // 插入换行，触发滚动
        Print("\r\n")
      ```
      - 如果 viewport 不在屏幕底部，向下滚动 viewport：
        ```rust
        // 使用 Reverse Index (RI, ESC M) 向下滚动
        for _ in 0..scroll_amount {
            Print("\x1bM")  // Reverse Index
        }
        ```

   3. **差异渲染**：
      - 比较前后两帧的 buffer
      - 只渲染变化的部分
      - 使用 synchronized output 包裹

   4. **URL 处理**：
    - URL-only 行保持完整（不插入硬换行），让终端自动换行以保持可点击性
      - 混合行（URL + 文本）使用自适应换行

   ### Vaxis 架构

   `references/libvaxis/src/Vaxis.zig` 的关键特性：

   1. **Alternate Screen 管理**：
      ```zig
      pub fn enterAltScreen(self: *Vaxis, tty: *IoWriter) !void {
          try tty.writeAll(ctlseqs.smcup);
          self.state.alt_screen = true;
      }
      
    pub fn exitAltScreen(self: *Vaxis, tty: *IoWriter) !void {
          try tty.writeAll(ctlseqs.rmcup);
          self.state.alt_screen = false;
      }
      ```

   2. **终端能力检测**：
    - 通过查询而非 terminfo 检测特性
      - 支持 Kitty keyboard protocol、图片协议、RGB 等
      - 使用 futex 等待查询响应

   3. **双缓冲渲染**：
      - `screen`: 当前帧
      - `screen_last`: 上一帧
      - 差分后只更新变化的 cell

   4. **高级特性**：
      - Synchronized output (Mode 2026)
      - Kitty graphics protocol
      - Hyperlinks (OSC 8)
       - System clipboard (OSC 52)

   ### 混合模式对比

   ┌─────────┬───────────────┬─────────┬────────────┐
   │ 特性     │ 纯 Vaxis 全屏        │ 纯 Inline 模式        │ 混合模式（推荐）    │
   ├───────┼─────────────┼───────┤
   │ 日常对话   │ 无历史滚动           │ 终端原生滚动     │ 终端原生滚动        │
   ├───────┼───────────────────┼──────────────────┼───────────────────┤
   │ 查看 diff  │ 全屏交互式         │ 需自行实现            │ 全屏交互式          │
   ├────────────┼───────────────┼────────┼─────────────────────┤
   │ 搜索历史   │ 无法搜索          │ 终端原生（Cmd+F）     │ 终端原生（Cmd+F）   │
   ├──────────┼──────────────────────┼──────────────┼──────┤
   │ 复制粘贴   │ 需特殊处理      │ 终端原生            │ 终端原生       │
   ├────────────┼───────────────────┼──────────────────┼───────────┤
   │ 实现复杂度 │ 中（依赖 Vaxis）     │ 高（全部自实现）      │ 中（复用 Vaxis）    │
   ├────────────┼───────┼────────────┼────────┤
   │ 维护成本   │ 低（Vaxis 维护）     │ 高（自行维护）        │ 低（Vaxis 维护）    │
   ├──────────┼──────────────────┼────────────┼───────────────────┤
   │ 终端兼容性 │ Vaxis 已处理         │ 需自行测试    │ Vaxis 已处理      │
   └────────────┴──────────┴─────────┴────────────────┘

   **混合模式的优势**：
   - 日常对话保留终端历史，用户体验最佳
   - 复杂交互（diff、日志）使用成熟的 Vaxis 全屏模式
   - 复用 Vaxis 的终端能力检测、键盘协议等基础设施
   - 降低实现和维护成本

   ### 关键 ANSI 转义序列

   ```bash
   # 设置滚动区域 (DECSTBM)
   \x1b[{top};{bottom}r

   # 重置滚动区域
   \x1b[r

   # Reverse Index (向上滚动一行)
   \x1bM

   # 清除到行尾
   \x1b[K

   # Synchronized output
   \x1b[?2026h  # 开始
   \x1b[?2026l  # 结束
   # Alternate screen
   \x1b[?1049h  # 进入
   \x1b[?1049l  # 退出
   ```

 ## Proposal

 ### 核心架构

 ```
   src/tui/
   ├── root.zig           # TUI 主类，inline 模式差分渲染
   ├── component.zig      # Component 接口和 Container
   ├── terminal.zig   # 终端抽象（读写、viewport 管理）
   ├── ansi.zig     # ANSI 转义码工具
   ├── viewport.zig       # Viewport 和滚动区域管理
   ├── insert_history.zig # 历史行插入（DECSTBM + RI）
   ├── markdown.zig       # Markdown → ANSI 渲染
   ├── editor.zig         # 输入编辑器组件
   └── vaxis_bridge.zig   # Vaxis 集成（全屏模式切换）
 ```

 ### 混合模式 API

 ```zig
   // src/tui/root.zig

   pub const TUI = struct {
       allocator: Allocator,
       terminal: Terminal,
       vaxis: ?*vaxis.Vaxis,  // 可选的 Vaxis 实例
       mode: Mode,
       
       pub const Mode = enum {
           inline,      // 默认 inline 模式
           fullscreen,  // Vaxis 全屏模式
       };
     
       /// 进入全屏模式（用于查看 diff、日志等）
       pub fn enterFullscreen(self: *TUI) !void {
           if (self.vaxis == null) {
            self.vaxis = try vaxis.init(self.allocator, .{});
           }
           try self.vaxis.?.enterAltScreen(self.terminal.writer());
           self.mode = .fullscreen;
       }
       
       /// 退出全屏模式，返回 inline 模式
       pub fn exitFullscreen(self: *TUI) !void {
           if (self.vaxis) |vx| {
               try vx.exitAltScreen(self.terminal.writer());
           }
           self.mode = .inline;
       }
       
       /// 在全屏模式下渲染（使用 Vaxis）
     pub fn renderFullscreen(self: *TUI, draw_fn: anytype) !void {
           assert(self.mode == .fullscreen);
           const vx = self.vaxis.?;
     const win = vx.window();
           draw_fn(win);
           try vx.render(self.terminal.writer());
       }
   };
 ```

 ### Viewport 和历史行插入

 ```zig
   // src/tui/viewport.zig
   
   pub const Viewport = struct {
       area: Rect,
       last_cursor_pos: Position,
       visible_history_rows: u16,
       
       pub fn init(cursor_pos: Position) Viewport {
           return .{
        .area = Rect{ .x = 0, .y = cursor_pos.y, .width = 0, .height = 0 },
           .last_cursor_pos = cursor_pos,
      .visible_history_rows = 0,
           };
       }
   };
   
   // src/tui/insert_history.zig
   
   /// 在 viewport 上方插入历史行（参考 Codex 实现）
   pub fn insertHistoryLines(
       terminal: *Terminal,
       viewport: *Viewport,
       lines: []const Line,
   ) !void {
       const screen_size = terminal.getSize();
       const wrap_width = viewport.area.width;
       
       // 预先换行处理
       var wrapped_lines = std.ArrayList(Line).init(allocator);
       defer wrapped_lines.deinit();
       
       for (lines) |line| {
           // URL-only 行保持完整，让终端自动换行
           if (isUrlOnlyLine(line)) {
       try wrapped_lines.append(line);
           } else {
               // 其他行进行自适应换行
               const wrapped = try wrapLine(line, wrap_width);
               try wrapped_lines.appendSlice(wrapped);
         }
       }
       
       const cursor_top = if (viewport.area.bottom() < screen_size.height) {
           // Viewport 不在底部，需要向下滚动
         const scroll_amount = wrapped_lines.items.len;
           
        // 设置滚动区域并使用 Reverse Index 向下滚动
           try terminal.setScrollRegion(viewport.area.top() + 1, screen_size.height);
           try terminal.moveTo(0, viewport.area.top());
           
        for (0..scroll_amount) |_| {
           try terminal.write("\x1bM");  // Reverse Index
           }
         
           try terminal.resetScrollRegion();
        
           viewport.area.y += scroll_amount;
           viewport.area.top() - 1
       } else {
           viewport.area.top() - 1
       };
       
       // 设置滚动区域为 viewport 上方
       try terminal.setScrollRegion(1, viewport.area.top());
       try terminal.moveTo(0, cursor_top);
       
       // 插入历史行
       for (wrapped_lines.items) |line| {
       try terminal.write("\r\n");
           try renderLine(terminal, line);
       }
       
       try terminal.resetScrollRegion();
       try terminal.moveTo(viewport.last_cursor_pos.x, viewport.last_cursor_pos.y);
     
     viewport.visible_history_rows += wrapped_lines.items.len;
   }
 ```

 ### Component 接口（保持不变）

 ```zig
   // src/tui/component.zig

   /// 组件接口——所有 UI 组件必须实现
   pub const Component = struct {
       ptr: *anyopaque,
       vtable: *const VTable,

       pub const VTable = struct {
           /// 渲染组件为文本行数组
           /// width: 当前终端宽度
           /// allocator: 用于分配返回的行数组
           /// 返回: [][]const u8，每个元素是一行（不含换行符）
           render: *const fn (ptr: *anyopaque, width: u16, allocator:
 Allocator) [][]const u8,

           /// 处理键盘输入（可选）
           /// 返回 true 表示消费了输入，false 表示未处理
           handle_input: ?*const fn (ptr: *anyopaque, data: []const u8) bool,

           /// 使缓存失效，强制下次 render 重新计算
           invalidate: *const fn (ptr: *anyopaque) void,

           /// 释放组件资源
           deinit: *const fn (ptr: *anyopaque) void,
       };

       pub fn render(self: Component, width: u16, allocator: Allocator)
 [][]const u8 {
           return self.vtable.render(self.ptr, width, allocator);
       }

       pub fn handleInput(self: Component, data: []const u8) bool {
           if (self.vtable.handle_input) |f| {
               return f(self.ptr, data);
           }
           return false;
       }

       pub fn invalidate(self: Component) void {
           self.vtable.invalidate(self.ptr);
       }

       pub fn deinit(self: Component) void {
           self.vtable.deinit(self.ptr);
       }
   };

   /// Container——垂直堆叠子组件
   pub const Container = struct {
       allocator: Allocator,
       children: std.ArrayList(Component),

       pub fn init(allocator: Allocator) Container {
           return .{
               .allocator = allocator,
               .children = std.ArrayList(Component).init(allocator),
           };
       }

       pub fn deinit(self: *Container) void {
           for (self.children.items) |child| {
               child.deinit();
           }
           self.children.deinit();
       }

       pub fn addChild(self: *Container, component: Component) !void {
           try self.children.append(component);
       }

       pub fn removeChild(self: *Container, component: Component) void {
           for (self.children.items, 0..) |child, i| {
               if (child.ptr == component.ptr) {
                   _ = self.children.orderedRemove(i);
                   break;
               }
           }
       }

       pub fn clear(self: *Container) void {
           for (self.children.items) |child| {
               child.deinit();
           }
           self.children.clearRetainingCapacity();
       }

       pub fn component(self: *Container) Component {
           return .{
               .ptr = self,
               .vtable = &.{
                   .render = renderImpl,
                   .handle_input = null,
                   .invalidate = invalidateImpl,
                   .deinit = deinitImpl,
               },
           };
       }

        fn renderImpl(ptr: *anyopaque, width: u16, allocator: Allocator)
 [][]const u8 {
            const self: *Container = @ptrCast(@alignCast(ptr));
            var lines = std.ArrayList([]const u8).init(allocator);
            errdefer {
             for (lines.items) |line| allocator.free(line);
                lines.deinit();
          }
            
            for (self.children.items) |child| {
                const child_lines = child.render(width, allocator);
      defer allocator.free(child_lines);
                
          for (child_lines) |line| {
              try lines.append(line);
                }
            }
            return lines.toOwnedSlice() catch &[_][]const u8{};
     }

       fn invalidateImpl(ptr: *anyopaque) void {
           const self: *Container = @ptrCast(@alignCast(ptr));
           for (self.children.items) |child| {
               child.invalidate();
           }
       }

       fn deinitImpl(ptr: *anyopaque) void {
           const self: *Container = @ptrCast(@alignCast(ptr));
           self.deinit();
       }
   };
 ```

 ### TUI 主类

 ```zig
   // src/tui/root.zig

   const std = @import("std");
   const Component = @import("component.zig").Component;
   const Terminal = @import("terminal.zig").Terminal;

   /// TUI 主类——管理差分渲染和输入分发
   pub const TUI = struct {
       allocator: Allocator,
       terminal: Terminal,
       root: Component,

       // 差分渲染状态
       previous_lines: [][]const u8,
       previous_width: u16,
       previous_height: u16,

       // 焦点管理
       focused_component: ?Component,

       // 渲染请求标志
       render_requested: bool,

       pub fn init(allocator: Allocator, terminal: Terminal, root: Component)
 TUI {
           return .{
               .allocator = allocator,
               .terminal = terminal,
               .root = root,
               .previous_lines = &[_][]const u8{},
               .previous_width = 0,
               .previous_height = 0,
               .focused_component = null,
               .render_requested = false,
           };
       }

       pub fn deinit(self: *TUI) void {
           for (self.previous_lines) |line| {
               self.allocator.free(line);
           }
           self.allocator.free(self.previous_lines);
           self.root.deinit();
       }

       /// 启动 TUI，开始监听输入和渲染
       pub fn start(self: *TUI) !void {
           try self.terminal.start();
           try self.terminal.hideCursor();
           self.requestRender();
       }

       /// 停止 TUI，恢复终端状态
       pub fn stop(self: *TUI) !void {
           // 移动光标到内容末尾
           if (self.previous_lines.len > 0) {
               try self.terminal.write("\r\n");
           }
           try self.terminal.showCursor();
           try self.terminal.stop();
       }

       /// 请求渲染（异步，下一个 tick 执行）
       pub fn requestRender(self: *TUI) void {
           if (self.render_requested) return;
           self.render_requested = true;
           // 在 Zig 中需要用事件循环或手动调用 doRender
           // 简化版：直接同步渲染
           self.doRender() catch {};
       }

       /// 设置焦点组件
       pub fn setFocus(self: *TUI, component: ?Component) void {
           self.focused_component = component;
       }

       /// 处理键盘输入
       pub fn handleInput(self: *TUI, data: []const u8) void {
           if (self.focused_component) |comp| {
               if (comp.handleInput(data)) {
                   self.requestRender();
                   return;
               }
           }
           // 未处理的输入可以传递给其他 handler
       }

        /// 执行差分渲染
        fn doRender(self: *TUI) !void {
          self.render_requested = false;

            const width = self.terminal.getWidth();
            const height = self.terminal.getHeight();

            // 渲染根组件
            const new_lines = try self.root.render(width, self.allocator);
            defer {
          for (new_lines) |line| {
           self.allocator.free(line);
                }
         self.allocator.free(new_lines);
            }

           // 检测终端尺寸变化
           const width_changed = self.previous_width != 0 and
 self.previous_width != width;
           const height_changed = self.previous_height != 0 and
 self.previous_height != height;

           // 尺寸变化或首次渲染 → 全量重绘
           if (width_changed or height_changed or self.previous_lines.len ==
 0) {
               try self.fullRender(new_lines, width_changed or
 height_changed);
               return;
           }

           // 差分渲染
           try self.diffRender(new_lines);
       }

       /// 全量渲染（清屏 + 输出所有行）
       fn fullRender(self: *TUI, lines: [][]const u8, clear: bool) !void {
           var buf = std.ArrayList(u8).init(self.allocator);
           defer buf.deinit();

           // 开始 synchronized output
           try buf.appendSlice("\x1b[?2026h");

           if (clear) {
               // 清屏 + 清 scrollback
               try buf.appendSlice("\x1b[2J\x1b[H\x1b[3J");
           }

           // 输出所有行
           for (lines, 0..) |line, i| {
               if (i > 0) try buf.appendSlice("\r\n");
               try buf.appendSlice(line);
           }

           // 结束 synchronized output
           try buf.appendSlice("\x1b[?2026l");

           try self.terminal.write(buf.items);

           // 更新 backbuffer
           try self.updateBackbuffer(lines);
           self.previous_width = self.terminal.getWidth();
           self.previous_height = self.terminal.getHeight();
       }

       /// 差分渲染（只重绘变化的行）
       fn diffRender(self: *TUI, new_lines: [][]const u8) !void {
           // 找到第一个和最后一个变化的行
           var first_changed: ?usize = null;
           var last_changed: usize = 0;

           const max_lines = @max(new_lines.len, self.previous_lines.len);
           for (0..max_lines) |i| {
               const old_line = if (i < self.previous_lines.len)
 self.previous_lines[i] else "";
               const new_line = if (i < new_lines.len) new_lines[i] else "";

               if (!std.mem.eql(u8, old_line, new_line)) {
                   if (first_changed == null) {
                       first_changed = i;
                   }
                   last_changed = i;
               }
           }

           // 无变化
           if (first_changed == null) return;

           var buf = std.ArrayList(u8).init(self.allocator);
           defer buf.deinit();

           // 开始 synchronized output
           try buf.appendSlice("\x1b[?2026h");

           // 移动到第一个变化的行
           // 简化版：假设光标在上一帧末尾，向上移动
           const cursor_row = self.previous_lines.len;
           const target_row = first_changed.?;
           if (target_row < cursor_row) {
               const up = cursor_row - target_row;
               try buf.writer().print("\x1b[{d}A", .{up});
           }
           try buf.appendSlice("\r");

           // 输出变化的行
           for (first_changed.?..last_changed + 1) |i| {
               if (i > first_changed.?) {
                   try buf.appendSlice("\r\n");
               }
               if (i < new_lines.len) {
                   try buf.appendSlice(new_lines[i]);
                   // 清除行尾（如果新行比旧行短）
                   try buf.appendSlice("\x1b[K");
               } else {
                   // 删除的行
                   try buf.appendSlice("\x1b[2K");
               }
           }

           // 如果有追加的行，继续输出
           if (new_lines.len > last_changed + 1) {
               for (last_changed + 1..new_lines.len) |i| {
                   try buf.appendSlice("\r\n");
                   try buf.appendSlice(new_lines[i]);
               }
           }

           // 结束 synchronized output
           try buf.appendSlice("\x1b[?2026l");

           try self.terminal.write(buf.items);

           // 更新 backbuffer
           try self.updateBackbuffer(new_lines);
       }

       fn updateBackbuffer(self: *TUI, new_lines: [][]const u8) !void {
           // 释放旧 backbuffer
           for (self.previous_lines) |line| {
               self.allocator.free(line);
           }
           self.allocator.free(self.previous_lines);

           // 复制新行
           self.previous_lines = try self.allocator.alloc([]const u8,
 new_lines.len);
           for (new_lines, 0..) |line, i| {
               self.previous_lines[i] = try self.allocator.dupe(u8, line);
           }
       }
   };
 ```

 ### Terminal 抽象

 ```zig
   // src/tui/terminal.zig

   const std = @import("std");
   const os = std.os;
   const posix = std.posix;

   /// 终端抽象——封装 stdin/stdout 和终端控制
   pub const Terminal = struct {
       stdin: std.fs.File,
       stdout: std.fs.File,
       original_termios: ?os.linux.termios,
       width: u16,
       height: u16,

       pub fn init() !Terminal {
           const stdin = std.io.getStdIn();
           const stdout = std.io.getStdOut();

           // 获取终端尺寸
           var ws: os.linux.winsize = undefined;
           _ = os.linux.ioctl(stdout.handle, os.linux.T.IOCGWINSZ,
 @intFromPtr(&ws));

           return .{
               .stdin = stdin,
               .stdout = stdout,
               .original_termios = null,
               .width = ws.ws_col,
               .height = ws.ws_row,
           };
       }

       /// 启动终端（设置 raw mode）
       pub fn start(self: *Terminal) !void {
           // 保存原始 termios
           var termios: os.linux.termios = undefined;
           _ = os.linux.tcgetattr(self.stdin.handle, &termios);
           self.original_termios = termios;

           // 设置 raw mode
           var raw = termios;
           raw.lflag.ECHO = false;
           raw.lflag.ICANON = false;
           raw.lflag.ISIG = false;
           raw.lflag.IEXTEN = false;
           raw.iflag.IXON = false;
           raw.iflag.ICRNL = false;
           raw.iflag.BRKINT = false;
           raw.iflag.INPCK = false;
           raw.iflag.ISTRIP = false;
           raw.oflag.OPOST = false;
           raw.cc[@intFromEnum(os.linux.V.MIN)] = 0;
           raw.cc[@intFromEnum(os.linux.V.TIME)] = 1;

           _ = os.linux.tcsetattr(self.stdin.handle, .FLUSH, &raw);

           // 启用 Kitty keyboard protocol（可选）
           try self.write("\x1b[>1u");
       }

       /// 停止终端（恢复原始 termios）
       pub fn stop(self: *Terminal) !void {
           if (self.original_termios) |termios| {
               _ = os.linux.tcsetattr(self.stdin.handle, .FLUSH, &termios);
           }
           // 禁用 Kitty keyboard protocol
           try self.write("\x1b[<1u");
       }

       pub fn write(self: *Terminal, data: []const u8) !void {
           _ = try self.stdout.write(data);
       }

       pub fn hideCursor(self: *Terminal) !void {
           try self.write("\x1b[?25l");
       }

       pub fn showCursor(self: *Terminal) !void {
           try self.write("\x1b[?25h");
       }

       pub fn getWidth(self: Terminal) u16 {
           return self.width;
       }

       pub fn getHeight(self: Terminal) u16 {
           return self.height;
       }

       /// 读取输入（非阻塞）
       pub fn read(self: *Terminal, buf: []u8) !usize {
           return self.stdin.read(buf) catch 0;
       }
   };
 ```

 ### Markdown 组件（简化版）

 ```zig
   // src/tui/markdown.zig

   const std = @import("std");
   const Component = @import("component.zig").Component;
   const ansi = @import("ansi.zig");

   /// Markdown 组件——渲染 Markdown 为 ANSI 文本
   pub const Markdown = struct {
       allocator: Allocator,
       text: []const u8,
       padding_x: u16,
       padding_y: u16,

       // 缓存
       cached_text: ?[]const u8,
       cached_width: ?u16,
       cached_lines: ?[][]const u8,

       pub fn init(allocator: Allocator, text: []const u8, padding_x: u16,
 padding_y: u16) Markdown {
           return .{
               .allocator = allocator,
               .text = text,
               .padding_x = padding_x,
               .padding_y = padding_y,
               .cached_text = null,
               .cached_width = null,
               .cached_lines = null,
           };
       }

       pub fn deinit(self: *Markdown) void {
           if (self.cached_lines) |lines| {
               for (lines) |line| {
                   self.allocator.free(line);
               }
               self.allocator.free(lines);
           }
           if (self.cached_text) |text| {
               self.allocator.free(text);
           }
       }

       pub fn setText(self: *Markdown, text: []const u8) !void {
           self.invalidate();
           if (self.cached_text) |old| {
               self.allocator.free(old);
           }
           self.cached_text = try self.allocator.dupe(u8, text);
           self.text = self.cached_text.?;
       }

       pub fn component(self: *Markdown) Component {
           return .{
               .ptr = self,
               .vtable = &.{
                   .render = renderImpl,
                   .handle_input = null,
                   .invalidate = invalidateImpl,
                   .deinit = deinitImpl,
               },
           };
       }

        fn renderImpl(ptr: *anyopaque, width: u16, allocator: Allocator)
 [][]const u8 {
            const self: *Markdown = @ptrCast(@alignCast(ptr));

         // 检查缓存
            if (self.cached_lines) |lines| {
             if (self.cached_width) |w| {
             if (w == width) {
             // 返回缓存的副本
             const result = allocator.alloc([]const u8, lines.len)
 catch return &[_][]const u8{};
                      errdefer allocator.free(result);
                 
             for (lines, 0..) |line, i| {
              result[i] = allocator.dupe(u8, line) catch {
                  // 清理已分配的行
                    for (result[0..i]) |allocated_line| {
                         allocator.free(allocated_line);
                       }
                        allocator.free(result);
            return &[_][]const u8{};
              };
                    }
              return result;
                 }
                }
            }

            // 渲染 Markdown（简化版：只处理代码块和段落）
       const content_width = if (width > self.padding_x * 2) width -
 self.padding_x * 2 else 1;
            var lines = std.ArrayList([]const u8).init(allocator);
            errdefer {
                for (lines.items) |line| allocator.free(line);
                lines.deinit();
            }

          // 顶部 padding
            for (0..self.padding_y) |_| {
          const empty = allocator.dupe(u8, "") catch {
         for (lines.items) |line| allocator.free(line);
                    lines.deinit();
              return &[_][]const u8{};
          };
                lines.append(empty) catch {
         allocator.free(empty);
                    for (lines.items) |line| allocator.free(line);
                lines.deinit();
                return &[_][]const u8{};
                };
            }

            // 简化版：按行处理
            var iter = std.mem.split(u8, self.text, "\n");
            var in_code_block = false;

            while (iter.next()) |line| {
         if (std.mem.startsWith(u8, line, "```")) {
              in_code_block = !in_code_block;
               if (in_code_block) {
               // 代码块开始
               const styled = ansi.dimText(allocator, "┌─ code ─") catch line;
           const padded = std.fmt.allocPrint(allocator, "{s}{s}", .{
                   " " ** self.padding_x, styled
                     }) catch {
                    if (!std.mem.eql(u8, styled, line)) allocator.free(styled);
                  continue;
            };
              if (!std.mem.eql(u8, styled, line)) allocator.free(styled);
           lines.append(padded) catch {
                 allocator.free(padded);
             continue;
                };
                    } else {
                     // 代码块结束
                   const styled = ansi.dimText(allocator, "└──────") catch line;
            const padded = std.fmt.allocPrint(allocator, "{s}{s}", .{
                   " " ** self.padding_x, styled
                 }) catch {
                 if (!std.mem.eql(u8, styled, line)) allocator.free(styled);
                continue;
                 };
                   if (!std.mem.eql(u8, styled, line)) allocator.free(styled);
                  lines.append(padded) catch {
            allocator.free(padded);
                   continue;
                 };
         }
              continue;
                }

          if (in_code_block) {
                    // 代码行
                    const styled = ansi.bgGray(allocator, line) catch line;
                    const padded = std.fmt.allocPrint(allocator, "{s}  {s}", .{
               " " ** self.padding_x, styled
             }) catch {
                   if (!std.mem.eql(u8, styled, line)) allocator.free(styled);
                      continue;
       };
            if (!std.mem.eql(u8, styled, line)) allocator.free(styled);
           lines.append(padded) catch {
                    allocator.free(padded);
                   continue;
                    };
           } else {
                    // 普通文本
                    const padded = std.fmt.allocPrint(allocator, "{s}{s}", .{
              " " ** self.padding_x, line
         }) catch continue;
                    lines.append(padded) catch {
             allocator.free(padded);
                      continue;
         };
             }
            }

         // 底部 padding
            for (0..self.padding_y) |_| {
         const empty = allocator.dupe(u8, "") catch continue;
                lines.append(empty) catch {
                    allocator.free(empty);
                    continue;
        };
            }
                   continue;
               }

               if (in_code_block) {
                   // 代码行
                   const styled = ansi.bgGray(line) catch line;
                   const padded = std.fmt.allocPrint(allocator, "{s}  {s}", .{
                       " " ** self.padding_x, styled
                   }) catch line;
                   lines.append(padded) catch {};
               } else {
                   // 普通文本
                   const padded = std.fmt.allocPrint(allocator, "{s}{s}", .{
                       " " ** self.padding_x, line
                   }) catch line;
                   lines.append(padded) catch {};
               }
           }

           // 底部 padding
           for (0..self.padding_y) |_| {
               lines.append(allocator.dupe(u8, "") catch "") catch {};
           }

          const result = lines.toOwnedSlice() catch {
                for (lines.items) |line| allocator.free(line);
                lines.deinit();
           return &[_][]const u8{};
            };

            // 更新缓存
            self.cached_width = width;
        if (self.cached_lines) |old| {
                for (old) |line| {
                    self.allocator.free(line);
        }
                self.allocator.free(old);
            }
            self.cached_lines = self.allocator.alloc([]const u8, result.len)
 catch null;
            if (self.cached_lines) |cache| {
                for (result, 0..) |line, i| {
                 cache[i] = self.allocator.dupe(u8, line) catch "";
                }
            }

            return result;
        }

        fn invalidateImpl(ptr: *anyopaque) void {
      const self: *Markdown = @ptrCast(@alignCast(ptr));
            if (self.cached_lines) |lines| {
                for (lines) |line| {
               self.allocator.free(line);
           }
         self.allocator.free(lines);
            }
       self.cached_lines = null;
            self.cached_width = null;
        }

        fn deinitImpl(ptr: *anyopaque) void {
        const self: *Markdown = @ptrCast(@alignCast(ptr));
            self.deinit();
        }
    };
```

### Editor 组件（简化版）

```zig
// src/tui/editor.zig

const std = @import("std");
const Component = @import("component.zig").Component;
const ansi = @import("ansi.zig");

/// 输入编辑器组件——支持多行输入和基本编辑
pub const Editor = struct {
    allocator: Allocator,
    buffer: std.ArrayList(u8),
    cursor_pos: usize,
    prompt: []const u8,
    
    // 历史记录
    history: std.ArrayList([]const u8),
    history_index: ?usize,
    
    // 缓存
    cached_lines: ?[][]const u8,
    cached_width: ?u16,
    
    pub fn init(allocator: Allocator, prompt: []const u8) Editor {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
       .cursor_pos = 0,
            .prompt = prompt,
            .history = std.ArrayList([]const u8).init(allocator),
            .history_index = null,
        .cached_lines = null,
            .cached_width = null,
        };
    }
    
    pub fn deinit(self: *Editor) void {
        self.buffer.deinit();
     for (self.history.items) |item| {
            self.allocator.free(item);
        }
        self.history.deinit();
        if (self.cached_lines) |lines| {
            for (lines) |line| {
                self.allocator.free(line);
            }
            self.allocator.free(lines);
        }
    }
    
    pub fn getText(self: *Editor) []const u8 {
        return self.buffer.items;
    }
    
    pub fn clear(self: *Editor) void {
        self.buffer.clearRetainingCapacity();
        self.cursor_pos = 0;
        self.invalidate();
    }
    
    pub fn component(self: *Editor) Component {
        return .{
          .ptr = self,
            .vtable = &.{
                .render = renderImpl,
                .handle_input = handleInputImpl,
            .invalidate = invalidateImpl,
                .deinit = deinitImpl,
            },
        };
    }
    
    fn renderImpl(ptr: *anyopaque, width: u16, allocator: Allocator) [][]const u8 {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        
        var lines = std.ArrayList([]const u8).init(allocator);
        
        // 渲染 prompt + buffer
        const line = std.fmt.allocPrint(allocator, "{s}{s}", .{
            self.prompt, self.buffer.items
      }) catch return &[_][]const u8{};
      
        lines.append(line) catch {};
        
        return lines.toOwnedSlice() catch &[_][]const u8{};
    }
    
    fn handleInputImpl(ptr: *anyopaque, data: []const u8) bool {
        const self: *Editor = @ptrCast(@alignCast(ptr));
    
        // 处理特殊键
        if (std.mem.eql(u8, data, "\x7f")) { // Backspace
            if (self.cursor_pos > 0 and self.buffer.items.len > 0) {
                _ = self.buffer.orderedRemove(self.cursor_pos - 1);
                self.cursor_pos -= 1;
                self.invalidate();
            }
          return true;
        }
        
        if (std.mem.eql(u8, data, "\x01")) { // Ctrl-A: 行首
      self.cursor_pos = 0;
            self.invalidate();
          return true;
        }
        
        if (std.mem.eql(u8, data, "\x05")) { // Ctrl-E: 行尾
            self.cursor_pos = self.buffer.items.len;
            self.invalidate();
            return true;
        }
        
        // 普通字符输入
        if (data.len > 0 and data[0] >= 32 and data[0] < 127) {
            self.buffer.insertSlice(self.cursor_pos, data) catch return false;
          self.cursor_pos += data.len;
            self.invalidate();
         return true;
        }
        
        return false;
    }
    
    fn invalidateImpl(ptr: *anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        if (self.cached_lines) |lines| {
         for (lines) |line| {
                self.allocator.free(line);
          }
            self.allocator.free(lines);
        }
        self.cached_lines = null;
        self.cached_width = null;
    }
    
    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Editor = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};
```

### ANSI 工具

```zig
// src/tui/ansi.zig

const std = @import("std");

/// ANSI 颜色代码
pub const Color = enum {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    
    pub fn fg(self: Color) []const u8 {
        return switch (self) {
      .black => "\x1b[30m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
        .blue => "\x1b[34m",
       .magenta => "\x1b[35m",
      .cyan => "\x1b[36m",
          .white => "\x1b[37m",
        };
    }
    
    pub fn bg(self: Color) []const u8 {
        return switch (self) {
            .black => "\x1b[40m",
            .red => "\x1b[41m",
     .green => "\x1b[42m",
            .yellow => "\x1b[43m",
       .blue => "\x1b[44m",
      .magenta => "\x1b[45m",
            .cyan => "\x1b[46m",
            .white => "\x1b[47m",
        };
    }
};

pub const reset = "\x1b[0m";
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";
pub const italic = "\x1b[3m";
pub const underline = "\x1b[4m";

/// 包装文本为指定颜色
pub fn colored(allocator: std.mem.Allocator, text: []const u8, color: Color) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ color.fg(), text, reset });
}

/// 包装文本为加粗
pub fn boldText(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ bold, text, reset });
}

/// 包装文本为暗淡
pub fn dimText(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ dim, text, reset });
}

/// 包装文本为灰色背景
pub fn bgGray(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "\x1b[48;5;236m{s}{s}", .{ text, reset });
}
```

## Implementation Plan

### Phase 1: Viewport 和历史行插入（Week 1-2）

1. **Terminal 抽象** (`src/tui/terminal.zig`)
   - 实现 raw mode 设置和恢复
   - 终端尺寸检测和 SIGWINCH 处理
   - stdin/stdout 封装
   - DECSTBM 滚动区域控制

2. **Viewport 管理** (`src/tui/viewport.zig`)
   - Viewport 结构和初始化
   - 光标位置跟踪
   - 历史行计数

3. **历史行插入** (`src/tui/insert_history.zig`)
   - DECSTBM + Reverse Index 实现
   - URL 检测和自适应换行
   - 滚动区域管理

**验收标准**：
- 能够在 viewport 上方插入历史行
- Viewport 正确向下滚动
- URL 行保持完整可点击

### Phase 2: Inline 模式差分渲染（Week 3）

1. **Component 接口** (`src/tui/component.zig`)
   - Component trait 定义
   - Container 实现
   - 基础 Text 组件

2. **差分渲染引擎** (`src/tui/root.zig`)
   - Backbuffer 管理
   - 差分算法实现
   - Synchronized output 包裹

**验收标准**：
- 差分渲染正确工作，只重绘变化的行
- 无闪烁（synchronized output 生效）
- 终端尺寸变化时正确处理

### Phase 3: Vaxis 集成（Week 4）

1. **Vaxis Bridge** (`src/tui/vaxis_bridge.zig`)
   - Vaxis 初始化和生命周期管理
   - Alternate screen 进入/退出
   - 模式切换 API

2. **混合模式协调**
   - 模式状态管理
   - 输入路由（inline vs fullscreen）
   - 渲染路由

**验收标准**：
- 能够在 inline 和 fullscreen 模式间切换
- 切换过程无闪烁或状态丢失
- Vaxis 全屏模式功能正常

### Phase 4: Markdown 和 Editor（Week 5）

1. **Markdown 组件** (`src/tui/markdown.zig`)
   - Markdown 解析（koino 或简化版）
   - ANSI 转义码生成
   - 渲染缓存

2. **Editor 组件** (`src/tui/editor.zig`)
   - 多行输入支持
   - Emacs 风格快捷键
   - 历史记录

**验收标准**：
- Markdown 正确渲染（标题、代码块、列表等）
- Editor 支持基本编辑操作
- 历史记录可以浏览

### Phase 5: 集成和优化（Week 6）

1. **与现有代码集成**
   - 替换现有 Vaxis 全屏调用为混合模式
   - 迁移 UI 逻辑
   - 更新事件循环

2. **性能优化和测试**
   - 减少不必要的重绘
   - 优化内存分配
   - 添加单元测试和集成测试

**验收标准**：
- Orbit 能够使用混合模式正常运行
- 对话流畅，无明显延迟
- 内存使用合理，无泄漏
- Diff 查看等功能正常工作

## Testing Strategy

### 单元测试

1. **Component 测试**
   - Container 堆叠逻辑
   - Text 组件渲染
   - Markdown 解析和渲染
   - Editor 输入处理

2. **差分渲染测试**
   - 无变化 → 无输出
   - 单行变化 → 只重绘该行
   - 追加行 → 只输出新行
   - 尺寸变化 → 全量重绘

3. **ANSI 工具测试**
   - 颜色代码生成
   - 文本包装
   - 宽度计算（考虑 ANSI 序列）

### 集成测试

1. **终端模拟器测试**
   - 使用 `script` 命令录制输出
   - 验证 ANSI 序列正确性
   - 检查 synchronized output 使用

2. **手动测试**
   - 在不同终端测试（iTerm2, Alacritty, Kitty, GNOME Terminal）
   - 测试终端尺寸变化
   - 测试长文本滚动
   - 测试输入编辑

### 性能测试

1. **渲染性能**
   - 大量文本渲染时间
   - 差分算法性能
   - 内存使用

2. **输入延迟**
   - 按键到渲染的延迟
   - 流式更新的流畅度

## Risks and Mitigations

### Risk 1: DECSTBM 终端兼容性问题

**风险**：不是所有终端都完美支持 DECSTBM（滚动区域）和 Reverse Index。

**缓解措施**：
- 使用 Vaxis 的终端能力检测来判断是否支持
- 对不支持的终端降级到简单模式（无历史行插入）
- 在主流终端测试（iTerm2, Alacritty, Kitty, GNOME Terminal, Windows Terminal）
- 提供 `--no-inline` 选项强制使用全屏模式

### Risk 2: 模式切换状态管理复杂

**风险**：在 inline 和 fullscreen 模式间切换可能导致状态不一致。

**缓解措施**：
- 明确定义模式切换的状态转换规则
- 在切换时保存/恢复必要的状态
- 添加断言验证状态一致性
- 充分的集成测试覆盖模式切换场景

### Risk 3: Vaxis 依赖维护

**风险**：Vaxis 更新可能破坏兼容性。

**缓解措施**：
- 固定 Vaxis 版本，谨慎升级
- 封装 Vaxis API，减少直接依赖
- 保持 vaxis_bridge 模块的隔离性
- 监控 Vaxis 的 breaking changes

### Risk 4: 性能问题

**风险**：频繁的历史行插入和差分渲染可能导致性能下降。

**缓解措施**：
- 实现渲染节流（debounce）
- 缓存已渲染的组件
- 优化差分算法
- 限制单次插入的最大行数
- 性能测试和 profiling

### Risk 5: 内存泄漏

**风险**：Zig 手动内存管理容易出现泄漏，特别是在复杂的渲染路径中。

**缓解措施**：
- 严格遵循 `STYLE.md` 的内存安全规则
- 使用 `std.testing.allocator` 检测泄漏
- 每个 `alloc` 都有明确的 `free` 路径
- Code review 重点检查内存管理
- 添加内存泄漏检测到 CI

## Alternatives Considered

### Alternative 1: 纯 Vaxis 全屏模式

**优点**：
- 无需重写 TUI 层
- Vaxis 功能完整，经过验证
- 实现简单

**缺点**：
- 丢失终端原生能力（滚动、搜索、复制）
- 不适合线性对话场景
- 调试困难

**决策**：拒绝。全屏模式的缺点对 coding agent 场景来说是致命的。

### Alternative 2: 纯 Inline 模式（完全放弃 Vaxis）

**优点**：
- 保留终端原生能力
- 代码量小，实现简单
- 适合线性对话

**缺点**：
- 需要自行实现终端能力检测
- 无法提供交互式 diff 查看等功能
- 需要自行处理跨平台兼容性
- 维护负担重

**决策**：拒绝。完全放弃 Vaxis 会失去成熟的全屏 TUI 能力，增加维护成本。

### Alternative 3: 使用其他 TUI 库

**调研结果**：
- Zig 生态中没有成熟的 inline 模式 TUI 库
- Ratatui（Rust）有 inline 模式，但无法直接使用
- 其他语言的库（如 Ink.js）无法直接使用

**决策**：拒绝。自行实现 inline 模式 + 集成 Vaxis 是最佳方案。

### Alternative 4: 使用 tmux/screen 管理历史

**可行性**：依赖外部工具，用户体验不一致。

**决策**：拒绝。应该提供开箱即用的体验，不依赖外部工具。

### Alternative 5: 混合模式（采纳）

**优点**：
- 日常对话保留终端历史
- 复杂交互使用成熟的 Vaxis 全屏模式
- 复用 Vaxis 的基础设施
- 降低实现和维护成本
- 最佳用户体验

**缺点**：
- 需要管理模式切换
- 略微增加复杂度

**决策**：采纳。这是平衡用户体验、实现复杂度和维护成本的最佳方案。

## Open Questions

1. **Markdown 解析器选择**
   - 使用 koino（完整但较重）还是自行实现简化版？
   - 需要支持哪些 Markdown 扩展（表格、任务列表等）？
   - **建议**：先使用 koino，后续根据性能需求考虑简化

2. **模式切换触发时机**
   - 哪些操作应该自动进入全屏模式？
   - 用户如何手动触发模式切换？
   - **建议**：提供快捷键（如 Ctrl-D 查看 diff），自动检测需要全屏的场景

3. **Vaxis 版本管理**
   - 固定在哪个 Vaxis 版本？
   - 升级策略是什么？
   - **建议**：固定在当前稳定版本，每季度评估升级

4. **性能目标**
   - 单次渲染的目标延迟是多少（<16ms for 60fps？）？
   - 最大支持多少行历史？
   - **建议**：目标 <16ms 渲染延迟，支持至少 10000 行历史

5. **URL 处理策略**
   - 如何检测 URL？
   - 是否需要支持自定义 URL 模式？
   - **建议**：使用简单的正则检测 http(s):// 和 domain.tld/path 模式
6. **测试策略**
   - 如何测试终端输出？
   - 是否需要 snapshot 测试？
   - **建议**：使用 VT100 模拟器（如 Codex 的 VT100Backend）进行测试

## References

1. **Codex TUI Inline 模式实现**
   - `references/codex/codex-rs/tui/src/insert_history.rs` - 历史行插入和 DECSTBM 使用
   - `references/codex/codex-rs/tui/src/custom_terminal.rs` - Viewport 管理和差分渲染
   - 验证了 inline 模式的可行性和性能

2. **Vaxis 库**
   - `references/libvaxis/src/Vaxis.zig` - 全屏 TUI 框架
   - `references/libvaxis/README.md` - API 文档和使用示例
   - https://github.com/rockorager/libvaxis - 官方仓库

3. **Flow TUI 架构**
   - `references/flow/src/renderer/vaxis/renderer.zig` - Vaxis 集成示例
   - `references/flow/src/tui.zig` - TUI 根对象和事件处理

4. **ANSI 转义序列参考**
   - https://gist.github.com/fnky/458719343aabd01cfb17a3a4f7296797 - 完整的 ANSI 转义码参考
   - DECSTBM (CSI Ps ; Ps r) - 设置滚动区域
   - RI (ESC M) - Reverse Index

5. **Synchronized Output**
   - https://gist.github.com/christianparpart/d8a62cc1ab659194337d73e399004036
   - CSI ?2026h/l 的详细说明

6. **Kitty Keyboard Protocol**
   - https://sw.kovidgoyal.net/kitty/keyboard-protocol/
   - 增强的键盘输入协议（Vaxis 已支持）

7. **Zig 内存管理最佳实践**
   - `STYLE.md` Memory Safety Rules
   - Orbit 项目的内存安全规范

---

**Status**: Ready for Review

**Next Steps**:
1. Team review and feedback on hybrid mode strategy
2. Finalize Markdown parser choice and URL detection strategy
3. Begin Phase 1 implementation (Viewport and history insertion)
4. Set up VT100-based testing infrastructure
5. Create proof-of-concept for mode switching
