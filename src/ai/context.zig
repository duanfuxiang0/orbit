const std = @import("std");
const models = @import("models.zig");
const types = @import("types.zig");

pub fn convertThinkingToText(
    messages: []const types.Message,
    allocator: std.mem.Allocator,
) ![]types.Message {
    return cloneMessages(messages, allocator, true);
}

pub fn normalizeForProvider(
    messages: []const types.Message,
    protocol: models.ApiProtocol,
    allocator: std.mem.Allocator,
) ![]types.Message {
    return switch (protocol) {
        .openai_completions => cloneMessages(messages, allocator, true),
        .anthropic_messages => cloneMessages(messages, allocator, false),
    };
}

pub fn freeMessages(allocator: std.mem.Allocator, messages: []types.Message) void {
    for (messages) |message| {
        for (message.content) |part| {
            freePart(allocator, part);
        }
        allocator.free(message.content);
    }
    allocator.free(messages);
}

fn cloneMessages(
    messages: []const types.Message,
    allocator: std.mem.Allocator,
    convert_thinking: bool,
) ![]types.Message {
    var out = try allocator.alloc(types.Message, messages.len);
    var initialized: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) {
            for (out[i].content) |part| {
                freePart(allocator, part);
            }
            allocator.free(out[i].content);
        }
        allocator.free(out);
    }

    for (messages, 0..) |message, i| {
        const cloned_parts = try cloneParts(message.content, allocator, convert_thinking);
        out[i] = .{
            .role = message.role,
            .content = cloned_parts,
        };
        initialized += 1;
    }
    return out;
}

fn cloneParts(
    parts: []const types.ContentPart,
    allocator: std.mem.Allocator,
    convert_thinking: bool,
) ![]types.ContentPart {
    var out = try allocator.alloc(types.ContentPart, parts.len);
    var initialized: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < initialized) : (i += 1) freePart(allocator, out[i]);
        allocator.free(out);
    }

    for (parts, 0..) |part, idx| {
        out[idx] = try clonePart(part, allocator, convert_thinking);
        initialized += 1;
    }
    return out;
}

fn clonePart(
    part: types.ContentPart,
    allocator: std.mem.Allocator,
    convert_thinking: bool,
) !types.ContentPart {
    return switch (part) {
        .text => |text| .{ .text = try allocator.dupe(u8, text) },
        .thinking => |thinking| blk: {
            if (convert_thinking) {
                const wrapped = try std.fmt.allocPrint(
                    allocator,
                    "<thinking>\n{s}\n</thinking>",
                    .{thinking.text},
                );
                break :blk .{ .text = wrapped };
            }
            break :blk .{
                .thinking = .{
                    .text = try allocator.dupe(u8, thinking.text),
                    .signature = if (thinking.signature) |signature|
                        try allocator.dupe(u8, signature)
                    else
                        null,
                },
            };
        },
        .image_url => |image| .{
            .image_url = .{ .url = try allocator.dupe(u8, image.url) },
        },
        .image_base64 => |image| .{
            .image_base64 = .{
                .data = try allocator.dupe(u8, image.data),
                .media_type = try allocator.dupe(u8, image.media_type),
            },
        },
        .tool_call => |tool_call| .{
            .tool_call = .{
                .id = try allocator.dupe(u8, tool_call.id),
                .name = try allocator.dupe(u8, tool_call.name),
                .arguments = try allocator.dupe(u8, tool_call.arguments),
            },
        },
        .tool_result => |tool_result| .{
            .tool_result = .{
                .tool_call_id = try allocator.dupe(u8, tool_result.tool_call_id),
                .content = try allocator.dupe(u8, tool_result.content),
                .is_error = tool_result.is_error,
            },
        },
    };
}

fn freePart(allocator: std.mem.Allocator, part: types.ContentPart) void {
    switch (part) {
        .text => |text| allocator.free(text),
        .thinking => |thinking| {
            allocator.free(thinking.text);
            if (thinking.signature) |signature| allocator.free(signature);
        },
        .image_url => |image| allocator.free(image.url),
        .image_base64 => |image| {
            allocator.free(image.data);
            allocator.free(image.media_type);
        },
        .tool_call => |tool_call| {
            allocator.free(tool_call.id);
            allocator.free(tool_call.name);
            allocator.free(tool_call.arguments);
        },
        .tool_result => |tool_result| {
            allocator.free(tool_result.tool_call_id);
            allocator.free(tool_result.content);
        },
    }
}

test "convert thinking wraps content in tags" {
    const input_parts = [_]types.ContentPart{
        .{ .text = "regular" },
        .{ .thinking = .{ .text = "hidden", .signature = "sig_1" } },
    };
    const input_messages = [_]types.Message{
        .{ .role = .assistant, .content = &input_parts },
    };

    const converted = try convertThinkingToText(&input_messages, std.testing.allocator);
    defer freeMessages(std.testing.allocator, converted);

    try std.testing.expectEqual(@as(usize, 2), converted[0].content.len);
    try std.testing.expectEqualStrings("regular", converted[0].content[0].text);
    try std.testing.expectEqualStrings(
        "<thinking>\nhidden\n</thinking>",
        converted[0].content[1].text,
    );
}

test "normalize for anthropic keeps thinking part" {
    const parts = [_]types.ContentPart{
        .{ .thinking = .{ .text = "trace", .signature = "sig_2" } },
    };
    const messages = [_]types.Message{
        .{ .role = .assistant, .content = &parts },
    };

    const normalized = try normalizeForProvider(
        &messages,
        .anthropic_messages,
        std.testing.allocator,
    );
    defer freeMessages(std.testing.allocator, normalized);

    try std.testing.expect(normalized[0].content[0] == .thinking);
    try std.testing.expectEqualStrings("trace", normalized[0].content[0].thinking.text);
    try std.testing.expectEqualStrings("sig_2", normalized[0].content[0].thinking.signature.?);
}
