const std = @import("std");
const protocol = @import("protocol.zig");
const client = @import("client.zig");
const game_state = @import("game_state.zig");

pub const RunOptions = struct {
    max_hands: ?usize = null,
    logger: ?client.MessageLogger = null,
};

pub const ControlError = error{StopSession};

pub fn BotCallbacks(comptime Context: type) type {
    return struct {
        onHandStart: *const fn (Context, *game_state.GameState) anyerror!void,
        onActionRequired: *const fn (Context, *game_state.GameState, protocol.ActionRequest) anyerror!protocol.OutgoingAction,
        onHandComplete: *const fn (Context, *game_state.GameState, protocol.HandResult) anyerror!void,
    };
}

pub fn run(
    allocator: std.mem.Allocator,
    config: client.Config,
    context: anytype,
    comptime callbacks: BotCallbacks(@TypeOf(context)),
    options: RunOptions,
) !void {
    var connector = client.Connector.init(allocator, config);
    var connection = try connector.connect();
    defer connection.deinit();

    if (options.logger) |logger| {
        connection.setLogger(logger);
    }

    var state = game_state.GameState.init(allocator);
    defer state.deinit();

    var hands_played: usize = 0;

    while (true) {
        const message_opt = try connection.readMessage();
        if (message_opt == null) break;
        const message = message_opt.?;
        defer protocol.freeMessage(allocator, message);

        switch (message) {
            .hand_start => |start| {
                try state.onHandStart(start);
                callbacks.onHandStart(context, &state) catch |err| switch (err) {
                    ControlError.StopSession => return,
                    else => return err,
                };
            },
            .player_action => |action| {
                state.onPlayerAction(action) catch |err| switch (err) {
                    else => return err,
                };
            },
            .street_change => |change| {
                try state.onStreetChange(change);
            },
            .action_request => |request| {
                state.onActionRequest(request);
                const decision = callbacks.onActionRequired(context, &state, request) catch |err| switch (err) {
                    ControlError.StopSession => return,
                    else => return err,
                };
                try connection.sendAction(decision);
                try state.recordHeroAction(decision, request);
            },
            .hand_result => |result| {
                try state.onHandResult(result);
                callbacks.onHandComplete(context, &state, result) catch |err| switch (err) {
                    ControlError.StopSession => return,
                    else => return err,
                };
                hands_played += 1;
                if (options.max_hands) |limit| {
                    if (hands_played >= limit) {
                        return;
                    }
                }
                state.reset();
            },
            .game_completed => break,
            .game_update, .noop => {},
            .error_message => return error.ServerError,
        }
    }
}
