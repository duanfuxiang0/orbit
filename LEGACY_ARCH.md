# Legacy Architecture Reference

This document describes the existing code structure from the opencode-zig prototype.
Use this when understanding or refactoring legacy modules.

## Historical Context

Orbit started as `opencode-zig`, a Zig + Vaxis TUI frontend for the opencode service.
The project has been renamed and repositioned as a standalone code agent.

## Current Module Structure

### Core Runtime

- `src/main.zig`:
  - Process lifecycle, event loop wiring, top-level orchestration
  - Vaxis initialization and terminal setup
  - Command-line argument parsing

- `src/runtime/`:
  - `event.zig` - Event type definitions
  - `event_router.zig` - Event dispatch and routing
  - `renderer.zig` - Renderer abstraction layer

### UI Layer

- `src/ui.zig`:
  - Legacy monolithic rendering functions
  - `drawHome()` - Home screen layout
  - `drawSession()` - Session screen layout
  
- `src/ui/root.zig`:
  - Root UI component (newer architecture)

### State Management

- `src/state.zig`:
  - Application state model
  - State transitions
  - Session and message data structures

### Input Handling

- `src/input/keymap.zig`:
  - Keyboard input mapping
  - Key event handling

### Application Logic

- `src/app_controller.zig`:
  - Application-level command dispatch
  - Coordination between UI, state, and API

- `src/app_types.zig`:
  - Shared type definitions

### API Layer (Legacy)

- `src/api.zig`:
  - HTTP transport for opencode service
  - JSON parsing and serialization
  - Session and message API calls
  - **Note:** This will be replaced with agent-native functionality

### Testing

- `src/tests.zig`:
  - Test entry point
  - Basic state transition tests

## Legacy Commands
These commands were used when Orbit was a frontend for opencode:

- Run TUI against API:
  - `zig build run -- --url http://127.0.0.1:4096`
- Run TUI offline:
  - `zig build run -- --offline`

## Migration Path

The following modules need refactoring or replacement:

1. **API Layer** (`src/api.zig`):
   - Remove opencode service dependency
   - Replace with agent-native code execution and file operations

2. **UI Layer** (`src/ui.zig`):
   - Split monolithic render functions into composable widgets
   - Move to `src/ui/` directory structure

3. **State Management** (`src/state.zig`):
   - Evolve from session-based to agent-task-based state model
   - Add file system and execution state tracking

4. **Input Handling**:
   - Expand keymap for agent-specific operations
   - Add command palette or modal input system

## Reference Mapping

When refactoring legacy code, consult these references:

- For UI refactoring: `references/flow/src/tui/`
- For module organization: `references/bun/src/`
- For testing patterns: `references/tigerbeetle/src/testing/`

## Preservation Notes

Keep these aspects from the prototype:

- Vaxis integration and terminal lifecycle management
- Event-driven architecture foundation
- Assertion-based safety checks
- Test infrastructure

Remove or replace:

- Opencode API client code
- Session-centric data model
- Polling-based message updates
- HTTP-dependent features
