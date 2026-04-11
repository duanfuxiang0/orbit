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

Install from source (user-local):
```bash
zig build --release=small --prefix ~/.local
# Ensure ~/.local/bin is in your PATH
export PATH="$HOME/.local/bin:$PATH"
```

Install (from GitHub Release):
```bash
curl -fsSL https://raw.githubusercontent.com/duanfuxiang0/orbit/main/install.sh | bash
```

Run tests:
```bash
zig build test
```

Interactive slash commands (TTY mode):
- `/new` create a new session
- `/resume [session-id]` list or switch sessions
- `/model [provider/id]` show or switch model
- `/quit` exit (`/exit` alias kept)

Format code:
```bash
zig fmt src/*
```

## Release Packaging

Build release artifacts (tarballs + SHA256 checksums):
```bash
scripts/release.sh v0.1.0
```

Artifacts are generated in `dist/v0.1.0/`:
- `orbit-v0.1.0-<target>.tar.gz`
- `checksums.txt`

Upload them to the matching GitHub Release tag (`v0.1.0`).

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
- **Minimal dependencies** - Every dependency must justify its cost

## Reference Materials

- `flow` - Vaxis TUI architecture and patterns
- `bun` - Large Zig codebase organization
- `tigerbeetle` - Safety, performance, and testing discipline
