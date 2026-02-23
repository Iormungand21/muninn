const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const bus_mod = @import("../bus.zig");
const websocket = @import("../websocket.zig");

const log = std.log.scoped(.slack);

/// Slack channel — polls conversations.history for new messages, sends via chat.postMessage.
pub const SlackChannel = struct {
    allocator: std.mem.Allocator,
    bot_token: []const u8,
    app_token: ?[]const u8,
    channel_id: ?[]const u8,
    allow_from: []const []const u8,
    last_ts: []const u8,
    thread_ts: ?[]const u8 = null,
    policy: root.ChannelPolicy = .{},

    // Socket Mode state
    bus: ?*bus_mod.Bus = null,
    bot_user_id: ?[]const u8 = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    gateway_thread: ?std.Thread = null,
    ws_fd: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),

    pub const API_BASE = "https://slack.com/api";

    pub fn init(
        allocator: std.mem.Allocator,
        bot_token: []const u8,
        app_token: ?[]const u8,
        channel_id: ?[]const u8,
        allow_from: []const []const u8,
    ) SlackChannel {
        return .{
            .allocator = allocator,
            .bot_token = bot_token,
            .app_token = app_token,
            .channel_id = channel_id,
            .allow_from = allow_from,
            .last_ts = "0",
        };
    }

    pub fn initWithPolicy(
        allocator: std.mem.Allocator,
        bot_token: []const u8,
        app_token: ?[]const u8,
        channel_id: ?[]const u8,
        allow_from: []const []const u8,
        policy: root.ChannelPolicy,
    ) SlackChannel {
        return .{
            .allocator = allocator,
            .bot_token = bot_token,
            .app_token = app_token,
            .channel_id = channel_id,
            .allow_from = allow_from,
            .last_ts = "0",
            .policy = policy,
        };
    }

    /// Set the thread timestamp for threaded replies.
    pub fn setThreadTs(self: *SlackChannel, ts: ?[]const u8) void {
        self.thread_ts = ts;
    }

    /// Parse a target string, splitting "channel_id:thread_ts" if colon-separated.
    /// Returns the channel ID and optionally sets thread_ts on the instance.
    pub fn parseTarget(self: *SlackChannel, target: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, target, ':')) |idx| {
            self.thread_ts = target[idx + 1 ..];
            return target[0..idx];
        }
        return target;
    }

    pub fn channelName(_: *SlackChannel) []const u8 {
        return "slack";
    }

    pub fn isUserAllowed(self: *const SlackChannel, sender: []const u8) bool {
        return root.isAllowed(self.allow_from, sender);
    }

    /// Check if an incoming message should be handled based on the channel policy.
    /// `sender_id`: the Slack user ID of the message sender.
    /// `is_dm`: true if the message is a direct message (IM channel).
    /// `message_text`: the raw message text (used to detect bot mention).
    /// `bot_user_id`: the bot's own Slack user ID (for mention detection).
    pub fn shouldHandle(self: *const SlackChannel, sender_id: []const u8, is_dm: bool, message_text: []const u8, bot_user_id: ?[]const u8) bool {
        const is_mention = if (bot_user_id) |bid| containsMention(message_text, bid) else false;
        return root.checkPolicy(self.policy, sender_id, is_dm, is_mention);
    }

    pub fn healthCheck(_: *SlackChannel) bool {
        return true;
    }

    // ── Channel vtable ──────────────────────────────────────────────

    /// Send a message to a Slack channel via chat.postMessage API.
    /// The target may contain "channel_id:thread_ts" for threaded replies.
    pub fn sendMessage(self: *SlackChannel, target_channel: []const u8, text: []const u8) !void {
        const url = API_BASE ++ "/chat.postMessage";

        // Parse target for thread_ts (channel_id:thread_ts)
        const actual_channel = self.parseTarget(target_channel);

        // Build JSON body
        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);

        try body_list.appendSlice(self.allocator, "{\"channel\":\"");
        try body_list.appendSlice(self.allocator, actual_channel);
        try body_list.appendSlice(self.allocator, "\",\"mrkdwn\":true,\"text\":");
        try root.json_util.appendJsonString(&body_list, self.allocator, text);
        if (self.thread_ts) |tts| {
            try body_list.appendSlice(self.allocator, ",\"thread_ts\":\"");
            try body_list.appendSlice(self.allocator, tts);
            try body_list.append(self.allocator, '"');
        }
        try body_list.append(self.allocator, '}');

        // Build auth header: "Authorization: Bearer xoxb-..."
        var auth_buf: [512]u8 = undefined;
        var auth_fbs = std.io.fixedBufferStream(&auth_buf);
        try auth_fbs.writer().print("Authorization: Bearer {s}", .{self.bot_token});
        const auth_header = auth_fbs.getWritten();

        const resp = root.http_util.curlPost(self.allocator, url, body_list.items, &.{auth_header}) catch |err| {
            log.err("Slack API POST failed: {}", .{err});
            return error.SlackApiError;
        };
        self.allocator.free(resp);
    }

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        if (self.app_token == null) return; // No app token — can't start Socket Mode
        self.running.store(true, .release);
        self.gateway_thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, socketModeLoop, .{self});
    }

    fn vtableStop(ptr: *anyopaque) void {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        self.running.store(false, .release);
        // Close socket to unblock blocking read
        const fd = self.ws_fd.load(.acquire);
        if (fd >= 0) {
            if (comptime builtin.os.tag != .windows) {
                std.posix.close(@intCast(fd));
            }
        }
        if (self.gateway_thread) |t| {
            t.join();
            self.gateway_thread = null;
        }
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8) anyerror!void {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        try self.sendMessage(target, message);
    }

    fn vtableName(ptr: *anyopaque) []const u8 {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        return self.channelName();
    }

    fn vtableHealthCheck(ptr: *anyopaque) bool {
        const self: *SlackChannel = @ptrCast(@alignCast(ptr));
        return self.healthCheck();
    }

    pub const vtable = root.Channel.VTable{
        .start = &vtableStart,
        .stop = &vtableStop,
        .send = &vtableSend,
        .name = &vtableName,
        .healthCheck = &vtableHealthCheck,
    };

    pub fn channel(self: *SlackChannel) root.Channel {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    // ── Socket Mode ──────────────────────────────────────────────────

    /// Outer reconnect loop with exponential backoff.
    fn socketModeLoop(self: *SlackChannel) void {
        var backoff_ms: u64 = 1000;
        while (self.running.load(.acquire)) {
            self.runSocketModeOnce() catch |err| {
                log.warn("Slack Socket Mode error: {}", .{err});
                if (!self.running.load(.acquire)) break;
                // Exponential backoff on connection failure
                var slept: u64 = 0;
                while (slept < backoff_ms and self.running.load(.acquire)) {
                    std.Thread.sleep(100 * std.time.ns_per_ms);
                    slept += 100;
                }
                backoff_ms = @min(backoff_ms * 2, 60_000);
                continue;
            };
            // Connected successfully — reset backoff
            backoff_ms = 1000;
            if (!self.running.load(.acquire)) break;
            // Brief delay before reconnect after clean disconnect
            var slept: u64 = 0;
            while (slept < 1000 and self.running.load(.acquire)) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                slept += 100;
            }
        }
    }

    /// Single Socket Mode connection lifecycle.
    fn runSocketModeOnce(self: *SlackChannel) !void {
        // 1. Request WebSocket URL via apps.connections.open
        const ws_url = try self.requestConnectionUrl();
        defer self.allocator.free(ws_url);

        // 2. Parse URL into host and path
        const host = parseWsHost(ws_url);
        const path = parseWsPath(ws_url);

        // 3. Connect WebSocket
        var ws = try websocket.WsClient.connect(self.allocator, host, 443, path, &.{});
        self.ws_fd.store(ws.stream.handle, .release);
        defer {
            self.ws_fd.store(-1, .release);
            ws.deinit();
        }

        // 4. Wait for hello
        const hello_text = try ws.readTextMessage() orelse return error.ConnectionClosed;
        defer self.allocator.free(hello_text);
        if (!isHelloEnvelope(hello_text)) {
            log.warn("Slack: expected hello envelope", .{});
            return error.UnexpectedMessage;
        }
        log.info("Slack Socket Mode: connected", .{});

        // 5. Main read loop
        while (self.running.load(.acquire)) {
            const maybe_text = ws.readTextMessage() catch break;
            const text = maybe_text orelse break;
            defer self.allocator.free(text);
            self.handleEnvelope(&ws, text) catch |err| switch (err) {
                error.ShouldReconnect => break,
            };
        }
    }

    /// Request a WebSocket URL from Slack's apps.connections.open endpoint.
    fn requestConnectionUrl(self: *SlackChannel) ![]u8 {
        const app_tok = self.app_token orelse return error.NoAppToken;

        var auth_buf: [512]u8 = undefined;
        var auth_fbs = std.io.fixedBufferStream(&auth_buf);
        try auth_fbs.writer().print("Authorization: Bearer {s}", .{app_tok});
        const auth_header = auth_fbs.getWritten();

        const resp = root.http_util.curlPost(
            self.allocator,
            API_BASE ++ "/apps.connections.open",
            "",
            &.{auth_header},
        ) catch |err| {
            log.err("Slack apps.connections.open failed: {}", .{err});
            return error.SlackApiError;
        };
        defer self.allocator.free(resp);

        return parseConnectionUrl(self.allocator, resp);
    }

    /// Parse the URL from apps.connections.open response JSON.
    pub fn parseConnectionUrl(allocator: std.mem.Allocator, response: []const u8) ![]u8 {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;

        const ok_val = obj.get("ok") orelse return error.MissingOkField;
        const ok = switch (ok_val) {
            .bool => |b| b,
            else => false,
        };
        if (!ok) return error.SlackApiNotOk;

        const url_val = obj.get("url") orelse return error.MissingUrlField;
        const url_str = switch (url_val) {
            .string => |s| s,
            else => return error.InvalidUrlField,
        };

        return try allocator.dupe(u8, url_str);
    }

    /// Parse host from wss:// URL.
    /// "wss://wss-primary.slack.com/link?t=abc" -> "wss-primary.slack.com"
    pub fn parseWsHost(url: []const u8) []const u8 {
        const no_scheme = if (std.mem.startsWith(u8, url, "wss://"))
            url[6..]
        else if (std.mem.startsWith(u8, url, "ws://"))
            url[5..]
        else
            url;

        const slash_pos = std.mem.indexOfScalar(u8, no_scheme, '/');
        const query_pos = std.mem.indexOfScalar(u8, no_scheme, '?');

        const end = blk: {
            if (slash_pos != null and query_pos != null) break :blk @min(slash_pos.?, query_pos.?);
            if (slash_pos != null) break :blk slash_pos.?;
            if (query_pos != null) break :blk query_pos.?;
            break :blk no_scheme.len;
        };

        return no_scheme[0..end];
    }

    /// Parse path (including query string) from wss:// URL.
    /// "wss://host/link?t=abc" -> "/link?t=abc"
    pub fn parseWsPath(url: []const u8) []const u8 {
        const no_scheme = if (std.mem.startsWith(u8, url, "wss://"))
            url[6..]
        else if (std.mem.startsWith(u8, url, "ws://"))
            url[5..]
        else
            url;

        if (std.mem.indexOfScalar(u8, no_scheme, '/')) |slash_pos| {
            return no_scheme[slash_pos..];
        }
        return "/";
    }

    /// Check if an envelope is a "hello" type.
    pub fn isHelloEnvelope(text: []const u8) bool {
        return std.mem.indexOf(u8, text, "\"type\":\"hello\"") != null;
    }

    /// Build ack JSON for an envelope_id (stack-allocated, no heap).
    pub fn buildAckJson(buf: []u8, envelope_id: []const u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        try fbs.writer().print("{{\"envelope_id\":\"{s}\"}}", .{envelope_id});
        return fbs.getWritten();
    }

    /// Handle a Socket Mode envelope.
    fn handleEnvelope(self: *SlackChannel, ws: *websocket.WsClient, text: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, text, .{}) catch |err| {
            log.warn("Slack: failed to parse envelope: {}", .{err});
            return;
        };
        defer parsed.deinit();

        const obj = parsed.value.object;

        // Get envelope type
        const type_val = obj.get("type") orelse {
            log.warn("Slack: envelope missing 'type' field", .{});
            return;
        };
        const env_type = switch (type_val) {
            .string => |s| s,
            else => {
                log.warn("Slack: envelope 'type' is not a string", .{});
                return;
            },
        };

        // Get envelope_id (not present in hello)
        const envelope_id: ?[]const u8 = if (obj.get("envelope_id")) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null;

        if (std.mem.eql(u8, env_type, "hello")) {
            return;
        }

        // Acknowledge the envelope
        if (envelope_id) |eid| {
            self.sendAck(ws, eid) catch |err| {
                log.warn("Slack: failed to send ack: {}", .{err});
            };
        }

        if (std.mem.eql(u8, env_type, "events_api")) {
            self.handleEventsApiEnvelope(obj) catch |err| {
                log.warn("Slack: events_api handling error: {}", .{err});
            };
        } else if (std.mem.eql(u8, env_type, "disconnect")) {
            log.info("Slack: received disconnect envelope, reconnecting", .{});
            return error.ShouldReconnect;
        }
    }

    /// Send an acknowledgment for an envelope.
    fn sendAck(_: *SlackChannel, ws: *websocket.WsClient, envelope_id: []const u8) !void {
        var buf: [256]u8 = undefined;
        const ack_json = try buildAckJson(&buf, envelope_id);
        try ws.writeText(ack_json);
    }

    /// Handle an events_api envelope — extract the event and dispatch.
    fn handleEventsApiEnvelope(self: *SlackChannel, env_obj: std.json.ObjectMap) !void {
        const payload_val = env_obj.get("payload") orelse {
            log.warn("Slack events_api: missing 'payload'", .{});
            return;
        };
        const payload = switch (payload_val) {
            .object => |o| o,
            else => {
                log.warn("Slack events_api: 'payload' is not an object", .{});
                return;
            },
        };

        const event_val = payload.get("event") orelse {
            log.warn("Slack events_api: missing 'event' in payload", .{});
            return;
        };
        const event = switch (event_val) {
            .object => |o| o,
            else => {
                log.warn("Slack events_api: 'event' is not an object", .{});
                return;
            },
        };

        const event_type_val = event.get("type") orelse return;
        const event_type = switch (event_type_val) {
            .string => |s| s,
            else => return,
        };

        if (std.mem.eql(u8, event_type, "message")) {
            try self.handleMessageEvent(event);
        }
    }

    /// Handle a message event from the events_api.
    fn handleMessageEvent(self: *SlackChannel, event: std.json.ObjectMap) !void {
        // Skip message subtypes (bot_message, message_changed, etc.)
        if (event.get("subtype") != null) return;

        // Extract user (sender_id)
        const user_id: []const u8 = if (event.get("user")) |v| switch (v) {
            .string => |s| s,
            else => return,
        } else return;

        // Extract text (content)
        const text: []const u8 = if (event.get("text")) |v| switch (v) {
            .string => |s| s,
            else => "",
        } else "";

        // Extract channel
        const channel_id: []const u8 = if (event.get("channel")) |v| switch (v) {
            .string => |s| s,
            else => return,
        } else return;

        // Extract channel_type to determine if DM
        const channel_type: []const u8 = if (event.get("channel_type")) |v| switch (v) {
            .string => |s| s,
            else => "channel",
        } else "channel";

        const is_dm = std.mem.eql(u8, channel_type, "im");

        // Extract ts for metadata
        const ts: []const u8 = if (event.get("ts")) |v| switch (v) {
            .string => |s| s,
            else => "",
        } else "";

        // Apply policy checks
        if (!self.shouldHandle(user_id, is_dm, text, self.bot_user_id)) {
            return;
        }

        // Apply allow_from filter
        if (self.allow_from.len > 0) {
            if (!self.isUserAllowed(user_id)) {
                return;
            }
        }

        // Build session key
        const session_key = try std.fmt.allocPrint(self.allocator, "slack:{s}", .{channel_id});
        defer self.allocator.free(session_key);

        // Build metadata JSON with ts and channel_type
        var meta_buf: [256]u8 = undefined;
        var meta_fbs = std.io.fixedBufferStream(&meta_buf);
        meta_fbs.writer().print("{{\"ts\":\"{s}\",\"channel_type\":\"{s}\"}}", .{ ts, channel_type }) catch {};
        const metadata_json: ?[]const u8 = if (meta_fbs.pos > 0) meta_fbs.getWritten() else null;

        const msg = try bus_mod.makeInboundFull(
            self.allocator,
            "slack",
            user_id,
            channel_id,
            text,
            session_key,
            &.{},
            metadata_json,
        );

        if (self.bus) |b| {
            b.publishInbound(msg) catch |err| {
                log.warn("Slack: failed to publish inbound message: {}", .{err});
                msg.deinit(self.allocator);
            };
        } else {
            msg.deinit(self.allocator);
        }
    }
};

