# orbit-input: Reliable Terminal Input And Multiline Editor

Table of Contents:

<!-- TOC start (generate with https://bitdowntoc.derlin.ch) -->

<!-- TOC end -->

Status: Draft

Authors:

* Orbit Team

Created: 2026-03-19

Last Updated: 2026-03-19

## Summary

Orbit's current interactive input path is byte-oriented and single-line.
This causes fragmented escape sequences to leak into the editor as literal `A/B/C/D`, prevents
multiline drafting, and makes cursor placement incorrect once input spans multiple terminal rows.
This RFC introduces a typed terminal input layer, a multiline editor model, and a modern-terminal-
first compatibility strategy with legacy fallback. The goal is to make the default Orbit prompt
editor reliable enough for real coding sessions without adding a full keybinding platform yet.

## Motivation

The current implementation has three concrete failures:

1. Arrow keys are not decoded reliably.
   `src/cli/interactive.zig` reads `ESC` and then polls with zero timeout for the tail. If the
   terminal delivers `ESC [` and `C` in separate reads, Orbit drops the sequence and inserts
   printable bytes instead.
2. The editor is single-line only.
   `src/tui/editor.zig` stores one flat line and renders it as one terminal row, so Orbit cannot
   represent `Shift+Enter` / `Ctrl+J` newlines or calculate wrapped cursor rows correctly.
3. Input semantics are coupled to terminal bytes.
   The editor currently understands hardcoded byte strings such as `\x1b[A` and `\x01`, which makes
   future keybinding work, terminal capability negotiation, and paste handling harder than it needs
   to be.

Do-nothing is not acceptable because the interactive input box is the primary UX surface for Orbit.
When editing is unreliable, the agent is unreliable regardless of model quality.

## Goals

- Decode terminal input into semantic events before it reaches the editor.
- Support multiline drafting with `Enter` submit and `Shift+Enter` / `Ctrl+J` newline insertion.
- Support reliable left/right/up/down navigation, including `Ctrl+B` / `Ctrl+F` and `Ctrl+P` /
  `Ctrl+N` aliases.
- Preserve exact prompt text, including embedded newlines and indentation.
- Support bracketed paste so pasted newlines never submit the prompt mid-paste.
- Keep the design small and compatible with future user-configurable keybindings.

## Non-Goals

- Full user-configurable keybinding files in this RFC.
- Vim mode, modal editing, or word-wise editing parity with mature editors.
- Non-bracketed paste burst heuristics.
- Mouse support or terminal image support.

## Background

Orbit currently splits responsibilities this way:

- `src/cli/interactive.zig` enters raw mode, reads stdin bytes, and forwards them directly to the
  editor.
- `src/tui/editor.zig` mixes byte decoding, edit actions, history navigation, and rendering.
- `src/tui/renderer.zig` expects the caller to supply final cursor row/column coordinates.

This arrangement was sufficient for single-byte control keys, but it breaks down for:

- fragmented ANSI escape sequences,
- CSI-u / `modifyOtherKeys` modified key reporting,
- multiline rendering and wrapped cursor math,
- bracketed paste handling.

## Proposal

### User-Facing Behavior

Orbit should behave as follows in interactive TTY mode:

- `Enter` submits the current prompt.
- `Shift+Enter` inserts a newline.
- `Ctrl+J` inserts a newline.
- `Left` / `Right` and `Ctrl+B` / `Ctrl+F` move by character.
- `Up` / `Down` and `Ctrl+P` / `Ctrl+N` move within the current draft first.
- History recall only activates when the cursor is already on the first or last visible row.
- Pasted content wrapped in bracketed-paste markers is inserted verbatim, including newlines.
- Prompt text is preserved exactly; Orbit does not trim user indentation before submission.

### Architecture and Module Ownership

Add a new typed input layer under `src/tui/`:

- `InputEvent` is the boundary between terminal decoding and editor behavior.
- `InputDecoder` owns escape-sequence buffering and bracketed-paste streaming.
- `Editor` consumes `InputEvent` values and no longer depends on raw terminal byte strings.

Keep `src/cli/interactive.zig` responsible for terminal lifecycle:

- enter raw mode,
- enable bracketed paste,
- best-effort enable enhanced keyboard reporting,
- read stdin chunks,
- feed the decoder,
- dispatch submit / exit actions.

### State and Data Model

The editor should keep a single owned UTF-8 buffer and a byte-index cursor.
This avoids split ownership across per-line allocations while still allowing multiline edits.

The editor also keeps:

- a width-scoped cached render layout,
- a cached cursor row/column,
- a preferred visual column for vertical movement,
- a saved pre-history draft so leaving history browse restores the user's multiline work.

Layout generation produces visual rows with:

- source byte range,
- prefix width,
- rendered line text.

That layout is reused for:

- rendering,
- wrapped cursor positioning,
- vertical cursor movement.

### Failure Modes and Safety

- Escape sequences are buffered until complete or until Orbit can safely classify them as a complete
  unknown sequence.
- Incomplete sequences must never emit raw printable `A/B/C/D` bytes.
- Bracketed paste streams content while reserving enough tail bytes to detect the end marker.
- Raw mode cleanup always attempts to disable input modes before restoring termios.
- Unsupported enhanced-key sequences are ignored rather than inserted as text.

## Impact Analysis

### Application Flow and Runtime

- [ ] Process lifecycle (`src/main.zig`)
- [x] Event definitions and routing (`src/runtime/`)
- [x] Renderer abstraction
- [x] App-level coordination (`src/app_controller.zig`)
- [ ] Background work, subprocesses, or async task handling

### UI and Interaction

- [x] Screen layout or rendering (`src/ui/` or legacy `src/ui.zig`)
- [x] Keyboard input or keymaps (`src/input/`)
- [x] Navigation, focus, or modal flows
- [ ] Streaming output or incremental updates
- [x] Accessibility or readability in terminal environments

### State and Domain Model

- [x] State shape or ownership (`src/state.zig`)
- [x] State transitions or invariants
- [ ] Session, message, or task model
- [ ] Persistence, serialization, or replay behavior

### Agent Capabilities

- [ ] File system operations
- [ ] Command execution
- [ ] Tool permissions or safety policy
- [ ] Prompting, planning, or conversation flow
- [ ] Multi-agent or task orchestration

### Reliability and Diagnostics

- [x] Error model and surfaced failures
- [x] Assertions or defensive checks
- [ ] Logging, tracing, or debug views
- [x] Crash recovery or resume behavior

### Developer Experience

- [x] Build/test workflow
- [ ] Configuration or CLI flags
- [x] Documentation
- [ ] Migration away from legacy opencode-zig behavior

## Operational Considerations

### Performance and Resource Use

- Startup cost: unchanged.
- Input/event latency: one short `poll` wait is only introduced for initial `ESC` reads so Orbit can
  assemble modified-key sequences without racing itself.
- Render cost: editor layout now computes wrapped rows, but only for the active draft and only when
  content or width changes.
- Allocation behavior in hot paths: the editor keeps one owned buffer; layout allocations are cached
  per width and reused until invalidated.
- Memory footprint: marginally higher due to cached visual-row metadata.
- File system / subprocess overhead: unchanged.

### Observability and Debuggability

- Failure reproduction should use deterministic decoder tests for fragmented escapes and modified key
  sequences.
- Editor tests should assert cursor byte index, rendered rows, and cursor row/column for wrapped
  input.

### Compatibility and Migration

- Modern terminals are the primary target.
- Orbit should continue to support legacy arrow/home/end/delete sequences.
- Enhanced key reporting is best-effort; unsupported terminals should degrade to the legacy subset
  rather than fail startup.
- This RFC supersedes the earlier broad input-editing claims in `rfcs/0004-orbit-tui.md`.

## Testing

- Unit tests:
  - fragmented arrow decoding,
  - CSI-u decoding for printable keys and control aliases,
  - `modifyOtherKeys` decoding for modified enter and control navigation,
  - bracketed paste assembly.
- State transition tests:
  - multiline insertion,
  - vertical movement across wrapped rows,
  - history recall and draft restoration.
- Integration tests:
  - interactive input chunking feeding the decoder.
- Manual TUI verification:
  - terminal, tmux, and VS Code integrated terminal.
- Performance checks:
  - verify no visible latency regression during normal typing.

## Rollout Plan

- Phase 1: land typed input events and decoder tests.
- Phase 2: refactor the editor to multiline rendering and cursor math.
- Phase 3: update interactive raw-mode handling and submission semantics.
- Phase 4: add docs and compatibility notes.

## Alternatives Considered

### Keep patching raw byte strings in the editor

Rejected because it preserves the current coupling and does not solve fragmented escape sequences.

### Introduce full user-configurable keymaps immediately

Rejected because it increases scope before the decoder/editor boundary is stable.

### Use a third-party terminal UI library for input decoding

Rejected for now because Orbit already has a bounded inline renderer and only needs a small,
project-specific input layer.

## Open Questions

- Whether to add word-wise editing and deletion in the next RFC or fold it into a keybinding RFC.
- Whether non-bracketed paste burst detection is worth the additional complexity on top of the
  current bracketed-paste support.

## References

- `references/pi-mono/packages/tui/src/stdin-buffer.ts`
- `references/pi-mono/packages/tui/src/keys.ts`
- `references/pi-mono/packages/tui/src/components/editor.ts`
- `references/pi-mono/packages/coding-agent/docs/terminal-setup.md`
- `references/codex/docs/tui-chat-composer.md`

## Updates

- 2026-03-19: Initial draft for typed input decoding and multiline editor behavior.
