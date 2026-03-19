# Slash Command Discoverability

Table of Contents:

<!-- TOC start (generate with https://bitdowntoc.derlin.ch) -->

<!-- TOC end -->

Status: Draft

Authors:

* Orbit Team

Created: 2026-03-19

Last Updated: 2026-03-19

## Summary

Orbit now supports a minimal slash command set in interactive mode (`/new`, `/resume`, `/model`,
`/quit`). This RFC defines the next step: command discoverability and guided usage, without
changing command semantics.

The goal is to make commands self-discoverable and hard to misuse while keeping the
implementation small, explicit, and terminal-friendly.

## Motivation

The current slash commands work, but users must remember exact syntax. This creates friction in
interactive sessions and leads to avoidable usage errors.

A code agent should expose operational controls clearly in the same interaction loop where users
write prompts. Better discoverability reduces command errors and improves flow.

## Goals

- Show available commands and one-line help from inside the interactive loop.
- Provide syntax guidance for commands with arguments (`/resume <id>`, `/model <provider/id>`).
- Keep command parsing deterministic and cheap.
- Preserve existing command semantics and persistence behavior.

## Non-Goals

- Shell-like autocomplete for arbitrary prompt text.
- Dynamic remote command registry.
- Rich modal UI framework.

## Background

Current implementation in `src/cli/interactive.zig` supports:

- `/new`: create a new session with current model.
- `/resume` and `/resume <id>`: list/switch sessions.
- `/model` and `/model <provider/id>`: inspect/switch model.
- `/quit` (and `/exit` alias): exit interactive mode.

Errors are shown as plain inline messages. There is no command help panel, shortcut hints, or
in-context completion.

## Proposal

Add a discoverability layer in three small phases.

### Phase 1: `/help` and contextual usage

- Add `/help` command in interactive mode.
- `/help` shows command list and short examples.
- Keep existing usage errors, but append a one-line hint:
  - Example: `usage: /resume [session-id] (try /help)`

### Phase 2: command-aware inline hint

- When editor text starts with `/`, render a single-line hint under the prompt:
  - Known command with missing args: show expected syntax.
  - Unknown command: show nearest known command suggestion by prefix.
- No popup menu in this phase.

### Phase 3: lightweight tab completion

- If editor text starts with `/` and cursor is in the command token:
  - `Tab` cycles known command names.
- For `/resume <...>`:
  - `Tab` cycles recent session ids from local session store.
- For `/model <...>`:
  - `Tab` cycles built-in model ids plus configured provider-qualified patterns.

## Architecture and Module Ownership

- `src/cli/interactive.zig`:
  - Slash command parsing and execution.
  - Hint/completion interaction in the input loop.
- `src/cli/session.zig`:
  - Session listing reused for `/resume` completion source.
- `src/cli/model_runtime.zig`:
  - Model parsing reused for `/model` completion validation.

No changes to `src/agent/` or provider protocol logic.

## Failure Modes and Safety

- Completion/hint failures must never block normal prompt submission.
- If session/model candidate enumeration fails, fallback to no completion and show a short error
  line.
- Keep all allocations bounded per keystroke; avoid unbounded growth in editor loop.

## Testing

- Unit tests:
  - `/help` text output includes all supported commands.
  - Hint generation for known/unknown commands.
  - Completion candidate ranking and cycling behavior.
- Integration tests:
  - Slash command execution behavior remains unchanged.
  - Normal non-command prompt flow remains unchanged.

## Rollout Plan

- Land `/help` first.
- Add hint rendering behind an internal feature constant.
- Add tab completion last, then remove the feature constant once stable.

## Open Questions

- Should `/help` include model/provider environment diagnostics in the same output?
- Should command hints be always visible or only after typing `/` followed by one character?

## References

- `rfcs/0005-orbit-cli.md`
- `rfcs/0008-interactive-markdown-and-tool-output.md`