/// Check if a message text contains a Slack mention of the given user ID.
/// Slack mentions use the format `<@U12345>`.
pub fn containsMention(text: []const u8, user_id: []const u8) bool {
    // Search for "<@USER_ID>" pattern
    var i: usize = 0;
    while (i + 3 + user_id.len <= text.len) {
        if (text[i] == '<' and text[i + 1] == '@') {
            const start = i + 2;
            if (start + user_id.len <= text.len and
                std.mem.eql(u8, text[start .. start + user_id.len], user_id) and
                start + user_id.len < text.len and text[start + user_id.len] == '>')
            {
                return true;
            }
        }
        i += 1;
    }
    return false;
}

/// Convert standard Markdown to Slack mrkdwn format.
///
/// Conversions:
///   **bold**         -> *bold*
///   ~~strike~~       -> ~strike~
///   ```code```       -> ```code``` (preserved)
///   `inline code`    -> `inline code` (preserved)
///   [text](url)      -> <url|text>
///   # Header         -> *Header*
///   - bullet         -> bullet (with bullet char)
pub fn markdownToSlackMrkdwn(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    var line_start = true;

    while (i < input.len) {
        // ── Fenced code blocks (```) — preserve as-is ──
        if (i + 3 <= input.len and std.mem.eql(u8, input[i..][0..3], "```")) {
            try result.appendSlice(allocator, input[i..][0..3]);
            i += 3;
            // Copy everything until closing ```
            while (i < input.len) {
                if (i + 3 <= input.len and std.mem.eql(u8, input[i..][0..3], "```")) {
                    try result.appendSlice(allocator, input[i..][0..3]);
                    i += 3;
                    break;
                }
                try result.append(allocator, input[i]);
                i += 1;
            }
            line_start = false;
            continue;
        }

        // ── Headers at start of line: "# " -> bold ──
        if (line_start and i < input.len and input[i] == '#') {
            var hashes: usize = 0;
            var hi = i;
            while (hi < input.len and input[hi] == '#') {
                hashes += 1;
                hi += 1;
            }
            if (hashes > 0 and hi < input.len and input[hi] == ' ') {
                hi += 1; // skip space after #
                // Find end of line
                var end = hi;
                while (end < input.len and input[end] != '\n') {
                    end += 1;
                }
                try result.append(allocator, '*');
                try result.appendSlice(allocator, input[hi..end]);
                try result.append(allocator, '*');
                i = end;
                line_start = false;
                continue;
            }
        }

        // ── Bullet points at start of line: "- " -> "* " ──
        if (line_start and i + 1 < input.len and input[i] == '-' and input[i + 1] == ' ') {
            try result.appendSlice(allocator, "\xe2\x80\xa2 "); // bullet char U+2022
            i += 2;
            line_start = false;
            continue;
        }

        // ── Bold: **text** -> *text* ──
        if (i + 2 <= input.len and std.mem.eql(u8, input[i..][0..2], "**")) {
            // Find closing **
            const start = i + 2;
            if (std.mem.indexOf(u8, input[start..], "**")) |close_offset| {
                try result.append(allocator, '*');
                try result.appendSlice(allocator, input[start .. start + close_offset]);
                try result.append(allocator, '*');
                i = start + close_offset + 2;
                line_start = false;
                continue;
            }
        }

        // ── Strikethrough: ~~text~~ -> ~text~ ──
        if (i + 2 <= input.len and std.mem.eql(u8, input[i..][0..2], "~~")) {
            const start = i + 2;
            if (std.mem.indexOf(u8, input[start..], "~~")) |close_offset| {
                try result.append(allocator, '~');
                try result.appendSlice(allocator, input[start .. start + close_offset]);
                try result.append(allocator, '~');
                i = start + close_offset + 2;
                line_start = false;
                continue;
            }
        }

        // ── Inline code: `code` -> `code` (preserved) ──
        if (i < input.len and input[i] == '`') {
            try result.append(allocator, '`');
            i += 1;
            while (i < input.len and input[i] != '`') {
                try result.append(allocator, input[i]);
                i += 1;
            }
            if (i < input.len) {
                try result.append(allocator, '`');
                i += 1;
            }
            line_start = false;
            continue;
        }

        // ── Links: [text](url) -> <url|text> ──
        if (i < input.len and input[i] == '[') {
            const text_start = i + 1;
            if (std.mem.indexOfScalar(u8, input[text_start..], ']')) |close_bracket_offset| {
                const text_end = text_start + close_bracket_offset;
                const after_bracket = text_end + 1;
                if (after_bracket < input.len and input[after_bracket] == '(') {
                    const url_start = after_bracket + 1;
                    if (std.mem.indexOfScalar(u8, input[url_start..], ')')) |close_paren_offset| {
                        const url_end = url_start + close_paren_offset;
                        try result.append(allocator, '<');
                        try result.appendSlice(allocator, input[url_start..url_end]);
                        try result.append(allocator, '|');
                        try result.appendSlice(allocator, input[text_start..text_end]);
                        try result.append(allocator, '>');
                        i = url_end + 1;
                        line_start = false;
                        continue;
                    }
                }
            }
        }

        // ── Track newlines for line_start ──
        if (input[i] == '\n') {
            try result.append(allocator, '\n');
            i += 1;
            line_start = true;
            continue;
        }

        // ── Default: copy character ──
        try result.append(allocator, input[i]);
        i += 1;
        line_start = false;
    }

    return result.toOwnedSlice(allocator);
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "slack channel init defaults" {
    const allowed = [_][]const u8{"U123"};
    var ch = SlackChannel.init(std.testing.allocator, "xoxb-test", null, "C123", &allowed);
    try std.testing.expectEqualStrings("xoxb-test", ch.bot_token);
    try std.testing.expectEqualStrings("C123", ch.channel_id.?);
    try std.testing.expectEqualStrings("0", ch.last_ts);
    try std.testing.expect(ch.thread_ts == null);
    try std.testing.expect(ch.app_token == null);
    _ = ch.channelName();
}

test "slack channel name" {
    const allowed = [_][]const u8{"*"};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);
    try std.testing.expectEqualStrings("slack", ch.channelName());
}

