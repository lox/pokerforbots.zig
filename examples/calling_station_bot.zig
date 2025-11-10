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
            .endpoint = "",
            .bot_name = "",
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

        if (args.endpoint.len == 0) return error.MissingEndpointArg;
        if (args.bot_name.len == 0) return error.MissingBotNameArg;
        return args;
    }
};

const CallingStation = struct {
    hands_played: u32 = 0,

    pub const callbacks = pfb.BotCallbacks(*CallingStation){
        .onHandStart = onHandStart,
        .onActionRequired = onActionRequired,
        .onHandComplete = onHandComplete,
    };

    fn onHandStart(self: *CallingStation, state: *const pfb.GameState) !void {
        self.hands_played += 1;
        const hero_stack = state.heroStack() orelse 0;
        std.debug.print("\n[Hand {}] Starting - Seat: {}, Button: {}, Chips: {}\n", .{
            self.hands_played,
            state.hero_seat,
            state.button,
            hero_stack,
        });
        std.debug.print("  Hole cards: {any}\n", .{state.hole_cards});
    }

    fn onActionRequired(
        self: *CallingStation,
        state: *const pfb.GameState,
        request: protocol.ActionRequest,
    ) !protocol.OutgoingAction {
        _ = self;
        std.debug.print("  Action request - Pot: {}, To call: {}\n", .{
            state.pot,
            state.to_call,
        });

        // Calling station strategy: always call/check if possible, otherwise fold
        const action = if (findAction(request.legal_actions, .call)) |call_action|
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

        return action;
    }

    fn onHandComplete(self: *CallingStation, state: *const pfb.GameState, result: protocol.HandResult) !void {
        _ = self;
        _ = state;
        _ = result;
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

    var bot = CallingStation{};
    try pfb.run(allocator, config, &bot, CallingStation.callbacks, .{});

    std.debug.print("\nBot finished. Total hands played: {}\n", .{bot.hands_played});
}
