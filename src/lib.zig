const std = @import("std");

// Public API
pub const protocol = @import("protocol.zig");
pub const client = @import("client.zig");
pub const game_state = @import("game_state.zig");
pub const bot_runner = @import("bot_runner.zig");

// Re-export commonly used types
pub const Config = client.Config;
pub const Connector = client.Connector;
pub const Connection = client.Connection;
pub const MessageLogger = client.MessageLogger;
pub const ActionType = protocol.ActionType;
pub const ActionDescriptor = protocol.ActionDescriptor;
pub const ActionRequest = protocol.ActionRequest;
pub const HandStart = protocol.HandStart;
pub const GameUpdate = protocol.GameUpdate;
pub const PlayerAction = protocol.PlayerAction;
pub const StreetChange = protocol.StreetChange;
pub const HandResult = protocol.HandResult;
pub const GameCompleted = protocol.GameCompleted;
pub const ErrorMessage = protocol.ErrorMessage;
pub const PlayerDetailedStats = protocol.PlayerDetailedStats;
pub const PositionStatSummary = protocol.PositionStatSummary;
pub const StreetStatSummary = protocol.StreetStatSummary;
pub const CategoryStatSummary = protocol.CategoryStatSummary;
pub const IncomingMessage = protocol.IncomingMessage;
pub const OutgoingAction = protocol.OutgoingAction;
pub const GameState = game_state.GameState;
pub const HistoricalAction = game_state.HistoricalAction;
pub const PlayerInfo = game_state.PlayerInfo;
pub const Street = game_state.Street;
pub const BotRunOptions = bot_runner.RunOptions;
pub const BotCallbacks = bot_runner.BotCallbacks;
pub const run = bot_runner.run;

// Re-export memory management helper
pub const freeMessage = protocol.freeMessage;

test {
    std.testing.refAllDecls(@This());
}
