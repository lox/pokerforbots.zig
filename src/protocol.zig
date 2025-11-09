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

pub const HandStart = struct {
    hand_id: []u8,
    your_seat: u8,
    button: u8,
    hole_cards: [2]u8,
    small_blind: u32,
    big_blind: u32,
    players: []SeatInfo = &[_]SeatInfo{},
};

pub const ActionRequest = struct {
    hand_id: []u8,
    pot: u32,
    to_call: u32,
    legal_actions: []ActionDescriptor,
    min_bet: u32,
    min_raise: u32,
    time_remaining_ms: u32,
};

pub const GameUpdate = struct {
    hand_id: []u8,
    pot: u32,
    players: []PlayerState,
};

pub const PlayerAction = struct {
    hand_id: []u8,
    street: []u8,
    seat: u8,
    player_name: []u8,
    action: []u8,
    amount_paid: i32,
    player_bet: u32,
    player_chips: u32,
    pot: u32,
};

pub const StreetChange = struct {
    hand_id: []u8,
    street: []u8,
    board: []u8,
};

pub const Winner = struct {
    name: []u8,
    amount: u32,
    hole_cards: []u8,
    hand_rank: ?[]u8 = null,
};

pub const ShowdownHand = struct {
    name: []u8,
    hole_cards: []u8,
    hand_rank: []u8,
};

pub const HandResult = struct {
    hand_id: []u8,
    board: []u8,
    winners: []Winner,
    showdown: []ShowdownHand,
};

pub const PositionStatSummary = struct {
    label: []u8,
    hands: u64,
    net_bb: f64,
    bb_per_hand: f64,
};

pub const StreetStatSummary = struct {
    label: []u8,
    hands_ended: u64,
    net_bb: f64,
    bb_per_hand: f64,
};

pub const CategoryStatSummary = struct {
    label: []u8,
    hands: u64,
    net_bb: f64,
    bb_per_hand: f64,
};

pub const PlayerDetailedStats = struct {
    hands: u64 = 0,
    net_bb: f64 = 0,
    bb_per_100: f64 = 0,
    mean: f64 = 0,
    median: f64 = 0,
    std_dev: f64 = 0,
    ci_95_low: f64 = 0,
    ci_95_high: f64 = 0,
    winning_hands: u64 = 0,
    win_rate: f64 = 0,
    showdown_wins: u64 = 0,
    non_showdown_wins: u64 = 0,
    showdown_win_rate: f64 = 0,
    showdown_bb: f64 = 0,
    non_showdown_bb: f64 = 0,
    max_pot_bb: f64 = 0,
    big_pots: u64 = 0,
    vpip: f64 = 0,
    pfr: f64 = 0,
    timeouts: u64 = 0,
    busts: u64 = 0,
    responses_tracked: u64 = 0,
    avg_response_ms: f64 = 0,
    p95_response_ms: f64 = 0,
    max_response_ms: f64 = 0,
    min_response_ms: f64 = 0,
    response_std_ms: f64 = 0,
    response_timeouts: u64 = 0,
    response_disconnects: u64 = 0,
    position_stats: []PositionStatSummary = &[_]PositionStatSummary{},
    street_stats: []StreetStatSummary = &[_]StreetStatSummary{},
    hand_category_stats: []CategoryStatSummary = &[_]CategoryStatSummary{},
};

pub const GameCompletedPlayer = struct {
    bot_id: []u8,
    display_name: []u8,
    hands: u64,
    net_chips: i64,
    avg_per_hand: f64,
    total_won: i64,
    total_lost: i64,
    last_delta: i32,
    timeouts: u32,
    invalid_actions: u32,
    disconnects: u32,
    busts: u32,
    detailed_stats: ?*PlayerDetailedStats = null,
};

pub const GameCompleted = struct {
    game_id: []u8,
    hands_completed: u64,
    hand_limit: u64,
    reason: []u8,
    seed: ?i64 = null,
    players: []GameCompletedPlayer = &[_]GameCompletedPlayer{},
};

pub const ErrorMessage = struct {
    code: []u8,
    message: []u8,
};

pub const OutgoingAction = struct {
    action_type: ActionType,
    amount: ?u32 = null,
};

pub const IncomingMessage = union(enum) {
    hand_start: HandStart,
    action_request: ActionRequest,
    game_update: GameUpdate,
    player_action: PlayerAction,
    street_change: StreetChange,
    hand_result: HandResult,
    game_completed: GameCompleted,
    error_message: ErrorMessage,
    noop,
};

/// Free all allocated memory in a message.
/// Call this instead of manually freeing each field.
pub fn freeMessage(allocator: std.mem.Allocator, msg: IncomingMessage) void {
    switch (msg) {
        .hand_start => |start| {
            allocator.free(start.hand_id);
            freeSeatInfos(allocator, start.players);
        },
        .action_request => |req| {
            allocator.free(req.hand_id);
            allocator.free(req.legal_actions);
        },
        .game_update => |update| {
            allocator.free(update.hand_id);
            freePlayerStates(allocator, update.players);
        },
        .player_action => |act| {
            allocator.free(act.hand_id);
            allocator.free(act.street);
            allocator.free(act.player_name);
            allocator.free(act.action);
        },
        .street_change => |change| {
            allocator.free(change.hand_id);
            allocator.free(change.street);
            allocator.free(change.board);
        },
        .hand_result => |result| {
            allocator.free(result.hand_id);
            allocator.free(result.board);
            freeWinners(allocator, result.winners);
            freeShowdownHands(allocator, result.showdown);
        },
        .game_completed => |completed| {
            allocator.free(completed.game_id);
            allocator.free(completed.reason);
            freeGameCompletedPlayers(allocator, completed.players);
        },
        .error_message => |err| {
            allocator.free(err.code);
            allocator.free(err.message);
        },
        .noop => {},
    }
}

fn freeSeatInfos(allocator: std.mem.Allocator, players: []SeatInfo) void {
    if (players.len == 0) return;
    for (players) |player| allocator.free(player.name);
    allocator.free(players);
}

fn freePlayerStates(allocator: std.mem.Allocator, players: []PlayerState) void {
    if (players.len == 0) return;
    for (players) |player| allocator.free(player.name);
    allocator.free(players);
}

fn freePositionStats(allocator: std.mem.Allocator, stats: []PositionStatSummary) void {
    if (stats.len == 0) return;
    for (stats) |entry| allocator.free(entry.label);
    allocator.free(stats);
}

fn freeStreetStats(allocator: std.mem.Allocator, stats: []StreetStatSummary) void {
    if (stats.len == 0) return;
    for (stats) |entry| allocator.free(entry.label);
    allocator.free(stats);
}

