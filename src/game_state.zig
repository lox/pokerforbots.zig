const std = @import("std");
const protocol = @import("protocol.zig");

pub const ActionType = protocol.ActionType;

pub const Street = enum(u3) {
    preflop,
    flop,
    turn,
    river,
};

/// Tracks current betting state for decision-making.
///
/// All chip amounts use i64 (signed) to simplify delta calculations and
/// prevent underflow when computing raise amounts and bet differences.
/// Chip values are never negative in practice but signed arithmetic
/// makes the math cleaner and safer.
pub const BettingState = struct {
    /// Current pot size in cents
    pot_cents: i64,
    /// Amount to call in cents (0 = no bet to call)
    to_call_cents: i64,
    /// Most recent raise delta in cents (increase from previous bet)
    last_raise_delta_cents: i64,
    /// Pot size before the most recent raise
    pot_before_last_raise_cents: i64,
    /// Price to call before the most recent raise
    to_call_before_last_raise_cents: i64,
    /// Street where this state applies
    street: Street,

    /// Ratio between the price to call and the current pot.
    /// Returns 0.0 if pot is empty or non-positive.
    /// Example: pot=100, to_call=50 -> ratio=0.5 (getting 2:1 pot odds)
    pub fn callRatio(self: BettingState) f64 {
        if (self.pot_cents <= 0) return 0.0;
        return @as(f64, @floatFromInt(self.to_call_cents)) / @as(f64, @floatFromInt(self.pot_cents));
    }

    /// Total chips needed to satisfy a minimum raise.
    pub fn minRaiseTotal(self: BettingState) i64 {
        return self.to_call_cents + self.last_raise_delta_cents;
    }
};

pub const PlayerInfo = struct {
    seat: u8,
    name: []const u8,
    chips: u32,
    bet: u32,
    folded: bool,
    all_in: bool,
};

pub const HistoricalAction = struct {
    street: Street,
    seat: u8,
    action: ActionType,
    amount: u32,
    is_hero: bool,
};

const HistorySource = enum {
    player_action,
    hero_action,
};

var history_debug_enabled = false;

pub fn setHistoryDebug(enabled: bool) void {
    history_debug_enabled = enabled;
}

const ActionKind = enum {
    fold,
    timeout_fold,
    check,
    call,
    bet,
    raise,
    allin,
    post_small_blind,
    post_big_blind,
    unknown,
};

