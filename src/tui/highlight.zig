const std = @import("std");
const ansi = @import("ansi.zig");
const theme = @import("theme.zig");

const Allocator = std.mem.Allocator;

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

pub const TokenSpan = struct {
    kind: TokenKind,
    start: usize,
    end: usize,
};

pub const Language = enum {
    zig,
    python,
    javascript,
    typescript,
    java,
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

pub const HighlightPalette = struct {
    keyword: theme.ColorValue,
    string: theme.ColorValue,
    comment: theme.ColorValue,
    number: theme.ColorValue,
    type_name: theme.ColorValue,
    function: theme.ColorValue,
    operator: theme.ColorValue,
    punctuation: theme.ColorValue,
};

const dark_palette = HighlightPalette{
    .keyword = .{ .rgb = .{ 255, 121, 198 }, .ansi256 = 212, .ansi16 = .magenta },
    .string = .{ .rgb = .{ 241, 250, 140 }, .ansi256 = 229, .ansi16 = .yellow },
    .comment = .{ .rgb = .{ 98, 114, 164 }, .ansi256 = 60, .ansi16 = .bright_black },
    .number = .{ .rgb = .{ 189, 147, 249 }, .ansi256 = 141, .ansi16 = .bright_magenta },
    .type_name = .{ .rgb = .{ 139, 233, 253 }, .ansi256 = 117, .ansi16 = .bright_cyan },
    .function = .{ .rgb = .{ 80, 250, 123 }, .ansi256 = 84, .ansi16 = .bright_green },
    .operator = .{ .rgb = .{ 255, 184, 108 }, .ansi256 = 215, .ansi16 = .bright_yellow },
    .punctuation = .{ .rgb = .{ 248, 248, 242 }, .ansi256 = 255, .ansi16 = .white },
};

const light_palette = HighlightPalette{
    .keyword = .{ .rgb = .{ 207, 34, 46 }, .ansi256 = 160, .ansi16 = .red },
    .string = .{ .rgb = .{ 10, 48, 105 }, .ansi256 = 24, .ansi16 = .blue },
    .comment = .{ .rgb = .{ 101, 109, 118 }, .ansi256 = 243, .ansi16 = .bright_black },
    .number = .{ .rgb = .{ 5, 80, 174 }, .ansi256 = 25, .ansi16 = .blue },
    .type_name = .{ .rgb = .{ 102, 57, 186 }, .ansi256 = 98, .ansi16 = .magenta },
    .function = .{ .rgb = .{ 130, 80, 223 }, .ansi256 = 99, .ansi16 = .bright_magenta },
    .operator = .{ .rgb = .{ 31, 35, 40 }, .ansi256 = 235, .ansi16 = .black },
    .punctuation = .{ .rgb = .{ 31, 35, 40 }, .ansi256 = 235, .ansi16 = .black },
};

const unsupported_language_color = theme.ColorValue{
    .rgb = .{ 178, 191, 80 }, // #B2BF50
    .ansi256 = 143,
    .ansi16 = .yellow,
};

const zig_keywords = [_][]const u8{
    "const", "var",      "fn",     "pub",         "if",     "else",     "switch",   "while",          "for",  "return",
    "break", "continue", "defer",  "errdefer",    "try",    "catch",    "orelse",   "and",            "or",   "struct",
    "enum",  "union",    "opaque", "packed",      "inline", "noinline", "comptime", "usingnamespace", "test", "async",
    "await", "suspend",  "resume", "threadlocal",
};

const zig_type_names = [_][]const u8{
    "u8",   "u16",      "u32",     "u64",      "u128", "usize",        "i8",             "i16",  "i32",
    "i64",  "i128",     "isize",   "f16",      "f32",  "f64",          "f80",            "f128", "bool",
    "void", "noreturn", "anytype", "anyerror", "type", "comptime_int", "comptime_float",
};

const bash_keywords = [_][]const u8{
    "if",     "then",  "elif",     "else",   "fi",    "for",    "in",    "do",     "done",     "case",    "esac",
    "while",  "until", "function", "select", "time",  "coproc", "local", "export", "readonly", "declare", "typeset",
    "return", "break", "continue", "shift",  "unset", "source",
};

const python_keywords = [_][]const u8{
    "def",    "class",    "if",     "elif",   "else",   "for",      "while", "try",
    "except", "finally",  "return", "yield",  "import", "from",     "as",    "pass",
    "break",  "continue", "with",   "lambda", "True",   "False",    "None",  "and",
    "or",     "not",      "in",     "is",     "global", "nonlocal", "raise", "async",
    "await",
};

const python_type_names = [_][]const u8{
    "int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes",
};

const js_keywords = [_][]const u8{
    "const",  "let",        "var",       "function", "class",   "if",    "else",
    "switch", "case",       "default",   "for",      "while",   "do",    "return",
    "break",  "continue",   "try",       "catch",    "finally", "throw", "new",
    "import", "from",       "export",    "extends",  "async",   "await", "yield",
    "typeof", "instanceof", "in",        "of",       "this",    "super", "null",
    "true",   "false",      "undefined",
};

const js_type_names = [_][]const u8{
    "number", "string", "boolean", "object", "Array", "Promise", "Date", "Map", "Set",
};

const java_keywords = [_][]const u8{
    "class",    "interface", "enum",         "public",   "private",   "protected",
    "static",   "final",     "abstract",     "if",       "else",      "switch",
    "case",     "default",   "for",          "while",    "do",        "try",
    "catch",    "finally",   "throw",        "throws",   "return",    "break",
    "continue", "new",       "this",         "super",    "extends",   "implements",
    "import",   "package",   "synchronized", "volatile", "transient", "native",
};

const java_type_names = [_][]const u8{
    "int", "long", "short", "byte", "float", "double", "char", "boolean", "void", "String",
};

const go_keywords = [_][]const u8{
    "package",     "import", "func",   "type",  "struct",   "interface", "map",     "chan",
    "go",          "defer",  "if",     "else",  "switch",   "case",      "default", "for",
    "range",       "select", "return", "break", "continue", "var",       "const",   "iota",
    "fallthrough",
};

const go_type_names = [_][]const u8{
    "int",    "int8",   "int16",   "int32",   "int64",   "uint", "uint8",  "uint16",
    "uint32", "uint64", "uintptr", "float32", "float64", "bool", "string", "byte",
    "rune",   "error",
};

const rust_keywords = [_][]const u8{
    "fn",   "let",   "mut",    "struct", "enum",     "impl",  "trait",
    "pub",  "use",   "mod",    "if",     "else",     "match", "while",
    "for",  "loop",  "return", "break",  "continue", "async", "await",
    "move", "const", "static", "unsafe", "where",    "crate", "super",
    "self", "Self",  "dyn",    "ref",    "as",
};

const rust_type_names = [_][]const u8{
    "i8",  "i16", "i32",  "i64", "i128",   "isize", "u8", "u16", "u32", "u64", "u128", "usize",
    "f32", "f64", "bool", "str", "String", "char",
};

const c_keywords = [_][]const u8{
    "if",       "else",    "switch",   "case",   "default",  "for",    "while",
    "do",       "break",   "continue", "return", "goto",     "struct", "union",
    "enum",     "typedef", "sizeof",   "const",  "volatile", "static", "extern",
    "register", "signed",  "unsigned", "inline", "restrict", "auto",
};

const cpp_keywords = [_][]const u8{
    "namespace",    "class",            "template",   "typename",  "public",
    "private",      "protected",        "virtual",    "override",  "final",
    "using",        "try",              "catch",      "throw",     "new",
    "delete",       "this",             "nullptr",    "constexpr", "consteval",
    "constinit",    "mutable",          "friend",     "operator",  "static_cast",
    "dynamic_cast", "reinterpret_cast", "const_cast",
};

const c_type_names = [_][]const u8{
    "void",   "char",    "short",   "int",     "long",     "float",    "double",
    "bool",   "size_t",  "ssize_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
    "int8_t", "int16_t", "int32_t", "int64_t", "wchar_t",  "string",   "std",
};

pub fn detectLanguage(info: []const u8) Language {
    const trimmed = std.mem.trim(u8, info, " \t\r");
    if (trimmed.len == 0) return .unknown;

    var end = trimmed.len;
    for (trimmed, 0..) |byte, i| {
        if (byte == ' ' or byte == '\t' or byte == ',' or byte == '{') {
            end = i;
            break;
        }
    }
    const token = trimmed[0..end];

    if (std.ascii.eqlIgnoreCase(token, "zig")) return .zig;
    if (std.ascii.eqlIgnoreCase(token, "bash")) return .bash;
    if (std.ascii.eqlIgnoreCase(token, "sh")) return .bash;
    if (std.ascii.eqlIgnoreCase(token, "shell")) return .bash;
    if (std.ascii.eqlIgnoreCase(token, "zsh")) return .bash;
    if (std.ascii.eqlIgnoreCase(token, "python")) return .python;
    if (std.ascii.eqlIgnoreCase(token, "py")) return .python;
    if (std.ascii.eqlIgnoreCase(token, "javascript")) return .javascript;
    if (std.ascii.eqlIgnoreCase(token, "js")) return .javascript;
    if (std.ascii.eqlIgnoreCase(token, "typescript")) return .typescript;
    if (std.ascii.eqlIgnoreCase(token, "ts")) return .typescript;
    if (std.ascii.eqlIgnoreCase(token, "java")) return .java;
    if (std.ascii.eqlIgnoreCase(token, "go")) return .go;
    if (std.ascii.eqlIgnoreCase(token, "rust")) return .rust;
    if (std.ascii.eqlIgnoreCase(token, "rs")) return .rust;
    if (std.ascii.eqlIgnoreCase(token, "c")) return .c;
    if (std.ascii.eqlIgnoreCase(token, "cpp")) return .cpp;
    if (std.ascii.eqlIgnoreCase(token, "c++")) return .cpp;
    if (std.ascii.eqlIgnoreCase(token, "json")) return .json;
    if (std.ascii.eqlIgnoreCase(token, "yaml")) return .yaml;
    if (std.ascii.eqlIgnoreCase(token, "yml")) return .yaml;
    if (std.ascii.eqlIgnoreCase(token, "sql")) return .sql;
    if (std.ascii.eqlIgnoreCase(token, "html")) return .html;
    if (std.ascii.eqlIgnoreCase(token, "css")) return .css;
    if (std.ascii.eqlIgnoreCase(token, "md")) return .markdown;
    if (std.ascii.eqlIgnoreCase(token, "markdown")) return .markdown;

    return .unknown;
}

pub fn tokenizeLine(
    allocator: Allocator,
    source: []const u8,
    language: Language,
) ![]TokenSpan {
    return switch (language) {
        .zig => tokenizeZig(allocator, source),
        .python => tokenizePython(allocator, source),
        .bash => tokenizeBash(allocator, source),
        .javascript => tokenizeCStyleWithTables(
            allocator,
            source,
            js_keywords[0..],
            null,
            js_type_names[0..],
        ),
        .typescript => tokenizeCStyleWithTables(
            allocator,
            source,
            js_keywords[0..],
            null,
            js_type_names[0..],
        ),
        .java => tokenizeCStyleWithTables(
            allocator,
            source,
            java_keywords[0..],
            null,
            java_type_names[0..],
        ),
        .go => tokenizeCStyleWithTables(
            allocator,
            source,
            go_keywords[0..],
            null,
            go_type_names[0..],
        ),
        .rust => tokenizeCStyleWithTables(
            allocator,
            source,
            rust_keywords[0..],
            null,
            rust_type_names[0..],
        ),
        .c => tokenizeCStyle(allocator, source, false),
        .cpp => tokenizeCStyle(allocator, source, true),
        else => allocator.alloc(TokenSpan, 0),
    };
}

pub fn renderLine(
    allocator: Allocator,
    source: []const u8,
    language: Language,
    current_theme: theme.Theme,
) ![]u8 {
    if (!current_theme.isColorEnabled()) return allocator.dupe(u8, source);

    const spans = try tokenizeLine(allocator, source, language);
    defer allocator.free(spans);

    if (spans.len == 0) {
        if (isConfiguredLanguage(language)) return allocator.dupe(u8, source);
        return ansi.fgColor(allocator, current_theme, source, unsupported_language_color);
    }

    const palette = paletteForScheme(current_theme.scheme);
    var default_buf: [24]u8 = undefined;
    const default_prefix = ansi.fgPrefix(&default_buf, current_theme, current_theme.palette.code_fg);

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    var cursor: usize = 0;
    for (spans) |span| {
        if (span.start > cursor) {
            try out.appendSlice(allocator, source[cursor..span.start]);
        }
        const token_color = colorForKind(palette, span.kind) orelse {
            try out.appendSlice(allocator, source[span.start..span.end]);
            cursor = span.end;
            continue;
        };

        var token_buf: [24]u8 = undefined;
        const token_prefix = ansi.fgPrefix(&token_buf, current_theme, token_color);
        if (token_prefix.len > 0) try out.appendSlice(allocator, token_prefix);
        try out.appendSlice(allocator, source[span.start..span.end]);
        if (default_prefix.len > 0) try out.appendSlice(allocator, default_prefix);
        cursor = span.end;
    }

    if (cursor < source.len) {
        try out.appendSlice(allocator, source[cursor..]);
    }

    return out.toOwnedSlice(allocator);
}

fn isConfiguredLanguage(language: Language) bool {
    return switch (language) {
        .zig,
        .python,
        .javascript,
        .typescript,
        .java,
        .go,
        .rust,
        .bash,
        .c,
        .cpp,
        => true,
        else => false,
    };
}

fn tokenizeZig(allocator: Allocator, source: []const u8) ![]TokenSpan {
    var spans: std.ArrayList(TokenSpan) = .{};
    errdefer spans.deinit(allocator);

    var i: usize = 0;
    while (i < source.len) {
        if (isZigCommentStart(source, i)) {
            try spans.append(allocator, .{ .kind = .comment, .start = i, .end = source.len });
            break;
        }

        const ch = source[i];
        if (ch == '"') {
            const end = scanString(source, i, '"', true);
            try spans.append(allocator, .{ .kind = .string, .start = i, .end = end });
            i = end;
            continue;
        }
        if (ch == '\'') {
            const end = scanString(source, i, '\'', true);
            try spans.append(allocator, .{ .kind = .string, .start = i, .end = end });
            i = end;
            continue;
        }
        if (isDigit(ch)) {
            const end = scanNumber(source, i);
            try spans.append(allocator, .{ .kind = .number, .start = i, .end = end });
            i = end;
            continue;
        }
        if (isIdentifierStart(ch)) {
            const end = scanIdentifier(source, i);
            const ident = source[i..end];
            const kind = classifyZigIdentifier(ident, source, end);
            if (kind != .plain) {
                try spans.append(allocator, .{ .kind = kind, .start = i, .end = end });
            }
            i = end;
            continue;
        }

        const punct_or_op = classifyPunctuationOrOperator(ch);
        if (punct_or_op != .plain) {
            try spans.append(allocator, .{ .kind = punct_or_op, .start = i, .end = i + 1 });
        }
        i += 1;
    }

    return spans.toOwnedSlice(allocator);
}

fn tokenizeBash(allocator: Allocator, source: []const u8) ![]TokenSpan {
    var spans: std.ArrayList(TokenSpan) = .{};
    errdefer spans.deinit(allocator);

    var i: usize = 0;
    while (i < source.len) {
        if (isBashCommentStart(source, i)) {
            try spans.append(allocator, .{ .kind = .comment, .start = i, .end = source.len });
            break;
        }

        const ch = source[i];
        if (ch == '"') {
            const end = scanString(source, i, '"', true);
            try spans.append(allocator, .{ .kind = .string, .start = i, .end = end });
            i = end;
            continue;
        }
        if (ch == '\'') {
            const end = scanString(source, i, '\'', false);
            try spans.append(allocator, .{ .kind = .string, .start = i, .end = end });
            i = end;
            continue;
        }
        if (isDigit(ch)) {
            const end = scanNumber(source, i);
            try spans.append(allocator, .{ .kind = .number, .start = i, .end = end });
            i = end;
            continue;
        }
        if (isIdentifierStart(ch)) {
            const end = scanIdentifier(source, i);
            const ident = source[i..end];
            const kind = classifyBashIdentifier(ident, source, end);
            if (kind != .plain) {
                try spans.append(allocator, .{ .kind = kind, .start = i, .end = end });
            }
            i = end;
            continue;
        }

        const punct_or_op = classifyPunctuationOrOperator(ch);
        if (punct_or_op != .plain) {
            try spans.append(allocator, .{ .kind = punct_or_op, .start = i, .end = i + 1 });
        }
        i += 1;
    }

    return spans.toOwnedSlice(allocator);
}

fn tokenizePython(allocator: Allocator, source: []const u8) ![]TokenSpan {
    var spans: std.ArrayList(TokenSpan) = .{};
    errdefer spans.deinit(allocator);

    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == '#') {
            try spans.append(allocator, .{ .kind = .comment, .start = i, .end = source.len });
            break;
        }

        const ch = source[i];
        if (ch == '"') {
            const end = scanPythonString(source, i, '"');
            try spans.append(allocator, .{ .kind = .string, .start = i, .end = end });
            i = end;
            continue;
        }
        if (ch == '\'') {
            const end = scanPythonString(source, i, '\'');
            try spans.append(allocator, .{ .kind = .string, .start = i, .end = end });
            i = end;
            continue;
        }
        if (isDigit(ch)) {
            const end = scanNumber(source, i);
            try spans.append(allocator, .{ .kind = .number, .start = i, .end = end });
            i = end;
            continue;
        }
        if (isIdentifierStart(ch)) {
            const end = scanIdentifier(source, i);
            const ident = source[i..end];
            const kind = classifyByTables(
                ident,
                source,
                end,
                python_keywords[0..],
                null,
                python_type_names[0..],
            );
            if (kind != .plain) {
                try spans.append(allocator, .{ .kind = kind, .start = i, .end = end });
            }
            i = end;
            continue;
        }

        const punct_or_op = classifyPunctuationOrOperator(ch);
        if (punct_or_op != .plain) {
            try spans.append(allocator, .{ .kind = punct_or_op, .start = i, .end = i + 1 });
        }
        i += 1;
    }

    return spans.toOwnedSlice(allocator);
}