fn freeCategoryStats(allocator: std.mem.Allocator, stats: []CategoryStatSummary) void {
    if (stats.len == 0) return;
    for (stats) |entry| allocator.free(entry.label);
    allocator.free(stats);
}

fn freeDetailedStats(allocator: std.mem.Allocator, stats: *PlayerDetailedStats) void {
    freePositionStats(allocator, stats.position_stats);
    freeStreetStats(allocator, stats.street_stats);
    freeCategoryStats(allocator, stats.hand_category_stats);
    stats.position_stats = &[_]PositionStatSummary{};
    stats.street_stats = &[_]StreetStatSummary{};
    stats.hand_category_stats = &[_]CategoryStatSummary{};
}

fn freeWinners(allocator: std.mem.Allocator, winners: []Winner) void {
    if (winners.len == 0) return;
    for (winners) |winner| {
        allocator.free(winner.name);
        allocator.free(winner.hole_cards);
        if (winner.hand_rank) |rank| allocator.free(rank);
    }
    allocator.free(winners);
}

fn freeShowdownHands(allocator: std.mem.Allocator, hands: []ShowdownHand) void {
    if (hands.len == 0) return;
    for (hands) |hand| {
        allocator.free(hand.name);
        allocator.free(hand.hole_cards);
        allocator.free(hand.hand_rank);
    }
    allocator.free(hands);
}

fn freeGameCompletedPlayers(allocator: std.mem.Allocator, players: []GameCompletedPlayer) void {
    if (players.len == 0) return;
    for (players) |player| {
        allocator.free(player.bot_id);
        allocator.free(player.display_name);
        if (player.detailed_stats) |stats| {
            freeDetailedStats(allocator, stats);
            allocator.destroy(stats);
        }
    }
    allocator.free(players);
}

fn freeRawPlayers(allocator: std.mem.Allocator, players: []RawPlayer) void {
    for (players) |player| allocator.free(player.name);
    allocator.free(players);
}

fn freeRawWinners(allocator: std.mem.Allocator, winners: []RawWinner) void {
    for (winners) |winner| {
        allocator.free(winner.name);
        if (winner.hole_cards) |cards| allocator.free(@constCast(cards));
        if (winner.hand_rank) |rank| allocator.free(rank);
    }
    allocator.free(winners);
}

fn freeRawShowdownHands(allocator: std.mem.Allocator, hands: []RawShowdownHand) void {
    for (hands) |hand| {
        allocator.free(hand.name);
        allocator.free(@constCast(hand.hole_cards));
        allocator.free(hand.hand_rank);
    }
    allocator.free(hands);
}

fn freeRawGameCompletedPlayers(allocator: std.mem.Allocator, players: []RawGameCompletedPlayer) void {
    for (players) |player| {
        allocator.free(player.bot_id);
        allocator.free(player.display_name);
        if (player.detailed_stats) |stats| {
            freeDetailedStats(allocator, stats);
            allocator.destroy(stats);
        }
    }
    allocator.free(players);
}

fn readCardIndices(allocator: std.mem.Allocator, unpacker: anytype) ![]const u8 {
    const names = try unpacker.read([][]const u8);
    defer {
        for (names) |name| allocator.free(name);
        allocator.free(names);
    }
    return try convertCardStrings(allocator, names);
}

fn readActionTypeArray(allocator: std.mem.Allocator, unpacker: anytype) ![]ActionType {
    const names = try unpacker.read([][]const u8);
    defer {
        for (names) |name| allocator.free(name);
        allocator.free(names);
    }
    var count: usize = 0;
    for (names) |name| {
        if (parseActionType(name) != null) count += 1;
    }
    const actions = try allocator.alloc(ActionType, count);
    var idx: usize = 0;
    for (names) |name| {
        if (parseActionType(name)) |atype| {
            actions[idx] = atype;
            idx += 1;
        }
    }
    return actions;
}

fn convertWinners(allocator: std.mem.Allocator, raw: []RawWinner) ![]Winner {
    const winners = try allocator.alloc(Winner, raw.len);
    errdefer allocator.free(winners);
    for (raw, 0..) |entry, idx| {
        winners[idx].name = try allocator.dupe(u8, entry.name);
        if (entry.amount < 0) return ParseError.ParseFailure;
        winners[idx].amount = @intCast(entry.amount);
        if (entry.hole_cards) |cards| {
            winners[idx].hole_cards = try allocator.dupe(u8, cards);
        } else {
            winners[idx].hole_cards = try allocator.alloc(u8, 0);
        }
        winners[idx].hand_rank = if (entry.hand_rank) |rank|
            try allocator.dupe(u8, rank)
        else
            null;
    }
    return winners;
}

fn convertShowdownHands(allocator: std.mem.Allocator, raw: []RawShowdownHand) ![]ShowdownHand {
    const hands = try allocator.alloc(ShowdownHand, raw.len);
    errdefer allocator.free(hands);
    for (raw, 0..) |entry, idx| {
        hands[idx].name = try allocator.dupe(u8, entry.name);
        hands[idx].hole_cards = try allocator.dupe(u8, entry.hole_cards);
        hands[idx].hand_rank = try allocator.dupe(u8, entry.hand_rank);
    }
    return hands;
}

fn convertCompletedPlayers(allocator: std.mem.Allocator, raw: []RawGameCompletedPlayer) ![]GameCompletedPlayer {
    const players = try allocator.alloc(GameCompletedPlayer, raw.len);
    errdefer allocator.free(players);
    for (raw, 0..) |*entry, idx| {
        players[idx].bot_id = try allocator.dupe(u8, entry.bot_id);
        players[idx].display_name = try allocator.dupe(u8, entry.display_name);
        players[idx].hands = entry.hands;
        players[idx].net_chips = entry.net_chips;
        players[idx].avg_per_hand = entry.avg_per_hand;
        players[idx].total_won = entry.total_won;
        players[idx].total_lost = entry.total_lost;
        players[idx].last_delta = entry.last_delta;
        players[idx].timeouts = entry.timeouts;
        players[idx].invalid_actions = entry.invalid_actions;
        players[idx].disconnects = entry.disconnects;
        players[idx].busts = entry.busts;
        if (entry.detailed_stats) |stats| {
            players[idx].detailed_stats = stats;
            entry.detailed_stats = null;
        } else {
            players[idx].detailed_stats = null;
        }
    }
    return players;
}