pub const GameState = struct {
    allocator: std.mem.Allocator,
    hand_id: []u8 = &[_]u8{},
    hero_seat: u8 = 0,
    button: u8 = 0,
    small_blind: u32 = 0,
    big_blind: u32 = 0,
    hole_cards: ?[2]u8 = null,
    street: Street = .preflop,
    pot: u32 = 0,
    to_call: u32 = 0,
    board: []u8 = &[_]u8{},
    players: []PlayerInfo = &[_]PlayerInfo{},
    history: std.ArrayListUnmanaged(HistoricalAction) = .{},
    active_players: std.ArrayListUnmanaged(PlayerInfo) = .{},
    active_mask: u64 = 0,
    street_max_bet: u32 = 0,
    raise_count: u8 = 0,
    pending_hero_actions: usize = 0,
    hero_index: ?usize = null,
    hand_active: bool = false,
    betting_state: ?BettingState = null,

    pub fn init(allocator: std.mem.Allocator) GameState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GameState) void {
        self.reset();
        self.history.deinit(self.allocator);
        self.active_players.deinit(self.allocator);
    }

    pub fn reset(self: *GameState) void {
        self.freeHandId();
        self.freeBoard();
        self.freePlayers();
        self.history.clearRetainingCapacity();
        self.active_players.clearRetainingCapacity();
        self.hand_id = &[_]u8{};
        self.board = &[_]u8{};
        self.players = &[_]PlayerInfo{};
        self.active_mask = 0;
        self.street = .preflop;
        self.street_max_bet = 0;
        self.raise_count = 0;
        self.pot = 0;
        self.to_call = 0;
        self.pending_hero_actions = 0;
        self.hero_index = null;
        self.hole_cards = null;
        self.betting_state = null;
        self.hand_active = false;
    }

    pub fn onHandStart(self: *GameState, start: protocol.HandStart) !void {
        self.reset();
        self.hand_id = try self.allocator.dupe(u8, start.hand_id);
        self.hero_seat = start.your_seat;
        self.button = start.button;
        self.small_blind = start.small_blind;
        self.big_blind = start.big_blind;
        self.hole_cards = start.hole_cards;
        self.street = .preflop;
        self.pot = 0;
        self.to_call = 0;
        self.street_max_bet = 0;
        self.raise_count = 0;
        self.pending_hero_actions = 0;
        const blinds_total = @as(u64, start.small_blind) + @as(u64, start.big_blind);
        self.betting_state = BettingState{
            .pot_cents = @as(i64, @intCast(blinds_total)),
            .to_call_cents = @as(i64, @intCast(start.big_blind)),
            .last_raise_delta_cents = @as(i64, @intCast(start.big_blind)),
            .pot_before_last_raise_cents = @as(i64, @intCast(blinds_total)),
            .to_call_before_last_raise_cents = @as(i64, @intCast(start.big_blind)),
            .street = .preflop,
        };

        if (start.players.len == 0) {
            self.players = &[_]PlayerInfo{};
            self.active_mask = 0;
            self.hero_index = null;
            return;
        }

        const storage = try self.allocator.alloc(PlayerInfo, start.players.len);
        var populated: usize = 0;
        errdefer {
            var idx: usize = 0;
            while (idx < populated) : (idx += 1) {
                self.allocator.free(storage[idx].name);
            }
            self.allocator.free(storage);
        }

        for (start.players, 0..) |seat_info, idx| {
            const name_copy = try self.allocator.dupe(u8, seat_info.name);
            storage[idx] = PlayerInfo{
                .seat = seat_info.seat,
                .name = name_copy,
                .chips = seat_info.chips,
                .bet = 0,
                .folded = false,
                .all_in = false,
            };
            populated = idx + 1;
            if (seat_info.seat == self.hero_seat) {
                self.hero_index = idx;
            }
        }
        self.players = storage;
        self.active_mask = if (storage.len >= 64)
            std.math.maxInt(u64)
        else if (storage.len == 0)
            0
        else
            (@as(u64, 1) << @intCast(storage.len)) - 1;
        try self.rebuildActivePlayers();
        self.hand_active = true;
    }

    pub fn onActionRequest(self: *GameState, request: protocol.ActionRequest) void {
        self.pot = request.pot;
        self.to_call = request.to_call;
        var state = self.ensureBettingState();
        const hero_contribution: u32 = if (self.hero_index) |idx| self.players[idx].bet else 0;
        const prev_max_total: u32 = self.street_max_bet;
        const prev_outstanding: u32 = if (prev_max_total > hero_contribution)
            prev_max_total - hero_contribution
        else
            0;
        state.pot_cents = @as(i64, @intCast(request.pot));
        state.to_call_cents = @as(i64, @intCast(request.to_call));
        state.street = self.street;
        if (state.to_call_cents > 0) {
            const max_total_u64 = @as(u64, hero_contribution) + @as(u64, request.to_call);
            const clamped_total: u32 = if (max_total_u64 > @as(u64, std.math.maxInt(u32)))
                std.math.maxInt(u32)
            else
                @intCast(max_total_u64);
            const new_total: i64 = @intCast(clamped_total);
            const prev_total: i64 = @intCast(prev_max_total);
            const delta = new_total - prev_total;
            if (delta > 0) {
                // Estimate pre-raise pot so downstream pot-odds math stays accurate.
                const pot_before = state.pot_cents - state.to_call_cents;
                state.pot_before_last_raise_cents = if (pot_before > 0) pot_before else 0;
                state.to_call_before_last_raise_cents = @as(i64, @intCast(prev_outstanding));
                state.last_raise_delta_cents = delta;
                if (clamped_total > self.street_max_bet) {
                    self.street_max_bet = clamped_total;
                }
            }
        }
    }

    pub fn onGameUpdate(self: *GameState, update: protocol.GameUpdate) void {
        const prev_pot = self.pot;
        const prev_max = self.street_max_bet;
        self.pot = update.pot;

        var new_max: u32 = 0;
        for (update.players) |player_state| {
            new_max = @max(new_max, player_state.bet);
            if (self.findPlayerByName(player_state.name)) |info| {
                info.chips = player_state.chips;
                info.bet = player_state.bet;
                info.folded = player_state.folded;
                info.all_in = player_state.all_in;
            }
        }

        self.syncBettingStateSnapshot(prev_pot, update.pot, prev_max, new_max);
        self.street_max_bet = new_max;
    }

    pub fn onPlayerAction(self: *GameState, action: protocol.PlayerAction) !void {
        const street = try parseStreet(action.street);
        self.street = street;
        self.pot = action.pot;
        const prev_max_bet = self.street_max_bet;

        const seat_idx = self.findPlayerIndex(action.seat) orelse return;
        var info = &self.players[seat_idx];

        const kind = classifyAction(action.action);
        info.bet = action.player_bet;
        info.chips = action.player_chips;
        if (kind == .allin or action.player_chips == 0) {
            info.all_in = true;
        }

        self.street_max_bet = @max(self.street_max_bet, action.player_bet);
        self.updateBettingStateFromPlayerAction(kind, action, prev_max_bet);

        var fold_state_changed = false;
        if (kind == .fold or kind == .timeout_fold) {
            if (!info.folded) {
                info.folded = true;
                fold_state_changed = true;
            }
        }

        const hero_idx = self.hero_index;
        const is_hero = if (hero_idx) |idx| idx == seat_idx else false;

        var should_record = !isBlind(kind);
        if (is_hero and self.pending_hero_actions > 0) {
            self.pending_hero_actions -= 1;
            should_record = false;
        }

        if (should_record) {
            if (actionTypeForKind(kind)) |atype| {
                const entry = HistoricalAction{
                    .street = street,
                    .seat = action.seat,
                    .action = atype,
                    .amount = amountForKind(kind, action.amount_paid),
                    .is_hero = is_hero,
                };
                self.appendHistory(entry, .player_action);
                if (atype == .bet or atype == .raise or atype == .allin) {
                    self.incrementRaiseDepth();
                }
                if (atype == .fold) {
                    fold_state_changed = true;
                }
            }
        }

        if (fold_state_changed) {
            self.clearActiveBit(seat_idx);
            try self.rebuildActivePlayers();
        }
    }

    pub fn onStreetChange(self: *GameState, change: protocol.StreetChange) !void {
        self.street = try parseStreet(change.street);
        self.raise_count = 0;
        self.street_max_bet = 0;
        self.to_call = 0;
        self.pending_hero_actions = 0;

        const board_copy = try self.allocator.dupe(u8, change.board);
        self.freeBoard();
        self.board = board_copy;

        for (self.players) |*player| {
            player.bet = 0;
        }
        self.resetBettingStateForNewStreet();
    }

    pub fn onHandResult(self: *GameState, result: protocol.HandResult) !void {
        const board_copy = try self.allocator.dupe(u8, result.board);
        self.freeBoard();
        self.board = board_copy;
    }

    pub fn recordHeroAction(
        self: *GameState,
        action: protocol.OutgoingAction,
        request: protocol.ActionRequest,
    ) !void {
        const idx = self.hero_index orelse return;
        var info = &self.players[idx];
        const prev_max_bet = self.street_max_bet;

        // The amount recorded in history represents the incremental chips
        // committed by hero as part of this decision. Calls only add chips
        // when there is something to call, whereas bets/raises/all-ins store
        // the final total contribution for the street (mirroring the protocol
        // snapshot fields used by downstream abstractions).
        const amount = switch (action.action_type) {
            .call => if (request.to_call == 0) 0 else request.to_call,
            .bet, .raise, .allin => action.amount orelse 0,
            else => 0,
        };

        const entry = HistoricalAction{
            .street = self.street,
            .seat = info.seat,
            .action = action.action_type,
            .amount = amount,
            .is_hero = true,
        };
        self.appendHistory(entry, .hero_action);

        switch (action.action_type) {
            .fold => {
                info.folded = true;
                self.clearActiveBit(idx);
                try self.rebuildActivePlayers();
            },
            .check => {},
            .call => {
                if (request.to_call > 0) {
                    info.bet += request.to_call;
                    self.street_max_bet = @max(self.street_max_bet, info.bet);
                    decreaseChips(info, request.to_call);
                    self.pot += request.to_call;
                }
            },
            .bet, .raise => {
                const target = action.amount orelse info.bet;
                if (target > info.bet) {
                    decreaseChips(info, target - info.bet);
                    self.pot += target - info.bet;
                }
                info.bet = target;
                self.street_max_bet = @max(self.street_max_bet, info.bet);
                self.incrementRaiseDepth();
            },
            .allin => {
                const target = action.amount orelse info.bet;
                if (target > info.bet) {
                    decreaseChips(info, target - info.bet);
                    self.pot += target - info.bet;
                }
                info.bet = target;
                info.all_in = true;
                info.chips = 0;
                self.street_max_bet = @max(self.street_max_bet, info.bet);
                self.incrementRaiseDepth();
            },
        }

        self.updateBettingStateAfterHeroAction(action.action_type, prev_max_bet, info.bet);
        self.pending_hero_actions += 1;
    }

    pub fn activePlayers(self: *const GameState) []const PlayerInfo {
        return self.active_players.items;
    }

    pub fn playerCount(self: *const GameState) u8 {
        return @intCast(self.active_players.items.len);
    }

    pub fn raiseDepth(self: *const GameState) u8 {
        return self.raise_count;
    }

    pub fn lastAggressor(self: *const GameState) ?PlayerInfo {
        if (self.history.items.len == 0) return null;
        var idx: usize = self.history.items.len;
        while (idx > 0) {
            idx -= 1;
            const entry = self.history.items[idx];
            switch (entry.action) {
                .bet, .raise, .allin => {
                    if (self.findPlayer(entry.seat)) |player| {
                        return player.*;
                    }
                },
                else => continue,
            }
        }
        return null;
    }

    pub fn seatToButton(self: *const GameState, seat: u8) u8 {
        if (self.players.len == 0) return 0;
        const seat_idx = self.findPlayerIndex(seat) orelse return 0;
        const button_idx = self.findPlayerIndex(self.button) orelse return 0;
        const total: usize = self.players.len;
        if (total == 0) return 0;
        return @intCast((seat_idx + total - button_idx) % total);
    }

    pub fn heroStack(self: *const GameState) ?u32 {
        if (self.hero_index) |idx| {
            return self.players[idx].chips;
        }
        return null;
    }

    fn findPlayerIndex(self: *const GameState, seat: u8) ?usize {
        for (self.players, 0..) |player, idx| {
            if (player.seat == seat) return idx;
        }
        return null;
    }

    fn findPlayer(self: *const GameState, seat: u8) ?*const PlayerInfo {
        for (self.players) |*player| {
            if (player.seat == seat) return player;
        }
        return null;
    }

    fn findPlayerByName(self: *GameState, name: []const u8) ?*PlayerInfo {
        for (self.players) |*player| {
            if (std.mem.eql(u8, player.name, name)) return player;
        }
        return null;
    }

    fn clearActiveBit(self: *GameState, idx: usize) void {
        if (idx < 64) {
            self.active_mask &= ~(@as(u64, 1) << @intCast(idx));
        }
    }

    fn rebuildActivePlayers(self: *GameState) !void {
        self.active_players.clearRetainingCapacity();
        try self.active_players.ensureTotalCapacityPrecise(self.allocator, self.players.len);
        self.active_mask = 0;
        for (self.players, 0..) |player, idx| {
            if (!player.folded) {
                try self.active_players.append(self.allocator, player);
                if (idx < 64) {
                    self.active_mask |= (@as(u64, 1) << @intCast(idx));
                }
            }
        }
    }

    fn appendHistory(self: *GameState, entry: HistoricalAction, source: HistorySource) void {
        self.history.append(self.allocator, entry) catch {
            if (history_debug_enabled) {
                std.debug.print(
                    "GameState history append failed (source={s})\n",
                    .{@tagName(source)},
                );
            }
            return;
        };
        if (history_debug_enabled) {
            const len = self.history.items.len;
            const idx = if (len == 0) 0 else len - 1;
            std.debug.print(
                "GameState history[{d}] source={s} seat={d} action={s} amount={d} hero={s} size={d}\n",
                .{
                    idx,
                    @tagName(source),
                    entry.seat,
                    @tagName(entry.action),
                    entry.amount,
                    if (entry.is_hero) "true" else "false",
                    len,
                },
            );
        }
    }

    fn incrementRaiseDepth(self: *GameState) void {
        if (self.raise_count < std.math.maxInt(u8)) {
            self.raise_count += 1;
        }
    }

    fn decreaseChips(player: *PlayerInfo, amount: u32) void {
        if (amount == 0) return;
        if (player.chips > amount) {
            player.chips -= amount;
        } else {
            player.chips = 0;
        }
    }

    /// Returns a pointer to the BettingState, initializing it with defaults if needed.
    ///
    /// In normal operation, onHandStart() should initialize betting_state with blinds.
    /// This fallback exists for robustness but should rarely trigger in practice.
    /// Lazily create betting state. onHandStart() must have been called first.
    fn ensureBettingState(self: *GameState) *BettingState {
        // Allow zero-player test doubles but ensure real hands call onHandStart() first.
        std.debug.assert(self.hand_active or self.betting_state != null or self.players.len == 0);
        if (self.betting_state) |*state| {
            return state;
        }
        // Debug mode: verify initialization order. In production, we lazily initialize
        // to handle edge cases gracefully (e.g., partial snapshot recovery).
        std.debug.assert(self.players.len > 0); // onHandStart should have been called
        self.betting_state = BettingState{
            .pot_cents = @as(i64, @intCast(self.pot)),
            .to_call_cents = @as(i64, @intCast(self.to_call)),
            .last_raise_delta_cents = 0,
            .pot_before_last_raise_cents = @as(i64, @intCast(self.pot)),
            .to_call_before_last_raise_cents = @as(i64, @intCast(self.to_call)),
            .street = self.street,
        };
        return &self.betting_state.?;
    }

    fn syncBettingStateSnapshot(
        self: *GameState,
        prev_pot: u32,
        new_pot: u32,
        prev_max_bet: u32,
        new_max_bet: u32,
    ) void {
        var state = self.ensureBettingState();
        const prev_pot_cents = state.pot_cents;
        const prev_to_call = state.to_call_cents;
        state.pot_cents = @as(i64, @intCast(new_pot));

        if (new_max_bet > prev_max_bet) {
            markPreRaiseSnapshot(state, prev_pot_cents, prev_to_call);
            updateRaiseFromTotals(state, prev_max_bet, new_max_bet);
        } else if (new_pot > prev_pot) {
            state.to_call_cents = self.heroOutstandingCall(new_max_bet);
        }
    }

    fn updateBettingStateFromPlayerAction(
        self: *GameState,
        kind: ActionKind,
        action: protocol.PlayerAction,
        prev_max_bet: u32,
    ) void {
        var state = self.ensureBettingState();
        const prev_pot = state.pot_cents;
        const prev_to_call = state.to_call_cents;
        state.pot_cents = @as(i64, @intCast(action.pot));
        state.street = self.street;

        switch (kind) {
            .bet, .raise => {
                recordRaise(state, prev_pot, prev_to_call, action.player_bet);
            },
            .allin => {
                if (action.player_bet > prev_max_bet) {
                    recordRaise(state, prev_pot, prev_to_call, action.player_bet);
                } else {
                    state.to_call_cents = 0;
                }
            },
            .call => {
                state.to_call_cents = 0;
            },
            else => {},
        }
    }

    fn updateBettingStateAfterHeroAction(
        self: *GameState,
        kind: protocol.ActionType,
        prev_max_bet: u32,
        hero_total: u32,
    ) void {
        var state = self.ensureBettingState();
        const prev_pot = state.pot_cents;
        const prev_to_call = state.to_call_cents;
        state.pot_cents = @as(i64, @intCast(self.pot));
        state.street = self.street;

        switch (kind) {
            .bet, .raise => {
                recordRaise(state, prev_pot, prev_to_call, hero_total);
            },
            .allin => {
                if (hero_total > prev_max_bet) {
                    recordRaise(state, prev_pot, prev_to_call, hero_total);
                } else {
                    state.to_call_cents = 0;
                }
            },
            .call => {
                state.to_call_cents = 0;
            },
            else => {},
        }
    }

    fn resetBettingStateForNewStreet(self: *GameState) void {
        var state = self.ensureBettingState();
        state.pot_cents = @as(i64, @intCast(self.pot));
        state.to_call_cents = 0;
        state.last_raise_delta_cents = 0;
        state.pot_before_last_raise_cents = state.pot_cents;
        state.to_call_before_last_raise_cents = state.to_call_cents;
        state.street = self.street;
    }

    fn applyRaiseDelta(state: *BettingState, prev_to_call: i64, new_to_call: i64) void {
        state.to_call_cents = new_to_call;
        const delta = new_to_call - prev_to_call;
        if (delta > 0) {
            state.last_raise_delta_cents = delta;
        }
    }

    fn recordRaise(state: *BettingState, prev_pot: i64, prev_to_call: i64, new_total: u32) void {
        markPreRaiseSnapshot(state, prev_pot, prev_to_call);
        applyRaiseDelta(state, prev_to_call, @as(i64, @intCast(new_total)));
    }

    fn updateRaiseFromTotals(state: *BettingState, prev_max_bet: u32, new_max_bet: u32) void {
        state.to_call_cents = @as(i64, @intCast(new_max_bet));
        const delta = @as(i64, @intCast(new_max_bet)) - @as(i64, @intCast(prev_max_bet));
        if (delta > 0) {
            state.last_raise_delta_cents = delta;
        }
    }

    fn markPreRaiseSnapshot(state: *BettingState, prev_pot: i64, prev_to_call: i64) void {
        state.pot_before_last_raise_cents = prev_pot;
        state.to_call_before_last_raise_cents = prev_to_call;
    }

    /// Compute how many chips hero still owes relative to the street max bet.
    /// Used when snapshots lack an explicit `to_call` field (see snapshot test).
    fn heroOutstandingCall(self: *const GameState, max_bet: u32) i64 {
        const idx = self.hero_index orelse return 0;
        const info = self.players[idx];
        if (info.folded or info.all_in) return 0;
        if (max_bet > info.bet) {
            return @as(i64, @intCast(max_bet - info.bet));
        }
        return 0;
    }

    fn parseStreet(label: []const u8) !Street {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(label, "preflop")) return .preflop;
        if (eq(label, "flop")) return .flop;
        if (eq(label, "turn")) return .turn;
        if (eq(label, "river")) return .river;
        if (eq(label, "showdown")) return .river;
        reportInvalidStreet(label);
        return error.InvalidStreet;
    }

    fn reportInvalidStreet(label: []const u8) void {
        std.debug.print("GameState: invalid street label (len={d}) bytes=", .{label.len});
        for (label) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("\n", .{});
    }

    fn classifyAction(name: []const u8) ActionKind {
        if (std.mem.eql(u8, name, "fold")) return .fold;
        if (std.mem.eql(u8, name, "timeout_fold")) return .timeout_fold;
        if (std.mem.eql(u8, name, "check")) return .check;
        if (std.mem.eql(u8, name, "call")) return .call;
        if (std.mem.eql(u8, name, "bet")) return .bet;
        if (std.mem.eql(u8, name, "raise")) return .raise;
        if (std.mem.eql(u8, name, "allin")) return .allin;
        if (std.mem.eql(u8, name, "post_small_blind")) return .post_small_blind;
        if (std.mem.eql(u8, name, "post_big_blind")) return .post_big_blind;
        return .unknown;
    }

    fn isBlind(kind: ActionKind) bool {
        return kind == .post_small_blind or kind == .post_big_blind;
    }

    fn actionTypeForKind(kind: ActionKind) ?ActionType {
        return switch (kind) {
            .fold, .timeout_fold => .fold,
            .check => .check,
            .call => .call,
            .bet => .bet,
            .raise => .raise,
            .allin => .allin,
            else => null,
        };
    }

    fn amountForKind(kind: ActionKind, amount_paid: i32) u32 {
        const positive: u32 = if (amount_paid <= 0)
            0
        else
            @intCast(amount_paid);
        return switch (kind) {
            .call, .bet, .raise, .allin => positive,
            else => 0,
        };
    }

    fn freePlayers(self: *GameState) void {
        if (self.players.len == 0) return;
        for (self.players) |player| {
            self.allocator.free(player.name);
        }
        self.allocator.free(self.players);
        self.players = &[_]PlayerInfo{};
    }

    fn freeHandId(self: *GameState) void {
        if (self.hand_id.len == 0) return;
        self.allocator.free(self.hand_id);
        self.hand_id = &[_]u8{};
    }

    fn freeBoard(self: *GameState) void {
        if (self.board.len == 0) return;
        self.allocator.free(self.board);
        self.board = &[_]u8{};
    }
};

