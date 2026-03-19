# orbit-interactive: Markdown Block Rendering And Tool Execution Lines

Table of Contents:

<!-- TOC start (generate with https://bitdowntoc.derlin.ch) -->

<!-- TOC end -->

Status: Draft

Authors:

* Orbit Team

Created: 2026-03-19

Last Updated: 2026-03-19

## Summary

This RFC upgrades interactive output readability in two areas: markdown rendering and tool execution
status rendering. Markdown now treats fenced code as a block-level surface and styles inline code
spans semantically instead of relying on byte slicing through ANSI sequences. Tool execution output
is changed from two-line start/end logs to a single line that is updated in place and keeps
arguments visible. The result is lower visual noise and higher information density for interactive
coding sessions.

## Motivation

The current output path has two concrete usability failures:

1. Markdown code rendering is line-oriented and wraps pre-styled ANSI strings by byte offset.
   This breaks visual continuity and can produce poor code block presentation.
2. Tool output in interactive mode shows only minimal metadata at start/end, often hiding the
   useful payload (`tool name + arguments`) that explains what was actually executed.

These issues reduce trust in the interface and increase manual effort for debugging agent behavior.

## Goals

- Render fenced code as a block with consistent background treatment across wrapped rows.
- Style inline code spans with dedicated color treatment.
- Show `tool_name + arguments` prominently for each tool execution.
- Update tool status in place on one terminal line, with colorized success/failure suffix.
- Keep the implementation within current `interactive` + `tui` architecture boundaries.

## Non-Goals

- Redesign of headless JSON event protocol as a standalone project.
- Full markdown feature parity (lists, tables, nested emphasis parser).
- Multi-tool concurrent status lanes in the interactive terminal.

## Background

Current behavior in `src/tui/markdown.zig`:

- Fenced code lines are styled per source line and then wrapped as raw bytes.
- Inline code spans are not rendered with dedicated semantics.

Current behavior in `src/cli/interactive.zig`:

- Tool start prints a line with name only.
- Tool end prints a separate line with result icon and optional details.

This design loses argument visibility and fragments tool execution context across multiple lines.

## Proposal

### User-Facing Behavior

- Fenced code renders as a contiguous block region (background-colored rows with width-aware fill).
- Inline code (single backtick spans) renders with dedicated foreground color.
- Tool execution renders on one line in this lifecycle:
  - start: `name + compact args + running symbol`
  - end: same line rewritten to `name + compact args + detail + success/error symbol`

### Architecture and Module Ownership

- `src/agent/types.zig`:
  - `AgentEvent.tool_exec_start` includes `arguments`.
- `src/agent/root.zig`:
  - forwards `tool_call.arguments` into `tool_exec_start`.
- `src/cli/interactive.zig`:
  - tracks one active tool status line and rewrites it in place.
  - compacts/truncates argument and detail text for stable single-line rendering.
- `src/tui/markdown.zig`:
  - semantic span rendering for plain/heading/inline-code text.
  - block-aware fenced code rendering with consistent background rows.

### State and Data Model

Interactive sink adds transient state:

- active tool id + label (owned memory, cleared on completion/deinit).

Markdown rendering changes internal data model from raw line styling to styled spans:

- `TextStyle` enum (`plain`, `heading`, `inline_code`).
- wrapped rendering uses visible-text chunking before ANSI styling.

### Failure Modes and Safety

- If tool end arrives without a matching active start, renderer falls back to name-only line.
- If start/end IDs mismatch, interactive mode closes the dangling line and prints fallback end line.
- All allocated summaries/labels are owned and explicitly freed in sink lifecycle.
- Markdown renderer never slices an ANSI-encoded string by byte index.

## Impact Analysis

### Application Flow and Runtime

- [ ] Process lifecycle (`src/main.zig`)
- [ ] Event definitions and routing (`src/runtime/`)
- [x] Renderer abstraction
- [x] App-level coordination (`src/app_controller.zig`)
- [ ] Background work, subprocesses, or async task handling

### UI and Interaction

- [x] Screen layout or rendering (`src/ui/` or legacy `src/ui.zig`)
- [ ] Keyboard input or keymaps (`src/input/`)
- [ ] Navigation, focus, or modal flows
- [x] Streaming output or incremental updates
- [x] Accessibility or readability in terminal environments

### State and Domain Model

- [ ] State shape or ownership (`src/state.zig`)
- [ ] State transitions or invariants
- [x] Session, message, or task model
- [ ] Persistence, serialization, or replay behavior

### Agent Capabilities

- [ ] File system operations
- [x] Command execution
- [ ] Tool permissions or safety policy
- [ ] Prompting, planning, or conversation flow
- [ ] Multi-agent or task orchestration

### Reliability and Diagnostics

- [x] Error model and surfaced failures
- [x] Assertions or defensive checks
- [ ] Logging, tracing, or debug views
- [ ] Crash recovery or resume behavior

### Developer Experience

- [x] Build/test workflow
- [ ] Configuration or CLI flags
- [x] Documentation
- [ ] Migration away from legacy opencode-zig behavior

## Operational Considerations

### Performance and Resource Use

- Startup cost: unchanged.
- Input/event latency: unchanged for user input path.
- Render cost: slightly higher per markdown render due to span-level formatting.
- Allocation behavior in hot paths: additional short-lived allocations for tool summaries and styled
  chunks; bounded by truncation limits.
- Memory footprint: negligible increase (single active tool label + transient buffers).
- File system / subprocess overhead: unchanged.

### Observability and Debuggability

- Tool output now preserves key context (`name + args`) directly in terminal transcript.
- Mismatch handling is explicit and deterministic in `interactive` sink logic.

### Compatibility and Migration

- Headless mode remains backward-compatible; it only adds `arguments` field to
  `tool_exec_start` serialization.
- No migration needed for existing session persistence.

## Testing

- Unit tests:
  - inline code span styling in markdown output.
  - fenced code block background rendering.
  - tool summary compaction and truncation.
- State transition tests:
  - tool start/end line rewrite on the same line.
  - fallback behavior for unmatched tool end.
- Integration tests:
  - existing interactive sink tests + headless event serialization checks.
- Manual TUI verification:
  - long args truncation,
  - success/error color suffix,
  - markdown with mixed headings/text/code blocks.
- Performance checks:
  - ensure no visible regression in incremental markdown updates.

## Rollout Plan

- Phase 1: land event payload extension (`tool_exec_start.arguments`) and serialization support.
- Phase 2: land interactive one-line tool lifecycle rendering.
- Phase 3: land markdown span/block renderer updates.
- Phase 4: refine based on interactive feedback and expand markdown coverage if needed.

## Alternatives Considered

### Keep current two-line tool logs

Rejected because it does not surface arguments at the point of execution and increases transcript
noise.

### Full markdown parser integration now

Rejected due scope and maintenance cost; current proposal targets the concrete readability problems
with bounded complexity.

### Leave tool arguments only in headless JSON

Rejected because interactive users need the same execution context without switching modes.

## Open Questions

- Should interactive mode support multiple concurrent tool status lines if tool execution becomes
  parallel in the future?
- Should inline code style use color-only or include subtle background for better contrast?

## References

- `references/codex/codex-rs/tui/src/history_cell.rs`
- `references/codex/codex-rs/tui/src/markdown_render.rs`
- `references/pi-mono/packages/coding-agent/src/modes/interactive/components/tool-execution.ts`
- `references/pi-mono/packages/tui/src/components/markdown.ts`

