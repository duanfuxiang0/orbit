# Reference Materials Guide

This directory contains complete, read-only projects for learning and inspiration.

## Purpose

The `references/` directory is a curated collection of high-quality codebases that serve as:
- Architecture and design pattern references
- Code style and safety examples
- Testing and tooling inspiration
- Domain-specific implementation guidance

## Read-Only Policy

**All projects in `references/` are read-only.**

- Do not edit, modify, or commit changes to any files in this directory.
- These are pinned snapshots of external projects for reference only.
- If you need to update a reference, document the reason and new commit hash.

## How To Use References

1. **Start with your concrete problem** in the Orbit codebase.
2. **Identify the relevant reference project** from the list below.
3. **Read 1-2 specific files** that address your problem domain.
4. **Extract structure and invariants**, not implementation details.
5. **Implement the minimal version** in Orbit's codebase.
6. **Add assertions and tests** before moving forward.
7. **Cite the source** in your commit message or code comments.

## Available References

### flow (Vaxis + TUI Architecture)

**Use when:** Building terminal UI components, event handling, or renderer abstractions.

**Key files:**
- `references/flow/src/main.zig` - App bootstrap and runtime flags
- `references/flow/src/renderer/vaxis/renderer.zig` - Vaxis wrapper and terminal lifecycle
- `references/flow/src/tui.zig` - TUI root object and orchestration
- `references/flow/src/EventHandler.zig` - Event dispatch abstraction
- `references/flow/src/tui/Widget.zig` - Widget composition patterns
- `references/flow/src/keybind/` - Keybinding architecture
- `references/flow/src/tui/mode/` - Mode management

**Learn from flow:**
- Renderer abstraction between vaxis and app logic
- Clear separation of event intake and UI drawing
- Widget-level composition instead of monolithic render functions

**Avoid copying:**
- Full actor/message infrastructure (too complex for current needs)

### bun (Large Zig Codebase Organization)

**Use when:** Scaling project structure, organizing large codebases, or CLI design.

**Key files:**
- `references/bun/src/main.zig` - Process entrypoint and boot sequence
- `references/bun/src/cli.zig` - CLI dispatch and command split
- `references/bun/src/cli/` - Command-level organization
- `references/bun/src/install/`, `src/http/`, etc. - Domain-oriented layout
- `references/bun/CONTRIBUTING.md` - Contributor workflow

**Learn from bun:**
- Thin `main` that delegates quickly
- Directory-by-domain over utility dumping
- Command-level files instead of large switch statements

**Avoid copying:**
- Heavy platform abstractions or generated code pipelines

### tigerbeetle (Safety, Performance, Testing Discipline)

**Use when:** Implementing safety-critical code, performance optimization, or rigorous testing.

**Key files:**
- `references/tigerbeetle/docs/ARCHITECTURE.md` - Design rationale
- `references/tigerbeetle/docs/TIGER_STYLE.md` - Style baseline (mirrors our STYLE.md)
- `references/tigerbeetle/docs/internals/HACKING.md` - Development workflow
- `references/tigerbeetle/docs/internals/testing.md` - Testing philosophy
- `references/tigerbeetle/src/testing/` - Testing infrastructure

**Learn from tigerbeetle:**
- Assertion-first programming
- Explicit upper bounds for buffers, loops, and queues
- Deterministic, reproducible testing mindset
- Zero technical debt policy

**Avoid copying:**
- Domain-specific distributed systems machinery

### nullclaw (Additional Reference)

**Use when:** [To be documented based on project needs]

## Reference Versions

- `flow` at commit `21dc4477`
- `bun` at commit `cf6cdbbbad`
- `tigerbeetle` at commit `1cb4eca89`
- `nullclaw` at commit [to be documented]

## Best Practices

- **Don't copy-paste large blocks.** Understand the pattern, then implement it in Orbit's style.
- **Cite your sources.** When borrowing an idea, mention the reference file in your commit or comment.
- **Stay focused.** Read only what's relevant to your current task.
- **Respect the read-only policy.** Never modify reference materials.
- **Document learnings.** If you discover a valuable pattern, consider documenting it in Orbit's own architecture docs.

## When To Add New References

New references should be:
- High-quality, production-grade codebases
- Relevant to Orbit's domain (TUI, agents, Zig tooling)
- Stable and well-maintained
- Properly licensed for reference use

Propose new references with:
- Project name and repository URL
- Specific commit hash to pin
- Rationale for inclusion
- Key files and patterns to learn from
