# Orbit RFC Title

<!-- Replace "RFC Title" with a short, descriptive title. -->

Table of Contents:

<!-- TOC start (generate with https://bitdowntoc.derlin.ch) -->

<!-- TOC end -->

Status: Draft

Authors:

* [Your Name](https://github.com/your_github_profile)

Created: YYYY-MM-DD

Last Updated: YYYY-MM-DD

## Summary

<!--
Briefly explain what this RFC changes and why.
Prefer 3-6 sentences focused on user impact and architectural impact.
-->

## Motivation

<!--
What problem are we solving in Orbit?
What user, operator, or maintainer pain exists today?
Why is "do nothing" not acceptable?
Use concrete examples from the current codebase or workflow.
-->

## Goals

- Goal 1
- Goal 2

## Non-Goals

- Non-goal 1
- Non-goal 2

## Background

<!--
Describe the current behavior, architecture, and constraints that matter for this change.
Reference relevant modules, prior discussions, or legacy behavior when helpful.
-->

## Proposal

<!--
Describe the proposed change in enough detail to implement it.
Prefer concrete behavior, data flow, invariants, and module ownership over vague intent.
Include diagrams, examples, state transitions, and pseudo-code where useful.
-->

### User-Facing Behavior

<!--
What will users notice in the TUI, CLI, or agent behavior?
Include example flows, commands, or screenshots if helpful.
-->

### Architecture and Module Ownership

<!--
Describe which modules are responsible for which parts of the design.
Respect the boundaries documented in AGENTS.md.

Useful prompts:
- What belongs in src/main.zig?
- What belongs in src/runtime/?
- What belongs in src/ui/?
- What belongs in src/state.zig?
- What belongs in src/input/?
- What belongs in src/app_controller.zig?
-->

### State and Data Model

<!--
Describe any state shape changes, transition rules, persistence implications,
or new invariants/assertions required by the design.
-->

### Failure Modes and Safety

<!--
Describe expected failures, recovery behavior, cancellation semantics,
and safety boundaries.
Call out invariants that must always hold.
-->

## Impact Analysis

Orbit features and components that this RFC interacts with. Check all that apply.

### Application Flow and Runtime

- [ ] Process lifecycle (`src/main.zig`)
- [ ] Event definitions and routing (`src/runtime/`)
- [ ] Renderer abstraction
- [ ] App-level coordination (`src/app_controller.zig`)
- [ ] Background work, subprocesses, or async task handling

### UI and Interaction

- [ ] Screen layout or rendering (`src/ui/` or legacy `src/ui.zig`)
- [ ] Keyboard input or keymaps (`src/input/`)
- [ ] Navigation, focus, or modal flows
- [ ] Streaming output or incremental updates
- [ ] Accessibility or readability in terminal environments

### State and Domain Model

- [ ] State shape or ownership (`src/state.zig`)
- [ ] State transitions or invariants
- [ ] Session, message, or task model
- [ ] Persistence, serialization, or replay behavior

### Agent Capabilities

- [ ] File system operations
- [ ] Command execution
- [ ] Tool permissions or safety policy
- [ ] Prompting, planning, or conversation flow
- [ ] Multi-agent or task orchestration

### Reliability and Diagnostics

- [ ] Error model and surfaced failures
- [ ] Assertions or defensive checks
- [ ] Logging, tracing, or debug views
- [ ] Crash recovery or resume behavior

### Developer Experience

- [ ] Build/test workflow
- [ ] Configuration or CLI flags
- [ ] Documentation
- [ ] Migration away from legacy opencode-zig behavior

## Operational Considerations

### Performance and Resource Use

<!--
Describe the performance implications of this change.
Focus on the paths Orbit cares about: input latency, render latency,
allocation behavior, subprocess overhead, memory use, and scaling with repo size.
-->

- Startup cost
- Input/event latency
- Render cost
- Allocation behavior in hot paths
- Memory footprint
- File system / subprocess overhead

### Observability and Debuggability

<!--
Describe how maintainers will inspect or debug this change.
Mention logs, debug panels, traces, counters, or failure reproduction hooks.
-->

- Configuration changes
- New logs, traces, or counters
- Failure reproduction strategy

### Compatibility and Migration

<!--
Describe compatibility implications.
Examples:
- Existing CLI behavior or flags
- Existing keymaps
- Existing state/data formats
- Interaction with legacy modules that have not yet been refactored
-->

- Existing CLI and TUI behavior
- Existing keymaps and user flows
- Existing state/data formats
- Legacy module migration plan

## Testing

<!--
Describe the test plan.
For state-transition changes, include deterministic tests.
For bug fixes, include a regression test when practical.
-->

- Unit tests:
- State transition tests:
- Integration tests:
- Manual TUI verification:
- Performance checks:

## Rollout Plan

<!--
Describe how this will land safely.
Prefer small, composable phases over large flag days.
-->

- Milestones / phases:
- Feature flags or guarded rollout:
- Docs updates:
- Follow-up cleanup:

## Alternatives Considered

List the serious alternatives and why they were rejected, including the status quo.
Call out trade-offs around complexity, safety, performance, and long-term maintenance.

## Open Questions

- Question 1
- Question 2

## References

<!--
Bullet list of related issues, PRs, RFCs, discussions, reference files, or external docs.
If borrowing an idea from references/, cite the exact file path here and in the change notes.
-->

- Reference 1
- Reference 2

## Updates

Log major changes to this RFC over time (optional).