fn readDetailedStats(allocator: std.mem.Allocator, unpacker: anytype) !*PlayerDetailedStats {
    const stats = try allocator.create(PlayerDetailedStats);
    stats.* = .{};
    errdefer allocator.destroy(stats);

    const len = try unpacker.readMapHeader(u32);
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const key = try unpacker.read([]const u8);
        defer allocator.free(key);
        if (std.mem.eql(u8, key, "hands")) {
            stats.hands = try readUnsignedFieldU64(unpacker);
        } else if (std.mem.eql(u8, key, "net_bb")) {
            stats.net_bb = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "bb_per_100")) {
            stats.bb_per_100 = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "mean")) {
            stats.mean = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "median")) {
            stats.median = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "std_dev")) {
            stats.std_dev = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "ci_95_low")) {
            stats.ci_95_low = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "ci_95_high")) {
            stats.ci_95_high = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "winning_hands")) {
            stats.winning_hands = try readUnsignedFieldU64(unpacker);
        } else if (std.mem.eql(u8, key, "win_rate")) {
            stats.win_rate = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "showdown_wins")) {
            stats.showdown_wins = try readUnsignedFieldU64(unpacker);
        } else if (std.mem.eql(u8, key, "non_showdown_wins")) {
            stats.non_showdown_wins = try readUnsignedFieldU64(unpacker);
        } else if (std.mem.eql(u8, key, "showdown_win_rate")) {
            stats.showdown_win_rate = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "showdown_bb")) {
            stats.showdown_bb = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "non_showdown_bb")) {
            stats.non_showdown_bb = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "max_pot_bb")) {
            stats.max_pot_bb = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "big_pots")) {
            stats.big_pots = try readUnsignedFieldU64(unpacker);
        } else if (std.mem.eql(u8, key, "vpip")) {
            stats.vpip = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "pfr")) {
            stats.pfr = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "timeouts")) {
            stats.timeouts = try readUnsignedFieldU64(unpacker);
        } else if (std.mem.eql(u8, key, "busts")) {
            stats.busts = try readUnsignedFieldU64(unpacker);
        } else if (std.mem.eql(u8, key, "responses_tracked")) {
            stats.responses_tracked = try readUnsignedFieldU64(unpacker);
        } else if (std.mem.eql(u8, key, "avg_response_ms")) {
            stats.avg_response_ms = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "p95_response_ms")) {
            stats.p95_response_ms = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "max_response_ms")) {
            stats.max_response_ms = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "min_response_ms")) {
            stats.min_response_ms = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "response_std_ms")) {
            stats.response_std_ms = try unpacker.read(f64);
        } else if (std.mem.eql(u8, key, "response_timeouts")) {
            stats.response_timeouts = try readUnsignedFieldU64(unpacker);
        } else if (std.mem.eql(u8, key, "response_disconnects")) {
            stats.response_disconnects = try readUnsignedFieldU64(unpacker);
        } else if (std.mem.eql(u8, key, "position_stats")) {
            stats.position_stats = try readPositionStats(allocator, unpacker);
        } else if (std.mem.eql(u8, key, "street_stats")) {
            stats.street_stats = try readStreetStats(allocator, unpacker);
        } else if (std.mem.eql(u8, key, "hand_category_stats")) {
            stats.hand_category_stats = try readCategoryStats(allocator, unpacker);
        } else {
            try skipValue(unpacker);
        }
    }

    return stats;
}

fn readUnsignedFieldU64(unpacker: anytype) !u64 {
    const value = try unpacker.read(i64);
    if (value < 0) return ParseError.ParseFailure;
    return @intCast(value);
}

fn readPositionStats(allocator: std.mem.Allocator, unpacker: anytype) ![]PositionStatSummary {
    const count = try unpacker.readMapHeader(u32);
    const stats = try allocator.alloc(PositionStatSummary, count);
    errdefer allocator.free(stats);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const label = try unpacker.read([]const u8);
        const label_copy = try allocator.dupe(u8, label);
        allocator.free(label);
        stats[idx].label = label_copy;
        const entry_len = try unpacker.readMapHeader(u32);
        var j: u32 = 0;
        while (j < entry_len) : (j += 1) {
            const key = try unpacker.read([]const u8);
            defer allocator.free(key);
            if (std.mem.eql(u8, key, "hands")) {
                stats[idx].hands = try readUnsignedFieldU64(unpacker);
            } else if (std.mem.eql(u8, key, "net_bb")) {
                stats[idx].net_bb = try unpacker.read(f64);
            } else if (std.mem.eql(u8, key, "bb_per_hand")) {
                stats[idx].bb_per_hand = try unpacker.read(f64);
            } else {
                try skipValue(unpacker);
            }
        }
    }
    return stats;
}

fn readStreetStats(allocator: std.mem.Allocator, unpacker: anytype) ![]StreetStatSummary {
    const count = try unpacker.readMapHeader(u32);
    const stats = try allocator.alloc(StreetStatSummary, count);
    errdefer allocator.free(stats);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const label = try unpacker.read([]const u8);
        const label_copy = try allocator.dupe(u8, label);
        allocator.free(label);
        stats[idx].label = label_copy;
        const entry_len = try unpacker.readMapHeader(u32);
        var j: u32 = 0;
        while (j < entry_len) : (j += 1) {
            const key = try unpacker.read([]const u8);
            defer allocator.free(key);
            if (std.mem.eql(u8, key, "hands_ended")) {
                stats[idx].hands_ended = try readUnsignedFieldU64(unpacker);
            } else if (std.mem.eql(u8, key, "net_bb")) {
                stats[idx].net_bb = try unpacker.read(f64);
            } else if (std.mem.eql(u8, key, "bb_per_hand")) {
                stats[idx].bb_per_hand = try unpacker.read(f64);
            } else {
                try skipValue(unpacker);
            }
        }
    }
    return stats;
}

fn readCategoryStats(allocator: std.mem.Allocator, unpacker: anytype) ![]CategoryStatSummary {
    const count = try unpacker.readMapHeader(u32);
    const stats = try allocator.alloc(CategoryStatSummary, count);
    errdefer allocator.free(stats);
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const label = try unpacker.read([]const u8);
        const label_copy = try allocator.dupe(u8, label);
        allocator.free(label);
        stats[idx].label = label_copy;
        const entry_len = try unpacker.readMapHeader(u32);
        var j: u32 = 0;
        while (j < entry_len) : (j += 1) {
            const key = try unpacker.read([]const u8);
            defer allocator.free(key);
            if (std.mem.eql(u8, key, "hands")) {
                stats[idx].hands = try readUnsignedFieldU64(unpacker);
            } else if (std.mem.eql(u8, key, "net_bb")) {
                stats[idx].net_bb = try unpacker.read(f64);
            } else if (std.mem.eql(u8, key, "bb_per_hand")) {
                stats[idx].bb_per_hand = try unpacker.read(f64);
            } else {
                try skipValue(unpacker);
            }
        }
    }
    return stats;
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