fn tokenizeCStyle(allocator: Allocator, source: []const u8, is_cpp: bool) ![]TokenSpan {
    if (is_cpp) {
        return tokenizeCStyleWithTables(
            allocator,
            source,
            c_keywords[0..],
            cpp_keywords[0..],
            c_type_names[0..],
        );
    }
    return tokenizeCStyleWithTables(allocator, source, c_keywords[0..], null, c_type_names[0..]);
}

fn tokenizeCStyleWithTables(
    allocator: Allocator,
    source: []const u8,
    primary_keywords: []const []const u8,
    extra_keywords: ?[]const []const u8,
    type_names: []const []const u8,
) ![]TokenSpan {
    var spans: std.ArrayList(TokenSpan) = .{};
    errdefer spans.deinit(allocator);

    var i: usize = 0;
    while (i < source.len) {
        if (i + 1 < source.len and source[i] == '/' and source[i + 1] == '/') {
            try spans.append(allocator, .{ .kind = .comment, .start = i, .end = source.len });
            break;
        }
        if (i + 1 < source.len and source[i] == '/' and source[i + 1] == '*') {
            const end = scanBlockComment(source, i);
            try spans.append(allocator, .{ .kind = .comment, .start = i, .end = end });
            i = end;
            continue;
        }

        const ch = source[i];
        if (ch == '"') {
            const end = scanString(source, i, '"', true);
            try spans.append(allocator, .{ .kind = .string, .start = i, .end = end });
            i = end;
            continue;
        }
        if (ch == '\'') {
            const end = scanString(source, i, '\'', true);
            try spans.append(allocator, .{ .kind = .string, .start = i, .end = end });
            i = end;
            continue;
        }
        if (isDigit(ch)) {
            const end = scanNumber(source, i);
            try spans.append(allocator, .{ .kind = .number, .start = i, .end = end });
            i = end;
            continue;
        }
        if (isIdentifierStart(ch)) {
            const end = scanIdentifier(source, i);
            const ident = source[i..end];
            const kind = classifyByTables(
                ident,
                source,
                end,
                primary_keywords,
                extra_keywords,
                type_names,
            );
            if (kind != .plain) {
                try spans.append(allocator, .{ .kind = kind, .start = i, .end = end });
            }
            i = end;
            continue;
        }

        const punct_or_op = classifyPunctuationOrOperator(ch);
        if (punct_or_op != .plain) {
            try spans.append(allocator, .{ .kind = punct_or_op, .start = i, .end = i + 1 });
        }
        i += 1;
    }

    return spans.toOwnedSlice(allocator);
}