test "GameState tracks folds and bets" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'h'};
    var hero_name = [_]u8{ 'h', 'e', 'r', 'o' };
    var opp_name = [_]u8{ 'v', 'i', 'l' };
    var players = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero_name[0..], .chips = 1000 },
        .{ .seat = 1, .name = opp_name[0..], .chips = 1000 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 1, 14 },
        .small_blind = 50,
        .big_blind = 100,
        .players = players[0..],
    };
    try state.onHandStart(start);
    try std.testing.expectEqual(@as(u8, 2), state.playerCount());

    var street = [_]u8{ 'p', 'r', 'e', 'f', 'l', 'o', 'p' };
    var fold_label = [_]u8{ 'f', 'o', 'l', 'd' };

    const action = protocol.PlayerAction{
        .hand_id = hand_id[0..],
        .street = street[0..],
        .seat = 1,
        .player_name = opp_name[0..],
        .action = fold_label[0..],
        .amount_paid = 0,
        .player_bet = 0,
        .player_chips = 1000,
        .pot = 150,
    };
    try state.onPlayerAction(action);
    try std.testing.expectEqual(@as(u8, 1), state.playerCount());
}

test "onHandStart initializes hero and active mask" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'a'};
    var hero_name = [_]u8{'h'};
    var opp_name = [_]u8{'o'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero_name[0..], .chips = 1000 },
        .{ .seat = 1, .name = opp_name[0..], .chips = 1000 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 1,
        .button = 0,
        .hole_cards = .{ 1, 14 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);
    try std.testing.expectEqual(@as(u8, 1), state.hero_seat);
    try std.testing.expectEqual(@as(u8, 2), state.playerCount());
    try std.testing.expectEqual(@as(usize, 2), state.activePlayers().len);
}