test "slack channel health check" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);
    try std.testing.expect(ch.healthCheck());
}

test "slack channel user allowed wildcard" {
    const allowed = [_][]const u8{"*"};
    const ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);
    try std.testing.expect(ch.isUserAllowed("anyone"));
}

test "slack channel user denied" {
    const allowed = [_][]const u8{"alice"};
    const ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);
    try std.testing.expect(!ch.isUserAllowed("bob"));
}

test "thread_ts field defaults to null" {
    const allowed = [_][]const u8{};
    const ch = SlackChannel.init(std.testing.allocator, "tok", null, "C1", &allowed);
    try std.testing.expect(ch.thread_ts == null);
}

test "setThreadTs sets and clears thread_ts" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, "C1", &allowed);

    ch.setThreadTs("1234567890.123456");
    try std.testing.expectEqualStrings("1234567890.123456", ch.thread_ts.?);

    ch.setThreadTs(null);
    try std.testing.expect(ch.thread_ts == null);
}

test "setThreadTs overwrites previous value" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, "C1", &allowed);

    ch.setThreadTs("111.111");
    try std.testing.expectEqualStrings("111.111", ch.thread_ts.?);

    ch.setThreadTs("222.222");
    try std.testing.expectEqualStrings("222.222", ch.thread_ts.?);
}