fn paletteForScheme(scheme: theme.Scheme) HighlightPalette {
    return switch (scheme) {
        .dark => dark_palette,
        .light => light_palette,
    };
}

fn colorForKind(palette: HighlightPalette, kind: TokenKind) ?theme.ColorValue {
    return switch (kind) {
        .keyword => palette.keyword,
        .string => palette.string,
        .comment => palette.comment,
        .number => palette.number,
        .type_name => palette.type_name,
        .function => palette.function,
        .operator => palette.operator,
        .punctuation => palette.punctuation,
        .plain => null,
    };
}

fn isZigCommentStart(source: []const u8, i: usize) bool {
    return i + 1 < source.len and source[i] == '/' and source[i + 1] == '/';
}

fn isBashCommentStart(source: []const u8, i: usize) bool {
    if (source[i] != '#') return false;
    if (i == 0) return true;
    return std.ascii.isWhitespace(source[i - 1]);
}

fn scanString(source: []const u8, start: usize, quote: u8, allow_escape: bool) usize {
    var i = start + 1;
    while (i < source.len) : (i += 1) {
        if (allow_escape and source[i] == '\\' and i + 1 < source.len) {
            i += 1;
            continue;
        }
        if (source[i] == quote) return i + 1;
    }
    return source.len;
}

