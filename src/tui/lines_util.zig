const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn freeLines(allocator: Allocator, lines: []const []const u8) void {
    for (lines) |line| {
        allocator.free(line);
    }
    allocator.free(lines);
}

pub fn freeOptionalLines(allocator: Allocator, maybe_lines: ?[]const []const u8) void {
    if (maybe_lines) |lines| {
        freeLines(allocator, lines);
    }
}

pub fn cloneLines(allocator: Allocator, source: []const []const u8) ![][]const u8 {
    const out = try allocator.alloc([]const u8, source.len);
    errdefer allocator.free(out);

    var i: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) {
            allocator.free(out[j]);
        }
    }

    while (i < source.len) : (i += 1) {
        out[i] = try allocator.dupe(u8, source[i]);
    }
    return out;
}

/// Appends owned line buffers into `dst`.
///
/// Ownership contract:
/// - On success, ownership of every `owned_lines[i]` transfers to `dst`.
/// - On failure, ownership of `owned_lines[0..i]` has already transferred to `dst`;
///   this function frees only the remaining untransferred lines and the outer slice.
/// - The outer `owned_lines` slice is always freed by this function.
pub fn appendOwnedLines(
    dst: *std.ArrayList([]const u8),
    allocator: Allocator,
    owned_lines: [][]const u8,
) !void {
    var i: usize = 0;
    while (i < owned_lines.len) : (i += 1) {
        dst.append(allocator, owned_lines[i]) catch |err| {
            var j = i;
            while (j < owned_lines.len) : (j += 1) {
                allocator.free(owned_lines[j]);
            }
            allocator.free(owned_lines);
            return err;
        };
    }
    allocator.free(owned_lines);
}

fn appendOwnedLinesTestImpl(allocator: Allocator) !void {
    var dst: std.ArrayList([]const u8) = .{};
    defer {
        for (dst.items) |line| {
            allocator.free(line);
        }
        dst.deinit(allocator);
    }

    var maybe_owned_lines: ?[][]const u8 = try allocator.alloc([]const u8, 3);
    errdefer if (maybe_owned_lines) |owned_lines| allocator.free(owned_lines);

    var initialized: usize = 0;
    errdefer {
        if (maybe_owned_lines) |owned_lines| {
            var i: usize = 0;
            while (i < initialized) : (i += 1) {
                allocator.free(owned_lines[i]);
            }
        }
    }

    const owned_lines = maybe_owned_lines.?;
    owned_lines[0] = try allocator.dupe(u8, "alpha");
    initialized += 1;
    owned_lines[1] = try allocator.dupe(u8, "beta");
    initialized += 1;
    owned_lines[2] = try allocator.dupe(u8, "gamma");
    initialized += 1;

    maybe_owned_lines = null;
    try appendOwnedLines(&dst, allocator, owned_lines);
}

test "clone lines duplicates each owned line" {
    const source = [_][]const u8{ "alpha", "beta" };
    const lines = try cloneLines(std.testing.allocator, &source);
    defer freeLines(std.testing.allocator, lines);

    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("alpha", lines[0]);
    try std.testing.expectEqualStrings("beta", lines[1]);
}

test "append owned lines cleans up across allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        appendOwnedLinesTestImpl,
        .{},
    );
}
