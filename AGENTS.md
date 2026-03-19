# Orbit Agent Guide

This file is the operating contract for all work in the Orbit project.

## Project Vision
Orbit is a true code agent built in Zig.
It is not a frontend for another service. It is a standalone autonomous coding assistant.

## Goals

- Build a reliable, fast, and safe code agent with Zig.
- Keep architecture explicit, bounded, and testable.
- Follow `STYLE.md` as the primary style and safety baseline.
- Maintain zero technical debt policy.

## Required Reading Policy

- Read `STYLE.md` when:
  - creating or refactoring Zig code,
  - changing control flow/state transitions,
  - touching performance-sensitive paths,
  - adding assertions/tests.
- Read `README.md` when:
  - running the app/tests for the first time in a session,
  - checking current feature scope or runtime commands.

## Core Commands

- Run CLI:
  - `zig build run`
- Run tests:
  - `zig build test`
- Build only:
  - `zig build`
- Format:
  - `zig fmt src/**/*.zig src/*.zig build.zig`

## Architecture Boundaries

- `src/main.zig`:
  - Process lifecycle only. Initialize allocator and call `cli.run()`.
- `src/cli/`:
  - CLI entry, config loading, context file loading, session persistence, local tool wiring.
  - No provider protocol parsing and no agent loop internals.
- `src/agent/`:
  - Agent loop, tool dispatch, event emission, message ownership.
- `src/ai/`:
  - Provider adapters, HTTP/SSE transport, model registry, message normalization.
- `src/runtime/`:
  - Event loop, timers, scheduling, and runtime primitives shared by higher layers.
  - No CLI policy, provider logic, or agent decision-making.
- `src/tui/`:
  - Terminal UI primitives, rendering, input decoding, editor behavior, and viewport logic.
  - No provider logic and no agent loop internals.

When adding modules, prefer domain folders over utility buckets.

## Coding Rules

- Use explicit integer types for persisted formats, protocol fields, and cross-boundary data. Use
  `usize` for indexes, lengths, and memory sizes.
- Keep control flow simple and bounded. No recursion.
- Add assertions for preconditions and invariants.
- Prefer small functions with single responsibility.
- Avoid hidden allocations in hot loops (input/render/event paths).
- Keep line length at or below 100 columns.
- Always run `zig fmt` for touched Zig files.

## Memory Safety Rules

Zig has no garbage collector. Every allocation is a contract. Violating it means silent leaks
or use-after-free. Treat every `alloc`/`dupe`/`create` as a critical section.

- **`errdefer` only fires on error return, not on normal return from a `catch` block.**
  This is the single most common memory leak pattern in this codebase. If you `catch` and
  do a normal `return`, all preceding `errdefer` statements are skipped.
  ```zig
  // BUG: id leaks if name allocation fails.
  const id = try allocator.dupe(u8, src_id);
  errdefer allocator.free(id);
  const name = allocator.dupe(u8, src_name) catch {
      log("OOM");
      return;       // ← normal return, errdefer for id does NOT fire
  };
  ```
  Fix: either propagate the error (`try`), or manually free in each `catch` block.

- **Pair every allocation with a clear owner and a deallocation path.**
  Before writing an `alloc`/`dupe`, answer: who frees this, and when? If ownership transfers
  (e.g. moving an ArrayList's buffer to another struct), document the transfer with a comment
  and null/reset the source immediately.

- **Do not duplicate free logic across modules.**
  If `ai/context.zig` already exports `freePart` / `freeMessages`, import and reuse them.
  Duplicated free functions diverge when types evolve, causing leaks or double-frees.

- **Test allocations with `std.testing.allocator`.**
  It detects leaks and use-after-free at test time. Every test that allocates must use it
  and must `defer deinit()` all owned resources.

## Testing Rules

- Every state-transition change must include or update tests.
- Bug fixes should include a regression test when practical.
- Prefer deterministic tests over timing-sensitive tests.

## Reference Materials Policy

- `references/` contains read-only complete projects for learning and inspiration.
- Any valuable project can be cloned into `references/` for research and study.
- Do not edit anything in `references/`.
- Learn structure and invariants; do not copy large blocks directly.
- When borrowing an idea, cite the source file path in your change notes.
- See `references/AGENTS.md` for detailed guidance on using reference materials.

## Design Documents Policy

- All design documents should be written to `rfcs/` using the template format.
- Follow the RFC template structure for consistency and completeness.

## Delivery Standard

- Explain the "why", not only the "what".
- Keep changes minimal and composable.
- If tests were not run, state why explicitly.