fn scanPythonString(source: []const u8, start: usize, quote: u8) usize {
    if (start + 2 < source.len and source[start + 1] == quote and source[start + 2] == quote) {
        var i = start + 3;
        while (i + 2 < source.len) : (i += 1) {
            if (source[i] == quote and source[i + 1] == quote and source[i + 2] == quote) {
                return i + 3;
            }
        }
        return source.len;
    }
    return scanString(source, start, quote, true);
}

fn scanNumber(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len) : (i += 1) {
        const byte = source[i];
        const is_num = isDigit(byte) or
            (byte >= 'a' and byte <= 'f') or
            (byte >= 'A' and byte <= 'F') or
            byte == '_' or
            byte == '.' or
            byte == 'x' or
            byte == 'X' or
            byte == 'o' or
            byte == 'O' or
            byte == 'b' or
            byte == 'B';
        if (!is_num) break;
    }
    return i;
}

fn scanBlockComment(source: []const u8, start: usize) usize {
    var i = start + 2;
    while (i + 1 < source.len) : (i += 1) {
        if (source[i] == '*' and source[i + 1] == '/') return i + 2;
    }
    return source.len;
}

fn scanIdentifier(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len and isIdentifierContinue(source[i])) : (i += 1) {}
    return i;
}

fn classifyZigIdentifier(ident: []const u8, source: []const u8, end_idx: usize) TokenKind {
    if (containsWord(zig_keywords[0..], ident)) return .keyword;
    if (containsWord(zig_type_names[0..], ident)) return .type_name;
    if (looksLikeCall(source, end_idx)) return .function;
    return .plain;
}

