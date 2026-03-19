# Orbit Style

Orbit favors code that is explicit, bounded, testable, and easy to reason about.
Style exists to improve safety, performance, and developer experience, in that order.

## Core Rules

- Explain why, not just what.
- Keep changes minimal and composable.
- Prefer designs that make invariants obvious in code.
- Avoid technical debt. Fix design problems while the code is still hot.

## Safety

- Use simple, explicit control flow.
- Do not use recursion.
- Loops must have explicit progress and exit conditions. Top-level event loops are the only
  exception.
- Put a limit on work, queue growth, retries, and resource usage.
- Use explicitly-sized integer types for persisted formats, protocol fields, and cross-boundary
  data. Use `usize` for indexes, lengths, and memory sizes.
- Assert preconditions, postconditions, invariants, and state transitions.
- Handle all errors.
- Keep variable scope as small as possible.
- Make ownership explicit. Every allocation must have one owner and one deallocation path.
- Avoid hidden allocations in hot paths.
- Prefer positive conditions over negated ones when expressing invariants.

## Design

- Keep functions small enough to fit on one screen. `70` lines is a guideline, not a hard rule.
- Push control flow up. Push non-branching work down into helpers.
- Keep state changes centralized and easy to inspect.
- Prefer simple function signatures and simple return types.
- Pass explicit options instead of relying on library defaults.
- Do not do large amounts of work directly in response to external events. Hand work back to a
  controlled loop when practical.

## Performance

- Think about performance during design, not only after profiling.
- Sketch costs early: CPU, memory, disk, network, latency, bandwidth.
- Batch work when it reduces overhead and keeps behavior predictable.
- Be explicit in hot paths. Do not rely on the compiler to recover a vague design.
- Optimize the slowest and most frequent costs first.

## Naming

- Use `snake_case` for functions, variables, and file names.
- Follow the Zig style guide unless Orbit has a stronger local rule.
- Do not abbreviate names unless the abbreviation is obvious and conventional.
- Add units and qualifiers to names when they matter: `timeout_ms`, `line_count`, `cursor_pos`.
- Do not overload one term with multiple meanings.
- Keep naming consistent across code, tests, docs, and CLI output.

## Comments And Tests

- Comments should explain why, constraints, or ownership. Do not restate obvious code.
- Write comments as short prose.
- Add or update tests for state-machine changes, parser changes, persistence changes, and bug fixes.
- Prefer deterministic tests over timing-sensitive tests.

## Style By The Numbers

- Run `zig fmt`.
- Use 4 spaces of indentation.
- Keep lines at or below `100` columns.
- Add braces to `if` unless it fits on one line.

## Dependencies And Tooling

- Prefer minimal dependencies. Every dependency must justify its safety, maintenance, portability,
  and build cost.
- Prefer Zig-based tooling when practical, but do not force it at the expense of clarity.

## Closing

Keep Orbit small, explicit, and fast.
