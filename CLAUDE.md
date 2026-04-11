# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
zig build              # Compile only
zig build run          # Build and run interactive CLI
zig build test         # Run all tests
zig fmt src/**/*.zig src/*.zig build.zig   # Format all Zig files
```

Release build: `zig build --release=small`

Requires **Zig 0.15.2+**. Single external dependency: libxev (event loop).

## Architecture

Orbit is a standalone code agent written in Zig (~12k lines). Four layers with strict dependency rules:

```
Layer 4: cli/    -> Depends on TUI + Agent
Layer 3: tui/    -> No dependency on Agent or AI
Layer 2: agent/  -> Depends on AI only
Layer 1: ai/     -> No internal dependencies
         runtime/ -> Event loop primitives (shared by CLI/TUI)
```

**Layer 1 — ai/**: Provider-agnostic LLM interface. Adapters for Anthropic, OpenAI, Zhipu in `providers/`. Vtable-based polymorphism (`provider.zig`). Streaming SSE + progressive JSON parsing (`http.zig`). Unified message/tool types (`types.zig`).

**Layer 2 — agent/**: Agent loop state machine (`root.zig:runLoop`). Cycle: call LLM -> parse response -> execute tools sequentially -> append results -> repeat until done. Event emission via `AgentEventSink`. Abort support via atomic flag at every stage.

**Layer 3 — tui/** : Non-fullscreen terminal UI (preserves scrollback). Differential rendering. Multiline editor with Emacs-like keybindings. Markdown rendering with syntax highlighting. ANSI input decoding with UTF-8/CJK support.

**Layer 4 — cli/**: Entry point, config loading, session persistence, context file injection (AGENTS.md/README.md/STYLE.md into system prompt). Tool implementations in `coding_tools.zig` (read/write/edit/bash). Dual mode: interactive TTY (`interactive.zig`) and headless JSON (`headless.zig`).

**main.zig** is process lifecycle only — initializes allocator and calls `cli.run()`.

## Key Design Constraints

Read `STYLE.md` before writing or refactoring Zig code. Critical rules:

- **No recursion.** All loops must have explicit progress and exit conditions.
- **Explicit memory ownership.** Every allocation has one owner and one deallocation path. The `errdefer` trap: it does NOT fire on normal return from a `catch` block — manually free in each `catch` or use `try`.
- **No hidden allocations in hot paths** (input/render/event loops).
- **Bounded work.** Put limits on queue growth, retries, and resource usage.
- **Lines <= 100 columns. Functions ~70 lines.** Run `zig fmt` on all touched files.
- Tests use `std.testing.allocator` (detects leaks and use-after-free).

## Testing

Tests are aggregated in `src/tests.zig` which imports all modules. Each module contains inline `test` blocks. State-transition changes require test updates. Bug fixes should include regression tests. Tests must be deterministic (no timing dependencies).

## Project Structure Conventions

- Design documents go in `rfcs/` using the RFC template.
- `references/` is read-only — complete projects cloned for learning. Never edit.
- Config lives at `~/.orbit/config.json` or `~/.orbit/config.toml`. Env overrides: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `ZHIPU_API_KEY`, `ORBIT_MODEL`, `ORBIT_VERBOSE`.
- Sessions persist in `~/.orbit/sessions/`.
- When adding modules, prefer domain folders over utility buckets.
