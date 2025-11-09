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

const RandomBot = struct {
    rng: std.Random.DefaultPrng,
    hands_played: u32 = 0,

    pub fn init(seed: u64) RandomBot {
        return .{
            .rng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub const callbacks = pfb.BotCallbacks(*RandomBot){
        .onHandStart = onHandStart,
        .onActionRequired = onActionRequired,
        .onHandComplete = onHandComplete,
    };

    fn onHandStart(self: *RandomBot, state: *const pfb.GameState) !void {
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
        self: *RandomBot,
        state: *const pfb.GameState,
        request: protocol.ActionRequest,
    ) !protocol.OutgoingAction {
        const random = self.rng.random();
        std.debug.print("  Action request - Pot: {}, To call: {}\n", .{
            state.pot,
            state.to_call,
        });

        // Choose random action from legal actions
        const action_idx = random.intRangeAtMost(usize, 0, request.legal_actions.len - 1);
        const chosen = request.legal_actions[action_idx];

        const action = protocol.OutgoingAction{
            .action_type = chosen.action_type,
            .amount = if (chosen.min_amount) |min| min else null,
        };

        std.debug.print("  Choosing: {s}", .{@tagName(action.action_type)});
        if (action.amount) |amt| {
            std.debug.print(" ({})\n", .{amt});
        } else {
            std.debug.print("\n", .{});
        }

        return action;
    }

    fn onHandComplete(self: *RandomBot, state: *const pfb.GameState, result: protocol.HandResult) !void {
        _ = self;
        _ = state;
        _ = result;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try Args.parse(allocator);

    std.debug.print("Random Bot starting...\n", .{});
    std.debug.print("  Endpoint: {s}\n", .{args.endpoint});
    std.debug.print("  Bot Name: {s}\n", .{args.bot_name});
    std.debug.print("  Game: {s}\n", .{args.game orelse "default"});

    const config = client.Config{
        .endpoint = args.endpoint,
        .api_key = args.api_key,
        .bot_name = args.bot_name,
        .game = args.game,
        .timeout_ms = 5000,
    };

    var bot = RandomBot.init(@bitCast(std.time.timestamp()));
    try pfb.run(allocator, config, &bot, RandomBot.callbacks, .{});

    std.debug.print("\nBot finished. Total hands played: {}\n", .{bot.hands_played});
}