test "activePlayers reflects folds" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'a'};
    var hero = [_]u8{'h'};
    var vill = [_]u8{'v'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero[0..], .chips = 1000 },
        .{ .seat = 1, .name = vill[0..], .chips = 1000 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 1, 14 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);

    var street = [_]u8{ 'p', 'r', 'e', 'f', 'l', 'o', 'p' };
    var name = [_]u8{'v'};
    var label = [_]u8{ 'f', 'o', 'l', 'd' };
    const action = protocol.PlayerAction{
        .hand_id = hand_id[0..],
        .street = street[0..],
        .seat = 1,
        .player_name = name[0..],
        .action = label[0..],
        .amount_paid = 0,
        .player_bet = 0,
        .player_chips = 1000,
        .pot = 150,
    };
    try state.onPlayerAction(action);
    try std.testing.expectEqual(@as(usize, 1), state.activePlayers().len);
}

test "seatToButton wraps positions" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'i'};
    var p0 = [_]u8{'0'};
    var p1 = [_]u8{'1'};
    var p2 = [_]u8{'2'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = p0[0..], .chips = 1000 },
        .{ .seat = 1, .name = p1[0..], .chips = 1000 },
        .{ .seat = 2, .name = p2[0..], .chips = 1000 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 2,
        .hole_cards = .{ 4, 18 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);
    try std.testing.expectEqual(@as(u8, 1), state.seatToButton(0));
    try std.testing.expectEqual(@as(u8, 2), state.seatToButton(1));
    try std.testing.expectEqual(@as(u8, 0), state.seatToButton(2));
}