test "parseTarget without colon returns full target" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);

    const result = ch.parseTarget("C12345");
    try std.testing.expectEqualStrings("C12345", result);
    try std.testing.expect(ch.thread_ts == null);
}

test "parseTarget with colon splits channel and thread_ts" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);

    const result = ch.parseTarget("C12345:1699999999.000100");
    try std.testing.expectEqualStrings("C12345", result);
    try std.testing.expectEqualStrings("1699999999.000100", ch.thread_ts.?);
}

test "parseTarget colon at end gives empty thread_ts" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);

    const result = ch.parseTarget("C999:");
    try std.testing.expectEqualStrings("C999", result);
    try std.testing.expectEqualStrings("", ch.thread_ts.?);
}

test "mrkdwn bold conversion" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "This is **bold** text");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("This is *bold* text", result);
}

test "mrkdwn strikethrough conversion" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "This is ~~deleted~~ text");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("This is ~deleted~ text", result);
}

test "mrkdwn inline code preserved" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "Use `fmt.Println` here");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Use `fmt.Println` here", result);
}

test "mrkdwn code block preserved" {
    const input = "Before\n```\ncode here\n```\nAfter";
    const result = try markdownToSlackMrkdwn(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "mrkdwn link conversion" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "Visit [Google](https://google.com) now");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Visit <https://google.com|Google> now", result);
}

