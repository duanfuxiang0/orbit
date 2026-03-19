const std = @import("std");

pub const types = @import("types.zig");
pub const models = @import("models.zig");
pub const stream = @import("stream.zig");
pub const provider = @import("provider.zig");
pub const http = @import("http.zig");
pub const context = @import("context.zig");
pub const json_util = @import("json_util.zig");
pub const providers = struct {
    pub const anthropic = @import("providers/anthropic.zig");
    pub const openai = @import("providers/openai.zig");
    pub const zhipu = @import("providers/zhipu.zig");
};

pub const Role = types.Role;
pub const ContentPart = types.ContentPart;
pub const Message = types.Message;
pub const ToolCall = types.ToolCall;
pub const ToolResult = types.ToolResult;
pub const ToolSpec = types.ToolSpec;
pub const TokenUsage = types.TokenUsage;
pub const TokenCost = types.TokenCost;
pub const ApiProtocol = models.ApiProtocol;
pub const Model = models.Model;
pub const StreamEvent = stream.StreamEvent;
pub const StopReason = stream.StopReason;
pub const StreamError = stream.StreamError;
pub const ErrorKind = stream.ErrorKind;
pub const Request = provider.Request;
pub const Provider = provider.Provider;
pub const EventSink = stream.EventSink;

pub fn streamCompletion(
    p: Provider,
    allocator: std.mem.Allocator,
    req: Request,
    sink: *EventSink,
) !void {
    std.debug.assert(req.model.len > 0);
    return p.stream(allocator, req, sink);
}

pub fn abortCompletion(p: Provider) void {
    p.abort();
}