test "recordHeroAction updates raise depth" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'h'};
    var name = [_]u8{'x'};
    var villain = [_]u8{'y'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = name[0..], .chips = 1000 },
        .{ .seat = 1, .name = villain[0..], .chips = 1000 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 10, 20 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);

    var raise_descriptor = [_]protocol.ActionDescriptor{.{ .action_type = .raise, .min_amount = 300 }};
    const request = protocol.ActionRequest{
        .hand_id = hand_id[0..],
        .pot = 150,
        .to_call = 100,
        .legal_actions = raise_descriptor[0..],
        .min_bet = 0,
        .min_raise = 0,
        .time_remaining_ms = 1000,
    };
    const action = protocol.OutgoingAction{ .action_type = .raise, .amount = 300 };
    try state.recordHeroAction(action, request);
    try std.testing.expectEqual(@as(u8, 1), state.raiseDepth());
    try std.testing.expectEqual(@as(u32, 300), state.street_max_bet);
}

test "onStreetChange resets per-street bets" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'h'};
    var hero_name = [_]u8{'h'};
    var opp_name = [_]u8{'o'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero_name[0..], .chips = 1000 },
        .{ .seat = 1, .name = opp_name[0..], .chips = 1000 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 3, 6 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);
    state.street_max_bet = 400;
    state.players[0].bet = 200;
    state.players[1].bet = 200;

    var label = [_]u8{ 'f', 'l', 'o', 'p' };
    var board = [_]u8{ 10, 20, 30 };
    const change = protocol.StreetChange{
        .hand_id = hand_id[0..],
        .street = label[0..],
        .board = board[0..],
    };
    try state.onStreetChange(change);
    try std.testing.expectEqual(@as(u32, 0), state.players[0].bet);
    try std.testing.expectEqual(@as(u32, 0), state.street_max_bet);
    try std.testing.expectEqualSlices(u8, board[0..], state.board);
}

test "onHandResult replaces board" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var original = [_]u8{ 1, 2, 3 };
    state.board = try allocator.dupe(u8, original[0..]);
    var new_board = [_]u8{ 4, 5, 6, 7, 8 };
    var result_id = [_]u8{'r'};
    var empty_winners = [_]protocol.Winner{};
    var empty_showdown = [_]protocol.ShowdownHand{};
    const result = protocol.HandResult{
        .hand_id = result_id[0..],
        .board = new_board[0..],
        .winners = empty_winners[0..],
        .showdown = empty_showdown[0..],
    };
    try state.onHandResult(result);
    try std.testing.expectEqualSlices(u8, new_board[0..], state.board);
}

test "BettingState initializes with blinds" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'b'};
    var hero_name = [_]u8{'h'};
    var opp_name = [_]u8{'o'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero_name[0..], .chips = 1000 },
        .{ .seat = 1, .name = opp_name[0..], .chips = 1000 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 7, 8 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);
    try std.testing.expect(state.betting_state != null);
    const betting = state.betting_state.?;
    try std.testing.expectEqual(@as(i64, 150), betting.pot_cents);
    try std.testing.expectEqual(@as(i64, 100), betting.to_call_cents);
    try std.testing.expectEqual(@as(i64, 100), betting.last_raise_delta_cents);
    try std.testing.expectEqual(@as(i64, 150), betting.pot_before_last_raise_cents);
    try std.testing.expectEqual(@as(i64, 100), betting.to_call_before_last_raise_cents);
    try std.testing.expectEqual(Street.preflop, betting.street);
}