test "mrkdwn header conversion" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "# My Header");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("*My Header*", result);
}

test "mrkdwn h2 header conversion" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "## Sub Header");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("*Sub Header*", result);
}

test "mrkdwn bullet conversion" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "- item one\n- item two");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\xe2\x80\xa2 item one\n\xe2\x80\xa2 item two", result);
}

test "mrkdwn combined bold and strikethrough" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "**bold** and ~~strike~~");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("*bold* and ~strike~", result);
}

test "mrkdwn combined link and bold" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "**Click** [here](https://example.com)");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("*Click* <https://example.com|here>", result);
}

test "mrkdwn empty input" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "mrkdwn plain text unchanged" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "Hello world, no markdown here.");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello world, no markdown here.", result);
}

test "mrkdwn multiple headers" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "# Title\n## Subtitle");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("*Title*\n*Subtitle*", result);
}

test "mrkdwn link with special chars in text" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "[my site!](https://example.com/path?q=1)");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("<https://example.com/path?q=1|my site!>", result);
}

test "mrkdwn bullets with bold items" {
    const result = try markdownToSlackMrkdwn(std.testing.allocator, "- **first**\n- second");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\xe2\x80\xa2 *first*\n\xe2\x80\xa2 second", result);
}

test "slack channel vtable compiles" {
    const vt = SlackChannel.vtable;
    try std.testing.expect(@TypeOf(vt) == root.Channel.VTable);
}

