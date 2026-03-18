const std = @import("std");
const vaxis = @import("vaxis");
const state_mod = @import("state.zig");

const MESSAGE_GAP_LINES: usize = 1;
const USER_PAD_X: u16 = 2;

const palette = struct {
    const foreground: u8 = 255; // opencode dark text (#eeeeee)
    const muted: u8 = 244; // opencode dark muted (#808080)
    const primary: u8 = 216; // opencode dark primary (#fab283)
    const accent: u8 = 140; // opencode dark accent (#9d7cd8)
    const info: u8 = 73; // opencode dark info (#56b6c2)
    const user_bg: u8 = 234; // opencode dark backgroundElement-ish
    const code_soft: u8 = 114; // opencode dark markdownCode (#7fd88f)
};

fn textStyle() vaxis.Style {
    return .{ .fg = .{ .index = palette.foreground } };
}

fn titleStyle() vaxis.Style {
    return .{
        .fg = .{ .index = palette.foreground },
        .bold = true,
    };
}

fn mutedStyle() vaxis.Style {
    return .{ .fg = .{ .index = palette.muted } };
}

fn sectionStyle() vaxis.Style {
    return .{
        .fg = .{ .index = palette.foreground },
        .bold = true,
    };
}

fn userBubbleFillStyle() vaxis.Style {
    return .{ .bg = .{ .index = palette.user_bg } };
}

pub fn draw(win: vaxis.Window, state: *const state_mod.State, input: *vaxis.widgets.TextInput) void {
    win.clear();

    switch (state.route) {
        .home => drawHome(win, state),
        .session => drawSession(win, state, input),
    }

    drawStatusBar(win, state);
}

fn drawHome(win: vaxis.Window, state: *const state_mod.State) void {
    win.hideCursor();

    printLine(win, 0, 0, "OpenCode Zig TUI (libvaxis)", titleStyle());
    printLine(win, 1, 0, "Route: HOME", mutedStyle());

    if (state.sessionCount() == 0) {
        printLine(win, 3, 0, "No sessions yet.", textStyle());
        printLine(win, 4, 0, "Press Enter or n to create your first session.", mutedStyle());
        return;
    }

    printLine(win, 3, 0, "Sessions:", sectionStyle());

    var row: u16 = 4;
    for (state.sessions.items, 0..) |*session, i| {
        if (row >= win.height -| 1) break;

        const selected = if (state.selectedIndex()) |idx| idx == i else false;
        const style: vaxis.Style = if (selected)
            .{
                .fg = .{ .index = palette.primary },
                .bold = true,
            }
        else
            textStyle();
        printLine(win, row, 2, if (selected) ">" else " ", style);
        printLine(win, row, 4, session.titleSlice(), style);
        row += 1;
    }

    if (win.height > 3) {
        printLine(win, win.height - 3, 0, "j/k or Up/Down: move selection", mutedStyle());
        printLine(win, win.height - 2, 0, "Enter: open | n: new | r: refresh | Tab: switch", mutedStyle());
    }
}

fn drawSession(win: vaxis.Window, state: *const state_mod.State, input: *vaxis.widgets.TextInput) void {
    if (win.height < 8 or win.width < 20) {
        win.hideCursor();
        printLine(win, 0, 0, "OpenCode Zig TUI (libvaxis)", titleStyle());
        printLine(win, 1, 0, "Route: SESSION", mutedStyle());
        printLine(win, 3, 0, "Window too small for session view.", textStyle());
        printLine(win, 4, 0, "Resize terminal to continue.", mutedStyle());
        return;
    }

    printLine(win, 0, 0, "OpenCode Zig TUI (libvaxis)", titleStyle());
    printLine(win, 1, 0, "Route: SESSION", mutedStyle());

    if (state.selectedSession()) |session| {
        printLine(win, 3, 0, "Active: ", sectionStyle());
        printLine(win, 3, 8, session.titleSlice(), sectionStyle());
        printLine(win, 4, 0, "Messages:", sectionStyle());

        const input_row = win.height - 3;
        const messages_row: u16 = 5;
        const messages_height = input_row -| messages_row;

        if (messages_height > 0) {
            const messages_win = win.child(.{
                .x_off = 0,
                .y_off = @intCast(messages_row),
                .width = win.width,
                .height = messages_height,
            });
            drawMessages(messages_win, state);
        }

        if (win.width > 2) {
            printLine(win, input_row, 0, "> ", mutedStyle());
            const input_win = win.child(.{
                .x_off = 2,
                .y_off = @intCast(input_row),
                .width = win.width - 2,
                .height = 1,
            });
            input.draw(input_win);
        } else {
            win.hideCursor();
        }

        printLine(win, win.height - 2, 0, "Mouse: select/copy | PgUp/PgDn: scroll | Enter: send | Esc: home | Tab: switch", mutedStyle());
    } else {
        win.hideCursor();
        printLine(win, 3, 0, "No session selected.", textStyle());
        printLine(win, 4, 0, "Press n to create one.", mutedStyle());
    }
}