test "BettingState tracks raises and street changes" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'r'};
    var hero_name = [_]u8{'h'};
    var opp_name = [_]u8{'v'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero_name[0..], .chips = 1200 },
        .{ .seat = 1, .name = opp_name[0..], .chips = 1200 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 11, 13 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);

    var street = [_]u8{ 'p', 'r', 'e', 'f', 'l', 'o', 'p' };
    var raise_label = [_]u8{ 'r', 'a', 'i', 's', 'e' };
    const action = protocol.PlayerAction{
        .hand_id = hand_id[0..],
        .street = street[0..],
        .seat = 1,
        .player_name = opp_name[0..],
        .action = raise_label[0..],
        .amount_paid = 200,
        .player_bet = 300,
        .player_chips = 900,
        .pot = 450,
    };
    try state.onPlayerAction(action);
    const betting_after_raise = state.betting_state.?;
    try std.testing.expectEqual(@as(i64, 450), betting_after_raise.pot_cents);
    try std.testing.expectEqual(@as(i64, 300), betting_after_raise.to_call_cents);
    try std.testing.expectEqual(@as(i64, 200), betting_after_raise.last_raise_delta_cents);
    try std.testing.expectEqual(@as(i64, 150), betting_after_raise.pot_before_last_raise_cents);
    try std.testing.expectEqual(@as(i64, 100), betting_after_raise.to_call_before_last_raise_cents);
    try std.testing.expectEqual(Street.preflop, betting_after_raise.street);

    var flop_label = [_]u8{ 'f', 'l', 'o', 'p' };
    var board = [_]u8{ 9, 10, 11 };
    const change = protocol.StreetChange{
        .hand_id = hand_id[0..],
        .street = flop_label[0..],
        .board = board[0..],
    };
    try state.onStreetChange(change);
    const betting_flop = state.betting_state.?;
    try std.testing.expectEqual(@as(i64, 450), betting_flop.pot_cents);
    try std.testing.expectEqual(@as(i64, 0), betting_flop.to_call_cents);
    try std.testing.expectEqual(@as(i64, 0), betting_flop.last_raise_delta_cents);
    try std.testing.expectEqual(@as(i64, 450), betting_flop.pot_before_last_raise_cents);
    try std.testing.expectEqual(@as(i64, 0), betting_flop.to_call_before_last_raise_cents);
    try std.testing.expectEqual(Street.flop, betting_flop.street);
}

test "BettingState handles sequential raises" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'s'};
    var hero_name = [_]u8{'h'};
    var opp_name = [_]u8{'v'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero_name[0..], .chips = 1500 },
        .{ .seat = 1, .name = opp_name[0..], .chips = 1500 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 5, 12 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);

    var street = [_]u8{ 'p', 'r', 'e', 'f', 'l', 'o', 'p' };
    var raise_label = [_]u8{ 'r', 'a', 'i', 's', 'e' };
    const first_raise = protocol.PlayerAction{
        .hand_id = hand_id[0..],
        .street = street[0..],
        .seat = 1,
        .player_name = opp_name[0..],
        .action = raise_label[0..],
        .amount_paid = 200,
        .player_bet = 300,
        .player_chips = 1200,
        .pot = 450,
    };
    try state.onPlayerAction(first_raise);
    const betting_after_first = state.betting_state.?;
    try std.testing.expectEqual(@as(i64, 300), betting_after_first.to_call_cents);
    try std.testing.expectEqual(@as(i64, 200), betting_after_first.last_raise_delta_cents);
    try std.testing.expectEqual(@as(i64, 150), betting_after_first.pot_before_last_raise_cents);
    try std.testing.expectEqual(@as(i64, 100), betting_after_first.to_call_before_last_raise_cents);

    const second_raise = protocol.PlayerAction{
        .hand_id = hand_id[0..],
        .street = street[0..],
        .seat = 1,
        .player_name = opp_name[0..],
        .action = raise_label[0..],
        .amount_paid = 600,
        .player_bet = 900,
        .player_chips = 600,
        .pot = 1050,
    };
    try state.onPlayerAction(second_raise);
    const betting_after_second = state.betting_state.?;
    try std.testing.expectEqual(@as(i64, 900), betting_after_second.to_call_cents);
    try std.testing.expectEqual(@as(i64, 600), betting_after_second.last_raise_delta_cents);
    try std.testing.expectEqual(@as(i64, 450), betting_after_second.pot_before_last_raise_cents);
    try std.testing.expectEqual(@as(i64, 300), betting_after_second.to_call_before_last_raise_cents);
}

test "BettingState call clears outstanding bet" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'c'};
    var hero_name = [_]u8{'h'};
    var opp_name = [_]u8{'v'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero_name[0..], .chips = 1500 },
        .{ .seat = 1, .name = opp_name[0..], .chips = 1500 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 2, 9 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);

    var street = [_]u8{ 'p', 'r', 'e', 'f', 'l', 'o', 'p' };
    var raise_label = [_]u8{ 'r', 'a', 'i', 's', 'e' };
    const raise_action = protocol.PlayerAction{
        .hand_id = hand_id[0..],
        .street = street[0..],
        .seat = 1,
        .player_name = opp_name[0..],
        .action = raise_label[0..],
        .amount_paid = 200,
        .player_bet = 300,
        .player_chips = 1200,
        .pot = 450,
    };
    try state.onPlayerAction(raise_action);

    var call_label = [_]u8{ 'c', 'a', 'l', 'l' };
    const call_action = protocol.PlayerAction{
        .hand_id = hand_id[0..],
        .street = street[0..],
        .seat = 0,
        .player_name = hero_name[0..],
        .action = call_label[0..],
        .amount_paid = 300,
        .player_bet = 300,
        .player_chips = 1200,
        .pot = 750,
    };
    try state.onPlayerAction(call_action);
    const betting_after_call = state.betting_state.?;
    try std.testing.expectEqual(@as(i64, 0), betting_after_call.to_call_cents);
}