test "slack channel interface returns slack name" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);
    const iface = ch.channel();
    try std.testing.expectEqualStrings("slack", iface.name());
}

test "slack channel api base constant" {
    try std.testing.expectEqualStrings("https://slack.com/api", SlackChannel.API_BASE);
}

// ════════════════════════════════════════════════════════════════════════════
// containsMention tests
// ════════════════════════════════════════════════════════════════════════════

test "containsMention detects mention" {
    try std.testing.expect(containsMention("Hello <@U12345> how are you?", "U12345"));
}

test "containsMention no mention" {
    try std.testing.expect(!containsMention("Hello world", "U12345"));
}

test "containsMention at start" {
    try std.testing.expect(containsMention("<@UBOT> do something", "UBOT"));
}

test "containsMention at end" {
    try std.testing.expect(containsMention("ping <@UBOT>", "UBOT"));
}

test "containsMention wrong user" {
    try std.testing.expect(!containsMention("Hey <@UOTHER>", "UBOT"));
}

test "containsMention empty text" {
    try std.testing.expect(!containsMention("", "UBOT"));
}

test "containsMention partial match not detected" {
    try std.testing.expect(!containsMention("<@UBOT", "UBOT"));
    try std.testing.expect(!containsMention("@UBOT>", "UBOT"));
}

