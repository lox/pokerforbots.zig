const std = @import("std");
const msgpack = @import("msgpack");

const mem = std.mem;
const meta = std.meta;

const ParseError = error{ParseFailure};

// Protocol v2 action types (simplified)
pub const ActionType = enum(u8) {
    fold = 0,
    call = 1,
    raise = 2,
    allin = 3,

    // Internal representation for valid_actions parsing
    // (server may send these in protocol v1 responses)
    check = 4,
    bet = 5,
};

pub const ActionDescriptor = struct {
    action_type: ActionType,
    min_amount: ?u32 = null,
    max_amount: ?u32 = null,
};

pub const SeatInfo = struct {
    seat: u8,
    name: []u8,
    chips: u32,
};

pub const PlayerState = struct {
    name: []u8,
    chips: u32,
    bet: u32,
    folded: bool,
    all_in: bool,
};

pub const GameStart = struct {
    game_id: []u8,
    player_index: u8,
    player_count: u8,
    button: u8,
    stack_sizes: []u32,
    hole_cards: ?[2]u8 = null,
    small_blind: ?u32 = null,
    big_blind: ?u32 = null,
    players: []SeatInfo = &[_]SeatInfo{},
};

pub const HandSummary = struct {
    game_id: []u8,
};

pub const GameUpdate = struct {
    game_id: []u8,
    pot: u32,
    players: []PlayerState,
};

pub const GameCompleted = struct {
    game_id: []u8,
    hands_completed: ?u32 = null,
    hand_limit: ?u32 = null,
    reason: ?[]u8 = null,
    seed: ?u64 = null,
};

pub const ActionRequest = struct {
    game_id: []u8,
    street: u8,
    board: []u8,
    pot: u32,
    to_call: u32,
    your_stack: u32,
    legal_actions: []ActionDescriptor,
    is_terminal: bool = false,
    hole_cards: ?[2]u8 = null,
    min_bet: ?u32 = null,
    min_raise: ?u32 = null,
    time_remaining_ms: ?u32 = null,
};

pub const OutgoingAction = struct {
    action_type: ActionType,
    amount: ?u32 = null,
};

pub const IncomingMessage = union(enum) {
    game_start: GameStart,
    action_request: ActionRequest,
    hand_complete: HandSummary,
    game_update: GameUpdate,
    game_completed: GameCompleted,
    noop,
};

/// Free all allocated memory in a message.
/// Call this instead of manually freeing each field.
pub fn freeMessage(allocator: std.mem.Allocator, msg: IncomingMessage) void {
    switch (msg) {
        .game_start => |start| {
            allocator.free(start.game_id);
            allocator.free(start.stack_sizes);
            for (start.players) |player| {
                allocator.free(player.name);
            }
            if (start.players.len > 0) allocator.free(start.players);
        },
        .action_request => |req| {
            allocator.free(req.game_id);
            allocator.free(req.board);
            allocator.free(req.legal_actions);
        },
        .hand_complete => |complete| {
            allocator.free(complete.game_id);
        },
        .game_update => |update| {
            allocator.free(update.game_id);
            for (update.players) |player| {
                allocator.free(player.name);
            }
            allocator.free(update.players);
        },
        .game_completed => |completed| {
            allocator.free(completed.game_id);
            if (completed.reason) |reason| {
                allocator.free(reason);
            }
        },
        .noop => {},
    }
}

// Internal structures for msgpack decoding
const RawActionDescriptor = struct {
    action_type: u8 = 0,
    min_amount: ?u32 = null,
    max_amount: ?u32 = null,

    pub fn msgpackRead(unpacker: anytype) !RawActionDescriptor {
        const len = try unpacker.readMapHeader(u32);
        var result = RawActionDescriptor{};
        var have_type = false;
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const key = try unpacker.read([]const u8);
            if (std.mem.eql(u8, key, "action_type")) {
                result.action_type = try unpacker.read(u8);
                have_type = true;
            } else if (std.mem.eql(u8, key, "min_amount")) {
                result.min_amount = try unpacker.read(u32);
            } else if (std.mem.eql(u8, key, "max_amount")) {
                result.max_amount = try unpacker.read(u32);
            } else {
                try skipValue(unpacker);
            }
        }
        if (!have_type) return ParseError.ParseFailure;
        return result;
    }
};

