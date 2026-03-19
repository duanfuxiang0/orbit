# 引入 libxev 事件循环（含 Orbit Runtime 抽象）

Status: Draft (v2)

Authors:

* Orbit Team

Created: 2026-03-19

Last Updated: 2026-03-19

## Summary

引入 [libxev](https://github.com/mitchellh/libxev) 作为 Orbit 的事件循环基础设施，
但**不直接在业务模块散用 xev API**。本 RFC 同时引入一层 Orbit 自有 runtime 抽象：

- `src/runtime/event_loop.zig`
- `src/runtime/timer.zig`
- `src/runtime/scheduler.zig`（可选）

第一阶段目标不是重写 AI/Agent，而是先解决当前 TUI 流式渲染体验问题：
用非阻塞定时器替换当前同步 `sleep` 节流，实现“到点主动 flush”。

这是 Orbit 首个外部依赖，本 RFC 同时定义依赖准入和升级策略。

## Motivation

Orbit 需要统一处理以下异步任务：

1. LLM SSE 流读取
2. TUI 渲染调度（按帧合并、到点刷新）
3. 用户输入与终端 IO
4. 工具执行与超时/重试定时器

当前缺少事件循环，已出现两个直接问题：

- TUI 节流路径需要同步等待，影响事件处理连续性
- 异步能力分散在阻塞调用和手工控制中，迁移成本持续上升

自行实现跨平台 event loop（io_uring/epoll/kqueue）工作量大且高风险，
明显偏离 Orbit 的产品目标。

## Goals

- 提供统一的跨平台事件循环能力（Timer/Async/IO）
- 通过 Zig 包管理器引入 libxev，保持构建简单
- 建立 Orbit runtime 抽象，隔离第三方 API 变动
- 第一阶段完成 TUI 渲染调度接入（先解决丝滑度）
- 保持四层架构边界：Loop 生命周期归 `cli` 管理

## Non-Goals

- 直接在 `src/ai` / `src/agent` / `src/tui` 中大量 `@import("xev")`
- 一次性把所有同步代码重写成异步
- 暴露 libxev C API
- 引入额外 async 框架

## Why libxev

### 选择理由

- 纯 Zig，原生 Zig 包管理器支持
- 跨平台后端统一（Linux/macOS 等）
- 提供 Timer/Async/ThreadPool 等核心原语
- 生产实践充分（如 Ghostty）

### 参考 Ghostty 的可借鉴模式

Ghostty 并非“每个模块都直接决定 xev 后端”，而是先在统一入口导出：

- `references/ghostty/src/global.zig`
  - `pub const xev = @import("xev").Dynamic;`
  - 在全局初始化阶段统一 `xev.detect()`

本 RFC 借鉴其“集中后端策略”的思路，但更进一步：
Orbit 通过 `src/runtime/*` 对外暴露稳定接口，业务层不直接依赖 xev 类型。

## Dependency Policy Update

Orbit 原有“零依赖”原则在本 RFC 下做**受控例外**：

1. 必要性明确（标准库难以低成本满足）
2. 纯 Zig + Zig 包管理器接入
3. 生产验证充分
4. 许可证兼容（MIT/Apache-2.0/BSD）
5. 低传递依赖风险
6. 必须有 RFC 与回滚方案

### 锁定与升级策略

- 锁定到 libxev 的具体 commit + hash
- 升级通过独立 PR/RFC，必须附兼容性与回归测试结果
- Orbit 仅在 `src/runtime` 触达 xev API，降低升级扩散面

## Proposal

### 1) 构建接入

`build.zig.zon` 增加：

```zig
.dependencies = .{
    .libxev = .{
        .url = "https://github.com/mitchellh/libxev/archive/<commit>.tar.gz",
        .hash = "<hash>",
    },
},
```

`build.zig` 增加：

```zig
const xev_dep = b.dependency("libxev", .{
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("xev", xev_dep.module("xev"));
tests_mod.addImport("xev", xev_dep.module("xev"));
```

### 2) 新增 Orbit Runtime 抽象层

新增模块：

```
src/runtime/
├── root.zig
├── event_loop.zig
├── timer.zig
└── scheduler.zig   # 可选，帧调度器
```

对外原则：

- `src/runtime/*` 内部可以使用 `@import("xev")`
- 业务层仅依赖 Orbit 抽象类型（例如 `runtime.EventLoop`, `runtime.Timer`）
- xev 的 backend 选择与初始化策略集中在 runtime 层

示例接口（草案）：

```zig
pub const EventLoop = struct {
    pub fn init(allocator: Allocator) !EventLoop;
    pub fn deinit(self: *EventLoop) void;
    pub fn runOnce(self: *EventLoop) !void;
    pub fn runUntilIdle(self: *EventLoop) !void;
    pub fn stop(self: *EventLoop) void;
};

pub const Timer = struct {
    pub fn init(loop: *EventLoop) !Timer;
    pub fn deinit(self: *Timer) void;
    pub fn armAfter(self: *Timer, ns: u64, cb: *const fn (*anyopaque) void, ctx: *anyopaque) !void;
    pub fn cancel(self: *Timer) void;
};
```

### 3) 生命周期与架构边界

- `src/cli/`：创建并持有唯一 `EventLoop` 实例，负责主循环运行
- `src/tui/`：通过 runtime scheduler 请求“下一帧渲染”
- `src/agent/` 与 `src/ai/`：后续通过抽象接口接入，不直接持有 xev Loop
- `src/main.zig`：仍只做进程初始化与 `cli.run()`

## Rollout Plan

### Phase 1（优先，解决当前体验）

- 接入 libxev 依赖与 `src/runtime` 抽象骨架
- 在 CLI/TUI 渲染路径接入 timer：
  - 替换同步 `sleep` 节流
  - 实现“到点主动 flush pending render”

### Phase 2

- 将 stdin/tty 事件驱动化（避免输入与渲染互相阻塞）

### Phase 3

- 在 ai 层迁移 SSE 读取到 runtime 抽象

### Phase 4

- agent 工具调度与超时机制迁移到 runtime 抽象

每个 Phase 独立提交、可回退。

## Failure Modes and Safety

- Loop 初始化失败：启动失败并返回明确错误，不 silent fallback
- Timer 回调异常：禁止 panic，转换为 Orbit 错误事件
- 资源释放：所有 loop/timer 必须 `deinit`，并在测试中验证泄漏
- 单实例约束：CLI 中断言主 loop 仅初始化一次

## Testing

### Unit

- `runtime/event_loop.zig`：init/run/deinit 生命周期
- `runtime/timer.zig`：arm/cancel/重复 arm 行为

### Integration

- TUI：高频 token 输入下，验证 16ms 到点 flush（不依赖后续 token）
- 回归：`turn_end` 前 pending 帧必须落盘
- 泄漏检测：`std.testing.allocator` 跑 runtime/TUI 新增路径

### Performance

- 记录渲染吞吐指标：
  - 每秒 render 次数
  - 每帧耗时分布
  - token 到可见输出延迟（p50/p95）

## Operational Considerations

- 首次构建需要网络下载依赖
- CI 需支持依赖缓存
- 通过 runtime 抽象降低 libxev API 升级风险

## Alternatives Considered

### 直接在业务层使用 xev

短期开发快，但会把第三方 API 扩散到全项目，升级和重构成本高。
不采用。

### 仅保留当前时间节流（无事件循环）

可工作，但难以稳定实现非阻塞调度，且无法支撑后续 SSE/工具并发演进。
不采用。

### 自研事件循环

成本高、风险高、与产品目标不匹配。不采用。

## Open Questions

- libxev 当前版本与 Orbit `minimum_zig_version = 0.15.2` 的兼容窗口
- `src/runtime/scheduler.zig` 是否在 Phase 1 立即引入，还是先只做 timer
- 是否需要 runtime 层暴露可观测性接口（队列长度、待处理回调数）

## References

- [libxev GitHub](https://github.com/mitchellh/libxev)
- [Ghostty](https://ghostty.org)
- `references/ghostty/src/global.zig`（集中 xev backend 策略）
- `references/ghostty/src/termio/Thread.zig`（xev loop + timer 在线程场景）
- `references/ghostty/src/terminal/search/Thread.zig`（事件循环与任务交织）
- [RFC 0001: 四层架构](./0001-four-layer-architecture.md)