const RawWinner = struct {
    name: []const u8 = &[_]u8{},
    amount: i64 = 0,
    hole_cards: ?[]const u8 = null,
    hand_rank: ?[]const u8 = null,

    pub fn msgpackRead(unpacker: anytype) !RawWinner {
        const len = try unpacker.readMapHeader(u32);
        var result = RawWinner{};
        const allocator = unpacker.allocator;
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const key = try unpacker.read([]const u8);
            defer allocator.free(key);
            if (std.mem.eql(u8, key, "name")) {
                result.name = try unpacker.read([]const u8);
            } else if (std.mem.eql(u8, key, "amount")) {
                result.amount = try unpacker.read(i64);
            } else if (std.mem.eql(u8, key, "hole_cards")) {
                const names = try unpacker.read([][]const u8);
                defer {
                    for (names) |name| allocator.free(name);
                    allocator.free(names);
                }
                result.hole_cards = try convertCardStrings(allocator, names);
            } else if (std.mem.eql(u8, key, "hand_rank")) {
                result.hand_rank = try unpacker.read([]const u8);
            } else {
                try skipValue(unpacker);
            }
        }
        return result;
    }
};

const RawShowdownHand = struct {
    name: []const u8 = &[_]u8{},
    hole_cards: []const u8 = &[_]u8{},
    hand_rank: []const u8 = &[_]u8{},

    pub fn msgpackRead(unpacker: anytype) !RawShowdownHand {
        const len = try unpacker.readMapHeader(u32);
        var result = RawShowdownHand{};
        const allocator = unpacker.allocator;
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const key = try unpacker.read([]const u8);
            defer allocator.free(key);
            if (std.mem.eql(u8, key, "name")) {
                result.name = try unpacker.read([]const u8);
            } else if (std.mem.eql(u8, key, "hole_cards")) {
                const names = try unpacker.read([][]const u8);
                defer {
                    for (names) |name| allocator.free(name);
                    allocator.free(names);
                }
                result.hole_cards = try convertCardStrings(allocator, names);
            } else if (std.mem.eql(u8, key, "hand_rank")) {
                result.hand_rank = try unpacker.read([]const u8);
            } else {
                try skipValue(unpacker);
            }
        }
        return result;
    }
};

const RawGameCompletedPlayer = struct {
    bot_id: []const u8 = &[_]u8{},
    display_name: []const u8 = &[_]u8{},
    hands: u64 = 0,
    net_chips: i64 = 0,
    avg_per_hand: f64 = 0,
    total_won: i64 = 0,
    total_lost: i64 = 0,
    last_delta: i32 = 0,
    timeouts: u32 = 0,
    invalid_actions: u32 = 0,
    disconnects: u32 = 0,
    busts: u32 = 0,
    detailed_stats: ?*PlayerDetailedStats = null,

    pub fn msgpackRead(unpacker: anytype) !RawGameCompletedPlayer {
        const len = try unpacker.readMapHeader(u32);
        var result = RawGameCompletedPlayer{};
        const allocator = unpacker.allocator;
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const key = try unpacker.read([]const u8);
            defer allocator.free(key);
            if (std.mem.eql(u8, key, "bot_id")) {
                result.bot_id = try unpacker.read([]const u8);
            } else if (std.mem.eql(u8, key, "display_name")) {
                result.display_name = try unpacker.read([]const u8);
            } else if (std.mem.eql(u8, key, "hands")) {
                const value = try unpacker.read(i64);
                if (value < 0) return ParseError.ParseFailure;
                result.hands = @intCast(value);
            } else if (std.mem.eql(u8, key, "net_chips")) {
                result.net_chips = try unpacker.read(i64);
            } else if (std.mem.eql(u8, key, "avg_per_hand")) {
                result.avg_per_hand = try unpacker.read(f64);
            } else if (std.mem.eql(u8, key, "total_won")) {
                result.total_won = try unpacker.read(i64);
            } else if (std.mem.eql(u8, key, "total_lost")) {
                result.total_lost = try unpacker.read(i64);
            } else if (std.mem.eql(u8, key, "last_delta")) {
                result.last_delta = try unpacker.read(i32);
            } else if (std.mem.eql(u8, key, "timeouts")) {
                const value = try unpacker.read(i64);
                if (value < 0) return ParseError.ParseFailure;
                result.timeouts = @intCast(value);
            } else if (std.mem.eql(u8, key, "invalid_actions")) {
                const value = try unpacker.read(i64);
                if (value < 0) return ParseError.ParseFailure;
                result.invalid_actions = @intCast(value);
            } else if (std.mem.eql(u8, key, "disconnects")) {
                const value = try unpacker.read(i64);
                if (value < 0) return ParseError.ParseFailure;
                result.disconnects = @intCast(value);
            } else if (std.mem.eql(u8, key, "busts")) {
                const value = try unpacker.read(i64);
                if (value < 0) return ParseError.ParseFailure;
                result.busts = @intCast(value);
            } else if (std.mem.eql(u8, key, "detailed_stats")) {
                result.detailed_stats = try readDetailedStats(allocator, unpacker);
            } else {
                try skipValue(unpacker);
            }
        }
        return result;
    }
};

pub const DecodedMessage = struct {
    msg: IncomingMessage,
    msg_type: []u8,
};

pub fn decodeMessage(allocator: std.mem.Allocator, data: []const u8) !DecodedMessage {
    const msg_type_slice = try detectMessageType(allocator, data) orelse return ParseError.ParseFailure;
    defer allocator.free(msg_type_slice);

    const msg_type_copy = try allocator.dupe(u8, msg_type_slice);
    errdefer allocator.free(msg_type_copy);

    const msg = blk: {
        if (std.mem.eql(u8, msg_type_slice, "hand_start")) {
            break :blk IncomingMessage{ .hand_start = try decodeHandStart(allocator, data) };
        } else if (std.mem.eql(u8, msg_type_slice, "game_start")) {
            break :blk IncomingMessage{ .hand_start = try decodeLegacyGameStart(allocator, data) };
        } else if (std.mem.eql(u8, msg_type_slice, "action_request")) {
            break :blk IncomingMessage{ .action_request = try decodeActionRequest(allocator, data) };
        } else if (std.mem.eql(u8, msg_type_slice, "game_update")) {
            break :blk IncomingMessage{ .game_update = try decodeGameUpdate(allocator, data) };
        } else if (std.mem.eql(u8, msg_type_slice, "player_action")) {
            break :blk IncomingMessage{ .player_action = try decodePlayerAction(allocator, data) };
        } else if (std.mem.eql(u8, msg_type_slice, "street_change")) {
            break :blk IncomingMessage{ .street_change = try decodeStreetChange(allocator, data) };
        } else if (std.mem.eql(u8, msg_type_slice, "hand_result")) {
            break :blk IncomingMessage{ .hand_result = try decodeHandResult(allocator, data) };
        } else if (std.mem.eql(u8, msg_type_slice, "game_completed")) {
            break :blk IncomingMessage{ .game_completed = try decodeGameCompleted(allocator, data) };
        } else if (std.mem.eql(u8, msg_type_slice, "error")) {
            break :blk IncomingMessage{ .error_message = try decodeErrorMessage(allocator, data) };
        } else if (std.mem.eql(u8, msg_type_slice, "hand_complete")) {
            break :blk IncomingMessage.noop; // Legacy summary no longer used
        } else if (!isHandledMessageType(msg_type_slice)) {
            break :blk IncomingMessage.noop;
        } else {
            break :blk IncomingMessage.noop;
        }
    };

    return DecodedMessage{ .msg = msg, .msg_type = msg_type_copy };
}