const RawPlayer = struct {
    seat: u8 = 0,
    chips: u32 = 0,
    name: []const u8 = &[_]u8{},
    bet: ?u32 = null,
    folded: ?bool = null,
    all_in: ?bool = null,

    pub fn msgpackRead(unpacker: anytype) !RawPlayer {
        const len = try unpacker.readMapHeader(u32);
        var result = RawPlayer{};
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const key = try unpacker.read([]const u8);
            if (std.mem.eql(u8, key, "seat")) {
                result.seat = try unpacker.read(u8);
            } else if (std.mem.eql(u8, key, "chips")) {
                const value = try unpacker.read(i32);
                if (value < 0) return ParseError.ParseFailure;
                result.chips = @intCast(value);
            } else if (std.mem.eql(u8, key, "name")) {
                result.name = try unpacker.read([]const u8);
            } else if (std.mem.eql(u8, key, "bet")) {
                const value = try unpacker.read(i32);
                if (value < 0) return ParseError.ParseFailure;
                result.bet = @intCast(value);
            } else if (std.mem.eql(u8, key, "folded")) {
                result.folded = try unpacker.read(bool);
            } else if (std.mem.eql(u8, key, "all_in")) {
                result.all_in = try unpacker.read(bool);
            } else {
                try skipValue(unpacker);
            }
        }
        return result;
    }
};

const RawMessage = struct {
    msg_type: []const u8 = &[_]u8{},
    game_id: ?[]const u8 = null,
    player_index: ?u8 = null,
    player_count: ?u8 = null,
    button: ?u8 = null,
    stack_sizes: ?[]const u32 = null,
    street: ?u8 = null,
    board: ?[]const u8 = null,
    pot: ?u32 = null,
    to_call: ?u32 = null,
    your_stack: ?u32 = null,
    is_terminal: ?bool = null,
    legal_actions: ?[]RawActionDescriptor = null,
    hole_cards: ?[]const u8 = null,
    valid_actions: ?[]ActionType = null,
    min_bet: ?u32 = null,
    min_raise: ?u32 = null,
    your_seat: ?u8 = null,
    players: ?[]RawPlayer = null,
    hand_id: ?[]const u8 = null,
    small_blind: ?u32 = null,
    big_blind: ?u32 = null,
    time_remaining: ?u32 = null,
    hands_completed: ?u32 = null,
    hand_limit: ?u32 = null,
    reason: ?[]const u8 = null,
    seed: ?u64 = null,

    pub fn msgpackRead(unpacker: anytype) !RawMessage {
        const len = try unpacker.readMapHeader(u32);
        var result = RawMessage{};
        const allocator = unpacker.*.allocator;
        errdefer freeRawMessage(allocator, &result);
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const key = try unpacker.read([]const u8);
            defer allocator.free(key);
            if (std.mem.eql(u8, key, "type")) {
                result.msg_type = try unpacker.read([]const u8);
            } else if (std.mem.eql(u8, key, "game_id")) {
                result.game_id = try unpacker.read([]const u8);
            } else if (std.mem.eql(u8, key, "player_index")) {
                result.player_index = try unpacker.read(u8);
            } else if (std.mem.eql(u8, key, "player_count")) {
                result.player_count = try unpacker.read(u8);
            } else if (std.mem.eql(u8, key, "button")) {
                result.button = try unpacker.read(u8);
            } else if (std.mem.eql(u8, key, "stack_sizes")) {
                result.stack_sizes = try unpacker.read([]const u32);
            } else if (std.mem.eql(u8, key, "street")) {
                result.street = try unpacker.read(u8);
            } else if (std.mem.eql(u8, key, "board")) {
                result.board = try unpacker.read([]const u8);
            } else if (std.mem.eql(u8, key, "pot")) {
                result.pot = try unpacker.read(u32);
            } else if (std.mem.eql(u8, key, "to_call")) {
                result.to_call = try unpacker.read(u32);
            } else if (std.mem.eql(u8, key, "your_stack")) {
                result.your_stack = try unpacker.read(u32);
            } else if (std.mem.eql(u8, key, "is_terminal")) {
                result.is_terminal = try unpacker.read(bool);
            } else if (std.mem.eql(u8, key, "legal_actions")) {
                result.legal_actions = try unpacker.read([]RawActionDescriptor);
            } else if (std.mem.eql(u8, key, "hole_cards")) {
                const names = try unpacker.read([][]const u8);
                defer {
                    for (names) |name| allocator.free(name);
                    allocator.free(names);
                }
                result.hole_cards = try convertCardStrings(allocator, names);
            } else if (std.mem.eql(u8, key, "valid_actions")) {
                const names = try unpacker.read([][]const u8);
                defer {
                    for (names) |name| allocator.free(name);
                    allocator.free(names);
                }
                var count: usize = 0;
                for (names) |name| {
                    if (parseActionType(name) != null) {
                        count += 1;
                    }
                }
                const actions = try allocator.alloc(ActionType, count);
                var idx_actions: usize = 0;
                for (names) |name| {
                    if (parseActionType(name)) |atype| {
                        actions[idx_actions] = atype;
                        idx_actions += 1;
                    }
                }
                result.valid_actions = actions;
            } else if (std.mem.eql(u8, key, "min_bet")) {
                result.min_bet = try unpacker.read(u32);
            } else if (std.mem.eql(u8, key, "min_raise")) {
                result.min_raise = try unpacker.read(u32);
            } else if (std.mem.eql(u8, key, "your_seat")) {
                result.your_seat = try unpacker.read(u8);
            } else if (std.mem.eql(u8, key, "players")) {
                result.players = try unpacker.read([]RawPlayer);
            } else if (std.mem.eql(u8, key, "hand_id")) {
                result.hand_id = try unpacker.read([]const u8);
            } else if (std.mem.eql(u8, key, "small_blind")) {
                result.small_blind = try unpacker.read(u32);
            } else if (std.mem.eql(u8, key, "big_blind")) {
                result.big_blind = try unpacker.read(u32);
            } else if (std.mem.eql(u8, key, "time_remaining")) {
                result.time_remaining = try unpacker.read(u32);
            } else if (std.mem.eql(u8, key, "hands_completed")) {
                result.hands_completed = try unpacker.read(u32);
            } else if (std.mem.eql(u8, key, "hand_limit")) {
                result.hand_limit = try unpacker.read(u32);
            } else if (std.mem.eql(u8, key, "reason")) {
                result.reason = try unpacker.read([]const u8);
            } else if (std.mem.eql(u8, key, "seed")) {
                result.seed = try unpacker.read(u64);
            } else {
                try skipValue(unpacker);
            }
        }
        if (result.msg_type.len == 0) return ParseError.ParseFailure;
        return result;
    }
};

