const std = @import("std");
const pfb = @import("pokerforbots");

const protocol = pfb.protocol;
const client = pfb.client;

const Args = struct {
    endpoint: []const u8,
    bot_name: []const u8,
    api_key: []const u8 = "dev",
    game: ?[]const u8 = null,

    pub fn parse(allocator: std.mem.Allocator) !Args {
        var args = Args{
            .endpoint = undefined,
            .bot_name = undefined,
        };

        var iter = try std.process.argsWithAllocator(allocator);
        defer iter.deinit();

        _ = iter.next(); // skip program name

        while (iter.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--endpoint=")) {
                args.endpoint = arg["--endpoint=".len..];
            } else if (std.mem.startsWith(u8, arg, "--bot-name=")) {
                args.bot_name = arg["--bot-name=".len..];
            } else if (std.mem.startsWith(u8, arg, "--api-key=")) {
                args.api_key = arg["--api-key=".len..];
            } else if (std.mem.startsWith(u8, arg, "--game=")) {
                args.game = arg["--game=".len..];
            }
        }

        return args;
    }
};

fn findAction(actions: []const protocol.ActionDescriptor, action_type: protocol.ActionType) ?protocol.ActionDescriptor {
    for (actions) |action| {
        if (action.action_type == action_type) return action;
    }
    return null;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try Args.parse(allocator);

    std.debug.print("Calling Station Bot starting...\n", .{});
    std.debug.print("  Endpoint: {s}\n", .{args.endpoint});
    std.debug.print("  Bot Name: {s}\n", .{args.bot_name});
    std.debug.print("  Game: {s}\n", .{args.game orelse "default"});
    std.debug.print("  Strategy: Always call when possible\n", .{});

    const config = client.Config{
        .endpoint = args.endpoint,
        .api_key = args.api_key,
        .bot_name = args.bot_name,
        .game = args.game,
        .timeout_ms = 5000,
    };

    var connector = client.Connector.init(allocator, config);
    var conn = try connector.connect();
    defer conn.deinit();

    std.debug.print("Connected successfully!\n", .{});

    var hands_played: u32 = 0;

    while (try conn.readMessage()) |msg| {
        switch (msg) {
            .hand_start => |start| {
                hands_played += 1;
                const hero_stack = findSeat(start.players, start.your_seat) orelse 0;
                std.debug.print("\n[Hand {}] Starting - Seat: {}, Button: {}, Chips: {}\n", .{
                    hands_played,
                    start.your_seat,
                    start.button,
                    hero_stack,
                });
                std.debug.print("  Hole cards: {any}\n", .{start.hole_cards});

                pfb.freeMessage(allocator, msg);
            },

            .action_request => |req| {
                std.debug.print("  Action request - Pot: {}, To call: {}\n", .{
                    req.pot,
                    req.to_call,
                });

                // Calling station strategy: always call/check if possible, otherwise fold
                const action = if (findAction(req.legal_actions, .call)) |call_action|
                    protocol.OutgoingAction{
                        .action_type = .call,
                        .amount = call_action.min_amount,
                    }
                else
                    protocol.OutgoingAction{
                        .action_type = .fold,
                        .amount = null,
                    };

                std.debug.print("  Choosing: {s}", .{@tagName(action.action_type)});
                if (action.amount) |amt| {
                    std.debug.print(" ({})\n", .{amt});
                } else {
                    std.debug.print("\n", .{});
                }

                try conn.sendAction(action);

                pfb.freeMessage(allocator, msg);
            },

            .game_update => |update| {
                std.debug.print("  Game update - Pot: {}, Players: {}\n", .{
                    update.pot,
                    update.players.len,
                });

                pfb.freeMessage(allocator, msg);
            },

            .player_action => |_| {
                pfb.freeMessage(allocator, msg);
            },

            .street_change => |_| {
                pfb.freeMessage(allocator, msg);
            },

            .hand_result => |_| {
                pfb.freeMessage(allocator, msg);
            },

            .error_message => |err| {
                std.debug.print("Protocol error: {s} - {s}\n", .{ err.code, err.message });
                pfb.freeMessage(allocator, msg);
            },

            .game_completed => |completed| {
                std.debug.print("\n=== Game Completed ===\n", .{});
                std.debug.print("Hands played: {}\n", .{completed.hands_completed});
                std.debug.print("Hand limit: {}\n", .{completed.hand_limit});
                std.debug.print("Reason: {s}\n", .{completed.reason});

                pfb.freeMessage(allocator, msg);
                break;
            },

            .noop => {},
        }
    }

    std.debug.print("\nBot finished. Total hands played: {}\n", .{hands_played});
}

fn findSeat(players: []const pfb.protocol.SeatInfo, seat: u8) ?u32 {
    for (players) |player| {
        if (player.seat == seat) return player.chips;
    }
    return null;
}
