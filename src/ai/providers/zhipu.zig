const std = @import("std");
const openai = @import("openai.zig");
const provider_mod = @import("../provider.zig");
const stream_mod = @import("../stream.zig");

pub const Header = provider_mod.Header;
pub const Transport = provider_mod.Transport;

const default_completions_url = "https://open.bigmodel.cn/api/paas/v4/chat/completions";
const zhipu_origin = "https://open.bigmodel.cn";

pub const ZhipuProvider = struct {
    allocator: std.mem.Allocator,
    inner: openai.OpenAIProvider,

    pub fn init(
        allocator: std.mem.Allocator,
        api_key: []const u8,
        base_url: ?[]const u8,
        transport: Transport,
    ) !ZhipuProvider {
        std.debug.assert(api_key.len > 0);

        const completions_url = try resolveCompletionsUrl(allocator, base_url);
        defer allocator.free(completions_url);

        return .{
            .allocator = allocator,
            .inner = try openai.OpenAIProvider.init(
                allocator,
                api_key,
                completions_url,
                transport,
            ),
        };
    }

    pub fn asProvider(self: *ZhipuProvider) provider_mod.Provider {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn streamImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: provider_mod.Request,
        sink: *stream_mod.EventSink,
    ) !void {
        const self: *ZhipuProvider = @ptrCast(@alignCast(ptr));
        return self.inner.asProvider().stream(allocator, request, sink);
    }

    fn abortImpl(ptr: *anyopaque) void {
        const self: *ZhipuProvider = @ptrCast(@alignCast(ptr));
        self.inner.asProvider().abort();
    }

    fn nameImpl(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "zhipu";
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *ZhipuProvider = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    pub fn deinit(self: *ZhipuProvider) void {
        self.inner.deinit();
        self.* = undefined;
    }
};

const vtable: provider_mod.Provider.VTable = .{
    .stream = ZhipuProvider.streamImpl,
    .abort = ZhipuProvider.abortImpl,
    .name = ZhipuProvider.nameImpl,
    .deinit = ZhipuProvider.deinitImpl,
};

fn resolveCompletionsUrl(allocator: std.mem.Allocator, base_url: ?[]const u8) ![]u8 {
    const raw = base_url orelse return allocator.dupe(u8, default_completions_url);
    std.debug.assert(raw.len > 0);

    if (std.mem.endsWith(u8, raw, "/chat/completions")) return allocator.dupe(u8, raw);
    if (isZhipuOrigin(raw)) return allocator.dupe(u8, default_completions_url);
    if (std.mem.endsWith(u8, raw, "/")) {
        return std.fmt.allocPrint(allocator, "{s}chat/completions", .{raw});
    }
    return std.fmt.allocPrint(allocator, "{s}/chat/completions", .{raw});
}

fn isZhipuOrigin(raw: []const u8) bool {
    if (std.mem.eql(u8, raw, zhipu_origin)) return true;
    if (std.mem.eql(u8, raw, zhipu_origin ++ "/")) return true;
    return false;
}

test "zhipu resolves base url roots and endpoints" {
    const allocator = std.testing.allocator;

    const default_url = try resolveCompletionsUrl(allocator, null);
    defer allocator.free(default_url);
    try std.testing.expectEqualStrings(default_completions_url, default_url);

    const root_url = try resolveCompletionsUrl(allocator, "https://open.bigmodel.cn");
    defer allocator.free(root_url);
    try std.testing.expectEqualStrings(default_completions_url, root_url);

    const v4_url = try resolveCompletionsUrl(
        allocator,
        "https://open.bigmodel.cn/api/paas/v4",
    );
    defer allocator.free(v4_url);
    try std.testing.expectEqualStrings(default_completions_url, v4_url);

    const explicit_url = try resolveCompletionsUrl(allocator, default_completions_url);
    defer allocator.free(explicit_url);
    try std.testing.expectEqualStrings(default_completions_url, explicit_url);
}