fn classifyBashIdentifier(ident: []const u8, source: []const u8, end_idx: usize) TokenKind {
    if (containsWord(bash_keywords[0..], ident)) return .keyword;
    if (looksLikeBashFunction(source, end_idx)) return .function;
    return .plain;
}

fn classifyByTables(
    ident: []const u8,
    source: []const u8,
    end_idx: usize,
    primary_keywords: []const []const u8,
    extra_keywords: ?[]const []const u8,
    type_names: []const []const u8,
) TokenKind {
    if (containsWord(primary_keywords, ident)) return .keyword;
    if (extra_keywords) |extra| {
        if (containsWord(extra, ident)) return .keyword;
    }
    if (containsWord(type_names, ident)) return .type_name;
    if (looksLikeCall(source, end_idx)) return .function;
    return .plain;
}

fn containsWord(words: []const []const u8, ident: []const u8) bool {
    for (words) |word| {
        if (std.mem.eql(u8, word, ident)) return true;
    }
    return false;
}

fn looksLikeCall(source: []const u8, end_idx: usize) bool {
    var i = end_idx;
    while (i < source.len and std.ascii.isWhitespace(source[i])) : (i += 1) {}
    return i < source.len and source[i] == '(';
}

fn looksLikeBashFunction(source: []const u8, end_idx: usize) bool {
    var i = end_idx;
    while (i < source.len and std.ascii.isWhitespace(source[i])) : (i += 1) {}
    return i + 1 < source.len and source[i] == '(' and source[i + 1] == ')';
}

