# Code Block Syntax Highlighting and Adaptive Color

Table of Contents:

<!-- TOC start (generate with https://bitdowntoc.derlin.ch) -->

<!-- TOC end -->

Status: Draft (v2 — replaces original 0009)

Authors:

* Orbit Team

Created: 2026-03-19

Last Updated: 2026-03-19

## Summary

Orbit renders code blocks as monochrome text on a flat background. This RFC adds two things:

1. **Lightweight syntax highlighting** for code blocks — the primary deliverable.
2. **Minimal terminal color adaptation** — detect dark/light background and color depth so
   highlighting degrades gracefully.

The original RFC 0009 focused on color infrastructure (CIE Lab perceptual distance, OSC 11
detection, 256-color quantization) while explicitly excluding syntax highlighting. That was
backwards. Users see code blocks; they do not see color quantization algorithms.

## Motivation

Orbit is a code agent. The most common output is code — diffs, file contents, shell commands,
generated snippets. Today all code blocks render as plain white text, optionally on a gray
background. This makes output hard to scan and looks amateur compared to any modern terminal tool.

Codex solves this with `syntect` (a Rust library wrapping TextMate grammars). Orbit cannot use
`syntect`, but the problem is solvable with a much simpler approach: a keyword-level token
scanner that covers the languages Orbit actually works with.

## Goals

- Syntax-highlighted code blocks for common languages (Zig, Python, JavaScript/TypeScript,
  Go, Rust, Bash, C/C++, JSON, YAML, Markdown, SQL, HTML/CSS).
- Detect terminal color depth and respect `NO_COLOR`.
- Detect dark/light background and select appropriate highlight palette.
- Graceful degradation: truecolor → 256 → 16 → none.

## Non-Goals

- TextMate grammar loading or tree-sitter integration.
- User-configurable themes or runtime theme switching.
- Highlighting inside inline code spans (only fenced code blocks).
- Perfect syntax accuracy — keyword-level is sufficient for readability.

## Background

### What Codex Does

Codex uses three layers:

1. `syntect` + `two_face` — full TextMate grammar engine, ~250 languages, 32 themes.
2. `pulldown-cmark` — full CommonMark AST parser for markdown.
3. `terminal_palette.rs` + `color.rs` — terminal bg detection, alpha blending, quantization.

Layer 1 provides the visible value. Layers 2-3 are supporting infrastructure.

### What the Original RFC 0009 Built

The original RFC copied layers 2-3 only:

| Module | Lines | What it does |
|--------|-------|-------------|
| `color.zig` | 101 | CIE Lab perceptual distance, sRGB→XYZ, alpha blend |
| `theme.zig` | 457 | OSC 11 query, palette detection, 256/16 quantization cache |
| `ansi.zig` changes | ~80 | Semantic color prefix API |

Net visible effect on code blocks: a single background color. No syntax coloring.

### What This RFC Adds

A token-level syntax scanner that produces colored output for code blocks. The color
infrastructure is simplified to the minimum needed to support this.

## Proposal

### Architecture Overview

```
src/tui/
├── highlight.zig      NEW — token scanner + ANSI colorization
├── theme.zig          SIMPLIFIED — depth detection + palette, no CIE Lab
├── ansi.zig           KEEP — existing semantic color helpers are sufficient
├── markdown.zig       MODIFIED — pipe code blocks through highlight
└── color.zig          DELETE — not needed without perceptual quantization
```

### Module: `highlight.zig`

The core deliverable. A simple token scanner that classifies bytes into token types and emits
ANSI-colored output.

#### Token Types

```zig
pub const TokenKind = enum {
    keyword,
    string,
    comment,
    number,
    type_name,
    function,
    operator,
    punctuation,
    plain,
};
```

#### Language Detection

Detect language from the fenced code block info string (` ```zig `, ` ```python `, etc.).
Map to a language-specific keyword set. Unknown languages render with no highlighting.

```zig
pub const Language = enum {
    zig,
    python,
    javascript,
    typescript,
    go,
    rust,
    bash,
    c,
    cpp,
    json,
    yaml,
    sql,
    html,
    css,
    markdown,
    unknown,
};

pub fn detectLanguage(info: []const u8) Language;
```

#### Scanner Design

The scanner is a single-pass byte iterator. No AST, no backtracking, no recursion.

For each language, define:
- A keyword set (checked on word boundaries).
- String delimiters (`"`, `'`, backtick, triple-quote).
- Comment syntax (`//`, `#`, `--`, `/* */`).
- Number patterns (digits, `0x`, `0b`, `0o` prefixes).

The scanner produces a slice of `TokenSpan`:

```zig
pub const TokenSpan = struct {
    kind: TokenKind,
    start: usize,
    end: usize,
};

pub fn tokenize(
    allocator: Allocator,
    source: []const u8,
    language: Language,
) ![]TokenSpan;
```

#### Colorization

Map token kinds to ANSI colors based on current theme palette:

```zig
pub fn renderHighlightedLine(
    allocator: Allocator,
    line: []const u8,
    spans: []const TokenSpan,
    line_offset: usize,
) ![]u8;
```

This produces a single line with embedded ANSI escape sequences.

#### Highlight Palette

Each palette defines colors per token kind:

```zig
pub const HighlightPalette = struct {
    keyword: Rgb,
    string: Rgb,
    comment: Rgb,
    number: Rgb,
    type_name: Rgb,
    function: Rgb,
    operator: Rgb,
    punctuation: Rgb,
};
```

Dark palette (Dracula-inspired):
```
keyword:     .{ 255, 121, 198 }  — pink
string:      .{ 241, 250, 140 }  — yellow
comment:     .{ 98, 114, 164 }   — muted blue
number:      .{ 189, 147, 249 }  — purple
type_name:   .{ 139, 233, 253 }  — cyan
function:    .{ 80, 250, 123 }   — green
operator:    .{ 255, 184, 108 }  — orange
punctuation: .{ 248, 248, 242 }  — light gray
```

Light palette (GitHub-inspired):
```
keyword:     .{ 207, 34, 46 }    — red
string:      .{ 10, 48, 105 }    — dark blue
comment:     .{ 101, 109, 118 }  — gray
number:      .{ 5, 80, 174 }     — blue
type_name:   .{ 102, 57, 186 }   — purple
function:    .{ 130, 80, 223 }   — violet
operator:    .{ 31, 35, 40 }     — near-black
punctuation: .{ 31, 35, 40 }     — near-black
```

### Module: `theme.zig` (Simplified)

Strip down to what is actually needed:

```zig
pub const ColorDepth = enum { none, ansi16, ansi256, true_color };
pub const Rgb = [3]u8;
pub const Scheme = enum { dark, light };

pub const Theme = struct {
    depth: ColorDepth,
    scheme: Scheme,
};

pub fn detect(stdin: std.fs.File, stdout: std.fs.File) Theme;
pub fn forceNoColor() Theme;
```

#### What to Remove

- **CIE Lab / perceptual distance / sRGB linearization** — not needed. For ANSI 256 fallback,
  use a simple hardcoded lookup table mapping each highlight color to its nearest xterm index.
  There are only ~8 highlight colors per palette; precompute the mapping at comptime.
- **`Semantic` enum and `ResolvedColor` union** — over-abstraction. Callers can use the
  highlight palette directly.
- **`fgFor()` / `bgFor()` indirection** — replace with direct palette field access.
- **`blend()` function** — unused, delete.
- **Global mutable state** — return a `Theme` struct from `detect()`, pass it explicitly.

#### What to Keep

- `NO_COLOR` and TTY detection.
- `COLORTERM` / `TERM` env var depth detection.
- OSC 11 background query (but reduce timeout to 100ms, and make it optional — if it fails,
  default to dark).

#### ANSI 256 Fallback

Instead of runtime perceptual distance calculation over 240 colors, precompute at comptime:

```zig
const dark_keyword_256: u8 = 204;   // nearest xterm to (255, 121, 198)
const dark_string_256: u8 = 186;    // nearest xterm to (241, 250, 140)
// ... 8 entries per palette, hardcoded
```

This eliminates `color.zig` entirely.

#### ANSI 16 Fallback

Map token kinds to basic ANSI colors:

```zig
keyword  → magenta
string   → yellow
comment  → white (dim)
number   → cyan
type     → cyan
function → green
operator → plain
punct    → plain
```

### Changes to `markdown.zig`

The fenced code block path changes from:

```
raw line → pad to width → apply background color
```

To:

```
raw line → tokenize(line, language) → render highlighted line → pad to width → apply background
```

Specifically, `appendCodeBlockWrapped` gains a `language` parameter. The ` ``` ` fence line
parser extracts the info string and calls `highlight.detectLanguage()`.

For `ColorDepth.none`: render plain text, no escapes.
For `ColorDepth.ansi16`: render foreground token colors only, no background.
For `ColorDepth.ansi256` / `.true_color`: render foreground token colors + code block background.

### Changes to `interactive.zig`

Minimal changes:
- Pass `Theme` struct instead of relying on global state.
- Tool status colors and error colors use direct palette values.
- Remove dependency on `color.zig`.

## State and Data Model

The `Theme` struct is immutable after detection. It is created once at startup and passed by
pointer to rendering functions. No global mutable state.

```zig
pub const Theme = struct {
    depth: ColorDepth,
    scheme: Scheme,
    // Derived at init, immutable after:
    highlight: HighlightPalette,
    code_bg: Rgb,
    tool_running: Rgb,
    tool_success: Rgb,
    tool_error: Rgb,
    dim: Rgb,
};
```

## Failure Modes and Safety

- Unknown language in fence info string: render without highlighting (plain text with bg).
- OSC 11 timeout or parse failure: default to dark scheme.
- Non-TTY output: plain text, no ANSI escapes.
- Malformed source code: scanner never crashes — unrecognized bytes emit as `plain` tokens.
- Scanner is bounded: single pass, no recursion, no backtracking.

## Impact Analysis

### UI and Interaction

- [x] Screen layout or rendering (`src/tui/`)
- [x] Streaming output or incremental updates
- [x] Accessibility or readability in terminal environments

### Reliability and Diagnostics

- [x] Assertions or defensive checks

### Developer Experience

- [x] Build/test workflow
- [x] Documentation

## Operational Considerations

### Performance and Resource Use

- Token scanning is single-pass O(n) per line, no allocations beyond the span list.
- Highlight palette lookup is O(1) — direct struct field access.
- No runtime color distance calculations.
- Code block rendering adds one tokenize + colorize pass per line. For typical LLM output
  (< 200 lines per block), this is negligible.

### Compatibility and Migration

- Remove `color.zig` (new, untracked, no compatibility concern).
- Simplify `theme.zig` (new, untracked, no compatibility concern).
- `ansi.zig` public API changes are additive.
- `markdown.zig` rendering output changes visually but API is unchanged.

## Testing

- Unit tests:
  - `highlight.zig`: tokenize known snippets for each supported language. Verify token
    boundaries and kinds. Test edge cases: empty input, unterminated strings, nested comments.
  - `theme.zig`: env var precedence, OSC 11 parsing, depth detection.
  - ANSI 256/16 fallback: verify hardcoded mappings produce valid escape sequences.
- Integration tests:
  - Markdown code block with ` ```zig ` renders with color escapes in truecolor mode.
  - Markdown code block with unknown language renders plain.
  - `NO_COLOR=1` produces zero escape sequences.
  - `ColorDepth.ansi16` omits background, keeps foreground token colors.
- Manual verification:
  - Dark terminal: code blocks should look like Dracula theme.
  - Light terminal: code blocks should look like GitHub theme.
  - `TERM=xterm` (16 color): keywords colored, no background.
  - Pipe to `cat`: plain text output.

## Rollout Plan

- **Phase 1:** Simplify `theme.zig` — remove CIE Lab, return `Theme` struct, delete `color.zig`.
  Fix the double-free bug in `tool_status.zig` and the `semantic_count` magic number.
- **Phase 2:** Implement `highlight.zig` — token scanner + language detection + colorization.
  Start with Zig and Bash (most common in Orbit's own development).
- **Phase 3:** Wire highlighting into `markdown.zig` code block rendering path.
- **Phase 4:** Add remaining languages incrementally (Python, JS/TS, Go, Rust, JSON, etc.).

Each phase is independently testable. Phase 2 can be developed and tested in isolation with
no changes to existing rendering.

## Alternatives Considered

### Keep current approach (background color only)

Rejected. 558 lines of infrastructure for a single `bgSemantic()` call is not justified.
The visible improvement is near zero.

### Full TextMate grammar engine (like Codex's syntect)

Rejected. Requires a large grammar database and a complex parsing engine. Orbit is written in
Zig with a minimal-dependency policy. The maintenance cost is not justified for a CLI tool.

### Tree-sitter integration

Rejected for now. Tree-sitter grammars provide accurate parsing but require C library
integration and grammar file management. Could be a future RFC if keyword-level highlighting
proves insufficient.

### Regex-based highlighting

Considered but rejected in favor of a simpler byte-level scanner. Regex engines add complexity
and are harder to bound for performance. A hand-written scanner is more predictable and easier
to audit.

## References

- `references/codex/codex-rs/tui/src/render/highlight.rs` — Codex syntax highlighting (syntect)
- `references/codex/codex-rs/tui/src/markdown_render.rs` — Codex markdown rendering
- `references/codex/codex-rs/tui/src/terminal_palette.rs` — Codex terminal detection
- `references/codex/codex-rs/tui/src/style.rs` — Codex adaptive styling
- `rfcs/0008-interactive-markdown-and-tool-output.md`
- https://no-color.org/

## Updates

- 2026-03-19 v2: Rewrote RFC. Moved syntax highlighting from Non-Goal to primary Goal.
  Simplified color infrastructure. Removed CIE Lab perceptual distance and alpha blending.
  Added token scanner design. Changed from global mutable state to explicit Theme struct.