// ════════════════════════════════════════════════════════════════════════════
// Per-channel policy integration tests (shouldHandle)
// ════════════════════════════════════════════════════════════════════════════

test "shouldHandle default policy allows DM" {
    const allowed = [_][]const u8{};
    const ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);
    // Default policy: dm=allow, group=open
    try std.testing.expect(ch.shouldHandle("U123", true, "hello", null));
}

test "shouldHandle default policy allows group without mention" {
    const allowed = [_][]const u8{};
    const ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);
    try std.testing.expect(ch.shouldHandle("U123", false, "hello", "UBOT"));
}

test "shouldHandle mention_only group requires mention" {
    const allowed = [_][]const u8{};
    const ch = SlackChannel.initWithPolicy(
        std.testing.allocator,
        "tok",
        null,
        null,
        &allowed,
        .{ .group = .mention_only },
    );
    try std.testing.expect(!ch.shouldHandle("U123", false, "hello", "UBOT"));
    try std.testing.expect(ch.shouldHandle("U123", false, "hey <@UBOT> help", "UBOT"));
}

test "shouldHandle deny dm blocks all DMs" {
    const allowed = [_][]const u8{};
    const ch = SlackChannel.initWithPolicy(
        std.testing.allocator,
        "tok",
        null,
        null,
        &allowed,
        .{ .dm = .deny },
    );
    try std.testing.expect(!ch.shouldHandle("U123", true, "hello", null));
    try std.testing.expect(!ch.shouldHandle("U456", true, "hi", "UBOT"));
}

test "shouldHandle dm allowlist permits listed users" {
    const allowed = [_][]const u8{};
    const list = [_][]const u8{ "alice", "bob" };
    const ch = SlackChannel.initWithPolicy(
        std.testing.allocator,
        "tok",
        null,
        null,
        &allowed,
        .{ .dm = .allowlist, .allowlist = &list },
    );
    try std.testing.expect(ch.shouldHandle("alice", true, "hi", null));
    try std.testing.expect(ch.shouldHandle("bob", true, "hi", null));
    try std.testing.expect(!ch.shouldHandle("eve", true, "hi", null));
}

test "shouldHandle group allowlist permits listed users" {
    const allowed = [_][]const u8{};
    const list = [_][]const u8{"trusted"};
    const ch = SlackChannel.initWithPolicy(
        std.testing.allocator,
        "tok",
        null,
        null,
        &allowed,
        .{ .group = .allowlist, .allowlist = &list },
    );
    try std.testing.expect(ch.shouldHandle("trusted", false, "msg", "UBOT"));
    try std.testing.expect(!ch.shouldHandle("stranger", false, "msg", "UBOT"));
}

test "shouldHandle mention_only without bot_user_id treats as no mention" {
    const allowed = [_][]const u8{};
    const ch = SlackChannel.initWithPolicy(
        std.testing.allocator,
        "tok",
        null,
        null,
        &allowed,
        .{ .group = .mention_only },
    );
    // No bot_user_id means mention cannot be detected
    try std.testing.expect(!ch.shouldHandle("U123", false, "hey <@UBOT> help", null));
}

test "initWithPolicy sets policy correctly" {
    const allowed = [_][]const u8{};
    const list = [_][]const u8{"admin"};
    const ch = SlackChannel.initWithPolicy(
        std.testing.allocator,
        "tok",
        "xapp-test",
        "C999",
        &allowed,
        .{ .dm = .deny, .group = .allowlist, .allowlist = &list },
    );
    try std.testing.expect(ch.policy.dm == .deny);
    try std.testing.expect(ch.policy.group == .allowlist);
    try std.testing.expectEqual(@as(usize, 1), ch.policy.allowlist.len);
    try std.testing.expectEqualStrings("admin", ch.policy.allowlist[0]);
    try std.testing.expectEqualStrings("tok", ch.bot_token);
    try std.testing.expectEqualStrings("xapp-test", ch.app_token.?);
    try std.testing.expectEqualStrings("C999", ch.channel_id.?);
}