pub const DecodedMessage = struct {
    msg: IncomingMessage,
    msg_type: []u8,
};

pub fn decodeMessage(allocator: std.mem.Allocator, data: []const u8) !DecodedMessage {
    var stream = std.io.fixedBufferStream(data);
    var unpacker = msgpack.unpacker(stream.reader(), allocator);
    var raw = RawMessage.msgpackRead(&unpacker) catch |err| {
        if (err == error.InvalidFormat) {
            const detected = detectMessageType(allocator, data) catch null;
            if (detected) |msg_type| {
                defer allocator.free(msg_type);
                if (!isHandledMessageType(msg_type)) {
                    const msg_type_copy = try allocator.dupe(u8, msg_type);
                    return DecodedMessage{ .msg = IncomingMessage.noop, .msg_type = msg_type_copy };
                }
            }
        }
        return err;
    };
    defer freeRawMessage(allocator, &raw);

    const msg_type_copy = try allocator.dupe(u8, raw.msg_type);
    errdefer allocator.free(msg_type_copy);

    if (std.mem.eql(u8, raw.msg_type, "game_start")) {
        const msg = try buildGameStart(allocator, raw);
        return DecodedMessage{ .msg = IncomingMessage{ .game_start = msg }, .msg_type = msg_type_copy };
    } else if (std.mem.eql(u8, raw.msg_type, "action_request")) {
        const msg = try buildActionRequest(allocator, raw);
        return DecodedMessage{ .msg = IncomingMessage{ .action_request = msg }, .msg_type = msg_type_copy };
    } else if (std.mem.eql(u8, raw.msg_type, "hand_complete")) {
        const msg = try buildHandSummary(allocator, raw);
        return DecodedMessage{ .msg = IncomingMessage{ .hand_complete = msg }, .msg_type = msg_type_copy };
    } else if (std.mem.eql(u8, raw.msg_type, "hand_start")) {
        const msg = try buildHandStart(allocator, raw);
        return DecodedMessage{ .msg = IncomingMessage{ .game_start = msg }, .msg_type = msg_type_copy };
    } else if (std.mem.eql(u8, raw.msg_type, "game_update")) {
        const msg = try buildGameUpdate(allocator, raw);
        return DecodedMessage{ .msg = IncomingMessage{ .game_update = msg }, .msg_type = msg_type_copy };
    } else if (std.mem.eql(u8, raw.msg_type, "game_completed")) {
        const msg = try buildGameCompleted(allocator, raw);
        return DecodedMessage{ .msg = IncomingMessage{ .game_completed = msg }, .msg_type = msg_type_copy };
    }

    return DecodedMessage{ .msg = IncomingMessage.noop, .msg_type = msg_type_copy };
}