test "onGameUpdate synchronizes betting snapshot" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'g'};
    var hero_name = [_]u8{'h'};
    var opp_name = [_]u8{'v'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero_name[0..], .chips = 1500 },
        .{ .seat = 1, .name = opp_name[0..], .chips = 1500 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 4, 7 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);

    var street = [_]u8{ 'p', 'r', 'e', 'f', 'l', 'o', 'p' };
    var raise_label = [_]u8{ 'r', 'a', 'i', 's', 'e' };
    const raise_action = protocol.PlayerAction{
        .hand_id = hand_id[0..],
        .street = street[0..],
        .seat = 1,
        .player_name = opp_name[0..],
        .action = raise_label[0..],
        .amount_paid = 200,
        .player_bet = 300,
        .player_chips = 1200,
        .pot = 450,
    };
    try state.onPlayerAction(raise_action);

    var update_players = [_]protocol.PlayerState{
        .{ .name = hero_name[0..], .chips = 1200, .bet = 300, .folded = false, .all_in = false },
        .{ .name = opp_name[0..], .chips = 600, .bet = 900, .folded = false, .all_in = false },
    };
    const snapshot = protocol.GameUpdate{
        .hand_id = hand_id[0..],
        .pot = 1050,
        .players = update_players[0..],
    };
    state.onGameUpdate(snapshot);
    const betting_after_update = state.betting_state.?;
    try std.testing.expectEqual(@as(i64, 1050), betting_after_update.pot_cents);
    try std.testing.expectEqual(@as(i64, 900), betting_after_update.to_call_cents);
    try std.testing.expectEqual(@as(i64, 600), betting_after_update.last_raise_delta_cents);
    try std.testing.expectEqual(@as(i64, 450), betting_after_update.pot_before_last_raise_cents);
    try std.testing.expectEqual(@as(i64, 300), betting_after_update.to_call_before_last_raise_cents);
}

test "snapshot preserves outstanding hero call when pot grows" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'o'};
    var hero_name = [_]u8{'h'};
    var opp_name = [_]u8{'v'};
    var cold_caller = [_]u8{'c'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero_name[0..], .chips = 1500 },
        .{ .seat = 1, .name = opp_name[0..], .chips = 1500 },
        .{ .seat = 2, .name = cold_caller[0..], .chips = 1500 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 6, 12 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);

    var street = [_]u8{ 'p', 'r', 'e', 'f', 'l', 'o', 'p' };
    var raise_label = [_]u8{ 'r', 'a', 'i', 's', 'e' };
    const raise_action = protocol.PlayerAction{
        .hand_id = hand_id[0..],
        .street = street[0..],
        .seat = 1,
        .player_name = opp_name[0..],
        .action = raise_label[0..],
        .amount_paid = 200,
        .player_bet = 300,
        .player_chips = 1200,
        .pot = 450,
    };
    try state.onPlayerAction(raise_action);

    var snapshot_players = [_]protocol.PlayerState{
        .{ .name = hero_name[0..], .chips = 1500, .bet = 0, .folded = false, .all_in = false },
        .{ .name = opp_name[0..], .chips = 1200, .bet = 300, .folded = false, .all_in = false },
        .{ .name = cold_caller[0..], .chips = 1200, .bet = 300, .folded = false, .all_in = false },
    };
    const snapshot = protocol.GameUpdate{
        .hand_id = hand_id[0..],
        .pot = 750,
        .players = snapshot_players[0..],
    };
    state.onGameUpdate(snapshot);
    const betting = state.betting_state.?;
    try std.testing.expectEqual(@as(i64, 300), betting.to_call_cents);
    try std.testing.expectEqual(@as(i64, 200), betting.last_raise_delta_cents);
}

test "recordHeroAction fold updates mask" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'h'};
    var hero = [_]u8{'h'};
    var vill = [_]u8{'v'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero[0..], .chips = 1000 },
        .{ .seat = 1, .name = vill[0..], .chips = 1000 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 1, 2 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);

    var fold_descriptor = [_]protocol.ActionDescriptor{.{ .action_type = .fold }};
    const request = protocol.ActionRequest{
        .hand_id = hand_id[0..],
        .pot = 150,
        .to_call = 0,
        .legal_actions = fold_descriptor[0..],
        .min_bet = 0,
        .min_raise = 0,
        .time_remaining_ms = 1000,
    };
    const action = protocol.OutgoingAction{ .action_type = .fold };
    try state.recordHeroAction(action, request);
    try std.testing.expectEqual(@as(usize, 1), state.activePlayers().len);
}

test "lastAggressor returns most recent aggressive action" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'h'};
    var hero = [_]u8{'h'};
    var vill = [_]u8{'v'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero[0..], .chips = 1000 },
        .{ .seat = 1, .name = vill[0..], .chips = 1000 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 3, 4 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);

    var raise_desc = [_]protocol.ActionDescriptor{.{ .action_type = .raise, .min_amount = 250 }};
    const request = protocol.ActionRequest{
        .hand_id = hand_id[0..],
        .pot = 150,
        .to_call = 100,
        .legal_actions = raise_desc[0..],
        .min_bet = 0,
        .min_raise = 0,
        .time_remaining_ms = 1000,
    };
    const raise_action = protocol.OutgoingAction{ .action_type = .raise, .amount = 250 };
    try state.recordHeroAction(raise_action, request);
    const last = state.lastAggressor().?;
    try std.testing.expectEqual(@as(u8, 0), last.seat);
}

test "playerCount reflects folds across streets" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'h'};
    var hero = [_]u8{'h'};
    var vill = [_]u8{'v'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero[0..], .chips = 1000 },
        .{ .seat = 1, .name = vill[0..], .chips = 1000 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 3, 4 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);
    try std.testing.expectEqual(@as(u8, 2), state.playerCount());

    var street = [_]u8{ 'p', 'r', 'e', 'f', 'l', 'o', 'p' };
    var vill_name = [_]u8{'v'};
    var fold = [_]u8{ 'f', 'o', 'l', 'd' };
    const action = protocol.PlayerAction{
        .hand_id = hand_id[0..],
        .street = street[0..],
        .seat = 1,
        .player_name = vill_name[0..],
        .action = fold[0..],
        .amount_paid = 0,
        .player_bet = 0,
        .player_chips = 1000,
        .pot = 200,
    };
    try state.onPlayerAction(action);
    try std.testing.expectEqual(@as(u8, 1), state.playerCount());
}

test "onActionRequest updates pot and to_call" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    // Initialize game state properly with onHandStart
    var hand_id = [_]u8{'h'};
    var hero_name = [_]u8{ 'h', 'e', 'r', 'o' };
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero_name[0..], .chips = 1000 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 0,
        .hole_cards = .{ 1, 2 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);

    var legal = [_]protocol.ActionDescriptor{.{ .action_type = .call }};
    const request = protocol.ActionRequest{
        .hand_id = hand_id[0..],
        .pot = 200,
        .to_call = 150,
        .legal_actions = legal[0..],
        .min_bet = 0,
        .min_raise = 0,
        .time_remaining_ms = 500,
    };
    state.onActionRequest(request);
    try std.testing.expectEqual(@as(u32, 200), state.pot);
    try std.testing.expectEqual(@as(u32, 150), state.to_call);
}

