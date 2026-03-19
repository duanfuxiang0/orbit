# Orbit

Orbit is a standalone code agent built in Zig.

## Vision

Orbit is a true autonomous coding assistant, not a frontend for another service. It provides:
- Direct file system operations
- Code execution and testing
- Interactive CLI and headless execution modes
- Fast, safe, and reliable operation

## Status

Currently in early development. The legacy opencode-zig prototype has been removed. The active codebase is organized around the `ai`, `agent`, and `cli` layers.

## Quick Start

Build and run:
```bash
zig build run
```

Run tests:
```bash
zig build test
```

Format code:
```bash
zig fmt src/ai/*.zig src/agent/*.zig src/cli/*.zig src/main.zig src/tests.zig build.zig
```

## Project Structure

- `src/` - Source code
  - `main.zig` - Process entry point
  - `cli/` - CLI entry, config, sessions, tools, headless mode
  - `agent/` - Agent loop and tool execution bridge
  - `ai/` - Models, providers, transport, message context
- `references/` - Read-only reference projects for learning
- `AGENTS.md` - Primary development guide (read this first)
- `STYLE.md` - Coding style and safety guidelines

## Development Workflow

1. **Always read `AGENTS.md` first** for any task
2. Read `STYLE.md` when writing or refactoring Zig code
3. Consult `references/AGENTS.md` for architecture patterns and examples
4. Run `zig fmt` before committing
5. Add tests for agent, AI, CLI, and persistence changes

## Key Principles

- **Zero technical debt** - Do it right the first time
- **Safety first** - Assertions, bounds checking, explicit types
- **Simple and bounded** - No recursion, explicit control flow
- **Testable** - Deterministic tests, clear invariants
- **Minimal dependencies** - Zig toolchain only

## Reference Materials

The `references/` directory contains complete projects for learning:
- `flow` - Vaxis TUI architecture and patterns
- `bun` - Large Zig codebase organization
- `tigerbeetle` - Safety, performance, and testing discipline
- `nullclaw` - Additional reference

See `references/AGENTS.md` for detailed guidance on using these materials.

## Contributing

Follow the guidelines in `AGENTS.md` and `STYLE.md`. Key points:
- Explain the "why", not just the "what"
- Keep changes minimal and composable
- Add assertions for preconditions and invariants
- Functions must be ≤70 lines
- Lines must be ≤100 columns
- Use explicit integer types (u32, u64, etc.)

## License

[To be determined]