fn isHandledMessageType(msg_type: []const u8) bool {
    return std.mem.eql(u8, msg_type, "game_start") or
        std.mem.eql(u8, msg_type, "action_request") or
        std.mem.eql(u8, msg_type, "hand_complete") or
        std.mem.eql(u8, msg_type, "hand_start") or
        std.mem.eql(u8, msg_type, "game_update") or
        std.mem.eql(u8, msg_type, "game_completed");
}

fn detectMessageType(allocator: std.mem.Allocator, data: []const u8) !?[]const u8 {
    var stream = std.io.fixedBufferStream(data);
    var unpacker = msgpack.unpacker(stream.reader(), allocator);
    const len = unpacker.readMapHeader(u32) catch return null;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const key = try unpacker.read([]const u8);
        defer allocator.free(key);
        if (std.mem.eql(u8, key, "type")) {
            const msg_type = try unpacker.read([]const u8);
            const wrapped: ?[]const u8 = msg_type;
            return wrapped;
        }
        try skipValue(&unpacker);
    }
    return null;
}

fn parseActionType(name: []const u8) ?ActionType {
    if (std.mem.eql(u8, name, "fold")) return .fold;
    if (std.mem.eql(u8, name, "check")) return .check;
    if (std.mem.eql(u8, name, "call")) return .call;
    if (std.mem.eql(u8, name, "bet")) return .bet;
    if (std.mem.eql(u8, name, "raise")) return .raise;
    if (std.mem.eql(u8, name, "allin")) return .allin;
    return null;
}

fn convertCardStrings(allocator: std.mem.Allocator, names: [][]const u8) ![]const u8 {
    const cards = try allocator.alloc(u8, names.len);
    for (names, 0..) |name, idx| {
        cards[idx] = try cardStringToIndex(name);
    }
    return cards;
}

fn cardStringToIndex(name: []const u8) !u8 {
    if (name.len != 2) return ParseError.ParseFailure;
    const rank_value: u8 = switch (name[0]) {
        '2' => 0,
        '3' => 1,
        '4' => 2,
        '5' => 3,
        '6' => 4,
        '7' => 5,
        '8' => 6,
        '9' => 7,
        'T', 't' => 8,
        'J', 'j' => 9,
        'Q', 'q' => 10,
        'K', 'k' => 11,
        'A', 'a' => 12,
        else => return ParseError.ParseFailure,
    };
    const suit_offset: u8 = switch (name[1]) {
        'c', 'C' => 0,
        'd', 'D' => 13,
        'h', 'H' => 26,
        's', 'S' => 39,
        else => return ParseError.ParseFailure,
    };
    return suit_offset + rank_value;
}

fn convertSeatInfo(allocator: std.mem.Allocator, raw_players: []RawPlayer) ![]SeatInfo {
    if (raw_players.len == 0) return &[_]SeatInfo{};

    const players = try allocator.alloc(SeatInfo, raw_players.len);
    var populated: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < populated) : (i += 1) {
            allocator.free(players[i].name);
        }
        allocator.free(players);
    }

    for (raw_players, 0..) |player, idx| {
        const name_copy = try allocator.dupe(u8, player.name);
        players[idx] = .{
            .seat = player.seat,
            .name = name_copy,
            .chips = player.chips,
        };
        populated += 1;
    }
    return players;
}

