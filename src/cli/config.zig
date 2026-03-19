const std = @import("std");

pub const Config = struct {
    default_model: []const u8,
    anthropic_api_key: ?[]const u8,
    anthropic_base_url: ?[]const u8,
    openai_api_key: ?[]const u8,
    sessions_dir: []const u8,
    verbose: bool,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.default_model);
        if (self.anthropic_api_key) |value| allocator.free(value);
        if (self.anthropic_base_url) |value| allocator.free(value);
        if (self.openai_api_key) |value| allocator.free(value);
        allocator.free(self.sessions_dir);
        self.* = undefined;
    }
};

const RawConfig = struct {
    default_model: ?[]const u8 = null,
    anthropic_api_key: ?[]const u8 = null,
    anthropic_base_url: ?[]const u8 = null,
    openai_api_key: ?[]const u8 = null,
    sessions_dir: ?[]const u8 = null,
    verbose: ?bool = null,

    fn deinit(self: *RawConfig, allocator: std.mem.Allocator) void {
        if (self.default_model) |value| allocator.free(value);
        if (self.anthropic_api_key) |value| allocator.free(value);
        if (self.anthropic_base_url) |value| allocator.free(value);
        if (self.openai_api_key) |value| allocator.free(value);
        if (self.sessions_dir) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const EnvOverrides = struct {
    orbit_model: ?[]const u8 = null,
    anthropic_api_key: ?[]const u8 = null,
    anthropic_base_url: ?[]const u8 = null,
    openai_api_key: ?[]const u8 = null,
    orbit_sessions_dir: ?[]const u8 = null,
    orbit_verbose: ?bool = null,

    fn deinit(self: *EnvOverrides, allocator: std.mem.Allocator) void {
        if (self.orbit_model) |value| allocator.free(value);
        if (self.anthropic_api_key) |value| allocator.free(value);
        if (self.anthropic_base_url) |value| allocator.free(value);
        if (self.openai_api_key) |value| allocator.free(value);
        if (self.orbit_sessions_dir) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn load(allocator: std.mem.Allocator) !Config {
    const home_dir = try getHomeDir(allocator);
    defer allocator.free(home_dir);

    var env = try loadEnvOverrides(allocator);
    defer env.deinit(allocator);

    const json_path = try std.fs.path.join(allocator, &.{ home_dir, ".orbit", "config.json" });
    defer allocator.free(json_path);

    const toml_path = try std.fs.path.join(allocator, &.{ home_dir, ".orbit", "config.toml" });
    defer allocator.free(toml_path);

    if (pathExists(json_path)) {
        return loadWithOverrides(allocator, home_dir, json_path, env);
    }
    return loadWithOverrides(allocator, home_dir, toml_path, env);
}

pub fn loadWithOverrides(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    config_path: []const u8,
    env: EnvOverrides,
) !Config {
    std.debug.assert(home_dir.len > 0);
    std.debug.assert(config_path.len > 0);

    var raw = try loadRawConfig(allocator, config_path);
    defer raw.deinit(allocator);

    return buildConfig(allocator, home_dir, raw, env);
}

fn loadRawConfig(allocator: std.mem.Allocator, config_path: []const u8) !RawConfig {
    const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    if (stat.size == 0) return .{};

    const content = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \r\n\t");
    if (trimmed.len == 0) return .{};
    return parseConfigContent(allocator, trimmed);
}

fn buildConfig(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    raw: RawConfig,
    env: EnvOverrides,
) !Config {
    const default_model_value = env.orbit_model orelse raw.default_model orelse
        "claude-sonnet-4-20250514";
    const sessions_dir_value = env.orbit_sessions_dir orelse raw.sessions_dir orelse
        "~/.orbit/sessions";
    const verbose_value = env.orbit_verbose orelse raw.verbose orelse false;

    return .{
        .default_model = try allocator.dupe(u8, default_model_value),
        .anthropic_api_key = try dupOptional(
            allocator,
            env.anthropic_api_key orelse raw.anthropic_api_key,
        ),
        .anthropic_base_url = try dupOptional(
            allocator,
            env.anthropic_base_url orelse raw.anthropic_base_url,
        ),
        .openai_api_key = try dupOptional(
            allocator,
            env.openai_api_key orelse raw.openai_api_key,
        ),
        .sessions_dir = try expandHomeDir(allocator, home_dir, sessions_dir_value),
        .verbose = verbose_value,
    };
}

fn parseConfigContent(allocator: std.mem.Allocator, content: []const u8) !RawConfig {
    if (content[0] == '{') {
        return parseJsonConfig(allocator, content);
    }
    return parseTomlSubset(allocator, content);
}

fn parseJsonConfig(allocator: std.mem.Allocator, content: []const u8) !RawConfig {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    var result: RawConfig = .{};
    errdefer result.deinit(allocator);

    const root = parsed.value;
    if (root != .object) return error.InvalidConfig;

    const scope = if (root.object.get("llm")) |llm|
        if (llm == .object) llm else root
    else
        root;

    try loadObjectConfig(allocator, &result, scope);
    return result;
}

fn loadObjectConfig(
    allocator: std.mem.Allocator,
    result: *RawConfig,
    value: std.json.Value,
) !void {
    if (value != .object) return error.InvalidConfig;

    try assignJsonString(allocator, &result.default_model, value, "default_model");
    try assignJsonString(allocator, &result.anthropic_api_key, value, "anthropic_api_key");
    try assignJsonString(allocator, &result.anthropic_base_url, value, "anthropic_base_url");
    try assignJsonString(allocator, &result.openai_api_key, value, "openai_api_key");
    try assignJsonString(allocator, &result.sessions_dir, value, "sessions_dir");

    if (value.object.get("verbose")) |raw_verbose| {
        if (raw_verbose != .bool) return error.InvalidConfig;
        result.verbose = raw_verbose.bool;
    }
}

fn assignJsonString(
    allocator: std.mem.Allocator,
    slot: *?[]const u8,
    value: std.json.Value,
    key: []const u8,
) !void {
    if (value.object.get(key)) |raw| {
        if (raw != .string) return error.InvalidConfig;
        slot.* = try allocator.dupe(u8, raw.string);
    }
}

fn parseTomlSubset(allocator: std.mem.Allocator, content: []const u8) !RawConfig {
    var result: RawConfig = .{};
    errdefer result.deinit(allocator);

    var line_it = std.mem.splitScalar(u8, content, '\n');
    var line_index: u32 = 0;
    var in_llm = false;
    while (line_it.next()) |raw_line| {
        line_index += 1;
        const line = std.mem.trim(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        if (line[0] == '[') {
            if (std.mem.eql(u8, line, "[llm]")) {
                in_llm = true;
                continue;
            }
            if (line[line.len - 1] != ']') return error.InvalidConfig;
            in_llm = false;
            continue;
        }

        if (!in_llm) continue;
        try parseTomlLine(allocator, &result, line, line_index);
    }
    return result;
}

fn parseTomlLine(
    allocator: std.mem.Allocator,
    result: *RawConfig,
    line: []const u8,
    line_index: u32,
) !void {
    _ = line_index;
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfig;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (key.len == 0) return error.InvalidConfig;

    if (std.mem.eql(u8, key, "verbose")) {
        result.verbose = try parseTomlBool(value);
        return;
    }

    const parsed = try parseTomlString(allocator, value);
    errdefer allocator.free(parsed);

    if (std.mem.eql(u8, key, "default_model")) {
        result.default_model = parsed;
        return;
    }
    if (std.mem.eql(u8, key, "anthropic_api_key")) {
        result.anthropic_api_key = parsed;
        return;
    }
    if (std.mem.eql(u8, key, "anthropic_base_url")) {
        result.anthropic_base_url = parsed;
        return;
    }
    if (std.mem.eql(u8, key, "openai_api_key")) {
        result.openai_api_key = parsed;
        return;
    }
    if (std.mem.eql(u8, key, "sessions_dir")) {
        result.sessions_dir = parsed;
        return;
    }

    allocator.free(parsed);
}

fn parseTomlString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (value.len < 2) return error.InvalidConfig;
    if (value[0] != '"') return error.InvalidConfig;
    if (value[value.len - 1] != '"') return error.InvalidConfig;
    return allocator.dupe(u8, value[1 .. value.len - 1]);
}

fn parseTomlBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidConfig;
}

fn loadEnvOverrides(allocator: std.mem.Allocator) !EnvOverrides {
    return .{
        .orbit_model = getEnvOwned(allocator, "ORBIT_MODEL"),
        .anthropic_api_key = getEnvOwned(allocator, "ANTHROPIC_API_KEY"),
        .anthropic_base_url = getEnvOwned(allocator, "ANTHROPIC_BASE_URL"),
        .openai_api_key = getEnvOwned(allocator, "OPENAI_API_KEY"),
        .orbit_sessions_dir = getEnvOwned(allocator, "ORBIT_SESSIONS_DIR"),
        .orbit_verbose = try parseOptionalBoolEnv(allocator, "ORBIT_VERBOSE"),
    };
}

fn getEnvOwned(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, name) catch null;
}

fn parseOptionalBoolEnv(allocator: std.mem.Allocator, name: []const u8) !?bool {
    const raw = std.process.getEnvVarOwned(allocator, name) catch return null;
    defer allocator.free(raw);

    if (std.mem.eql(u8, raw, "1")) return true;
    if (std.mem.eql(u8, raw, "0")) return false;
    if (std.ascii.eqlIgnoreCase(raw, "true")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "false")) return false;
    return error.InvalidConfig;
}

fn dupOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |slice| try allocator.dupe(u8, slice) else null;
}

