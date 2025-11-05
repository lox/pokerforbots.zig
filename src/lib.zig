const std = @import("std");

// Public API
pub const protocol = @import("protocol.zig");
pub const client = @import("client.zig");

// Re-export commonly used types
pub const Config = client.Config;
pub const Connector = client.Connector;
pub const Connection = client.Connection;
pub const ActionType = protocol.ActionType;
pub const ActionRequest = protocol.ActionRequest;
pub const GameStart = protocol.GameStart;
pub const GameUpdate = protocol.GameUpdate;
pub const GameCompleted = protocol.GameCompleted;
pub const IncomingMessage = protocol.IncomingMessage;
pub const OutgoingAction = protocol.OutgoingAction;

// Re-export memory management helper
pub const freeMessage = protocol.freeMessage;

test {
    std.testing.refAllDecls(@This());
}
