const std = @import("std");
const ws = @import("websocket");
const msgpack = @import("msgpack");
const protocol = @import("protocol.zig");

pub const Config = struct {
    endpoint: []const u8,
    api_key: []const u8,
    bot_name: []const u8,
    game: ?[]const u8 = null,
    timeout_ms: u32 = 5000,
};

pub const ConnectorError = error{
    MissingApiKey,
    MissingBotName,
    InvalidEndpoint,
    UnsupportedScheme,
    MissingHost,
};

pub const Connector = struct {
    allocator: std.mem.Allocator,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, config: Config) Connector {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn connect(self: *Connector) !Connection {
        if (self.config.api_key.len == 0) return ConnectorError.MissingApiKey;
        if (self.config.bot_name.len == 0) return ConnectorError.MissingBotName;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const endpoint = try resolveEndpoint(arena.allocator(), self.config.endpoint);

        var client = try ws.Client.init(self.allocator, .{
            .port = endpoint.port,
            .host = endpoint.host,
            .tls = endpoint.tls,
        });
        errdefer client.deinit();

        try client.handshake(endpoint.request_path, .{
            .timeout_ms = self.config.timeout_ms,
            .headers = endpoint.handshake_header,
        });

        try client.writeTimeout(self.config.timeout_ms);
        try client.readTimeout(self.config.timeout_ms);

        const scratch = try std.ArrayList(u8).initCapacity(self.allocator, 0);
        var connection = Connection{
            .allocator = self.allocator,
            .client = client,
            .scratch = scratch,
        };
        errdefer connection.deinit();

        // Send connect message (protocol v2)
        const connect_msg = struct {
            type: []const u8 = "connect",
            name: []const u8,
            game: ?[]const u8,
            auth_token: ?[]const u8,
            protocol_version: []const u8 = "2",
        }{
            .name = self.config.bot_name,
            .game = self.config.game,
            .auth_token = if (self.config.api_key.len == 0) null else self.config.api_key,
        };
        try connection.send(connect_msg);

        return connection;
    }
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    client: ws.Client,
    scratch: std.ArrayList(u8),

    pub fn deinit(self: *Connection) void {
        self.client.deinit();
        self.scratch.deinit(self.allocator);
    }

    pub fn send(self: *Connection, value: anytype) !void {
        self.scratch.clearRetainingCapacity();
        try msgpack.encode(value, self.scratch.writer(self.allocator));
        try self.client.writeBin(self.scratch.items);
    }

    pub fn sendAction(self: *Connection, action: protocol.OutgoingAction) !void {
        // Validate that raise/bet actions have amounts
        switch (action.action_type) {
            .raise, .bet => {
                if (action.amount == null or action.amount.? == 0) {
                    return error.InvalidActionAmount;
                }
            },
            .fold, .call, .check, .allin => {},
        }

        // Protocol v2: send action as string
        const action_str = switch (action.action_type) {
            .fold => "fold",
            .call => "call",
            .raise => "raise",
            .allin => "allin",
            .check => "check", // For protocol v1 compatibility
            .bet => "bet", // For protocol v1 compatibility
        };

        const payload = struct {
            type: []const u8 = "action",
            action: []const u8,
            amount: u32,
        }{
            .action = action_str,
            .amount = action.amount orelse 0,
        };
        try self.send(payload);
    }

    pub fn readMessage(self: *Connection) !?protocol.IncomingMessage {
        while (true) {
            const frame_opt = try self.client.read();
            if (frame_opt == null) return null;
            const frame = frame_opt.?;
            defer self.client.done(frame);

            switch (frame.type) {
                .binary => {
                    const decoded = try protocol.decodeMessage(self.allocator, frame.data);
                    defer self.allocator.free(decoded.msg_type);
                    return decoded.msg;
                },
                .ping => {
                    // Reply to ping to avoid timeout disconnection
                    try self.client.writePong(frame.data);
                    continue;
                },
                .close => {
                    // Server closed connection
                    return null;
                },
                else => continue,
            }
        }
    }
};

const EndpointParts = struct {
    tls: bool,
    host: []const u8,
    request_path: []u8,
    handshake_header: []u8,
    port: u16,
};

fn resolveEndpoint(allocator: std.mem.Allocator, endpoint: []const u8) !EndpointParts {
    const uri = try std.Uri.parse(endpoint);
    if (uri.scheme.len == 0) return ConnectorError.InvalidEndpoint;
    const scheme = uri.scheme;
    const tls = if (std.mem.eql(u8, scheme, "ws"))
        false
    else if (std.mem.eql(u8, scheme, "wss"))
        true
    else
        return ConnectorError.UnsupportedScheme;

    const host_component = uri.host orelse return ConnectorError.MissingHost;
    const host = try host_component.toRawMaybeAlloc(allocator);
    const port: u16 = uri.port orelse (if (tls) 443 else 80);

    const raw_path = try uri.path.toRawMaybeAlloc(allocator);
    const base_path = if (raw_path.len == 0) "/" else raw_path;
    const raw_query = if (uri.query) |component|
        try component.toRawMaybeAlloc(allocator)
    else
        "";
    const request_path = if (raw_query.len == 0)
        try allocator.dupe(u8, base_path)
    else
        try std.fmt.allocPrint(allocator, "{s}?{s}", .{ base_path, raw_query });

    const header_host = if (uri.port) |explicit|
        try std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, explicit })
    else
        try allocator.dupe(u8, host);

    const handshake_header = try std.fmt.allocPrint(allocator, "Host: {s}\r\n", .{header_host});

    return .{
        .tls = tls,
        .host = host,
        .request_path = request_path,
        .handshake_header = handshake_header,
        .port = port,
    };
}