fn convertPlayerStates(allocator: std.mem.Allocator, raw_players: []RawPlayer) ![]PlayerState {
    if (raw_players.len == 0) return &[_]PlayerState{};

    const players = try allocator.alloc(PlayerState, raw_players.len);
    var populated: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < populated) : (i += 1) {
            allocator.free(players[i].name);
        }
        allocator.free(players);
    }

    for (raw_players, 0..) |player, idx| {
        const name_copy = try allocator.dupe(u8, player.name);
        players[idx] = .{
            .name = name_copy,
            .chips = player.chips,
            .bet = player.bet orelse 0,
            .folded = player.folded orelse false,
            .all_in = player.all_in orelse false,
        };
        populated += 1;
    }

    return players;
}

fn buildGameStart(allocator: std.mem.Allocator, raw: RawMessage) !GameStart {
    const game_id_raw = raw.game_id orelse return ParseError.ParseFailure;
    const stacks_raw = raw.stack_sizes orelse return ParseError.ParseFailure;
    const player_index = raw.player_index orelse return ParseError.ParseFailure;
    const player_count = raw.player_count orelse return ParseError.ParseFailure;
    const button = raw.button orelse return ParseError.ParseFailure;

    const game_id = try allocator.dupe(u8, game_id_raw);
    const stacks = try allocator.alloc(u32, stacks_raw.len);
    for (stacks_raw, 0..) |value, idx| {
        stacks[idx] = value;
    }

    var hole_cards: ?[2]u8 = null;
    if (raw.hole_cards) |cards| {
        if (cards.len == 2) {
            hole_cards = .{ cards[0], cards[1] };
        }
    }

    var players: []SeatInfo = &[_]SeatInfo{};
    if (raw.players) |raw_players| {
        players = try convertSeatInfo(allocator, raw_players);
    }

    return GameStart{
        .game_id = game_id,
        .player_index = player_index,
        .player_count = player_count,
        .button = button,
        .stack_sizes = stacks,
        .hole_cards = hole_cards,
        .small_blind = raw.small_blind,
        .big_blind = raw.big_blind,
        .players = players,
    };
}

fn buildHandStart(allocator: std.mem.Allocator, raw: RawMessage) !GameStart {
    const players_raw = raw.players orelse return ParseError.ParseFailure;
    var max_seat: usize = 0;
    for (players_raw) |player| {
        max_seat = @max(max_seat, @as(usize, player.seat));
    }
    const player_count: u8 = @intCast(max_seat + 1);
    const hero_index = raw.your_seat orelse 0;
    const button = raw.button orelse 0;
    const game_id_source = raw.game_id orelse raw.hand_id orelse "";

    const game_id = try allocator.dupe(u8, game_id_source);
    const stacks = try allocator.alloc(u32, max_seat + 1);
    @memset(stacks, 0);
    for (players_raw) |player| {
        if (player.seat >= stacks.len) continue;
        stacks[player.seat] = player.chips;
    }

    var hole_cards: ?[2]u8 = null;
    if (raw.hole_cards) |cards| {
        if (cards.len == 2) {
            hole_cards = .{ cards[0], cards[1] };
        }
    }

    const players = try convertSeatInfo(allocator, players_raw);

    return GameStart{
        .game_id = game_id,
        .player_index = hero_index,
        .player_count = player_count,
        .button = button,
        .stack_sizes = stacks,
        .hole_cards = hole_cards,
        .small_blind = raw.small_blind,
        .big_blind = raw.big_blind,
        .players = players,
    };
}

fn buildGameUpdate(allocator: std.mem.Allocator, raw: RawMessage) !GameUpdate {
    const pot_value = raw.pot orelse return ParseError.ParseFailure;
    const players_raw = raw.players orelse return ParseError.ParseFailure;
    const game_id_source = raw.game_id orelse raw.hand_id orelse return ParseError.ParseFailure;

    const game_id = try allocator.dupe(u8, game_id_source);
    const players = try convertPlayerStates(allocator, players_raw);

    return GameUpdate{
        .game_id = game_id,
        .pot = pot_value,
        .players = players,
    };
}