fn isHandledMessageType(msg_type: []const u8) bool {
    return std.mem.eql(u8, msg_type, "hand_start") or
        std.mem.eql(u8, msg_type, "game_start") or
        std.mem.eql(u8, msg_type, "action_request") or
        std.mem.eql(u8, msg_type, "game_update") or
        std.mem.eql(u8, msg_type, "player_action") or
        std.mem.eql(u8, msg_type, "street_change") or
        std.mem.eql(u8, msg_type, "hand_result") or
        std.mem.eql(u8, msg_type, "game_completed") or
        std.mem.eql(u8, msg_type, "error");
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

fn synthesizeLegalActions(
    allocator: std.mem.Allocator,
    legal_raw: ?[]RawActionDescriptor,
    valid_actions: ?[]ActionType,
    min_bet: u32,
    min_raise: u32,
    to_call: u32,
) ![]ActionDescriptor {
    if (legal_raw) |entries| {
        const legal = try allocator.alloc(ActionDescriptor, entries.len);
        for (entries, 0..) |entry, idx| {
            const action_type = meta.intToEnum(ActionType, entry.action_type) catch return ParseError.ParseFailure;
            legal[idx] = .{
                .action_type = action_type,
                .min_amount = entry.min_amount,
                .max_amount = entry.max_amount,
            };
        }
        return legal;
    }

    const actions = valid_actions orelse return ParseError.ParseFailure;
    const legal = try allocator.alloc(ActionDescriptor, actions.len);
    const min_bet_total = min_bet;
    const min_raise_increment = min_raise;
    const raise_min_total: ?u32 = if (min_bet_total != 0)
        min_bet_total
    else if (min_raise_increment != 0)
        to_call + min_raise_increment
    else
        null;
    for (actions, 0..) |atype, idx| {
        legal[idx] = switch (atype) {
            .fold => .{ .action_type = .fold },
            .check => .{ .action_type = .check },
            .call => .{ .action_type = .call },
            .bet => .{
                .action_type = .bet,
                .min_amount = if (min_bet_total == 0) null else min_bet_total,
                .max_amount = null,
            },
            .raise => .{
                .action_type = .raise,
                .min_amount = raise_min_total,
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

fn decodeHandStart(allocator: std.mem.Allocator, data: []const u8) !HandStart {
    var stream = std.io.fixedBufferStream(data);
    var unpacker = msgpack.unpacker(stream.reader(), allocator);
    const len = try unpacker.readMapHeader(u32);

    var hand_id_slice: ?[]const u8 = null;
    var your_seat: ?u8 = null;
    var button: ?u8 = null;
    var players_raw: ?[]RawPlayer = null;
    var hole_cards_raw: ?[]const u8 = null;
    var small_blind: ?u32 = null;
    var big_blind: ?u32 = null;

    errdefer {
        if (hand_id_slice) |slice| allocator.free(slice);
        if (hole_cards_raw) |cards| allocator.free(@constCast(cards));
        if (players_raw) |players| freeRawPlayers(allocator, players);
    }

    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const key = try unpacker.read([]const u8);
        defer allocator.free(key);
        if (std.mem.eql(u8, key, "hand_id")) {
            hand_id_slice = try unpacker.read([]const u8);
        } else if (std.mem.eql(u8, key, "your_seat")) {
            your_seat = try unpacker.read(u8);
        } else if (std.mem.eql(u8, key, "button")) {
            button = try unpacker.read(u8);
        } else if (std.mem.eql(u8, key, "players")) {
            players_raw = try unpacker.read([]RawPlayer);
        } else if (std.mem.eql(u8, key, "hole_cards")) {
            hole_cards_raw = try readCardIndices(allocator, unpacker);
        } else if (std.mem.eql(u8, key, "small_blind")) {
            small_blind = try unpacker.read(u32);
        } else if (std.mem.eql(u8, key, "big_blind")) {
            big_blind = try unpacker.read(u32);
        } else {
            try skipValue(unpacker);
        }
    }

    const raw_id = hand_id_slice orelse return ParseError.ParseFailure;
    const seat_index = your_seat orelse return ParseError.ParseFailure;
    const btn = button orelse return ParseError.ParseFailure;
    const raw_players = players_raw orelse return ParseError.ParseFailure;
    const cards_buf = hole_cards_raw orelse return ParseError.ParseFailure;
    if (cards_buf.len != 2) return ParseError.ParseFailure;
    defer allocator.free(@constCast(cards_buf));
    const hole_cards = [2]u8{ cards_buf[0], cards_buf[1] };
    hole_cards_raw = null;
    const sb = small_blind orelse return ParseError.ParseFailure;
    const bb = big_blind orelse return ParseError.ParseFailure;

    const players = try convertSeatInfo(allocator, raw_players);
    freeRawPlayers(allocator, raw_players);
    players_raw = null;

    const hand_id = @constCast(raw_id);
    hand_id_slice = null;

    return HandStart{
        .hand_id = hand_id,
        .your_seat = seat_index,
        .button = btn,
        .hole_cards = hole_cards,
        .small_blind = sb,
        .big_blind = bb,
        .players = players,
    };
}

fn decodeLegacyGameStart(allocator: std.mem.Allocator, data: []const u8) !HandStart {
    var stream = std.io.fixedBufferStream(data);
    var unpacker = msgpack.unpacker(stream.reader(), allocator);
    const len = try unpacker.readMapHeader(u32);

    var game_id_slice: ?[]const u8 = null;
    var player_index: ?u8 = null;
    var button: ?u8 = null;
    var players_raw: ?[]RawPlayer = null;
    var stack_sizes: ?[]const u32 = null;
    var hole_cards_raw: ?[]const u8 = null;
    var small_blind: ?u32 = null;
    var big_blind: ?u32 = null;

    errdefer {
        if (game_id_slice) |slice| allocator.free(slice);
        if (stack_sizes) |slice| allocator.free(@constCast(slice));
        if (hole_cards_raw) |cards| allocator.free(@constCast(cards));
        if (players_raw) |players| freeRawPlayers(allocator, players);
    }

    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const key = try unpacker.read([]const u8);
        defer allocator.free(key);
        if (std.mem.eql(u8, key, "game_id")) {
            game_id_slice = try unpacker.read([]const u8);
        } else if (std.mem.eql(u8, key, "player_index")) {
            player_index = try unpacker.read(u8);
        } else if (std.mem.eql(u8, key, "button")) {
            button = try unpacker.read(u8);
        } else if (std.mem.eql(u8, key, "players")) {
            players_raw = try unpacker.read([]RawPlayer);
        } else if (std.mem.eql(u8, key, "stack_sizes")) {
            stack_sizes = try unpacker.read([]const u32);
        } else if (std.mem.eql(u8, key, "hole_cards")) {
            hole_cards_raw = try readCardIndices(allocator, unpacker);
        } else if (std.mem.eql(u8, key, "small_blind")) {
            small_blind = try unpacker.read(u32);
        } else if (std.mem.eql(u8, key, "big_blind")) {
            big_blind = try unpacker.read(u32);
        } else {
            try skipValue(unpacker);
        }
    }

    const base_id = game_id_slice orelse return ParseError.ParseFailure;
    const seat_index = player_index orelse return ParseError.ParseFailure;
    const btn = button orelse return ParseError.ParseFailure;

    var seat_infos: []SeatInfo = &[_]SeatInfo{};
    if (players_raw) |raw_players| {
        seat_infos = try convertSeatInfo(allocator, raw_players);
        freeRawPlayers(allocator, raw_players);
        players_raw = null;
    } else if (stack_sizes) |stacks| {
        seat_infos = try allocator.alloc(SeatInfo, stacks.len);
        for (seat_infos, 0..) |*seat, idx| {
            seat.* = .{ .seat = @intCast(idx), .name = try allocator.dupe(u8, ""), .chips = stacks[idx] };
        }
        allocator.free(@constCast(stacks));
        stack_sizes = null;
    }

    const cards_buf = hole_cards_raw orelse return ParseError.ParseFailure;
    if (cards_buf.len != 2) return ParseError.ParseFailure;
    defer allocator.free(@constCast(cards_buf));
    const hole_cards = [2]u8{ cards_buf[0], cards_buf[1] };
    hole_cards_raw = null;
    const sb = small_blind orelse return ParseError.ParseFailure;
    const bb = big_blind orelse return ParseError.ParseFailure;

    const hand_id = @constCast(base_id);
    game_id_slice = null;

    return HandStart{
        .hand_id = hand_id,
        .your_seat = seat_index,
        .button = btn,
        .hole_cards = hole_cards,
        .small_blind = sb,
        .big_blind = bb,
        .players = seat_infos,
    };
}

fn decodeActionRequest(allocator: std.mem.Allocator, data: []const u8) !ActionRequest {
    var stream = std.io.fixedBufferStream(data);
    var unpacker = msgpack.unpacker(stream.reader(), allocator);
    const len = try unpacker.readMapHeader(u32);

    var hand_id_slice: ?[]const u8 = null;
    var pot: ?u32 = null;
    var to_call: ?u32 = null;
    var legal_actions_raw: ?[]RawActionDescriptor = null;
    var valid_actions_raw: ?[]ActionType = null;
    var min_bet: ?u32 = null;
    var min_raise: ?u32 = null;
    var time_remaining: ?u32 = null;

    errdefer {
        if (hand_id_slice) |slice| allocator.free(slice);
        if (legal_actions_raw) |entries| allocator.free(entries);
        if (valid_actions_raw) |entries| allocator.free(entries);
    }

    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const key = try unpacker.read([]const u8);
        defer allocator.free(key);
        if (std.mem.eql(u8, key, "hand_id")) {
            hand_id_slice = try unpacker.read([]const u8);
        } else if (std.mem.eql(u8, key, "pot")) {
            pot = try unpacker.read(u32);
        } else if (std.mem.eql(u8, key, "to_call")) {
            to_call = try unpacker.read(u32);
        } else if (std.mem.eql(u8, key, "legal_actions")) {
            legal_actions_raw = try unpacker.read([]RawActionDescriptor);
        } else if (std.mem.eql(u8, key, "valid_actions")) {
            valid_actions_raw = try readActionTypeArray(allocator, unpacker);
        } else if (std.mem.eql(u8, key, "min_bet")) {
            min_bet = try unpacker.read(u32);
        } else if (std.mem.eql(u8, key, "min_raise")) {
            min_raise = try unpacker.read(u32);
        } else if (std.mem.eql(u8, key, "time_remaining")) {
            time_remaining = try unpacker.read(u32);
        } else {
            try skipValue(unpacker);
        }
    }

    const hand_id_slice_val = hand_id_slice orelse return ParseError.ParseFailure;
    const pot_value = pot orelse return ParseError.ParseFailure;
    const to_call_value = to_call orelse return ParseError.ParseFailure;
    const min_bet_value = min_bet orelse return ParseError.ParseFailure;
    const min_raise_value = min_raise orelse return ParseError.ParseFailure;
    const time_remaining_ms = time_remaining orelse return ParseError.ParseFailure;

    const actions = try synthesizeLegalActions(allocator, legal_actions_raw, valid_actions_raw, min_bet_value, min_raise_value, to_call_value);
    if (legal_actions_raw) |entries| allocator.free(entries);
    if (valid_actions_raw) |entries| allocator.free(entries);
    legal_actions_raw = null;
    valid_actions_raw = null;

    const hand_id = @constCast(hand_id_slice_val);
    hand_id_slice = null;

    return ActionRequest{
        .hand_id = hand_id,
        .pot = pot_value,
        .to_call = to_call_value,
        .legal_actions = actions,
        .min_bet = min_bet_value,
        .min_raise = min_raise_value,
        .time_remaining_ms = time_remaining_ms,
    };
}

fn decodeGameUpdate(allocator: std.mem.Allocator, data: []const u8) !GameUpdate {
    var stream = std.io.fixedBufferStream(data);
    var unpacker = msgpack.unpacker(stream.reader(), allocator);
    const len = try unpacker.readMapHeader(u32);

    var hand_id_slice: ?[]const u8 = null;
    var pot: ?u32 = null;
    var players_raw: ?[]RawPlayer = null;

    errdefer {
        if (hand_id_slice) |slice| allocator.free(slice);
        if (players_raw) |players| freeRawPlayers(allocator, players);
    }

    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const key = try unpacker.read([]const u8);
        defer allocator.free(key);
        if (std.mem.eql(u8, key, "hand_id")) {
            hand_id_slice = try unpacker.read([]const u8);
        } else if (std.mem.eql(u8, key, "pot")) {
            pot = try unpacker.read(u32);
        } else if (std.mem.eql(u8, key, "players")) {
            players_raw = try unpacker.read([]RawPlayer);
        } else {
            try skipValue(unpacker);
        }
    }

    const hand_id_slice_val = hand_id_slice orelse return ParseError.ParseFailure;
    const pot_value = pot orelse return ParseError.ParseFailure;
    const raw_players = players_raw orelse return ParseError.ParseFailure;

    const players = try convertPlayerStates(allocator, raw_players);
    freeRawPlayers(allocator, raw_players);
    players_raw = null;

    const hand_id = @constCast(hand_id_slice_val);
    hand_id_slice = null;

    return GameUpdate{
        .hand_id = hand_id,
        .pot = pot_value,
        .players = players,
    };
}

fn decodePlayerAction(allocator: std.mem.Allocator, data: []const u8) !PlayerAction {
    var stream = std.io.fixedBufferStream(data);
    var unpacker = msgpack.unpacker(stream.reader(), allocator);
    const len = try unpacker.readMapHeader(u32);

    var hand_id_slice: ?[]const u8 = null;
    var street_slice: ?[]const u8 = null;
    var player_name_slice: ?[]const u8 = null;
    var action_slice: ?[]const u8 = null;
    var seat: ?u8 = null;
    var amount_paid: ?i32 = null;
    var player_bet: ?u32 = null;
    var player_chips: ?u32 = null;
    var pot: ?u32 = null;

    errdefer {
        if (hand_id_slice) |slice| allocator.free(slice);
        if (street_slice) |slice| allocator.free(slice);
        if (player_name_slice) |slice| allocator.free(slice);
        if (action_slice) |slice| allocator.free(slice);
    }

    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const key = try unpacker.read([]const u8);
        defer allocator.free(key);
        if (std.mem.eql(u8, key, "hand_id")) {
            hand_id_slice = try unpacker.read([]const u8);
        } else if (std.mem.eql(u8, key, "street")) {
            street_slice = try unpacker.read([]const u8);
        } else if (std.mem.eql(u8, key, "player_name")) {
            player_name_slice = try unpacker.read([]const u8);
        } else if (std.mem.eql(u8, key, "action")) {
            action_slice = try unpacker.read([]const u8);
        } else if (std.mem.eql(u8, key, "seat")) {
            seat = try unpacker.read(u8);
        } else if (std.mem.eql(u8, key, "amount_paid")) {
            amount_paid = try unpacker.read(i32);
        } else if (std.mem.eql(u8, key, "player_bet")) {
            player_bet = try unpacker.read(u32);
        } else if (std.mem.eql(u8, key, "player_chips")) {
            player_chips = try unpacker.read(u32);
        } else if (std.mem.eql(u8, key, "pot")) {
            pot = try unpacker.read(u32);
        } else {
            try skipValue(unpacker);
        }
    }

    const hand_id = hand_id_slice orelse return ParseError.ParseFailure;
    const street = street_slice orelse return ParseError.ParseFailure;
    const player_name = player_name_slice orelse return ParseError.ParseFailure;
    const action = action_slice orelse return ParseError.ParseFailure;
    const seat_value = seat orelse return ParseError.ParseFailure;
    const amount_paid_value = amount_paid orelse return ParseError.ParseFailure;
    const player_bet_value = player_bet orelse return ParseError.ParseFailure;
    const player_chips_value = player_chips orelse return ParseError.ParseFailure;
    const pot_value = pot orelse return ParseError.ParseFailure;

    const result = PlayerAction{
        .hand_id = @constCast(hand_id),
        .street = @constCast(street),
        .seat = seat_value,
        .player_name = @constCast(player_name),
        .action = @constCast(action),
        .amount_paid = amount_paid_value,
        .player_bet = player_bet_value,
        .player_chips = player_chips_value,
        .pot = pot_value,
    };

    hand_id_slice = null;
    street_slice = null;
    player_name_slice = null;
    action_slice = null;

    return result;
}

