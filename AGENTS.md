# Orbit Agent Guide

This file is the operating contract for all work in the Orbit project.

## Project Vision
Orbit is a true code agent built in Zig with a Vaxis TUI.
It is not a frontend for another service—it is a standalone autonomous coding assistant.

## Goals

- Build a reliable, fast, and safe code agent with Zig + Vaxis TUI.
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
- Read `LEGACY_ARCH.md` when:
  - understanding existing code structure from the opencode-zig prototype,
  - planning refactors of legacy modules.

## Core Commands

- Run TUI:
  - `zig build run`
- Run tests:
  - `zig build test`
- Build only:
  - `zig build`
- Format:
  - `zig fmt src/*.zig build.zig`

## Architecture Boundaries

- `src/main.zig`:
  - Process lifecycle, event loop wiring, top-level orchestration only.
- `src/ui/`:
  - Rendering and layout only.
  - No network I/O, no business logic.
- `src/state.zig`:
  - State model and transitions.
  - No terminal I/O and no network I/O.
- `src/runtime/`:
  - Event routing, renderer abstraction, core runtime infrastructure.
- `src/input/`:
  - Keyboard input handling and keymaps.
- `src/app_controller.zig`:
  - Application-level command dispatch and coordination.

When adding modules, prefer domain folders over utility buckets.

## Coding Rules

- Use explicit integer types unless there is a concrete reason not to.
- Keep control flow simple and bounded. No recursion.
- Add assertions for preconditions and invariants.
- Prefer small functions with single responsibility.
- Avoid hidden allocations in hot loops (input/render/event paths).
- Keep line length at or below 100 columns.
- Always run `zig fmt` for touched Zig files.

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
