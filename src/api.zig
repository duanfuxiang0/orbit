const std = @import("std");

pub const Error = error{
    UnexpectedStatus,
};

pub const SessionSummary = struct {
    id: []u8,
    title: []u8,

    pub fn deinit(self: *SessionSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        self.* = undefined;
    }
};

pub fn freeSessionSummaries(allocator: std.mem.Allocator, sessions: []SessionSummary) void {
    for (sessions) |*session| {
        session.deinit(allocator);
    }
    allocator.free(sessions);
}

pub const MessageRole = enum {
    user,
    assistant,
    thinking,
    tool,
};

pub const MessageLine = struct {
    role: MessageRole,
    text: []u8,

    pub fn deinit(self: *MessageLine, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub fn freeMessageLines(allocator: std.mem.Allocator, lines: []MessageLine) void {
    for (lines) |*line| {
        line.deinit(allocator);
    }
    allocator.free(lines);
}

pub const Client = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    directory: []const u8,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, directory: []const u8) Client {
        return .{
            .allocator = allocator,
            .base_url = base_url,
            .directory = directory,
        };
    }

    pub fn listSessions(self: *const Client) ![]SessionSummary {
        const response = try self.requestJson(.GET, "/session?roots=true&limit=200", null);
        defer self.allocator.free(response.body);

        if (response.status != .ok) return Error.UnexpectedStatus;

        const SessionWire = struct {
            id: []const u8,
            title: []const u8,
        };

        var parsed = try std.json.parseFromSlice([]SessionWire, self.allocator, response.body, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var out = try self.allocator.alloc(SessionSummary, parsed.value.len);
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |*session| session.deinit(self.allocator);
            self.allocator.free(out);
        }

        for (parsed.value, 0..) |entry, idx| {
            out[idx] = .{
                .id = try self.allocator.dupe(u8, entry.id),
                .title = try self.allocator.dupe(u8, entry.title),
            };
            i += 1;
        }

        return out;
    }

    pub fn createSession(self: *const Client) !SessionSummary {
        const response = try self.requestJson(.POST, "/session", "{}");
        defer self.allocator.free(response.body);

        if (response.status != .ok and response.status != .created) return Error.UnexpectedStatus;

        const SessionWire = struct {
            id: []const u8,
            title: []const u8,
        };

        var parsed = try std.json.parseFromSlice(SessionWire, self.allocator, response.body, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        return .{
            .id = try self.allocator.dupe(u8, parsed.value.id),
            .title = try self.allocator.dupe(u8, parsed.value.title),
        };
    }

    pub fn getSessionMessages(self: *const Client, session_id: []const u8) ![]MessageLine {
        const path = try std.fmt.allocPrint(self.allocator, "/session/{s}/message?limit=200", .{session_id});
        defer self.allocator.free(path);

        const response = try self.requestJson(.GET, path, null);
        defer self.allocator.free(response.body);

        if (response.status != .ok) return Error.UnexpectedStatus;

        const ToolStateWire = struct {
            status: []const u8,
            title: ?[]const u8 = null,
            @"error": ?[]const u8 = null,
        };

        const PartWire = struct {
            type: []const u8,
            text: ?[]const u8 = null,
            tool: ?[]const u8 = null,
            state: ?ToolStateWire = null,
        };

        const MessageWire = struct {
            info: struct {
                role: []const u8,
            },
            parts: []PartWire,
        };

        var parsed = try std.json.parseFromSlice([]MessageWire, self.allocator, response.body, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var out: std.ArrayListUnmanaged(MessageLine) = .{};
        errdefer {
            for (out.items) |*line| line.deinit(self.allocator);
            out.deinit(self.allocator);
        }

        for (parsed.value) |msg| {
            const role: MessageRole = if (std.mem.eql(u8, msg.info.role, "assistant")) .assistant else .user;
            var can_merge_same_message = false;

            for (msg.parts) |part| {
                if (std.mem.eql(u8, part.type, "text")) {
                    const text = part.text orelse continue;
                    const appended = try appendMergedLine(
                        self.allocator,
                        &out,
                        role,
                        text,
                        can_merge_same_message,
                    );
                    if (appended) can_merge_same_message = true;
                    continue;
                }

                if (std.mem.eql(u8, part.type, "reasoning")) {
                    const text = part.text orelse continue;
                    const appended = try appendMergedLine(
                        self.allocator,
                        &out,
                        .thinking,
                        text,
                        can_merge_same_message,
                    );
                    if (appended) can_merge_same_message = true;
                    continue;
                }

                if (std.mem.eql(u8, part.type, "tool")) {
                    const st = part.state orelse continue;
                    can_merge_same_message = false;

                    const tool_name = part.tool orelse "tool";
                    if (std.mem.eql(u8, st.status, "pending")) {
                        const text = try std.fmt.allocPrint(self.allocator, "{s} [pending]", .{tool_name});
                        defer self.allocator.free(text);
                        try appendLine(self.allocator, &out, .tool, text);
                        continue;
                    }
                    if (std.mem.eql(u8, st.status, "running")) {
                        if (st.title) |title| {
                            if (std.mem.indexOf(u8, title, tool_name) != null) {
                                try appendLine(self.allocator, &out, .tool, title);
                            } else {
                                const text = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ tool_name, title });
                                defer self.allocator.free(text);
                                try appendLine(self.allocator, &out, .tool, text);
                            }
                        } else {
                            const text = try std.fmt.allocPrint(self.allocator, "{s} [running]", .{tool_name});
                            defer self.allocator.free(text);
                            try appendLine(self.allocator, &out, .tool, text);
                        }
                        continue;
                    }
                    if (std.mem.eql(u8, st.status, "completed")) {
                        if (st.title) |title| {
                            if (std.mem.indexOf(u8, title, tool_name) != null) {
                                try appendLine(self.allocator, &out, .tool, title);
                            } else {
                                const text = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ tool_name, title });
                                defer self.allocator.free(text);
                                try appendLine(self.allocator, &out, .tool, text);
                            }
                        } else {
                            const text = try std.fmt.allocPrint(self.allocator, "{s} [completed]", .{tool_name});
                            defer self.allocator.free(text);
                            try appendLine(self.allocator, &out, .tool, text);
                        }
                        continue;
                    }
                    if (std.mem.eql(u8, st.status, "error")) {
                        if (st.@"error") |err_text| {
                            const text = try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ tool_name, err_text });
                            defer self.allocator.free(text);
                            try appendLine(self.allocator, &out, .tool, text);
                        } else {
                            const text = try std.fmt.allocPrint(self.allocator, "{s}: failed", .{tool_name});
                            defer self.allocator.free(text);
                            try appendLine(self.allocator, &out, .tool, text);
                        }
                        continue;
                    }
                }
            }
        }

        return out.toOwnedSlice(self.allocator);
    }

    pub fn sendPrompt(self: *const Client, session_id: []const u8, text: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "/session/{s}/prompt_async", .{session_id});
        defer self.allocator.free(path);

        const PartInput = struct {
            type: []const u8,
            text: []const u8,
        };

        const Payload = struct {
            parts: []const PartInput,
        };

        const payload: Payload = .{
            .parts = &.{.{ .type = "text", .text = text }},
        };

        var body_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer body_writer.deinit();

        try std.json.Stringify.value(payload, .{}, &body_writer.writer);
        const body = try body_writer.toOwnedSlice();
        defer self.allocator.free(body);

        const response = try self.requestJson(.POST, path, body);
        defer self.allocator.free(response.body);

        if (response.status != .no_content and response.status != .ok) {
            return Error.UnexpectedStatus;
        }
    }

    fn requestJson(
        self: *const Client,
        method: std.http.Method,
        path: []const u8,
        payload: ?[]const u8,
    ) !struct {
        status: std.http.Status,
        body: []u8,
    } {
        var http_client: std.http.Client = .{ .allocator = self.allocator };
        defer http_client.deinit();

        const url = try self.joinUrl(path);
        defer self.allocator.free(url);

        var response_body: std.Io.Writer.Allocating = .init(self.allocator);
        defer response_body.deinit();

        var headers_buf: [2]std.http.Header = undefined;
        var headers_len: usize = 0;

        if (self.directory.len > 0) {
            headers_buf[headers_len] = .{
                .name = "x-opencode-directory",
                .value = self.directory,
            };
            headers_len += 1;
        }

        if (payload != null) {
            headers_buf[headers_len] = .{
                .name = "content-type",
                .value = "application/json",
            };
            headers_len += 1;
        }

        const result = try http_client.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = payload,
            .extra_headers = headers_buf[0..headers_len],
            .response_writer = &response_body.writer,
        });

        return .{
            .status = result.status,
            .body = try response_body.toOwnedSlice(),
        };
    }

    fn joinUrl(self: *const Client, path: []const u8) ![]u8 {
        const base = if (std.mem.endsWith(u8, self.base_url, "/"))
            self.base_url[0 .. self.base_url.len - 1]
        else
            self.base_url;

        return std.fmt.allocPrint(self.allocator, "{s}{s}", .{ base, path });
    }
};

fn appendLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(MessageLine),
    role: MessageRole,
    text: []const u8,
) !void {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len == 0) return;

    try out.append(allocator, .{
        .role = role,
        .text = try allocator.dupe(u8, trimmed),
    });
}

fn appendMergedLine(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(MessageLine),
    role: MessageRole,
    text: []const u8,
    can_merge_with_previous: bool,
) !bool {
    const normalized = switch (role) {
        .thinking => std.mem.trim(u8, text, " \r\n\t"),
        else => std.mem.trim(u8, text, "\r"),
    };
    if (std.mem.trim(u8, normalized, " \n\t").len == 0) return false;

    if (out.items.len > 0 and role != .tool and can_merge_with_previous) {
        var last = &out.items[out.items.len - 1];
        if (last.role == role) {
            const merged = try std.fmt.allocPrint(allocator, "{s}{s}", .{ last.text, normalized });
            allocator.free(last.text);
            last.text = merged;
            return true;
        }
    }

    try out.append(allocator, .{
        .role = role,
        .text = try allocator.dupe(u8, normalized),
    });
    return true;
}