fn buildGameCompleted(allocator: std.mem.Allocator, raw: RawMessage) !GameCompleted {
    const game_id_source = raw.game_id orelse raw.hand_id orelse return ParseError.ParseFailure;
    const game_id = try allocator.dupe(u8, game_id_source);

    var reason_copy: ?[]u8 = null;
    if (raw.reason) |value| {
        reason_copy = try allocator.dupe(u8, value);
    }

    return GameCompleted{
        .game_id = game_id,
        .hands_completed = raw.hands_completed,
        .hand_limit = raw.hand_limit,
        .reason = reason_copy,
        .seed = raw.seed,
    };
}

fn buildActionRequest(allocator: std.mem.Allocator, raw: RawMessage) !ActionRequest {
    const game_id_raw = raw.game_id orelse "";
    const board_raw = raw.board orelse &[_]u8{};
    const pot = raw.pot orelse return ParseError.ParseFailure;
    const to_call = raw.to_call orelse return ParseError.ParseFailure;
    const stack = raw.your_stack orelse 0;
    const street = raw.street orelse 0;

    const legal = try synthesizeLegalActions(allocator, raw);

    const game_id = try allocator.dupe(u8, game_id_raw);
    const board = try allocator.dupe(u8, board_raw);

    var hole_cards: ?[2]u8 = null;
    if (raw.hole_cards) |cards| {
        if (cards.len == 2) {
            hole_cards = .{ cards[0], cards[1] };
        }
    }

    return ActionRequest{
        .game_id = game_id,
        .street = street,
        .board = board,
        .pot = pot,
        .to_call = to_call,
        .your_stack = stack,
        .legal_actions = legal,
        .is_terminal = raw.is_terminal orelse false,
        .hole_cards = hole_cards,
        .min_bet = raw.min_bet,
        .min_raise = raw.min_raise,
        .time_remaining_ms = raw.time_remaining,
    };
}

fn synthesizeLegalActions(allocator: std.mem.Allocator, raw: RawMessage) ![]ActionDescriptor {
    if (raw.legal_actions) |legal_raw| {
        const legal = try allocator.alloc(ActionDescriptor, legal_raw.len);
        for (legal_raw, 0..) |entry, idx| {
            const action_type = meta.intToEnum(ActionType, entry.action_type) catch return ParseError.ParseFailure;
            legal[idx] = .{
                .action_type = action_type,
                .min_amount = entry.min_amount,
                .max_amount = entry.max_amount,
            };
        }
        return legal;
    }

    const actions = raw.valid_actions orelse return ParseError.ParseFailure;
    const legal = try allocator.alloc(ActionDescriptor, actions.len);
    const min_bet = raw.min_bet orelse raw.min_raise orelse 0;
    const min_raise = raw.min_raise orelse raw.min_bet orelse 0;
    for (actions, 0..) |atype, idx| {
        legal[idx] = switch (atype) {
            .fold => .{ .action_type = .fold },
            .check => .{ .action_type = .check },
            .call => .{ .action_type = .call },
            .bet => .{
                .action_type = .bet,
                .min_amount = if (min_bet == 0) null else min_bet,
                .max_amount = null,
            },
            .raise => .{
                .action_type = .raise,
                .min_amount = if (min_raise == 0) null else min_raise,
                .max_amount = null,
            },
            .allin => .{
                .action_type = .allin,
                .min_amount = null,
                .max_amount = null,
            },
        };
    }
    return legal;
}

fn buildHandSummary(allocator: std.mem.Allocator, raw: RawMessage) !HandSummary {
    const game_id_raw = raw.game_id orelse return ParseError.ParseFailure;
    const game_id = try allocator.dupe(u8, game_id_raw);
    return HandSummary{ .game_id = game_id };
}

fn freeRawMessage(allocator: std.mem.Allocator, raw: *RawMessage) void {
    allocator.free(@constCast(raw.msg_type));
    if (raw.game_id) |slice| allocator.free(@constCast(slice));
    if (raw.stack_sizes) |slice| allocator.free(@constCast(slice));
    if (raw.board) |slice| allocator.free(@constCast(slice));
    if (raw.legal_actions) |slice| allocator.free(slice);
    if (raw.hole_cards) |slice| allocator.free(@constCast(slice));
    if (raw.valid_actions) |slice| allocator.free(slice);
    if (raw.hand_id) |slice| allocator.free(@constCast(slice));
    if (raw.players) |slice| {
        for (slice) |player| {
            allocator.free(player.name);
        }
        allocator.free(slice);
    }
    if (raw.reason) |value| allocator.free(value);
}