fn decodeStreetChange(allocator: std.mem.Allocator, data: []const u8) !StreetChange {
    var stream = std.io.fixedBufferStream(data);
    var unpacker = msgpack.unpacker(stream.reader(), allocator);
    const len = try unpacker.readMapHeader(u32);

    var hand_id_slice: ?[]const u8 = null;
    var street_slice: ?[]const u8 = null;
    var board_cards: ?[]const u8 = null;

    errdefer {
        if (hand_id_slice) |slice| allocator.free(slice);
        if (street_slice) |slice| allocator.free(slice);
        if (board_cards) |cards| allocator.free(@constCast(cards));
    }

    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const key = try unpacker.read([]const u8);
        defer allocator.free(key);
        if (std.mem.eql(u8, key, "hand_id")) {
            hand_id_slice = try unpacker.read([]const u8);
        } else if (std.mem.eql(u8, key, "street")) {
            street_slice = try unpacker.read([]const u8);
        } else if (std.mem.eql(u8, key, "board")) {
            board_cards = try readCardIndices(allocator, unpacker);
        } else {
            try skipValue(unpacker);
        }
    }

    const hand_id = @constCast(hand_id_slice orelse return ParseError.ParseFailure);
    hand_id_slice = null;
    const street = @constCast(street_slice orelse return ParseError.ParseFailure);
    street_slice = null;

    const board = if (board_cards) |cards| blk: {
        const dup = try allocator.dupe(u8, cards);
        allocator.free(@constCast(cards));
        board_cards = null;
        break :blk dup;
    } else try allocator.alloc(u8, 0);

    return StreetChange{
        .hand_id = hand_id,
        .street = street,
        .board = board,
    };
}