fn drawMessages(win: vaxis.Window, state: *const state_mod.State) void {
    if (win.height == 0) return;

    if (state.messageCount() == 0) {
        printLine(win, 0, 0, "No messages yet. Type below and press Enter.", mutedStyle());
        return;
    }

    var lines_buf: [2048]DisplayLine = undefined;
    var lines_len: usize = 0;

    for (state.messages.items, 0..) |*message, idx| {
        if (idx > 0) {
            pushGapLines(&lines_buf, &lines_len, message.role, MESSAGE_GAP_LINES);
        }

        appendMessageDisplayLines(
            win,
            &lines_buf,
            &lines_len,
            message.role,
            message.textSlice(),
        );
    }

    if (lines_len == 0) {
        printLine(win, 0, 0, "No visible content.", mutedStyle());
        return;
    }

    const visible = @as(usize, win.height);
    const max_scroll = lines_len -| visible;
    const scroll = @min(state.messageScroll(), max_scroll);
    const start = max_scroll -| scroll;

    var row: u16 = 0;
    for (lines_buf[start..lines_len]) |line| {
        if (row >= win.height) break;
        if (line.is_gap) {
            row += 1;
            continue;
        }

        if (line.role == .user) {
            const line_win = win.child(.{
                .x_off = 0,
                .y_off = @intCast(row),
                .width = win.width,
                .height = 1,
            });
            line_win.fill(.{
                .style = userBubbleFillStyle(),
            });
        }

        var col: u16 = if (line.role == .user) @min(USER_PAD_X, win.width) else 0;
        for (line.segments[0..line.seg_len]) |segment| {
            if (col >= win.width) break;
            const result = win.printSegment(
                .{
                    .text = segment.text,
                    .style = segment.style,
                },
                .{
                    .row_offset = row,
                    .col_offset = col,
                    .wrap = .none,
                },
            );
            col = result.col;
        }
        row += 1;
    }
}

fn messageBodyStyle(role: state_mod.MessageRole) vaxis.Style {
    return switch (role) {
        .user => .{
            .fg = .{ .index = palette.foreground },
            .bg = .{ .index = palette.user_bg },
        },
        .assistant => .{ .fg = .{ .index = palette.foreground } },
        .thinking => .{
            .fg = .{ .index = palette.muted },
            .italic = true,
        },
        .tool => toolBodyStyle(),
    };
}

fn inlineCodeStyle(role: state_mod.MessageRole) vaxis.Style {
    var style = messageBodyStyle(role);
    style.fg = .{ .index = palette.code_soft };
    style.bold = false;
    style.italic = false;
    return style;
}

fn codeBlockStyle(role: state_mod.MessageRole) vaxis.Style {
    var style = messageBodyStyle(role);
    style.fg = .{ .index = palette.code_soft };
    style.italic = false;
    return style;
}

fn tableStyle(role: state_mod.MessageRole) vaxis.Style {
    var style = messageBodyStyle(role);
    style.fg = .{ .index = palette.muted };
    style.italic = false;
    return style;
}

fn headingStyle(role: state_mod.MessageRole) vaxis.Style {
    var style = messageBodyStyle(role);
    style.fg = .{ .index = palette.accent };
    style.bold = true;
    style.italic = false;
    return style;
}

fn toolNameStyle() vaxis.Style {
    return .{
        .fg = .{ .index = palette.info },
        .bold = true,
    };
}

fn toolBodyStyle() vaxis.Style {
    return .{ .fg = .{ .index = palette.muted } };
}

const LineSegment = struct {
    text: []const u8,
    style: vaxis.Style,
};