fn getHomeDir(allocator: std.mem.Allocator) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, "HOME");
}

fn pathExists(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

fn expandHomeDir(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    path: []const u8,
) ![]const u8 {
    if (path.len == 0) return allocator.dupe(u8, path);
    if (!std.mem.startsWith(u8, path, "~")) return allocator.dupe(u8, path);
    if (path.len == 1) return allocator.dupe(u8, home_dir);
    if (path[1] != '/') return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ home_dir, path[2..] });
}

test "config missing file returns defaults" {
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    const home = try temp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(home);

    const config_path = try std.fs.path.join(allocator, &.{ home, ".orbit", "config.toml" });
    defer allocator.free(config_path);

    const config = try loadWithOverrides(allocator, home, config_path, .{});
    defer {
        var mutable = config;
        mutable.deinit(allocator);
    }

    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", config.default_model);
    const expected = try std.fs.path.join(allocator, &.{ home, ".orbit", "sessions" });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, config.sessions_dir);
}

test "config accepts empty json object" {
    const allocator = std.testing.allocator;
    var raw = try parseConfigContent(allocator, "{}");
    defer raw.deinit(allocator);

    try std.testing.expect(raw.default_model == null);
    try std.testing.expect(raw.anthropic_base_url == null);
    try std.testing.expect(raw.sessions_dir == null);
}