fn decodeHandResult(allocator: std.mem.Allocator, data: []const u8) !HandResult {
    var stream = std.io.fixedBufferStream(data);
    var unpacker = msgpack.unpacker(stream.reader(), allocator);
    const len = try unpacker.readMapHeader(u32);

    var hand_id_slice: ?[]const u8 = null;
    var board_cards: ?[]const u8 = null;
    var winners_raw: ?[]RawWinner = null;
    var showdown_raw: ?[]RawShowdownHand = null;

    errdefer {
        if (hand_id_slice) |slice| allocator.free(slice);
        if (board_cards) |cards| allocator.free(@constCast(cards));
        if (winners_raw) |entries| freeRawWinners(allocator, entries);
        if (showdown_raw) |entries| freeRawShowdownHands(allocator, entries);
    }

    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const key = try unpacker.read([]const u8);
        defer allocator.free(key);
        if (std.mem.eql(u8, key, "hand_id")) {
            hand_id_slice = try unpacker.read([]const u8);
        } else if (std.mem.eql(u8, key, "board")) {
            board_cards = try readCardIndices(allocator, unpacker);
        } else if (std.mem.eql(u8, key, "winners")) {
            winners_raw = try unpacker.read([]RawWinner);
        } else if (std.mem.eql(u8, key, "showdown")) {
            showdown_raw = try unpacker.read([]RawShowdownHand);
        } else {
            try skipValue(unpacker);
        }
    }

    const hand_id = @constCast(hand_id_slice orelse return ParseError.ParseFailure);
    hand_id_slice = null;

    const board = if (board_cards) |cards| blk: {
        const dup = try allocator.dupe(u8, cards);
        allocator.free(@constCast(cards));
        board_cards = null;
        break :blk dup;
    } else try allocator.alloc(u8, 0);

    const winners = if (winners_raw) |entries| blk: {
        defer freeRawWinners(allocator, entries);
        winners_raw = null;
        break :blk try convertWinners(allocator, entries);
    } else try allocator.alloc(Winner, 0);

    const showdown = if (showdown_raw) |entries| blk: {
        defer freeRawShowdownHands(allocator, entries);
        showdown_raw = null;
        break :blk try convertShowdownHands(allocator, entries);
    } else try allocator.alloc(ShowdownHand, 0);

    return HandResult{
        .hand_id = hand_id,
        .board = board,
        .winners = winners,
        .showdown = showdown,
    };
}