const DisplayLine = struct {
    role: state_mod.MessageRole,
    segments: [12]LineSegment = undefined,
    seg_len: usize = 0,
    is_gap: bool = false,
};

fn appendMessageDisplayLines(
    win: vaxis.Window,
    lines_buf: *[2048]DisplayLine,
    lines_len: *usize,
    role: state_mod.MessageRole,
    text: []const u8,
) void {
    if (win.width == 0) return;

    var in_code_block = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= text.len) {
        if (i < text.len and text[i] != '\n') {
            i += 1;
            continue;
        }

        const raw_line = text[start..i];
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (isCodeFence(line)) {
            in_code_block = !in_code_block;
        } else {
            const is_blank = std.mem.trim(u8, line, " \t").len == 0;
            if (role == .thinking and !in_code_block and is_blank) {
                if (i == text.len) break;
                i += 1;
                start = i;
                continue;
            }

            var parsed: [32]LineSegment = undefined;
            var parsed_len: usize = 0;

            if (in_code_block) {
                pushLineSegment(32, &parsed, &parsed_len, .{
                    .text = line,
                    .style = codeBlockStyle(role),
                });
            } else if (role == .tool) {
                parseToolLine(line, &parsed, &parsed_len);
            } else if (isMarkdownTableLine(line)) {
                pushLineSegment(32, &parsed, &parsed_len, .{
                    .text = line,
                    .style = tableStyle(role),
                });
            } else if (isMarkdownHeadingLine(line)) {
                pushLineSegment(32, &parsed, &parsed_len, .{
                    .text = line,
                    .style = headingStyle(role),
                });
            } else {
                parseInlineMarkdown(line, role, &parsed, &parsed_len);
            }

            appendWrappedSegments(win, lines_buf, lines_len, role, parsed[0..parsed_len], messageContentWidth(win, role));
        }

        if (i == text.len) break;
        i += 1;
        start = i;
    }
}

fn isCodeFence(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    return std.mem.startsWith(u8, trimmed, "```");
}

fn isMarkdownTableLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;
    if (trimmed[0] != '|' or trimmed[trimmed.len - 1] != '|') return false;
    return std.mem.indexOfScalar(u8, trimmed[1 .. trimmed.len - 1], '|') != null;
}

fn isMarkdownHeadingLine(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    var i: usize = 0;
    while (i < trimmed.len and trimmed[i] == '#') : (i += 1) {}
    if (i == 0 or i >= trimmed.len) return false;
    return trimmed[i] == ' ';
}

fn parseToolLine(line: []const u8, out: *[32]LineSegment, out_len: *usize) void {
    if (line.len == 0) return;

    const body = toolBodyStyle();
    var i: usize = 0;
    while (i < line.len and !isToolNameChar(line[i])) : (i += 1) {}

    if (i >= line.len) {
        pushLineSegment(32, out, out_len, .{
            .text = line,
            .style = body,
        });
        return;
    }

    if (i > 0) {
        pushLineSegment(32, out, out_len, .{
            .text = line[0..i],
            .style = body,
        });
    }

    var j = i;
    while (j < line.len and isToolNameChar(line[j])) : (j += 1) {}

    if (j > i) {
        pushLineSegment(32, out, out_len, .{
            .text = line[i..j],
            .style = toolNameStyle(),
        });
    }
    if (j < line.len) {
        pushLineSegment(32, out, out_len, .{
            .text = line[j..line.len],
            .style = body,
        });
    }
}

fn isToolNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == '.';
}

fn messageContentWidth(win: vaxis.Window, role: state_mod.MessageRole) u16 {
    if (role == .user) {
        const pad = USER_PAD_X * 2;
        return if (win.width > pad) win.width - pad else 1;
    }
    return if (win.width > 0) win.width else 1;
}