test "config rejects invalid json" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedEndOfInput, parseConfigContent(allocator, "{"));
}

test "env overrides config values" {
    const allocator = std.testing.allocator;
    var raw = try parseConfigContent(allocator,
        \\{
        \\  "llm": {
        \\    "default_model": "gpt-4o",
        \\    "anthropic_base_url": "https://config.example/api/anthropic",
        \\    "sessions_dir": "~/sessions-a",
        \\    "verbose": false
        \\  }
        \\}
    );
    defer raw.deinit(allocator);

    var env: EnvOverrides = .{
        .orbit_model = try allocator.dupe(u8, "claude-sonnet-4-20250514"),
        .anthropic_base_url = try allocator.dupe(u8, "https://env.example"),
        .orbit_sessions_dir = try allocator.dupe(u8, "~/sessions-b"),
        .orbit_verbose = true,
    };
    defer env.deinit(allocator);

    const config = try buildConfig(allocator, "/tmp/home", raw, env);
    defer {
        var mutable = config;
        mutable.deinit(allocator);
    }

    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", config.default_model);
    try std.testing.expectEqualStrings("https://env.example", config.anthropic_base_url.?);
    try std.testing.expectEqualStrings("/tmp/home/sessions-b", config.sessions_dir);
    try std.testing.expect(config.verbose);
}

test "config expands tilde in sessions dir" {
    const allocator = std.testing.allocator;
    const expanded = try expandHomeDir(allocator, "/tmp/orbit-home", "~/.orbit/sessions");
    defer allocator.free(expanded);

    try std.testing.expectEqualStrings("/tmp/orbit-home/.orbit/sessions", expanded);
}

test "config parses toml subset" {
    const allocator = std.testing.allocator;
    var raw = try parseConfigContent(allocator,
        \\[llm]
        \\default_model = "gpt-4o"
        \\anthropic_base_url = "https://open.bigmodel.cn"
        \\sessions_dir = "~/.orbit/custom"
        \\verbose = true
    );
    defer raw.deinit(allocator);

    try std.testing.expectEqualStrings("gpt-4o", raw.default_model.?);
    try std.testing.expectEqualStrings("https://open.bigmodel.cn", raw.anthropic_base_url.?);
    try std.testing.expectEqualStrings("~/.orbit/custom", raw.sessions_dir.?);
    try std.testing.expect(raw.verbose.?);
}