fn skipValue(unpacker: anytype) !void {
    try skipValueReader(&unpacker.reader);
}

fn skipValueReader(reader: anytype) !void {
    const marker = try reader.readByte();
    switch (marker) {
        0x00...0x7f, 0xe0...0xff => return,
        0xc0, 0xc2, 0xc3 => return,
        0xcc, 0xd0 => try reader.skipBytes(1, .{}),
        0xcd, 0xd1 => try reader.skipBytes(2, .{}),
        0xce, 0xd2 => try reader.skipBytes(4, .{}),
        0xcf, 0xd3 => try reader.skipBytes(8, .{}),
        0xca => try reader.skipBytes(4, .{}),
        0xcb => try reader.skipBytes(8, .{}),
        0xc4 => {
            const len = try reader.readByte();
            try reader.skipBytes(len, .{});
        },
        0xc5 => {
            const len = try readU16(reader);
            try reader.skipBytes(len, .{});
        },
        0xc6 => {
            const len = try readU32(reader);
            try reader.skipBytes(len, .{});
        },
        0xd9 => {
            const len = try reader.readByte();
            try reader.skipBytes(len, .{});
        },
        0xda => {
            const len = try readU16(reader);
            try reader.skipBytes(len, .{});
        },
        0xdb => {
            const len = try readU32(reader);
            try reader.skipBytes(len, .{});
        },
        0xc7 => {
            const len = try reader.readByte();
            try reader.skipBytes(1 + len, .{});
        },
        0xc8 => {
            const len = try readU16(reader);
            try reader.skipBytes(1 + len, .{});
        },
        0xc9 => {
            const len = try readU32(reader);
            try reader.skipBytes(1 + len, .{});
        },
        0xd4 => try reader.skipBytes(1 + 1, .{}),
        0xd5 => try reader.skipBytes(1 + 2, .{}),
        0xd6 => try reader.skipBytes(1 + 4, .{}),
        0xd7 => try reader.skipBytes(1 + 8, .{}),
        0xd8 => try reader.skipBytes(1 + 16, .{}),
        0x90...0x9f => {
            const count = marker & 0x0f;
            var idx: usize = 0;
            while (idx < count) : (idx += 1) {
                try skipValueReader(reader);
            }
        },
        0xdc => {
            const count = try readU16(reader);
            var idx: usize = 0;
            while (idx < count) : (idx += 1) {
                try skipValueReader(reader);
            }
        },
        0xdd => {
            const count = try readU32(reader);
            var idx: usize = 0;
            while (idx < count) : (idx += 1) {
                try skipValueReader(reader);
            }
        },
        0x80...0x8f => {
            const count = marker & 0x0f;
            var idx: usize = 0;
            while (idx < count) : (idx += 1) {
                try skipValueReader(reader);
                try skipValueReader(reader);
            }
        },
        0xde => {
            const count = try readU16(reader);
            var idx: usize = 0;
            while (idx < count) : (idx += 1) {
                try skipValueReader(reader);
                try skipValueReader(reader);
            }
        },
        0xdf => {
            const count = try readU32(reader);
            var idx: usize = 0;
            while (idx < count) : (idx += 1) {
                try skipValueReader(reader);
                try skipValueReader(reader);
            }
        },
        0xa0...0xbf => {
            const len = marker & 0x1f;
            try reader.skipBytes(len, .{});
        },
        else => return ParseError.ParseFailure,
    }
}

fn readU16(reader: anytype) !usize {
    var buf: [2]u8 = undefined;
    try readExactly(reader, buf[0..]);
    return (@as(usize, buf[0]) << 8) | buf[1];
}

fn readU32(reader: anytype) !usize {
    var buf: [4]u8 = undefined;
    try readExactly(reader, buf[0..]);
    return (@as(usize, buf[0]) << 24) | (@as(usize, buf[1]) << 16) | (@as(usize, buf[2]) << 8) | buf[3];
}

fn readExactly(reader: anytype, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const amt = try reader.read(buffer[offset..]);
        if (amt == 0) return ParseError.ParseFailure;
        offset += amt;
    }
}