fn parseInlineMarkdown(
    line: []const u8,
    role: state_mod.MessageRole,
    out: *[32]LineSegment,
    out_len: *usize,
) void {
    const base = messageBodyStyle(role);
    if (line.len == 0) return;

    var plain_start: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, line, i + 2, "**")) |close| {
                if (close > i + 2) {
                    if (plain_start < i) {
                        pushLineSegment(32, out, out_len, .{
                            .text = line[plain_start..i],
                            .style = base,
                        });
                    }

                    var bold_style = base;
                    bold_style.bold = true;
                    pushLineSegment(32, out, out_len, .{
                        .text = line[i + 2 .. close],
                        .style = bold_style,
                    });

                    i = close + 2;
                    plain_start = i;
                    continue;
                }
            }
        }

        if (line[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '`')) |close| {
                if (close > i + 1) {
                    if (plain_start < i) {
                        pushLineSegment(32, out, out_len, .{
                            .text = line[plain_start..i],
                            .style = base,
                        });
                    }

                    pushLineSegment(32, out, out_len, .{
                        .text = line[i + 1 .. close],
                        .style = inlineCodeStyle(role),
                    });

                    i = close + 1;
                    plain_start = i;
                    continue;
                }
            }
        }

        i += 1;
    }

    if (plain_start < line.len) {
        pushLineSegment(32, out, out_len, .{
            .text = line[plain_start..line.len],
            .style = base,
        });
    }
}

fn appendWrappedSegments(
    win: vaxis.Window,
    lines_buf: *[2048]DisplayLine,
    lines_len: *usize,
    role: state_mod.MessageRole,
    segments: []const LineSegment,
    max_cols_arg: u16,
) void {
    if (segments.len == 0) {
        pushDisplayLine(lines_buf, lines_len, .{ .role = role });
        return;
    }

    const max_cols = if (max_cols_arg > 0) max_cols_arg else 1;
    var current: DisplayLine = .{ .role = role };
    var col: u16 = 0;

    for (segments) |segment| {
        if (segment.text.len == 0) continue;

        var run_start: usize = 0;
        var i: usize = 0;
        while (i < segment.text.len) {
            var char_len: usize = std.unicode.utf8ByteSequenceLength(segment.text[i]) catch 1;
            if (i + char_len > segment.text.len) char_len = 1;

            const g = segment.text[i .. i + char_len];
            var w = win.gwidth(g);
            if (w == 0) w = 1;

            if (col > 0 and col + w > max_cols) {
                if (run_start < i) {
                    pushLineSegment(12, &current.segments, &current.seg_len, .{
                        .text = segment.text[run_start..i],
                        .style = segment.style,
                    });
                }
                pushDisplayLine(lines_buf, lines_len, current);
                current = .{ .role = role };
                col = 0;
                run_start = i;
            }

            col += w;
            i += char_len;
        }

        if (run_start < segment.text.len) {
            pushLineSegment(12, &current.segments, &current.seg_len, .{
                .text = segment.text[run_start..segment.text.len],
                .style = segment.style,
            });
        }
    }

    pushDisplayLine(lines_buf, lines_len, current);
}

fn pushLineSegment(comptime N: usize, buf: *[N]LineSegment, len: *usize, seg: LineSegment) void {
    if (seg.text.len == 0) return;
    if (len.* >= buf.len) return;
    buf[len.*] = seg;
    len.* += 1;
}

fn pushDisplayLine(lines_buf: *[2048]DisplayLine, lines_len: *usize, line: DisplayLine) void {
    if (lines_len.* == lines_buf.len) {
        std.mem.copyForwards(DisplayLine, lines_buf[0 .. lines_buf.len - 1], lines_buf[1..lines_buf.len]);
        lines_len.* = lines_buf.len - 1;
    }
    lines_buf[lines_len.*] = line;
    lines_len.* += 1;
}

fn pushGapLines(lines_buf: *[2048]DisplayLine, lines_len: *usize, role: state_mod.MessageRole, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        pushDisplayLine(lines_buf, lines_len, .{
            .role = role,
            .is_gap = true,
        });
    }
}

fn drawStatusBar(win: vaxis.Window, state: *const state_mod.State) void {
    if (win.height == 0) return;

    const style: vaxis.Style = mutedStyle();
    printLine(win, win.height - 1, 0, " ", style);
    printLine(
        win,
        win.height - 1,
        1,
        switch (state.route) {
            .home => "HOME",
            .session => "SESSION",
        },
        style,
    );
    printLine(win, win.height - 1, 6, " | ", style);
    printLine(win, win.height - 1, 9, state.status(), style);
}

fn printLine(win: vaxis.Window, row: u16, col: u16, text: []const u8, style: vaxis.Style) void {
    if (row >= win.height or col >= win.width) return;

    _ = win.printSegment(
        .{ .text = text, .style = style },
        .{
            .row_offset = row,
            .col_offset = col,
            .wrap = .none,
        },
    );
}