test "onActionRequest infers pot snapshot when facing new bet" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'h'};
    var hero_name = [_]u8{'h'};
    var villain_name = [_]u8{'v'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero_name[0..], .chips = 2000 },
        .{ .seat = 1, .name = villain_name[0..], .chips = 2000 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 1, 2 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);

    var legal = [_]protocol.ActionDescriptor{.{ .action_type = .call }};
    const initial_request = protocol.ActionRequest{
        .hand_id = hand_id[0..],
        .pot = 450,
        .to_call = 300,
        .legal_actions = legal[0..],
        .min_bet = 0,
        .min_raise = 0,
        .time_remaining_ms = 500,
    };
    state.onActionRequest(initial_request);

    const hero_raise = protocol.OutgoingAction{ .action_type = .raise, .amount = 900 };
    try state.recordHeroAction(hero_raise, initial_request);

    const second_request = protocol.ActionRequest{
        .hand_id = hand_id[0..],
        .pot = 2550,
        .to_call = 1200,
        .legal_actions = legal[0..],
        .min_bet = 0,
        .min_raise = 0,
        .time_remaining_ms = 400,
    };
    state.onActionRequest(second_request);

    const betting = state.betting_state.?;
    try std.testing.expectEqual(@as(i64, 2550), betting.pot_cents);
    try std.testing.expectEqual(@as(i64, 1200), betting.to_call_cents);
    try std.testing.expectEqual(@as(i64, 1350), betting.pot_before_last_raise_cents);
    try std.testing.expectEqual(@as(i64, 0), betting.to_call_before_last_raise_cents);
    try std.testing.expectEqual(@as(i64, 1200), betting.last_raise_delta_cents);
}

test "onPlayerAction marks all_in when chips hit zero" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'h'};
    var hero = [_]u8{'h'};
    var vill = [_]u8{'v'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero[0..], .chips = 1000 },
        .{ .seat = 1, .name = vill[0..], .chips = 1200 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 3, 4 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);

    var street = [_]u8{ 'p', 'r', 'e', 'f', 'l', 'o', 'p' };
    var label = [_]u8{ 'a', 'l', 'l', 'i', 'n' };
    var vill_name = [_]u8{'v'};
    const action = protocol.PlayerAction{
        .hand_id = hand_id[0..],
        .street = street[0..],
        .seat = 1,
        .player_name = vill_name[0..],
        .action = label[0..],
        .amount_paid = 1200,
        .player_bet = 1200,
        .player_chips = 0,
        .pot = 1400,
    };
    try state.onPlayerAction(action);
    try std.testing.expect(state.players[1].all_in);
}

test "recordHeroAction bet deducts chips and raises pot" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'h'};
    var hero = [_]u8{'h'};
    var vill = [_]u8{'v'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero[0..], .chips = 1000 },
        .{ .seat = 1, .name = vill[0..], .chips = 1000 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 3, 4 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);

    var bet_desc = [_]protocol.ActionDescriptor{.{ .action_type = .bet, .min_amount = 200 }};
    state.pot = 150;
    const request = protocol.ActionRequest{
        .hand_id = hand_id[0..],
        .pot = 150,
        .to_call = 0,
        .legal_actions = bet_desc[0..],
        .min_bet = 0,
        .min_raise = 0,
        .time_remaining_ms = 500,
    };
    const bet = protocol.OutgoingAction{ .action_type = .bet, .amount = 200 };
    try state.recordHeroAction(bet, request);
    try std.testing.expectEqual(@as(u32, 800), state.players[0].chips);
    try std.testing.expectEqual(@as(u32, 350), state.pot);
}

test "heroStack returns hero chip count" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'h'};
    var hero = [_]u8{'h'};
    var vill = [_]u8{'v'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero[0..], .chips = 750 },
        .{ .seat = 1, .name = vill[0..], .chips = 1200 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 8, 9 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);
    try std.testing.expectEqual(@as(u32, 750), state.heroStack().?);
}

test "recordHeroAction call handles zero to_call" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'h'};
    var hero_name = [_]u8{'h'};
    var villain_name = [_]u8{'v'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero_name[0..], .chips = 1000 },
        .{ .seat = 1, .name = villain_name[0..], .chips = 1000 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 3, 17 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);

    var legal = [_]protocol.ActionDescriptor{.{ .action_type = .call }};
    const request = protocol.ActionRequest{
        .hand_id = hand_id[0..],
        .pot = 150,
        .to_call = 0,
        .legal_actions = legal[0..],
        .min_bet = 0,
        .min_raise = 0,
        .time_remaining_ms = 1000,
    };
    const action = protocol.OutgoingAction{ .action_type = .call, .amount = null };
    try state.recordHeroAction(action, request);

    try std.testing.expectEqual(@as(usize, 1), state.history.items.len);
    try std.testing.expectEqual(@as(u32, 0), state.history.items[0].amount);
    try std.testing.expectEqual(@as(u32, 0), state.pot);
}

test "recordHeroAction call tracks positive to_call" {
    const allocator = std.testing.allocator;
    var state = GameState.init(allocator);
    defer state.deinit();

    var hand_id = [_]u8{'h'};
    var hero_name = [_]u8{'h'};
    var villain_name = [_]u8{'v'};
    var seats = [_]protocol.SeatInfo{
        .{ .seat = 0, .name = hero_name[0..], .chips = 800 },
        .{ .seat = 1, .name = villain_name[0..], .chips = 1200 },
    };
    const start = protocol.HandStart{
        .hand_id = hand_id[0..],
        .your_seat = 0,
        .button = 1,
        .hole_cards = .{ 5, 18 },
        .small_blind = 50,
        .big_blind = 100,
        .players = seats[0..],
    };
    try state.onHandStart(start);

    var legal = [_]protocol.ActionDescriptor{.{ .action_type = .call }};
    const request = protocol.ActionRequest{
        .hand_id = hand_id[0..],
        .pot = 200,
        .to_call = 150,
        .legal_actions = legal[0..],
        .min_bet = 0,
        .min_raise = 0,
        .time_remaining_ms = 1000,
    };
    const action = protocol.OutgoingAction{ .action_type = .call, .amount = null };
    try state.recordHeroAction(action, request);

    try std.testing.expectEqual(@as(usize, 1), state.history.items.len);
    try std.testing.expectEqual(@as(u32, 150), state.history.items[0].amount);
    try std.testing.expectEqual(@as(u32, 150), state.pot);
    try std.testing.expectEqual(@as(u32, 150), state.street_max_bet);
}