// ════════════════════════════════════════════════════════════════════════════
// Socket Mode Tests
// ════════════════════════════════════════════════════════════════════════════

test "parseConnectionUrl extracts url" {
    const resp = "{\"ok\":true,\"url\":\"wss://wss-primary.slack.com/link?ticket=abc123\"}";
    const url = try SlackChannel.parseConnectionUrl(std.testing.allocator, resp);
    defer std.testing.allocator.free(url);
    try std.testing.expectEqualStrings("wss://wss-primary.slack.com/link?ticket=abc123", url);
}

test "parseConnectionUrl rejects not ok" {
    const resp = "{\"ok\":false,\"error\":\"invalid_auth\"}";
    try std.testing.expectError(error.SlackApiNotOk, SlackChannel.parseConnectionUrl(std.testing.allocator, resp));
}

test "parseConnectionUrl rejects missing url" {
    const resp = "{\"ok\":true}";
    try std.testing.expectError(error.MissingUrlField, SlackChannel.parseConnectionUrl(std.testing.allocator, resp));
}

test "parseConnectionUrl rejects missing ok" {
    const resp = "{\"url\":\"wss://example.com\"}";
    try std.testing.expectError(error.MissingOkField, SlackChannel.parseConnectionUrl(std.testing.allocator, resp));
}

test "parseWsHost from wss url" {
    const host = SlackChannel.parseWsHost("wss://wss-primary.slack.com/link?ticket=abc");
    try std.testing.expectEqualStrings("wss-primary.slack.com", host);
}

test "parseWsHost without path" {
    const host = SlackChannel.parseWsHost("wss://wss-primary.slack.com");
    try std.testing.expectEqualStrings("wss-primary.slack.com", host);
}

test "parseWsHost no scheme" {
    const host = SlackChannel.parseWsHost("wss-primary.slack.com/link");
    try std.testing.expectEqualStrings("wss-primary.slack.com", host);
}

test "parseWsPath from wss url" {
    const path = SlackChannel.parseWsPath("wss://wss-primary.slack.com/link?ticket=abc&app_id=A1");
    try std.testing.expectEqualStrings("/link?ticket=abc&app_id=A1", path);
}

test "parseWsPath no path returns slash" {
    const path = SlackChannel.parseWsPath("wss://wss-primary.slack.com");
    try std.testing.expectEqualStrings("/", path);
}

test "parseWsPath with just slash" {
    const path = SlackChannel.parseWsPath("wss://host.com/");
    try std.testing.expectEqualStrings("/", path);
}

test "isHelloEnvelope detects hello" {
    try std.testing.expect(SlackChannel.isHelloEnvelope(
        \\{"type":"hello","num_connections":1}
    ));
}

test "isHelloEnvelope rejects non-hello" {
    try std.testing.expect(!SlackChannel.isHelloEnvelope(
        \\{"type":"events_api","envelope_id":"abc"}
    ));
}

test "isHelloEnvelope rejects empty" {
    try std.testing.expect(!SlackChannel.isHelloEnvelope(""));
}

test "buildAckJson produces correct format" {
    var buf: [256]u8 = undefined;
    const ack = try SlackChannel.buildAckJson(&buf, "env-123-abc");
    try std.testing.expectEqualStrings("{\"envelope_id\":\"env-123-abc\"}", ack);
}

test "buildAckJson with long envelope id" {
    var buf: [256]u8 = undefined;
    const ack = try SlackChannel.buildAckJson(&buf, "1a2b3c4d-5e6f-7890-abcd-ef0123456789");
    try std.testing.expectEqualStrings("{\"envelope_id\":\"1a2b3c4d-5e6f-7890-abcd-ef0123456789\"}", ack);
}

test "socket mode fields have correct defaults" {
    const allowed = [_][]const u8{};
    const ch = SlackChannel.init(std.testing.allocator, "tok", "xapp-tok", null, &allowed);
    try std.testing.expect(ch.bus == null);
    try std.testing.expect(ch.bot_user_id == null);
    try std.testing.expect(!ch.running.load(.acquire));
    try std.testing.expect(ch.gateway_thread == null);
    try std.testing.expectEqual(@as(i32, -1), ch.ws_fd.load(.acquire));
}

test "vtableStart is no-op without app_token" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);
    // vtableStart should not error and should not spawn a thread
    const iface = ch.channel();
    try iface.start();
    try std.testing.expect(ch.gateway_thread == null);
    try std.testing.expect(!ch.running.load(.acquire));
}

test "vtableStop is safe without running thread" {
    const allowed = [_][]const u8{};
    var ch = SlackChannel.init(std.testing.allocator, "tok", null, null, &allowed);
    const iface = ch.channel();
    // Should not crash even without a running thread
    iface.stop();
}
