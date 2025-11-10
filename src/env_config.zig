const std = @import("std");
const client = @import("client.zig");

pub const LoadError = error{
    MissingEndpoint,
    MissingApiKey,
    MissingBotName,
};

pub const Overrides = struct {
    endpoint: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    bot_name: ?[]const u8 = null,
    game: ?[]const u8 = null,
    timeout_ms: ?u32 = null,
};

pub const LoadedConfig = struct {
    config: client.Config,
    seed: ?u64 = null,
    owned_endpoint: ?[]u8 = null,
    owned_api_key: ?[]u8 = null,
    owned_bot_name: ?[]u8 = null,
    owned_game: ?[]u8 = null,

    pub fn deinit(self: *LoadedConfig, allocator: std.mem.Allocator) void {
        if (self.owned_endpoint) |value| allocator.free(value);
        if (self.owned_api_key) |value| allocator.free(value);
        if (self.owned_bot_name) |value| allocator.free(value);
        if (self.owned_game) |value| allocator.free(value);
    }
};

pub fn loadConfigFromEnv(
    allocator: std.mem.Allocator,
    env: anytype,
    overrides: Overrides,
) !LoadedConfig {
    var result = LoadedConfig{
        .config = .{
            .endpoint = undefined,
            .api_key = undefined,
            .bot_name = undefined,
            .game = null,
            .timeout_ms = overrides.timeout_ms orelse 5000,
        },
        .seed = null,
    };
    errdefer result.deinit(allocator);

    result.config.endpoint = try resolveValue(
        allocator,
        overrides.endpoint,
        env,
        "POKERFORBOTS_SERVER",
        null,
        &result.owned_endpoint,
    ) orelse return LoadError.MissingEndpoint;

    result.config.api_key = try resolveValue(
        allocator,
        overrides.api_key,
        env,
        "POKERFORBOTS_AUTH_TOKEN",
        "POKERFORBOTS_API_KEY",
        &result.owned_api_key,
    ) orelse return LoadError.MissingApiKey;

    result.config.bot_name = try resolveValue(
        allocator,
        overrides.bot_name,
        env,
        "POKERFORBOTS_BOT_NAME",
        "POKERFORBOTS_BOT_ID",
        &result.owned_bot_name,
    ) orelse return LoadError.MissingBotName;

    if (try resolveValue(allocator, overrides.game, env, "POKERFORBOTS_GAME", null, &result.owned_game)) |game_value| {
        result.config.game = game_value;
    }

    if (overrides.timeout_ms == null) {
        if (parseUnsigned(u32, env, "POKERFORBOTS_TIMEOUT_MS")) |timeout_value| {
            result.config.timeout_ms = timeout_value;
        }
    }

    if (parseUnsigned(u64, env, "POKERFORBOTS_SEED")) |seed_value| {
        result.seed = seed_value;
    }

    return result;
}

fn resolveValue(
    allocator: std.mem.Allocator,
    override_value: ?[]const u8,
    env: anytype,
    primary_key: []const u8,
    secondary_key: ?[]const u8,
    owned_storage: *?[]u8,
) !?[]const u8 {
    if (override_value) |value| return value;

    const env_value = env.get(primary_key) orelse blk: {
        if (secondary_key) |key| break :blk env.get(key) orelse null;
        break :blk null;
    };

    if (env_value) |value| {
        const copy = try allocator.dupe(u8, value);
        owned_storage.* = copy;
        return copy;
    }

    owned_storage.* = null;
    return null;
}

fn parseUnsigned(comptime T: type, env: anytype, key: []const u8) ?T {
    if (env.get(key)) |value| {
        return std.fmt.parseUnsigned(T, std.mem.trim(u8, value, " \t\r\n"), 10) catch null;
    }
    return null;
}

test "loadConfigFromEnv uses env when overrides missing" {
    const allocator = std.testing.allocator;
    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();
    try env.put("POKERFORBOTS_SERVER", "ws://127.0.0.1:1234/ws");
    try env.put("POKERFORBOTS_AUTH_TOKEN", "dev-token");
    try env.put("POKERFORBOTS_BOT_NAME", "aragorn-env");
    try env.put("POKERFORBOTS_GAME", "default");
    try env.put("POKERFORBOTS_TIMEOUT_MS", "250");
    try env.put("POKERFORBOTS_SEED", "999");

    var loaded = try loadConfigFromEnv(allocator, &env, .{});
    defer loaded.deinit(allocator);

    try std.testing.expectEqualStrings("ws://127.0.0.1:1234/ws", loaded.config.endpoint);
    try std.testing.expectEqualStrings("dev-token", loaded.config.api_key);
    try std.testing.expectEqualStrings("aragorn-env", loaded.config.bot_name);
    try std.testing.expect(loaded.config.game != null);
    try std.testing.expectEqualStrings("default", loaded.config.game.?);
    try std.testing.expectEqual(@as(u32, 250), loaded.config.timeout_ms);
    try std.testing.expectEqual(@as(u64, 999), loaded.seed.?);
}

test "loadConfigFromEnv honors overrides over env" {
    const allocator = std.testing.allocator;
    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();
    try env.put("POKERFORBOTS_SERVER", "ws://env/ws");
    try env.put("POKERFORBOTS_AUTH_TOKEN", "env-token");
    try env.put("POKERFORBOTS_BOT_NAME", "env-bot");

    var loaded = try loadConfigFromEnv(allocator, &env, .{
        .endpoint = "ws://override/ws",
        .api_key = "override-key",
        .bot_name = "override-bot",
        .timeout_ms = 1500,
    });
    defer loaded.deinit(allocator);

    try std.testing.expectEqualStrings("ws://override/ws", loaded.config.endpoint);
    try std.testing.expectEqualStrings("override-key", loaded.config.api_key);
    try std.testing.expectEqualStrings("override-bot", loaded.config.bot_name);
    try std.testing.expectEqual(@as(u32, 1500), loaded.config.timeout_ms);
    try std.testing.expect(loaded.seed == null);
}

test "loadConfigFromEnv uses default timeout when unset" {
    const allocator = std.testing.allocator;
    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();
    try env.put("POKERFORBOTS_SERVER", "ws://env/ws");
    try env.put("POKERFORBOTS_AUTH_TOKEN", "env-token");
    try env.put("POKERFORBOTS_BOT_NAME", "env-bot");

    var loaded = try loadConfigFromEnv(allocator, &env, .{});
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 5000), loaded.config.timeout_ms);
}