fn classifyPunctuationOrOperator(byte: u8) TokenKind {
    return switch (byte) {
        '+', '-', '*', '/', '%', '!', '=', '<', '>', '&', '|', '^', ':', '?' => .operator,
        '(', ')', '{', '}', '[', ']', ';', ',', '.' => .punctuation,
        else => .plain,
    };
}

fn isIdentifierStart(byte: u8) bool {
    return std.ascii.isAlphabetic(byte) or byte == '_';
}

fn isIdentifierContinue(byte: u8) bool {
    return isIdentifierStart(byte) or isDigit(byte);
}

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

test "detect language from fenced info string" {
    try std.testing.expectEqual(Language.zig, detectLanguage("zig"));
    try std.testing.expectEqual(Language.bash, detectLanguage(" bash"));
    try std.testing.expectEqual(Language.bash, detectLanguage("sh"));
    try std.testing.expectEqual(Language.javascript, detectLanguage("js"));
    try std.testing.expectEqual(Language.python, detectLanguage("py"));
    try std.testing.expectEqual(Language.go, detectLanguage("go"));
    try std.testing.expectEqual(Language.java, detectLanguage("java"));
    try std.testing.expectEqual(Language.cpp, detectLanguage("c++"));
    try std.testing.expectEqual(Language.unknown, detectLanguage(""));
}

