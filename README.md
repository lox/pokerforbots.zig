# PokerForBots Zig SDK

Zig bindings for the [PokerForBots](https://github.com/lox/pokerforbots) poker bot server. Build high-performance poker bots with type-safe message handling and automatic game state tracking.

## Features

- **Callback-based API**: Focus on strategy, not protocol handling
- **Automatic state tracking**: Built-in GameState manages pot, players, and history
- **Type-safe messages**: Union-based message handling with compile-time guarantees
- **MessagePack encoding**: Efficient binary protocol serialization
- **WebSocket client**: Built-in connection management with TLS support
- **Zero-copy parsing**: Efficient message decoding with minimal allocations
- **Example bots**: Random and calling station implementations included

## Installation

Requires Zig 0.15.1 or later.

```bash
zig fetch --save "git+https://github.com/lox/pokerforbots.zig?ref=v1.2.0"
```

In your `build.zig`:

```zig
const pokerforbots = b.dependency("pokerforbots", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("pokerforbots", pokerforbots.module("pokerforbots"));
```

## Quick Start

```zig
const std = @import("std");
const pfb = @import("pokerforbots");

const MyBot = struct {
    hands_played: u32 = 0,

    pub const callbacks = pfb.BotCallbacks(*MyBot){
        .onHandStart = onHandStart,
        .onActionRequired = onActionRequired,
        .onHandComplete = onHandComplete,
    };

    fn onHandStart(self: *MyBot, state: *const pfb.GameState) !void {
        self.hands_played += 1;
        std.debug.print("Hand {}: {} players active\n", .{
            self.hands_played,
            state.playerCount(),
        });
    }

    fn onActionRequired(
        self: *MyBot,
        state: *const pfb.GameState,
        request: pfb.ActionRequest,
    ) !pfb.OutgoingAction {
        _ = self;

        // Make decision based on game state
        if (state.raiseDepth() > 2) {
            return .{ .action_type = .fold };
        }

        // Call if possible, otherwise fold
        for (request.legal_actions) |action| {
            if (action.action_type == .call) {
                return .{
                    .action_type = .call,
                    .amount = action.min_amount,
                };
            }
        }

        return .{ .action_type = .fold };
    }

    fn onHandComplete(
        self: *MyBot,
        state: *const pfb.GameState,
        result: pfb.HandResult,
    ) !void {
        _ = self;
        _ = state;
        _ = result;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = pfb.Config{
        .endpoint = "ws://localhost:8080/ws",
        .api_key = "your-api-key",
        .bot_name = "my-bot",
    };

    var bot = MyBot{};
    try pfb.run(allocator, config, &bot, MyBot.callbacks, .{});
}
```

## Environment Configuration Helper

When you launch bots via `pokerforbots spawn --bot-cmd`, the spawner sets standard environment variables (endpoint, auth token, bot name, etc.). Use `pfb.env_config.loadConfigFromEnv` to hydrate a `pfb.Config` (and optional deterministic seed) directly from that contract while still allowing CLI overrides:

```zig
const pfb = @import("pokerforbots");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();

    var bundle = try pfb.env_config.loadConfigFromEnv(allocator, &env_map, .{
        .endpoint = null, // pass CLI override here if supplied
    });
    defer bundle.deinit(allocator);

    var bot = MyBot{};
    try pfb.run(allocator, bundle.config, &bot, MyBot.callbacks, .{});
}
```

Supported variables (first match wins):

| Purpose | Primary Var | Secondary Var |
| --- | --- | --- |
| WebSocket endpoint | `POKERFORBOTS_SERVER` | — |
| API key / auth token | `POKERFORBOTS_AUTH_TOKEN` | `POKERFORBOTS_API_KEY` |
| Bot name | `POKERFORBOTS_BOT_NAME` | `POKERFORBOTS_BOT_ID` |
| Game identifier | `POKERFORBOTS_GAME` | — |
| Timeout (ms) | `POKERFORBOTS_TIMEOUT_MS` | — |
| Seed (u64) | `POKERFORBOTS_SEED` | — |

The helper returns a `LoadedConfig` struct that owns any duplicated strings; call `deinit()` when finished to free them.

## Game State

The `GameState` struct automatically tracks game information and provides useful queries:

```zig
fn onActionRequired(
    self: *MyBot,
    state: *const pfb.GameState,
    request: pfb.ActionRequest,
) !pfb.OutgoingAction {
    // Current game info
    const pot = state.pot;
    const to_call = state.to_call;
    const street = state.street; // .preflop, .flop, .turn, .river

    // Player queries
    const active = state.playerCount(); // Players still in hand
    const hero_chips = state.heroStack() orelse 0;

    // Action tracking
    const raises = state.raiseDepth(); // Number of raises this street
    const aggressor = state.lastAggressor(); // Most recent bettor/raiser

    // Position
    const position = state.seatToButton(state.hero_seat);

    // Make decision...
}
```

## Examples

### Random Bot

Chooses random valid actions:

```zig
const RandomBot = struct {
    rng: std.Random.DefaultPrng,
    hands_played: u32 = 0,

    pub fn init(seed: u64) RandomBot {
        return .{ .rng = std.Random.DefaultPrng.init(seed) };
    }

    pub const callbacks = pfb.BotCallbacks(*RandomBot){
        .onHandStart = onHandStart,
        .onActionRequired = onActionRequired,
        .onHandComplete = onHandComplete,
    };

    fn onHandStart(self: *RandomBot, state: *const pfb.GameState) !void {
        self.hands_played += 1;
        std.debug.print("Hand {}: Hole cards {any}\n", .{
            self.hands_played,
            state.hole_cards,
        });
    }

    fn onActionRequired(
        self: *RandomBot,
        state: *const pfb.GameState,
        request: pfb.ActionRequest,
    ) !pfb.OutgoingAction {
        _ = state;
        const random = self.rng.random();

        // Pick random legal action
        const idx = random.intRangeAtMost(usize, 0, request.legal_actions.len - 1);
        const chosen = request.legal_actions[idx];

        return pfb.OutgoingAction{
            .action_type = chosen.action_type,
            .amount = chosen.min_amount,
        };
    }

    fn onHandComplete(
        self: *RandomBot,
        state: *const pfb.GameState,
        result: pfb.HandResult,
    ) !void {
        _ = self;
        _ = state;
        _ = result;
    }
};
```

Run it:

```bash
task random SERVER_URL=ws://localhost:8080/ws BOT_NAME=random-bot
```

### Calling Station Bot

Always calls/checks when possible:

```zig
const CallingStation = struct {
    hands_played: u32 = 0,

    pub const callbacks = pfb.BotCallbacks(*CallingStation){
        .onHandStart = onHandStart,
        .onActionRequired = onActionRequired,
        .onHandComplete = onHandComplete,
    };

    fn onActionRequired(
        self: *CallingStation,
        state: *const pfb.GameState,
        request: pfb.ActionRequest,
    ) !pfb.OutgoingAction {
        _ = self;
        _ = state;

        // Find call action
        for (request.legal_actions) |action| {
            if (action.action_type == .call) {
                return pfb.OutgoingAction{
                    .action_type = .call,
                    .amount = action.min_amount,
                };
            }
        }

        // No call available, must fold
        return .{ .action_type = .fold };
    }

    // ... other callbacks
};
```

Run it:

```bash
task calling SERVER_URL=ws://localhost:8080/ws BOT_NAME=calling-bot
```

### Position-Aware Strategy

Use GameState to make position-based decisions:

```zig
fn onActionRequired(
    self: *MyBot,
    state: *const pfb.GameState,
    request: pfb.ActionRequest,
) !pfb.OutgoingAction {
    const position = state.seatToButton(state.hero_seat);
    const active = state.playerCount();
    const raises = state.raiseDepth();

    // Late position (button or cutoff)
    const is_late_position = position >= active - 2;

    // Be aggressive in late position with no raises
    if (is_late_position and raises == 0) {
        for (request.legal_actions) |action| {
            if (action.action_type == .raise) {
                return pfb.OutgoingAction{
                    .action_type = .raise,
                    .amount = action.min_amount,
                };
            }
        }
    }

    // Early position: play tighter when facing aggression
    if (position < 2 and raises > 1) {
        return .{ .action_type = .fold };
    }

    // Default to calling
    for (request.legal_actions) |action| {
        if (action.action_type == .call) {
            return pfb.OutgoingAction{
                .action_type = .call,
                .amount = action.min_amount,
            };
        }
    }

    return .{ .action_type = .fold };
}
```

### Action History

Track opponent actions using GameState history:

```zig
fn onActionRequired(
    self: *MyBot,
    state: *const pfb.GameState,
    request: pfb.ActionRequest,
) !pfb.OutgoingAction {
    // Count preflop raises
    var preflop_raises: u32 = 0;
    for (state.history.items) |action| {
        if (action.street == .preflop and
            (action.action_type == .raise or action.action_type == .bet)) {
            preflop_raises += 1;
        }
    }

    // Check if last aggressor is still active
    if (state.lastAggressor()) |aggressor| {
        std.debug.print("Facing aggression from {s}\n", .{aggressor.name});
    }

    // Make decision based on history...
}
```

## Advanced Usage

### Run Options

Customize bot execution:

```zig
try pfb.run(allocator, config, &bot, MyBot.callbacks, .{
    .max_hands = 100,  // Stop after 100 hands
    .logger = logger,  // Optional MessageLogger for debugging
});
```

### Message Logging

Debug protocol messages:

```zig
const log_file = try std.fs.cwd().createFile("messages.jsonl", .{});
defer log_file.close();

const logger = pfb.MessageLogger{
    .enabled = true,
    .file = &log_file,
    .allocator = allocator,
};

try pfb.run(allocator, config, &bot, MyBot.callbacks, .{
    .logger = logger,
});
```

### Low-Level API

For advanced use cases, you can use the low-level connection API directly:

```zig
var connector = pfb.Connector.init(allocator, config);
var conn = try connector.connect();
defer conn.deinit();

while (try conn.readMessage()) |msg| {
    defer pfb.freeMessage(allocator, msg);

    switch (msg) {
        .action_request => |req| {
            const action = pfb.OutgoingAction{
                .action_type = .call,
                .amount = null,
            };
            try conn.sendAction(action);
        },
        .game_completed => break,
        else => {},
    }
}
```

## Protocol

### Action Types

- **fold**: Give up the hand
- **call**: Match current bet (or check if to_call = 0)
- **raise**: Increase the bet (amount is total bet size, not increment)
- **allin**: Bet entire stack

### Message Types

```zig
pub const IncomingMessage = union(enum) {
    hand_start: HandStart,        // Hand begins
    action_request: ActionRequest, // Decision point
    game_update: GameUpdate,       // Table snapshot
    player_action: PlayerAction,   // Every wager/post
    street_change: StreetChange,   // Board update
    hand_result: HandResult,       // Winners + showdown
    game_completed: GameCompleted, // Simulation end
    error_message: ErrorMessage,   // Protocol error
    noop,
};
```

## Building

```bash
# Build all targets
zig build

# Run tests
task test

# Build with optimizations
zig build -Doptimize=ReleaseFast

# Using Task
task build
task test
task clean
```

## Testing

Run smoke tests against a local PokerForBots server:

```bash
# Test random bot (default)
task test:pfbspawn

# Test calling station bot
task test:pfbspawn BOT=calling-station

# Customize parameters
task test:pfbspawn HANDS=500 SEED=123

# Use different server
task test:pfbspawn ADDR=localhost:9000 PFB_BIN=/path/to/pokerforbots
```

The smoke test spawns bots and plays the specified number of hands, saving statistics to `tmp/pfb_smoke_*.json`.

## Development

```bash
# Format code
zig fmt src examples

# Check formatting
task lint

# Clean build artifacts
task clean
```

## Releasing

1. Install [`svu`](https://github.com/caarlos0/svu) (via Hermit or your package manager) and ensure you're on a clean `main` branch.
2. Run `task release` to execute `scripts/release.sh`. The script runs the full test suite before and after the bump, updates `README.md` and `build.zig.zon` with the new version, commits the change (`chore: release vX.Y.Z`), and pushes to `origin`.
3. GitHub's Auto Release workflow listens for pushes to `main` and tags/releases the commit using the version declared in `build.zig.zon`.
4. If automation fails, trigger the "Manual Release" GitHub workflow after ensuring `build.zig.zon` already carries the desired version.

## Performance

Zig's zero-cost abstractions and manual memory management make it ideal for poker bots:

- **Small binaries**: ~4MB executables (vs ~10MB for Go)
- **Fast startup**: No GC initialization overhead
- **Predictable latency**: No GC pauses during critical decisions
- **Native performance**: Compiles to optimized machine code

Perfect for high-frequency decision-making in poker tournaments.

## Related Projects

- [PokerForBots Server](https://github.com/lox/pokerforbots) - The poker server
- [Go SDK](https://github.com/lox/pokerforbots/tree/main/sdk) - Official Go SDK
- [Protocol Spec](https://github.com/lox/pokerforbots/blob/main/docs/websocket-protocol.md) - WebSocket protocol documentation

## License

MIT
