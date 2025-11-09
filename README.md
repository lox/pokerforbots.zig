# PokerForBots Zig SDK

Zig bindings for the [PokerForBots](https://github.com/lox/pokerforbots) poker bot server. Build high-performance poker bots with type-safe message handling and zero-overhead abstractions.

## Features

- **Protocol v2 support**: Simplified 4-action system (fold, call, raise, allin)
- **Type-safe messages**: Union-based message handling with compile-time guarantees
- **MessagePack encoding**: Efficient binary protocol serialization
- **WebSocket client**: Built-in connection management with TLS support
- **Zero-copy parsing**: Efficient message decoding with minimal allocations
- **Example bots**: Random and calling station implementations included

## Installation

Requires Zig 0.15.1 or later.

```bash
zig fetch --save "git+https://github.com/lox/pokerforbots.zig"
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Connect to server
    const config = pfb.Config{
        .endpoint = "ws://localhost:8080/ws",
        .api_key = "your-api-key",
        .bot_name = "my-bot",
    };

    var connector = pfb.Connector.init(allocator, config);
    var conn = try connector.connect();
    defer conn.deinit();

    // Main game loop
    while (try conn.readMessage()) |msg| {
        switch (msg) {
            .action_request => |_| {
                // Make decision
                const action = pfb.OutgoingAction{
                    .action_type = .call,
                    .amount = null,
                };
                try conn.sendAction(action);

                // Cleanup - frees all nested allocations
                pfb.freeMessage(allocator, msg);
            },
            .game_completed => |_| {
                pfb.freeMessage(allocator, msg);
                break;
            },
            else => {
                pfb.freeMessage(allocator, msg);
            },
        }
    }
}
```

## Examples

### Random Bot

Makes random valid decisions:

```zig
const pfb = @import("pokerforbots");

// Choose random action from legal actions
var prng = std.Random.DefaultPrng.init(@bitCast(std.time.timestamp()));
const random = prng.random();

const action_idx = random.intRangeAtMost(usize, 0, req.legal_actions.len - 1);
const chosen = req.legal_actions[action_idx];

const action = pfb.OutgoingAction{
    .action_type = chosen.action_type,
    .amount = chosen.min_amount,
};
try conn.sendAction(action);
```

Run it:

```bash
task random SERVER_URL=ws://localhost:8080/ws BOT_NAME=random-bot
```

### Calling Station Bot

Always calls/checks when possible:

```zig
fn findAction(actions: []const pfb.ActionDescriptor, action_type: pfb.ActionType) ?pfb.ActionDescriptor {
    for (actions) |action| {
        if (action.action_type == action_type) return action;
    }
    return null;
}

// Calling station strategy
const action = if (findAction(req.legal_actions, .call)) |call_action|
    pfb.OutgoingAction{
        .action_type = .call,
        .amount = call_action.min_amount,
    }
else
    pfb.OutgoingAction{
        .action_type = .fold,
        .amount = null,
    };

try conn.sendAction(action);
```

Run it:

```bash
task calling SERVER_URL=ws://localhost:8080/ws BOT_NAME=calling-bot
```

### Hand Information

Access hole cards and game state:

```zig
.hand_start => |start| {
    var hero_stack: u32 = 0;
    for (start.players) |player| {
        if (player.seat == start.your_seat) {
            hero_stack = player.chips;
            break;
        }
    }
    std.debug.print("Hand {s} | Seat: {}, Button: {}, Chips: {}\n", .{
        start.hand_id,
        start.your_seat,
        start.button,
        hero_stack,
    });

    if (start.hole_cards) |cards| {
        // Cards are u8 indices (0-51)
        std.debug.print("Hole cards: {any}\n", .{cards});
    }

    pfb.freeMessage(allocator, msg);
},
```

### Action Decisions

Inspect legal actions and make strategic decisions:

```zig
.action_request => |req| {
    std.debug.print("Pot: {}, To call: {}, Stack: {}\n", .{
        req.pot,
        req.to_call,
        req.your_stack,
    });

    // Check available actions
    for (req.legal_actions) |legal| {
        std.debug.print("  {s}", .{@tagName(legal.action_type)});
        if (legal.min_amount) |min| {
            std.debug.print(" (min: {})\n", .{min});
        } else {
            std.debug.print("\n", .{});
        }
    }

    // Make decision based on pot odds, hand strength, etc.
    const pot_odds = @as(f64, @floatFromInt(req.to_call)) /
                     @as(f64, @floatFromInt(req.pot + req.to_call));

    // Your strategy here...

    pfb.freeMessage(allocator, msg);
},
```

### Game Updates

Track opponent actions and pot size:

```zig
.game_update => |update| {
    std.debug.print("Pot: {}\n", .{update.pot});

    for (update.players) |player| {
        std.debug.print("  {s}: chips={}, bet={}, folded={}\n", .{
            player.name,
            player.chips,
            player.bet,
            player.folded,
        });
    }

    pfb.freeMessage(allocator, msg);
},
```

### Game Completion

Handle end-of-game statistics:

```zig
.game_completed => |completed| {
    std.debug.print("Game finished!\n", .{});
    std.debug.print("  Hands: {}\n", .{completed.hands_completed orelse 0});

    if (completed.hand_limit) |limit| {
        std.debug.print("  Limit: {}\n", .{limit});
    }

    if (completed.reason) |reason| {
        std.debug.print("  Reason: {s}\n", .{reason});
    }

    pfb.freeMessage(allocator, msg);
    break; // Exit game loop
},
```

## Protocol

### Action Types (Protocol v2)

- **fold**: Give up the hand
- **call**: Match current bet (or check if to_call = 0)
- **raise**: Increase the bet (amount is total bet size, not increment)
- **allin**: Bet entire stack (amount field ignored)

Protocol v2 simplifies bot logic by eliminating context-dependent actions:
- Use `call` for both checking and calling
- Use `raise` for both betting and raising
- Server handles normalization based on game state

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

### Memory Management

Use `pfb.freeMessage()` to clean up all allocated memory in a message:

```zig
while (try conn.readMessage()) |msg| {
    defer pfb.freeMessage(allocator, msg);  // Automatic cleanup

    switch (msg) {
        .action_request => |req| {
            // Use req fields...
            try conn.sendAction(action);
        },
        .game_completed => break,
        else => {},
    }
}
```

This handles all nested allocations (strings, arrays, player names, etc.) automatically.

## Building

```bash
# Build all targets
zig build

# Run tests
zig build test

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
task smoke

# Test calling station bot
task smoke BOT=calling-station

# Customize parameters
task smoke HANDS=500 SEED=123 BOT=random

# Use different server
task smoke ADDR=localhost:9000 PFB_BIN=/path/to/pokerforbots
```

The smoke test spawns 6 bots and plays the specified number of hands, saving statistics to `tmp/pfb_smoke_*.json`.

## Development

```bash
# Format code
zig fmt src examples

# Check formatting
task lint

# Clean build artifacts
task clean
```

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