test "tokenize zig line highlights keyword and comment" {
    const spans = try tokenizeLine(std.testing.allocator, "const x = 42; // note", .zig);
    defer std.testing.allocator.free(spans);

    try std.testing.expect(spans.len >= 3);
    try std.testing.expectEqual(TokenKind.keyword, spans[0].kind);
    try std.testing.expectEqualStrings("const", "const x = 42; // note"[spans[0].start..spans[0].end]);

    const last = spans[spans.len - 1];
    try std.testing.expectEqual(TokenKind.comment, last.kind);
}

test "tokenize bash line highlights keyword and string" {
    const spans = try tokenizeLine(std.testing.allocator, "if echo \"hi\"; then", .bash);
    defer std.testing.allocator.free(spans);

    try std.testing.expect(spans.len >= 3);
    try std.testing.expectEqual(TokenKind.keyword, spans[0].kind);

    var found_string = false;
    for (spans) |span| {
        if (span.kind == .string) {
            found_string = true;
            break;
        }
    }
    try std.testing.expect(found_string);
}

test "tokenize cpp line highlights keyword and type" {
    const spans = try tokenizeLine(std.testing.allocator, "const std::string s = \"x\";", .cpp);
    defer std.testing.allocator.free(spans);

    var saw_keyword = false;
    var saw_type = false;
    for (spans) |span| {
        if (span.kind == .keyword) saw_keyword = true;
        if (span.kind == .type_name) saw_type = true;
    }

    try std.testing.expect(saw_keyword);
    try std.testing.expect(saw_type);
}

test "tokenize javascript line highlights keyword and comment" {
    const spans = try tokenizeLine(std.testing.allocator, "const x = 1; // note", .javascript);
    defer std.testing.allocator.free(spans);

    var saw_keyword = false;
    var saw_comment = false;
    for (spans) |span| {
        if (span.kind == .keyword) saw_keyword = true;
        if (span.kind == .comment) saw_comment = true;
    }

    try std.testing.expect(saw_keyword);
    try std.testing.expect(saw_comment);
}

test "tokenize python line highlights keyword and comment" {
    const spans = try tokenizeLine(std.testing.allocator, "def f(x): return x # note", .python);
    defer std.testing.allocator.free(spans);

    var saw_keyword = false;
    var saw_comment = false;
    for (spans) |span| {
        if (span.kind == .keyword) saw_keyword = true;
        if (span.kind == .comment) saw_comment = true;
    }

    try std.testing.expect(saw_keyword);
    try std.testing.expect(saw_comment);
}

test "tokenize go line highlights keyword and type" {
    const spans = try tokenizeLine(std.testing.allocator, "func f(x int) int { return x }", .go);
    defer std.testing.allocator.free(spans);

    var saw_keyword = false;
    var saw_type = false;
    for (spans) |span| {
        if (span.kind == .keyword) saw_keyword = true;
        if (span.kind == .type_name) saw_type = true;
    }

    try std.testing.expect(saw_keyword);
    try std.testing.expect(saw_type);
}

test "render line adds ansi escapes for known language" {
    const current_theme = theme.themeFor(.ansi16, .dark);
    const rendered = try renderLine(std.testing.allocator, "const x = 1", .zig, current_theme);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "const") != null);
}

test "render line uses fallback color for unsupported language" {
    const current_theme = theme.themeFor(.true_color, .dark);
    const rendered = try renderLine(std.testing.allocator, "print('hi')", .unknown, current_theme);
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[38;2;178;191;80m") != null);
}