fn decodeGameCompleted(allocator: std.mem.Allocator, data: []const u8) !GameCompleted {
    var stream = std.io.fixedBufferStream(data);
    var unpacker = msgpack.unpacker(stream.reader(), allocator);
    const len = try unpacker.readMapHeader(u32);

    var game_id_slice: ?[]const u8 = null;
    var hands_completed: ?u64 = null;
    var hand_limit: ?u64 = null;
    var reason_slice: ?[]const u8 = null;
    var seed: ?i64 = null;
    var players_raw: ?[]RawGameCompletedPlayer = null;

    errdefer {
        if (game_id_slice) |slice| allocator.free(slice);
        if (reason_slice) |slice| allocator.free(slice);
        if (players_raw) |players| freeRawGameCompletedPlayers(allocator, players);
    }

    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const key = try unpacker.read([]const u8);
        defer allocator.free(key);
        if (std.mem.eql(u8, key, "game_id")) {
            game_id_slice = try unpacker.read([]const u8);
        } else if (std.mem.eql(u8, key, "hands_completed")) {
            hands_completed = try unpacker.read(u64);
        } else if (std.mem.eql(u8, key, "hand_limit")) {
            hand_limit = try unpacker.read(u64);
        } else if (std.mem.eql(u8, key, "reason")) {
            reason_slice = try unpacker.read([]const u8);
        } else if (std.mem.eql(u8, key, "seed")) {
            seed = try unpacker.read(i64);
        } else if (std.mem.eql(u8, key, "players")) {
            players_raw = try unpacker.read([]RawGameCompletedPlayer);
        } else {
            try skipValue(unpacker);
        }
    }

    const game_id = @constCast(game_id_slice orelse return ParseError.ParseFailure);
    game_id_slice = null;
    const hands_completed_value = hands_completed orelse return ParseError.ParseFailure;
    const hand_limit_value = hand_limit orelse return ParseError.ParseFailure;
    const reason_slice_val = reason_slice orelse return ParseError.ParseFailure;
    const reason = blk: {
        const dup = try allocator.dupe(u8, reason_slice_val);
        allocator.free(reason_slice_val);
        reason_slice = null;
        break :blk dup;
    };

    const players = if (players_raw) |entries| blk: {
        defer freeRawGameCompletedPlayers(allocator, entries);
        players_raw = null;
        break :blk try convertCompletedPlayers(allocator, entries);
    } else try allocator.alloc(GameCompletedPlayer, 0);

    return GameCompleted{
        .game_id = game_id,
        .hands_completed = hands_completed_value,
        .hand_limit = hand_limit_value,
        .reason = reason,
        .seed = seed,
        .players = players,
    };
}

fn decodeErrorMessage(allocator: std.mem.Allocator, data: []const u8) !ErrorMessage {
    var stream = std.io.fixedBufferStream(data);
    var unpacker = msgpack.unpacker(stream.reader(), allocator);
    const len = try unpacker.readMapHeader(u32);

    var code_slice: ?[]const u8 = null;
    var message_slice: ?[]const u8 = null;

    errdefer {
        if (code_slice) |slice| allocator.free(slice);
        if (message_slice) |slice| allocator.free(slice);
    }

    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const key = try unpacker.read([]const u8);
        defer allocator.free(key);
        if (std.mem.eql(u8, key, "code")) {
            code_slice = try unpacker.read([]const u8);
        } else if (std.mem.eql(u8, key, "message")) {
            message_slice = try unpacker.read([]const u8);
        } else {
            try skipValue(unpacker);
        }
    }

    const code_buf = code_slice orelse return ParseError.ParseFailure;
    const msg_buf = message_slice orelse blk: {
        const dup = try allocator.dupe(u8, "");
        message_slice = dup;
        break :blk dup;
    };

    const result = ErrorMessage{
        .code = @constCast(code_buf),
        .message = @constCast(msg_buf),
    };
    code_slice = null;
    message_slice = null;
    return result;
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

test "synthesizeLegalActions uses min_bet for raise minimum" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var actions = try allocator.alloc(ActionType, 3);
    defer allocator.free(actions);
    actions[0] = .fold;
    actions[1] = .call;
    actions[2] = .raise;

    const legal = try synthesizeLegalActions(allocator, null, actions, 20, 10, 5);
    defer allocator.free(legal);

    try std.testing.expectEqual(@as(usize, 3), legal.len);
    try std.testing.expectEqual(ActionType.raise, legal[2].action_type);
    try std.testing.expect(legal[2].min_amount != null);
    try std.testing.expectEqual(@as(u32, 20), legal[2].min_amount.?);
}
