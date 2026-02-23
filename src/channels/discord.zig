const std = @import("std");
const builtin = @import("builtin");
const root = @import("root.zig");
const bus_mod = @import("../bus.zig");
const websocket = @import("../websocket.zig");

const log = std.log.scoped(.discord);

/// Discord channel — connects via WebSocket gateway, sends via REST API.
/// Splits messages at 2000 chars (Discord limit).
pub const DiscordChannel = struct {
    allocator: std.mem.Allocator,
    token: []const u8,
    guild_id: ?[]const u8,
    allow_bots: bool,

    // Optional gateway fields (have defaults so existing init works)
    application_id: ?[]const u8 = null,
    allow_from: []const []const u8 = &.{},
    mention_only: bool = true,
    intents: u32 = 37377, // GUILDS|GUILD_MESSAGES|MESSAGE_CONTENT|DIRECT_MESSAGES
    bus: ?*bus_mod.Bus = null,

    // Conversation mode — channels where bot responds to all messages
    conversation_channels: std.StringHashMapUnmanaged(void) = .empty,

    // Thread support — per-channel turn counts for auto-threading
    auto_thread_after: u32 = 0, // 0 = disabled
    turn_counts: std.StringHashMapUnmanaged(u32) = .empty,

    // Gateway state
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    sequence: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    heartbeat_interval_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    heartbeat_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    session_id: ?[]u8 = null,
    resume_gateway_url: ?[]u8 = null,
    bot_user_id: ?[]u8 = null,
    gateway_thread: ?std.Thread = null,
    ws_fd: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),

    pub const MAX_MESSAGE_LEN: usize = 2000;
    pub const GATEWAY_URL = "wss://gateway.discord.gg/?v=10&encoding=json";

    pub fn init(
        allocator: std.mem.Allocator,
        token: []const u8,
        guild_id: ?[]const u8,
        allow_bots: bool,
    ) DiscordChannel {
        return .{
            .allocator = allocator,
            .token = token,
            .guild_id = guild_id,
            .allow_bots = allow_bots,
        };
    }

    pub fn channelName(_: *DiscordChannel) []const u8 {
        return "discord";
    }

    /// Build a Discord REST API URL for sending to a channel.
    pub fn sendUrl(buf: []u8, channel_id: []const u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.print("https://discord.com/api/v10/channels/{s}/messages", .{channel_id});
        return fbs.getWritten();
    }

    /// Extract bot user ID from a bot token.
    /// Discord bot tokens are base64(bot_user_id).random.hmac
    pub fn extractBotUserId(token: []const u8) ?[]const u8 {
        // Find the first '.'
        const dot_pos = std.mem.indexOf(u8, token, ".") orelse return null;
        return token[0..dot_pos];
    }

    pub fn healthCheck(_: *DiscordChannel) bool {
        return true;
    }

    // ── Pure helper functions ─────────────────────────────────────────────

    /// Build IDENTIFY JSON payload (op=2).
    /// Example: {"op":2,"d":{"token":"Bot TOKEN","intents":37377,"properties":{"os":"linux","browser":"nullclaw","device":"nullclaw"}}}
    pub fn buildIdentifyJson(buf: []u8, token: []const u8, intents: u32) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.print(
            "{{\"op\":2,\"d\":{{\"token\":\"Bot {s}\",\"intents\":{d},\"properties\":{{\"os\":\"linux\",\"browser\":\"nullclaw\",\"device\":\"nullclaw\"}}}}}}",
            .{ token, intents },
        );
        return fbs.getWritten();
    }

    /// Build HEARTBEAT JSON payload (op=1).
    /// seq==0 → {"op":1,"d":null}, else {"op":1,"d":42}
    pub fn buildHeartbeatJson(buf: []u8, seq: i64) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        if (seq == 0) {
            try w.writeAll("{\"op\":1,\"d\":null}");
        } else {
            try w.print("{{\"op\":1,\"d\":{d}}}", .{seq});
        }
        return fbs.getWritten();
    }

    /// Build RESUME JSON payload (op=6).
    /// {"op":6,"d":{"token":"Bot TOKEN","session_id":"SESSION","seq":42}}
    pub fn buildResumeJson(buf: []u8, token: []const u8, session_id: []const u8, seq: i64) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.print(
            "{{\"op\":6,\"d\":{{\"token\":\"Bot {s}\",\"session_id\":\"{s}\",\"seq\":{d}}}}}",
            .{ token, session_id, seq },
        );
        return fbs.getWritten();
    }

    /// Parse gateway host from wss:// URL.
    /// "wss://us-east1.gateway.discord.gg" -> "us-east1.gateway.discord.gg"
    /// "wss://gateway.discord.gg/?v=10&encoding=json" -> "gateway.discord.gg"
    /// Returns slice into wss_url (no allocation).
    pub fn parseGatewayHost(wss_url: []const u8) []const u8 {
        // Strip scheme prefix if present
        const no_scheme = if (std.mem.startsWith(u8, wss_url, "wss://"))
            wss_url[6..]
        else if (std.mem.startsWith(u8, wss_url, "ws://"))
            wss_url[5..]
        else
            wss_url;

        // Strip path (everything after first '/' or '?')
        const slash_pos = std.mem.indexOf(u8, no_scheme, "/");
        const query_pos = std.mem.indexOf(u8, no_scheme, "?");

        const end = blk: {
            if (slash_pos != null and query_pos != null) {
                break :blk @min(slash_pos.?, query_pos.?);
            } else if (slash_pos != null) {
                break :blk slash_pos.?;
            } else if (query_pos != null) {
                break :blk query_pos.?;
            } else {
                break :blk no_scheme.len;
            }
        };

        return no_scheme[0..end];
    }

    /// Strip the bot's own mention (<@BOT_ID> or <@!BOT_ID>) from message content.
    /// Returns a newly allocated string with the mention removed, or the original if no mention found.
    fn stripBotMention(self: *DiscordChannel, content: []const u8, bot_uid: []const u8) ![]const u8 {
        if (bot_uid.len == 0) return content;

        // Try <@BOT_ID> first, then <@!BOT_ID>
        var buf1: [64]u8 = undefined;
        const mention1 = std.fmt.bufPrint(&buf1, "<@{s}>", .{bot_uid}) catch return content;
        var buf2: [64]u8 = undefined;
        const mention2 = std.fmt.bufPrint(&buf2, "<@!{s}>", .{bot_uid}) catch return content;

        const mention = if (std.mem.indexOf(u8, content, mention1) != null)
            mention1
        else if (std.mem.indexOf(u8, content, mention2) != null)
            mention2
        else
            return content;

        const pos = std.mem.indexOf(u8, content, mention).?;
        const before = content[0..pos];
        const after = content[pos + mention.len ..];
        const result = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ before, after });
        // Trim leading/trailing whitespace from the result
        const trimmed = std.mem.trim(u8, result, " ");
        if (trimmed.len == result.len) return result;
        // Re-allocate trimmed version and free the original
        const trimmed_copy = try self.allocator.dupe(u8, trimmed);
        self.allocator.free(result);
        return trimmed_copy;
    }

    /// Check if bot is mentioned in message content.
    /// Returns true if "<@BOT_ID>" or "<@!BOT_ID>" appears in content.
    pub fn isMentioned(content: []const u8, bot_user_id: []const u8) bool {
        // Check for <@BOT_ID>
        var buf1: [64]u8 = undefined;
        const mention1 = std.fmt.bufPrint(&buf1, "<@{s}>", .{bot_user_id}) catch return false;
        if (std.mem.indexOf(u8, content, mention1) != null) return true;

        // Check for <@!BOT_ID>
        var buf2: [64]u8 = undefined;
        const mention2 = std.fmt.bufPrint(&buf2, "<@!{s}>", .{bot_user_id}) catch return false;
        if (std.mem.indexOf(u8, content, mention2) != null) return true;

        return false;
    }

    /// Check if this message is a reply to a message authored by the bot.
    /// Inspects d.referenced_message.author.id in the MESSAGE_CREATE payload.
    pub fn isReplyToBot(d_obj: std.json.ObjectMap, bot_user_id: []const u8) bool {
        if (bot_user_id.len == 0) return false;
        const ref_msg = d_obj.get("referenced_message") orelse return false;
        const ref_obj = switch (ref_msg) {
            .object => |o| o,
            else => return false,
        };
        const ref_author = ref_obj.get("author") orelse return false;
        const ref_author_obj = switch (ref_author) {
            .object => |o| o,
            else => return false,
        };
        const ref_author_id = ref_author_obj.get("id") orelse return false;
        const ref_id_str = switch (ref_author_id) {
            .string => |s| s,
            else => return false,
        };
        return std.mem.eql(u8, ref_id_str, bot_user_id);
    }

    // ── Thread support ──────────────────────────────────────────────

    /// Build a Discord REST API URL for creating a thread from a message.
    /// POST /channels/{channel_id}/messages/{message_id}/threads
    pub fn createThreadUrl(buf: []u8, channel_id: []const u8, message_id: []const u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.print("https://discord.com/api/v10/channels/{s}/messages/{s}/threads", .{ channel_id, message_id });
        return fbs.getWritten();
    }

    /// Check if a MESSAGE_CREATE payload has a message_reference field (thread/reply context).
    pub fn hasMessageReference(d_obj: std.json.ObjectMap) bool {
        return d_obj.get("message_reference") != null;
    }

    /// Extract the channel_id from a message_reference field (thread context).
    pub fn getMessageReferenceChannelId(d_obj: std.json.ObjectMap) ?[]const u8 {
        const ref_val = d_obj.get("message_reference") orelse return null;
        const ref_obj = switch (ref_val) {
            .object => |o| o,
            else => return null,
        };
        const chan_val = ref_obj.get("channel_id") orelse return null;
        return switch (chan_val) {
            .string => |s| s,
            else => null,
        };
    }

    /// Create a new thread from a message via Discord REST API.
    /// POST /channels/{channel_id}/messages/{message_id}/threads
    pub fn createThread(self: *DiscordChannel, channel_id: []const u8, message_id: []const u8, name: []const u8) !void {
        var url_buf: [512]u8 = undefined;
        const url = try createThreadUrl(&url_buf, channel_id, message_id);

        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);

        try body_list.appendSlice(self.allocator, "{\"name\":");
        try root.json_util.appendJsonString(&body_list, self.allocator, name);
        try body_list.appendSlice(self.allocator, ",\"auto_archive_duration\":60}");

        var auth_buf: [512]u8 = undefined;
        var auth_fbs = std.io.fixedBufferStream(&auth_buf);
        try auth_fbs.writer().print("Authorization: Bot {s}", .{self.token});
        const auth_header = auth_fbs.getWritten();

        const resp = root.http_util.curlPost(self.allocator, url, body_list.items, &.{auth_header}) catch |err| {
            log.err("Discord: thread creation failed: {}", .{err});
            return error.DiscordApiError;
        };
        self.allocator.free(resp);
    }

    /// Increment the turn count for a channel. Returns the new count.
    pub fn incrementTurnCount(self: *DiscordChannel, channel_id: []const u8) u32 {
        if (self.turn_counts.getPtr(channel_id)) |count_ptr| {
            count_ptr.* += 1;
            return count_ptr.*;
        }
        const key = self.allocator.dupe(u8, channel_id) catch return 1;
        self.turn_counts.put(self.allocator, key, 1) catch {
            self.allocator.free(key);
            return 1;
        };
        return 1;
    }

    /// Reset the turn count for a channel (e.g., after creating a thread).
    pub fn resetTurnCount(self: *DiscordChannel, channel_id: []const u8) void {
        if (self.turn_counts.fetchRemove(channel_id)) |entry| {
            self.allocator.free(entry.key);
        }
    }

    /// Get the current turn count for a channel.
    pub fn getTurnCount(self: *DiscordChannel, channel_id: []const u8) u32 {
        return self.turn_counts.get(channel_id) orelse 0;
    }

    // ── Channel vtable ──────────────────────────────────────────────

    /// Send a message to a Discord channel via REST API.
    /// Splits at MAX_MESSAGE_LEN (2000 chars).
    pub fn sendMessage(self: *DiscordChannel, channel_id: []const u8, text: []const u8) !void {
        var it = root.splitMessage(text, MAX_MESSAGE_LEN);
        while (it.next()) |chunk| {
            try self.sendChunk(channel_id, chunk);
        }
    }

    fn sendChunk(self: *DiscordChannel, channel_id: []const u8, text: []const u8) !void {
        var url_buf: [256]u8 = undefined;
        const url = try sendUrl(&url_buf, channel_id);

        // Build JSON body: {"content":"..."}
        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);

        try body_list.appendSlice(self.allocator, "{\"content\":");
        try root.json_util.appendJsonString(&body_list, self.allocator, text);
        try body_list.appendSlice(self.allocator, "}");

        // Build auth header value: "Authorization: Bot <token>"
        var auth_buf: [512]u8 = undefined;
        var auth_fbs = std.io.fixedBufferStream(&auth_buf);
        try auth_fbs.writer().print("Authorization: Bot {s}", .{self.token});
        const auth_header = auth_fbs.getWritten();

        const resp = root.http_util.curlPost(self.allocator, url, body_list.items, &.{auth_header}) catch |err| {
            log.err("Discord API POST failed: {}", .{err});
            return error.DiscordApiError;
        };
        self.allocator.free(resp);
    }

    // ── Reactions ─────────────────────────────────────────────────────

    /// Add an emoji reaction to a message via Discord REST API.
    /// `emoji` should be URL-encoded (e.g. "%F0%9F%91%80" for eyes).
    pub fn addReaction(self: *DiscordChannel, channel_id: []const u8, message_id: []const u8, emoji: []const u8) void {
        var url_buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&url_buf);
        fbs.writer().print(
            "https://discord.com/api/v10/channels/{s}/messages/{s}/reactions/{s}/@me",
            .{ channel_id, message_id, emoji },
        ) catch return;
        const url = fbs.getWritten();

        var auth_buf: [512]u8 = undefined;
        var auth_fbs = std.io.fixedBufferStream(&auth_buf);
        auth_fbs.writer().print("Authorization: Bot {s}", .{self.token}) catch return;
        const auth_header = auth_fbs.getWritten();

        root.http_util.curlPutEmpty(self.allocator, url, &.{auth_header}) catch |err| {
            log.warn("Discord: failed to add reaction: {}", .{err});
        };
    }

    // ── Slash Commands ────────────────────────────────────────────────

    /// Build the URL for bulk-overwriting global application commands.
    /// PUT /applications/{app_id}/commands
    pub fn bulkOverwriteUrl(buf: []u8, app_id: []const u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.print("https://discord.com/api/v10/applications/{s}/commands", .{app_id});
        return fbs.getWritten();
    }

    /// Build the URL for sending an interaction response.
    /// POST /interactions/{interaction_id}/{interaction_token}/callback
    pub fn interactionResponseUrl(buf: []u8, interaction_id: []const u8, interaction_token: []const u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.print("https://discord.com/api/v10/interactions/{s}/{s}/callback", .{ interaction_id, interaction_token });
        return fbs.getWritten();
    }

    /// Build the URL for sending a followup message.
    /// POST /webhooks/{app_id}/{interaction_token}
    pub fn followupUrl(buf: []u8, app_id: []const u8, interaction_token: []const u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.print("https://discord.com/api/v10/webhooks/{s}/{s}", .{ app_id, interaction_token });
        return fbs.getWritten();
    }

    /// JSON payload for registering all 4 slash commands via bulk overwrite.
    pub const SLASH_COMMANDS_JSON =
        \\[{"name":"ask","description":"Ask the bot a question","type":1,"options":[{"name":"prompt","description":"Your question or prompt","type":3,"required":true}]},
        \\{"name":"remember","description":"Store a key-value pair in memory","type":1,"options":[{"name":"key","description":"Memory key","type":3,"required":true},{"name":"value","description":"Value to remember","type":3,"required":true}]},
        \\{"name":"forget","description":"Remove a key from memory","type":1,"options":[{"name":"key","description":"Memory key to forget","type":3,"required":true}]},
        \\{"name":"status","description":"Show bot status","type":1}]
    ;

    /// Register slash commands with Discord's bulk overwrite endpoint.
    /// Requires application_id to be configured.
    pub fn registerSlashCommands(self: *DiscordChannel) !void {
        const app_id = self.application_id orelse return;

        var url_buf: [256]u8 = undefined;
        const url = try bulkOverwriteUrl(&url_buf, app_id);

        var auth_buf: [512]u8 = undefined;
        var auth_fbs = std.io.fixedBufferStream(&auth_buf);
        try auth_fbs.writer().print("Authorization: Bot {s}", .{self.token});
        const auth_header = auth_fbs.getWritten();

        const resp = root.http_util.curlPut(self.allocator, url, SLASH_COMMANDS_JSON, &.{auth_header}) catch |err| {
            log.err("Discord: failed to register slash commands: {}", .{err});
            return error.DiscordApiError;
        };
        defer self.allocator.free(resp);

        log.info("Discord: slash commands registered for app {s}", .{app_id});
    }

    /// Send an interaction response (type 4 = channel message, type 5 = deferred).
    /// `resp_type` should be 4 for immediate response or 5 for deferred.
    pub fn sendInteractionResponse(self: *DiscordChannel, interaction_id: []const u8, interaction_token: []const u8, resp_type: u8, content: ?[]const u8) !void {
        var url_buf: [512]u8 = undefined;
        const url = try interactionResponseUrl(&url_buf, interaction_id, interaction_token);

        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);

        if (content) |text| {
            try body_list.appendSlice(self.allocator, "{\"type\":");
            var type_buf: [4]u8 = undefined;
            const type_str = try std.fmt.bufPrint(&type_buf, "{d}", .{resp_type});
            try body_list.appendSlice(self.allocator, type_str);
            try body_list.appendSlice(self.allocator, ",\"data\":{\"content\":");
            try root.json_util.appendJsonString(&body_list, self.allocator, text);
            try body_list.appendSlice(self.allocator, "}}");
        } else {
            // Deferred response (type 5) with no content
            try body_list.appendSlice(self.allocator, "{\"type\":");
            var type_buf: [4]u8 = undefined;
            const type_str = try std.fmt.bufPrint(&type_buf, "{d}", .{resp_type});
            try body_list.appendSlice(self.allocator, type_str);
            try body_list.appendSlice(self.allocator, "}");
        }

        const resp = root.http_util.curlPost(self.allocator, url, body_list.items, &.{}) catch |err| {
            log.err("Discord: interaction response failed: {}", .{err});
            return error.DiscordApiError;
        };
        self.allocator.free(resp);
    }

    /// Send a followup message to an interaction.
    pub fn sendFollowup(self: *DiscordChannel, interaction_token: []const u8, content: []const u8) !void {
        const app_id = self.application_id orelse return error.NoApplicationId;

        var url_buf: [512]u8 = undefined;
        const url = try followupUrl(&url_buf, app_id, interaction_token);

        var body_list: std.ArrayListUnmanaged(u8) = .empty;
        defer body_list.deinit(self.allocator);

        try body_list.appendSlice(self.allocator, "{\"content\":");
        try root.json_util.appendJsonString(&body_list, self.allocator, content);
        try body_list.appendSlice(self.allocator, "}");

        var auth_buf: [512]u8 = undefined;
        var auth_fbs = std.io.fixedBufferStream(&auth_buf);
        try auth_fbs.writer().print("Authorization: Bot {s}", .{self.token});
        const auth_header = auth_fbs.getWritten();

        const resp = root.http_util.curlPost(self.allocator, url, body_list.items, &.{auth_header}) catch |err| {
            log.err("Discord: followup message failed: {}", .{err});
            return error.DiscordApiError;
        };
        self.allocator.free(resp);
    }

    /// Build JSON for an interaction response of a given type with optional content.
    /// Returns a slice into the provided buffer.
    pub fn buildInteractionResponseJson(buf: []u8, resp_type: u8, content: ?[]const u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        if (content) |text| {
            try w.print("{{\"type\":{d},\"data\":{{\"content\":\"{s}\"}}}}", .{ resp_type, text });
        } else {
            try w.print("{{\"type\":{d}}}", .{resp_type});
        }
        return fbs.getWritten();
    }

    /// Parse an INTERACTION_CREATE event and extract command details.
    /// Returns command name, interaction id, interaction token, channel_id, and user id.
    pub const InteractionInfo = struct {
        command_name: []const u8,
        interaction_id: []const u8,
        interaction_token: []const u8,
        channel_id: []const u8,
        user_id: []const u8,
        guild_id: ?[]const u8,
    };

    /// Extract an option value by name from interaction data options array.
    pub fn getInteractionOption(d_obj: std.json.ObjectMap, option_name: []const u8) ?[]const u8 {
        const data_val = d_obj.get("data") orelse return null;
        const data_obj = switch (data_val) {
            .object => |o| o,
            else => return null,
        };
        const options_val = data_obj.get("options") orelse return null;
        const options_arr = switch (options_val) {
            .array => |a| a,
            else => return null,
        };
        for (options_arr.items) |opt_val| {
            const opt_obj = switch (opt_val) {
                .object => |o| o,
                else => continue,
            };
            const name_val = opt_obj.get("name") orelse continue;
            const name_str = switch (name_val) {
                .string => |s| s,
                else => continue,
            };
            if (std.mem.eql(u8, name_str, option_name)) {
                const value_val = opt_obj.get("value") orelse return null;
                return switch (value_val) {
                    .string => |s| s,
                    else => null,
                };
            }
        }
        return null;
    }

    /// Parse INTERACTION_CREATE event "d" object into InteractionInfo.
    pub fn parseInteraction(d_obj: std.json.ObjectMap) ?InteractionInfo {
        // type must be 2 (APPLICATION_COMMAND)
        const type_val = d_obj.get("type") orelse return null;
        const interaction_type: i64 = switch (type_val) {
            .integer => |i| i,
            else => return null,
        };
        if (interaction_type != 2) return null;

        const id_val = d_obj.get("id") orelse return null;
        const interaction_id: []const u8 = switch (id_val) {
            .string => |s| s,
            else => return null,
        };

        const token_val = d_obj.get("token") orelse return null;
        const interaction_token: []const u8 = switch (token_val) {
            .string => |s| s,
            else => return null,
        };

        const channel_val = d_obj.get("channel_id") orelse return null;
        const channel_id: []const u8 = switch (channel_val) {
            .string => |s| s,
            else => return null,
        };

        // Extract command name from data.name
        const data_val = d_obj.get("data") orelse return null;
        const data_obj = switch (data_val) {
            .object => |o| o,
            else => return null,
        };
        const name_val = data_obj.get("name") orelse return null;
        const command_name: []const u8 = switch (name_val) {
            .string => |s| s,
            else => return null,
        };

        // Extract user id from member.user.id (guild) or user.id (DM)
        const user_id: []const u8 = blk: {
            if (d_obj.get("member")) |member_val| {
                const member_obj = switch (member_val) {
                    .object => |o| o,
                    else => break :blk "",
                };
                const user_val = member_obj.get("user") orelse break :blk "";
                const user_obj = switch (user_val) {
                    .object => |o| o,
                    else => break :blk "",
                };
                const uid_val = user_obj.get("id") orelse break :blk "";
                break :blk switch (uid_val) {
                    .string => |s| s,
                    else => "",
                };
            } else if (d_obj.get("user")) |user_val| {
                const user_obj = switch (user_val) {
                    .object => |o| o,
                    else => break :blk "",
                };
                const uid_val = user_obj.get("id") orelse break :blk "";
                break :blk switch (uid_val) {
                    .string => |s| s,
                    else => "",
                };
            } else break :blk "";
        };

        const guild_id: ?[]const u8 = if (d_obj.get("guild_id")) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null;

        return .{
            .command_name = command_name,
            .interaction_id = interaction_id,
            .interaction_token = interaction_token,
            .channel_id = channel_id,
            .user_id = user_id,
            .guild_id = guild_id,
        };
    }

    /// Handle INTERACTION_CREATE event: parse, send deferred response, and publish to bus.
    fn handleInteractionCreate(self: *DiscordChannel, root_val: std.json.Value) !void {
        const d_val = root_val.object.get("d") orelse return;
        const d_obj = switch (d_val) {
            .object => |o| o,
            else => return,
        };

        const info = parseInteraction(d_obj) orelse return;

        // Build content string from command + options
        var content_buf: [2048]u8 = undefined;
        var content_fbs = std.io.fixedBufferStream(&content_buf);
        const cw = content_fbs.writer();

        if (std.mem.eql(u8, info.command_name, "ask")) {
            const prompt = getInteractionOption(d_obj, "prompt") orelse "help";
            cw.print("/{s} {s}", .{ info.command_name, prompt }) catch return;
        } else if (std.mem.eql(u8, info.command_name, "remember")) {
            const key = getInteractionOption(d_obj, "key") orelse "";
            const value = getInteractionOption(d_obj, "value") orelse "";
            cw.print("/{s} {s} {s}", .{ info.command_name, key, value }) catch return;
        } else if (std.mem.eql(u8, info.command_name, "forget")) {
            const key = getInteractionOption(d_obj, "key") orelse "";
            cw.print("/{s} {s}", .{ info.command_name, key }) catch return;
        } else if (std.mem.eql(u8, info.command_name, "status")) {
            cw.print("/{s}", .{info.command_name}) catch return;
        } else {
            return; // Unknown command
        }
        const content = content_fbs.getWritten();

        // Send deferred response (type 5) so user sees "thinking..."
        self.sendInteractionResponse(info.interaction_id, info.interaction_token, 5, null) catch |err| {
            log.warn("Discord: failed to send deferred response: {}", .{err});
        };

        // Build session_key and metadata, publish to bus
        const session_key = std.fmt.allocPrint(self.allocator, "discord:{s}", .{info.channel_id}) catch return;
        defer self.allocator.free(session_key);

        // Metadata includes interaction token for followup responses
        var meta_buf: [512]u8 = undefined;
        var meta_fbs = std.io.fixedBufferStream(&meta_buf);
        meta_fbs.writer().print("{{\"interaction_token\":\"{s}\",\"command\":\"{s}\"}}", .{ info.interaction_token, info.command_name }) catch return;
        const metadata_json: ?[]const u8 = if (meta_fbs.pos > 0) meta_fbs.getWritten() else null;

        const msg = bus_mod.makeInboundFull(
            self.allocator,
            "discord",
            info.user_id,
            info.channel_id,
            content,
            session_key,
            &.{},
            metadata_json,
        ) catch return;

        if (self.bus) |b| {
            b.publishInbound(msg) catch |err| {
                log.warn("Discord: failed to publish interaction message: {}", .{err});
                msg.deinit(self.allocator);
            };
        } else {
            msg.deinit(self.allocator);
        }
    }

    // ── Conversation mode ───────────────────────────────────────────

    /// Enable conversation mode for a channel (bot responds to all messages).
    pub fn setConversationMode(self: *DiscordChannel, channel_id: []const u8) void {
        if (self.conversation_channels.get(channel_id) != null) return; // already active
        const key = self.allocator.dupe(u8, channel_id) catch return;
        self.conversation_channels.put(self.allocator, key, {}) catch {
            self.allocator.free(key);
        };
        log.info("Discord: conversation mode enabled for channel {s}", .{channel_id});
    }

    /// Disable conversation mode for a channel.
    pub fn clearConversationMode(self: *DiscordChannel, channel_id: []const u8) void {
        if (self.conversation_channels.fetchRemove(channel_id)) |entry| {
            self.allocator.free(entry.key);
            log.info("Discord: conversation mode disabled for channel {s}", .{channel_id});
        }
    }

    /// Check if a channel has conversation mode active.
    pub fn isConversationChannel(self: *DiscordChannel, channel_id: []const u8) bool {
        return self.conversation_channels.get(channel_id) != null;
    }

    // ── Gateway ──────────────────────────────────────────────────────

    fn vtableStart(ptr: *anyopaque) anyerror!void {
        const self: *DiscordChannel = @ptrCast(@alignCast(ptr));
        self.running.store(true, .release);
        self.gateway_thread = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, gatewayLoop, .{self});
    }

    fn vtableStop(ptr: *anyopaque) void {
        const self: *DiscordChannel = @ptrCast(@alignCast(ptr));
        self.running.store(false, .release);
        self.heartbeat_stop.store(true, .release);
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
        // Free session state
        if (self.session_id) |s| {
            self.allocator.free(s);
            self.session_id = null;
        }
        if (self.resume_gateway_url) |u| {
            self.allocator.free(u);
            self.resume_gateway_url = null;
        }
        if (self.bot_user_id) |u| {
            self.allocator.free(u);
            self.bot_user_id = null;
        }
        // Free conversation mode channel keys
        var conv_it = self.conversation_channels.keyIterator();
        while (conv_it.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.conversation_channels.deinit(self.allocator);
        // Free turn count keys
        var turn_it = self.turn_counts.keyIterator();
        while (turn_it.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.turn_counts.deinit(self.allocator);
    }

    fn vtableSend(ptr: *anyopaque, target: []const u8, message: []const u8) anyerror!void {
        const self: *DiscordChannel = @ptrCast(@alignCast(ptr));
        try self.sendMessage(target, message);
    }

    fn vtableName(ptr: *anyopaque) []const u8 {
        const self: *DiscordChannel = @ptrCast(@alignCast(ptr));
        return self.channelName();
    }

    fn vtableHealthCheck(ptr: *anyopaque) bool {
        const self: *DiscordChannel = @ptrCast(@alignCast(ptr));
        return self.healthCheck();
    }

    pub const vtable = root.Channel.VTable{
        .start = &vtableStart,
        .stop = &vtableStop,
        .send = &vtableSend,
        .name = &vtableName,
        .healthCheck = &vtableHealthCheck,
    };

    pub fn channel(self: *DiscordChannel) root.Channel {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    // ── Gateway loop ─────────────────────────────────────────────────

    fn gatewayLoop(self: *DiscordChannel) void {
        while (self.running.load(.acquire)) {
            self.runGatewayOnce() catch |err| {
                log.warn("Discord gateway error: {}", .{err});
            };
            if (!self.running.load(.acquire)) break;
            // 5 second backoff between reconnects (interruptible)
            var slept: u64 = 0;
            while (slept < 5000 and self.running.load(.acquire)) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                slept += 100;
            }
        }
    }

    fn runGatewayOnce(self: *DiscordChannel) !void {
        // Determine host
        const default_host = "gateway.discord.gg";
        const host: []const u8 = if (self.resume_gateway_url) |u| parseGatewayHost(u) else default_host;

        var ws = try websocket.WsClient.connect(
            self.allocator,
            host,
            443,
            "/?v=10&encoding=json",
            &.{},
        );

        // Store fd for interrupt-on-stop
        self.ws_fd.store(ws.stream.handle, .release);

        // Start heartbeat thread — on failure, clean up ws manually (no errdefer to avoid
        // double-deinit with the defer block below once spawn succeeds).
        self.heartbeat_stop.store(false, .release);
        self.heartbeat_interval_ms.store(0, .release);
        const hbt = std.Thread.spawn(.{ .stack_size = 128 * 1024 }, heartbeatLoop, .{ self, &ws }) catch |err| {
            ws.deinit();
            return err;
        };
        defer {
            self.heartbeat_stop.store(true, .release);
            hbt.join();
            self.ws_fd.store(-1, .release);
            ws.deinit();
        }

        // Wait for HELLO (first message)
        const hello_text = try ws.readTextMessage() orelse return error.ConnectionClosed;
        defer self.allocator.free(hello_text);
        try self.handleHello(&ws, hello_text);

        // IDENTIFY or RESUME
        if (self.session_id != null) {
            try self.sendResumePayload(&ws);
        } else {
            try self.sendIdentifyPayload(&ws);
        }

        // Main read loop
        while (self.running.load(.acquire)) {
            const maybe_text = ws.readTextMessage() catch break;
            const text = maybe_text orelse break;
            defer self.allocator.free(text);
            self.handleGatewayMessage(&ws, text) catch |err| switch (err) {
                error.ShouldReconnect => break,
            };
        }
    }

    // ── Heartbeat thread ─────────────────────────────────────────────

    fn heartbeatLoop(self: *DiscordChannel, ws: *websocket.WsClient) void {
        // Wait for interval to be set
        while (!self.heartbeat_stop.load(.acquire) and self.heartbeat_interval_ms.load(.acquire) == 0) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        while (!self.heartbeat_stop.load(.acquire)) {
            const interval_ms = self.heartbeat_interval_ms.load(.acquire);
            var elapsed: u64 = 0;
            while (elapsed < interval_ms) {
                if (self.heartbeat_stop.load(.acquire)) return;
                std.Thread.sleep(100 * std.time.ns_per_ms);
                elapsed += 100;
            }
            if (self.heartbeat_stop.load(.acquire)) return;

            const seq = self.sequence.load(.acquire);
            var hb_buf: [64]u8 = undefined;
            const hb_json = buildHeartbeatJson(&hb_buf, seq) catch continue;
            ws.writeText(hb_json) catch |err| {
                log.warn("Discord heartbeat failed: {}", .{err});
            };
        }
    }

    // ── Message handlers ─────────────────────────────────────────────

    /// Parse HELLO payload and store heartbeat interval.
    fn handleHello(self: *DiscordChannel, _: *websocket.WsClient, text: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, text, .{});
        defer parsed.deinit();

        const root_val = parsed.value;
        const d_val = root_val.object.get("d") orelse return;
        switch (d_val) {
            .object => |d_obj| {
                const hb_val = d_obj.get("heartbeat_interval") orelse return;
                switch (hb_val) {
                    .integer => |ms| {
                        if (ms > 0) {
                            self.heartbeat_interval_ms.store(@intCast(ms), .release);
                        }
                    },
                    .float => |ms| {
                        if (ms > 0) {
                            self.heartbeat_interval_ms.store(@intFromFloat(ms), .release);
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    /// Handle a gateway message, switching on op code.
    fn handleGatewayMessage(self: *DiscordChannel, ws: *websocket.WsClient, text: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, text, .{}) catch |err| {
            log.warn("Discord: failed to parse gateway message: {}", .{err});
            return;
        };
        defer parsed.deinit();

        const root_val = parsed.value;

        // Get op code
        const op_val = root_val.object.get("op") orelse {
            log.warn("Discord: gateway message missing 'op' field", .{});
            return;
        };
        const op: i64 = switch (op_val) {
            .integer => |i| i,
            else => {
                log.warn("Discord: gateway 'op' is not an integer", .{});
                return;
            },
        };

        switch (op) {
            10 => { // HELLO
                self.handleHello(ws, text) catch |err| {
                    log.warn("Discord: handleHello error: {}", .{err});
                };
            },
            0 => { // DISPATCH
                // Update sequence from "s" field
                if (root_val.object.get("s")) |s_val| {
                    switch (s_val) {
                        .integer => |s| {
                            if (s > self.sequence.load(.acquire)) {
                                self.sequence.store(s, .release);
                            }
                        },
                        else => {},
                    }
                }

                // Get event type "t"
                const t_val = root_val.object.get("t") orelse return;
                const event_type: []const u8 = switch (t_val) {
                    .string => |s| s,
                    else => return,
                };

                if (std.mem.eql(u8, event_type, "READY")) {
                    self.handleReady(root_val) catch |err| {
                        log.warn("Discord: handleReady error: {}", .{err});
                    };
                    // Register slash commands after READY if application_id is set
                    if (self.application_id != null) {
                        self.registerSlashCommands() catch |err| {
                            log.warn("Discord: slash command registration failed: {}", .{err});
                        };
                    }
                } else if (std.mem.eql(u8, event_type, "INTERACTION_CREATE")) {
                    self.handleInteractionCreate(root_val) catch |err| {
                        log.warn("Discord: handleInteractionCreate error: {}", .{err});
                    };
                } else if (std.mem.eql(u8, event_type, "MESSAGE_CREATE")) {
                    self.handleMessageCreate(root_val) catch |err| {
                        log.warn("Discord: handleMessageCreate error: {}", .{err});
                    };
                }
            },
            1 => { // HEARTBEAT — server requests immediate heartbeat
                const seq = self.sequence.load(.acquire);
                var hb_buf: [64]u8 = undefined;
                const hb_json = buildHeartbeatJson(&hb_buf, seq) catch return;
                ws.writeText(hb_json) catch |err| {
                    log.warn("Discord: immediate heartbeat failed: {}", .{err});
                };
            },
            11 => { // HEARTBEAT_ACK
                // No-op — heartbeat acknowledged
            },
            7 => { // RECONNECT
                log.info("Discord: server requested reconnect", .{});
                return error.ShouldReconnect;
            },
            9 => { // INVALID_SESSION
                // Check if resumable (d field)
                const d_val = root_val.object.get("d");
                const resumable = if (d_val) |d| switch (d) {
                    .bool => |b| b,
                    else => false,
                } else false;

                if (!resumable) {
                    // Free session state — must re-identify
                    if (self.session_id) |s| {
                        self.allocator.free(s);
                        self.session_id = null;
                    }
                    if (self.resume_gateway_url) |u| {
                        self.allocator.free(u);
                        self.resume_gateway_url = null;
                    }
                }

                // Send IDENTIFY
                self.sendIdentifyPayload(ws) catch |err| {
                    log.warn("Discord: re-identify failed: {}", .{err});
                    return error.ShouldReconnect;
                };
            },
            else => {
                log.warn("Discord: unhandled gateway op={d}", .{op});
            },
        }
    }

    /// Handle READY event: extract session_id, resume_gateway_url, bot_user_id.
    fn handleReady(self: *DiscordChannel, root_val: std.json.Value) !void {
        const d_val = root_val.object.get("d") orelse {
            log.warn("Discord READY: missing 'd' field", .{});
            return;
        };
        const d_obj = switch (d_val) {
            .object => |o| o,
            else => {
                log.warn("Discord READY: 'd' is not an object", .{});
                return;
            },
        };

        // Extract session_id
        if (d_obj.get("session_id")) |sid_val| {
            switch (sid_val) {
                .string => |s| {
                    if (self.session_id) |old| self.allocator.free(old);
                    self.session_id = try self.allocator.dupe(u8, s);
                },
                else => {},
            }
        }

        // Extract resume_gateway_url
        if (d_obj.get("resume_gateway_url")) |rgu_val| {
            switch (rgu_val) {
                .string => |s| {
                    if (self.resume_gateway_url) |old| self.allocator.free(old);
                    self.resume_gateway_url = try self.allocator.dupe(u8, s);
                },
                else => {},
            }
        }

        // Extract bot user ID from d.user.id
        if (d_obj.get("user")) |user_val| {
            switch (user_val) {
                .object => |user_obj| {
                    if (user_obj.get("id")) |id_val| {
                        switch (id_val) {
                            .string => |s| {
                                if (self.bot_user_id) |old| self.allocator.free(old);
                                self.bot_user_id = try self.allocator.dupe(u8, s);
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }

        log.info("Discord READY: session_id={s}", .{self.session_id orelse "<none>"});
    }

    /// Handle MESSAGE_CREATE event and publish to bus if filters pass.
    fn handleMessageCreate(self: *DiscordChannel, root_val: std.json.Value) !void {
        const d_val = root_val.object.get("d") orelse {
            log.warn("Discord MESSAGE_CREATE: missing 'd' field", .{});
            return;
        };
        const d_obj = switch (d_val) {
            .object => |o| o,
            else => {
                log.warn("Discord MESSAGE_CREATE: 'd' is not an object", .{});
                return;
            },
        };

        // Extract message id
        const message_id: []const u8 = if (d_obj.get("id")) |v| switch (v) {
            .string => |s| s,
            else => "",
        } else "";

        // Extract channel_id
        const channel_id: []const u8 = if (d_obj.get("channel_id")) |v| switch (v) {
            .string => |s| s,
            else => {
                log.warn("Discord MESSAGE_CREATE: 'channel_id' is not a string", .{});
                return;
            },
        } else {
            log.warn("Discord MESSAGE_CREATE: missing 'channel_id'", .{});
            return;
        };

        // Extract content
        const content: []const u8 = if (d_obj.get("content")) |v| switch (v) {
            .string => |s| s,
            else => "",
        } else "";

        // Extract guild_id (optional — absent for DMs)
        const guild_id: ?[]const u8 = if (d_obj.get("guild_id")) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null;

        // Extract author object
        const author_obj = if (d_obj.get("author")) |v| switch (v) {
            .object => |o| o,
            else => {
                log.warn("Discord MESSAGE_CREATE: 'author' is not an object", .{});
                return;
            },
        } else {
            log.warn("Discord MESSAGE_CREATE: missing 'author'", .{});
            return;
        };

        // Extract author.id
        const author_id: []const u8 = if (author_obj.get("id")) |v| switch (v) {
            .string => |s| s,
            else => {
                log.warn("Discord MESSAGE_CREATE: 'author.id' is not a string", .{});
                return;
            },
        } else {
            log.warn("Discord MESSAGE_CREATE: missing 'author.id'", .{});
            return;
        };

        // Extract author.bot (defaults to false if absent)
        const author_is_bot: bool = if (author_obj.get("bot")) |v| switch (v) {
            .bool => |b| b,
            else => false,
        } else false;

        // Filter 1: bot author
        if (author_is_bot and !self.allow_bots) {
            return;
        }

        // Filter 2: mention_only for guild (non-DM) messages
        // Pass if: @mentioned, replying to a bot message, DM, or conversation mode active
        if (self.mention_only and guild_id != null and !self.isConversationChannel(channel_id)) {
            const bot_uid = self.bot_user_id orelse "";
            const is_mentioned = isMentioned(content, bot_uid);
            const is_reply_to_bot = isReplyToBot(d_obj, bot_uid);
            if (!is_mentioned and !is_reply_to_bot) {
                return;
            }
        }

        // Filter 3: allow_from allowlist
        if (self.allow_from.len > 0) {
            if (!root.isAllowed(self.allow_from, author_id)) {
                return;
            }
        }

        // Strip bot's own mention from content so the LLM sees clean text
        const clean_content = if (self.bot_user_id) |bot_uid| self.stripBotMention(content, bot_uid) catch content else content;
        const clean_content_owned = if (self.bot_user_id != null) !std.mem.eql(u8, @as([]const u8, clean_content), @as([]const u8, content)) else false;
        defer if (clean_content_owned) self.allocator.free(clean_content);

        // Thread detection: check for message_reference
        const in_thread = hasMessageReference(d_obj);

        // Track conversation turns per channel (skip for thread messages)
        if (!in_thread) {
            const turns = self.incrementTurnCount(channel_id);

            // Auto-create thread if threshold exceeded
            if (self.auto_thread_after > 0 and turns >= self.auto_thread_after and message_id.len > 0) {
                self.createThread(channel_id, message_id, "Continued conversation") catch |err| {
                    log.warn("Discord: auto-thread creation failed: {}", .{err});
                };
                self.resetTurnCount(channel_id);
            }
        }

        // Build session_key and publish to bus
        const session_key = try std.fmt.allocPrint(self.allocator, "discord:{s}", .{channel_id});
        defer self.allocator.free(session_key);

        // Build metadata JSON with message_id and thread context
        var meta_buf: [512]u8 = undefined;
        var meta_fbs = std.io.fixedBufferStream(&meta_buf);
        if (in_thread) {
            const ref_chan = getMessageReferenceChannelId(d_obj) orelse channel_id;
            meta_fbs.writer().print("{{\"message_id\":\"{s}\",\"in_thread\":true,\"thread_channel_id\":\"{s}\"}}", .{ message_id, ref_chan }) catch {};
        } else {
            meta_fbs.writer().print("{{\"message_id\":\"{s}\",\"in_thread\":false}}", .{message_id}) catch {};
        }
        const metadata_json: ?[]const u8 = if (meta_fbs.pos > 0) meta_fbs.getWritten() else null;

        const msg = try bus_mod.makeInboundFull(
            self.allocator,
            "discord",
            author_id,
            channel_id,
            clean_content,
            session_key,
            &.{},
            metadata_json,
        );

        if (self.bus) |b| {
            b.publishInbound(msg) catch |err| {
                log.warn("Discord: failed to publish inbound message: {}", .{err});
                msg.deinit(self.allocator);
            };
        } else {
            // No bus configured — free the message
            msg.deinit(self.allocator);
        }
    }

    /// Send IDENTIFY payload.
    fn sendIdentifyPayload(self: *DiscordChannel, ws: *websocket.WsClient) !void {
        var buf: [1024]u8 = undefined;
        const json = try buildIdentifyJson(&buf, self.token, self.intents);
        try ws.writeText(json);
    }

    /// Send RESUME payload.
    fn sendResumePayload(self: *DiscordChannel, ws: *websocket.WsClient) !void {
        const sid = self.session_id orelse return error.NoSessionId;
        const seq = self.sequence.load(.acquire);
        var buf: [512]u8 = undefined;
        const json = try buildResumeJson(&buf, self.token, sid, seq);
        try ws.writeText(json);
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "discord send url" {
    var buf: [256]u8 = undefined;
    const url = try DiscordChannel.sendUrl(&buf, "123456");
    try std.testing.expectEqualStrings("https://discord.com/api/v10/channels/123456/messages", url);
}

test "discord extract bot user id" {
    const id = DiscordChannel.extractBotUserId("MTIzNDU2.Ghijk.abcdef");
    try std.testing.expectEqualStrings("MTIzNDU2", id.?);
}

test "discord extract bot user id no dot" {
    try std.testing.expect(DiscordChannel.extractBotUserId("notokenformat") == null);
}

// ════════════════════════════════════════════════════════════════════════════
// Additional Discord Tests (ported from ZeroClaw Rust)
// ════════════════════════════════════════════════════════════════════════════

test "discord send url with different channel ids" {
    var buf: [256]u8 = undefined;
    const url1 = try DiscordChannel.sendUrl(&buf, "999");
    try std.testing.expectEqualStrings("https://discord.com/api/v10/channels/999/messages", url1);

    var buf2: [256]u8 = undefined;
    const url2 = try DiscordChannel.sendUrl(&buf2, "1234567890");
    try std.testing.expectEqualStrings("https://discord.com/api/v10/channels/1234567890/messages", url2);
}

test "discord extract bot user id multiple dots" {
    // Token format: base64(user_id).timestamp.hmac
    const id = DiscordChannel.extractBotUserId("MTIzNDU2.fake.hmac");
    try std.testing.expectEqualStrings("MTIzNDU2", id.?);
}

test "discord extract bot user id empty token" {
    // Empty string before dot means empty result
    const id = DiscordChannel.extractBotUserId("");
    try std.testing.expect(id == null);
}

test "discord extract bot user id single dot" {
    const id = DiscordChannel.extractBotUserId("abc.");
    try std.testing.expectEqualStrings("abc", id.?);
}

test "discord max message len constant" {
    try std.testing.expectEqual(@as(usize, 2000), DiscordChannel.MAX_MESSAGE_LEN);
}

test "discord gateway url constant" {
    try std.testing.expectEqualStrings("wss://gateway.discord.gg/?v=10&encoding=json", DiscordChannel.GATEWAY_URL);
}

test "discord init stores fields" {
    const ch = DiscordChannel.init(std.testing.allocator, "my-bot-token", "guild-123", true);
    try std.testing.expectEqualStrings("my-bot-token", ch.token);
    try std.testing.expectEqualStrings("guild-123", ch.guild_id.?);
    try std.testing.expect(ch.allow_bots);
}

test "discord init no guild id" {
    const ch = DiscordChannel.init(std.testing.allocator, "tok", null, false);
    try std.testing.expect(ch.guild_id == null);
    try std.testing.expect(!ch.allow_bots);
}

test "discord send url buffer too small returns error" {
    var buf: [10]u8 = undefined;
    const result = DiscordChannel.sendUrl(&buf, "123456");
    try std.testing.expect(if (result) |_| false else |_| true);
}

// ════════════════════════════════════════════════════════════════════════════
// New Gateway Helper Tests
// ════════════════════════════════════════════════════════════════════════════

test "discord buildIdentifyJson" {
    var buf: [512]u8 = undefined;
    const json = try DiscordChannel.buildIdentifyJson(&buf, "mytoken", 37377);
    // Should contain op:2 and the token and intents
    try std.testing.expect(std.mem.indexOf(u8, json, "\"op\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "mytoken") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "37377") != null);
}

test "discord buildHeartbeatJson no sequence" {
    var buf: [64]u8 = undefined;
    const json = try DiscordChannel.buildHeartbeatJson(&buf, 0);
    try std.testing.expectEqualStrings("{\"op\":1,\"d\":null}", json);
}

test "discord buildHeartbeatJson with sequence" {
    var buf: [64]u8 = undefined;
    const json = try DiscordChannel.buildHeartbeatJson(&buf, 42);
    try std.testing.expectEqualStrings("{\"op\":1,\"d\":42}", json);
}

test "discord buildResumeJson" {
    var buf: [256]u8 = undefined;
    const json = try DiscordChannel.buildResumeJson(&buf, "mytoken", "session123", 99);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"op\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "session123") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "99") != null);
}

test "discord parseGatewayHost from wss url" {
    const host = DiscordChannel.parseGatewayHost("wss://us-east1.gateway.discord.gg");
    try std.testing.expectEqualStrings("us-east1.gateway.discord.gg", host);
}

test "discord parseGatewayHost with path" {
    const host = DiscordChannel.parseGatewayHost("wss://gateway.discord.gg/?v=10&encoding=json");
    try std.testing.expectEqualStrings("gateway.discord.gg", host);
}

test "discord parseGatewayHost no scheme returns original" {
    const host = DiscordChannel.parseGatewayHost("gateway.discord.gg");
    try std.testing.expectEqualStrings("gateway.discord.gg", host);
}

test "discord isMentioned with user id" {
    try std.testing.expect(DiscordChannel.isMentioned("<@123456> hello", "123456"));
    try std.testing.expect(DiscordChannel.isMentioned("hello <@!123456>", "123456"));
    try std.testing.expect(!DiscordChannel.isMentioned("hello world", "123456"));
    try std.testing.expect(!DiscordChannel.isMentioned("<@999999> hello", "123456"));
}

test "discord intents default" {
    const ch = DiscordChannel.init(std.testing.allocator, "tok", null, false);
    try std.testing.expectEqual(@as(u32, 37377), ch.intents);
}

test "discord intent bitmask guilds" {
    // GUILDS = 1
    try std.testing.expectEqual(@as(u32, 1), 1);
    // GUILD_MESSAGES = 512
    try std.testing.expectEqual(@as(u32, 512), 512);
    // MESSAGE_CONTENT = 32768
    try std.testing.expectEqual(@as(u32, 32768), 32768);
    // DIRECT_MESSAGES = 4096
    try std.testing.expectEqual(@as(u32, 4096), 4096);
    // Default intents = 1|512|32768|4096 = 37377
    try std.testing.expectEqual(@as(u32, 37377), 1 | 512 | 32768 | 4096);
}

test "discord mention_only defaults to true" {
    const ch = DiscordChannel.init(std.testing.allocator, "tok", null, false);
    try std.testing.expect(ch.mention_only);
}

test "discord conversation mode set and clear" {
    var ch = DiscordChannel.init(std.testing.allocator, "tok", null, false);
    defer ch.conversation_channels.deinit(std.testing.allocator);

    // Initially not in conversation mode
    try std.testing.expect(!ch.isConversationChannel("chan123"));

    // Enable conversation mode
    ch.setConversationMode("chan123");
    try std.testing.expect(ch.isConversationChannel("chan123"));
    try std.testing.expect(!ch.isConversationChannel("other"));

    // Disable conversation mode
    ch.clearConversationMode("chan123");
    try std.testing.expect(!ch.isConversationChannel("chan123"));
}

test "discord conversation mode double set is idempotent" {
    var ch = DiscordChannel.init(std.testing.allocator, "tok", null, false);
    defer ch.conversation_channels.deinit(std.testing.allocator);

    ch.setConversationMode("chan1");
    ch.setConversationMode("chan1"); // should not leak
    try std.testing.expect(ch.isConversationChannel("chan1"));

    ch.clearConversationMode("chan1");
    try std.testing.expect(!ch.isConversationChannel("chan1"));
}

test "discord conversation mode clear nonexistent is safe" {
    var ch = DiscordChannel.init(std.testing.allocator, "tok", null, false);
    defer ch.conversation_channels.deinit(std.testing.allocator);

    // Should not crash
    ch.clearConversationMode("nonexistent");
}

// ════════════════════════════════════════════════════════════════════════════
// Slash Command and Interaction Tests
// ════════════════════════════════════════════════════════════════════════════

test "discord bulkOverwriteUrl" {
    var buf: [256]u8 = undefined;
    const url = try DiscordChannel.bulkOverwriteUrl(&buf, "123456789");
    try std.testing.expectEqualStrings("https://discord.com/api/v10/applications/123456789/commands", url);
}

test "discord interactionResponseUrl" {
    var buf: [512]u8 = undefined;
    const url = try DiscordChannel.interactionResponseUrl(&buf, "inter_123", "token_abc");
    try std.testing.expectEqualStrings("https://discord.com/api/v10/interactions/inter_123/token_abc/callback", url);
}

test "discord followupUrl" {
    var buf: [512]u8 = undefined;
    const url = try DiscordChannel.followupUrl(&buf, "app_123", "token_abc");
    try std.testing.expectEqualStrings("https://discord.com/api/v10/webhooks/app_123/token_abc", url);
}

test "discord buildInteractionResponseJson deferred" {
    var buf: [256]u8 = undefined;
    const json = try DiscordChannel.buildInteractionResponseJson(&buf, 5, null);
    try std.testing.expectEqualStrings("{\"type\":5}", json);
}

test "discord buildInteractionResponseJson with content" {
    var buf: [256]u8 = undefined;
    const json = try DiscordChannel.buildInteractionResponseJson(&buf, 4, "hello world");
    try std.testing.expectEqualStrings("{\"type\":4,\"data\":{\"content\":\"hello world\"}}", json);
}

test "discord application_id defaults to null" {
    const ch = DiscordChannel.init(std.testing.allocator, "tok", null, false);
    try std.testing.expect(ch.application_id == null);
}

test "discord application_id can be set" {
    var ch = DiscordChannel.init(std.testing.allocator, "tok", null, false);
    ch.application_id = "app_12345";
    try std.testing.expectEqualStrings("app_12345", ch.application_id.?);
}

test "discord SLASH_COMMANDS_JSON is valid json" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, DiscordChannel.SLASH_COMMANDS_JSON, .{});
    defer parsed.deinit();
    // Should be an array of 4 commands
    try std.testing.expect(parsed.value == .array);
    try std.testing.expectEqual(@as(usize, 4), parsed.value.array.items.len);

    // Verify command names
    const commands = parsed.value.array.items;
    const name0 = commands[0].object.get("name").?.string;
    try std.testing.expectEqualStrings("ask", name0);
    const name1 = commands[1].object.get("name").?.string;
    try std.testing.expectEqualStrings("remember", name1);
    const name2 = commands[2].object.get("name").?.string;
    try std.testing.expectEqualStrings("forget", name2);
    const name3 = commands[3].object.get("name").?.string;
    try std.testing.expectEqualStrings("status", name3);
}

test "discord parseInteraction valid ask command" {
    const json =
        \\{"type":2,"id":"inter_1","token":"tok_abc","channel_id":"chan_1",
        \\"data":{"name":"ask","options":[{"name":"prompt","value":"hello?","type":3}]},
        \\"member":{"user":{"id":"user_42"}},"guild_id":"guild_1"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const info = DiscordChannel.parseInteraction(parsed.value.object).?;
    try std.testing.expectEqualStrings("ask", info.command_name);
    try std.testing.expectEqualStrings("inter_1", info.interaction_id);
    try std.testing.expectEqualStrings("tok_abc", info.interaction_token);
    try std.testing.expectEqualStrings("chan_1", info.channel_id);
    try std.testing.expectEqualStrings("user_42", info.user_id);
    try std.testing.expectEqualStrings("guild_1", info.guild_id.?);
}

test "discord parseInteraction DM user fallback" {
    const json =
        \\{"type":2,"id":"inter_2","token":"tok_def","channel_id":"dm_1",
        \\"data":{"name":"status"},"user":{"id":"user_99"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const info = DiscordChannel.parseInteraction(parsed.value.object).?;
    try std.testing.expectEqualStrings("status", info.command_name);
    try std.testing.expectEqualStrings("user_99", info.user_id);
    try std.testing.expect(info.guild_id == null);
}

test "discord parseInteraction rejects non-command type" {
    const json =
        \\{"type":1,"id":"inter_3","token":"tok_ghi","channel_id":"chan_2",
        \\"data":{"name":"ping"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(DiscordChannel.parseInteraction(parsed.value.object) == null);
}

test "discord parseInteraction missing data returns null" {
    const json =
        \\{"type":2,"id":"inter_4","token":"tok_jkl","channel_id":"chan_3"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(DiscordChannel.parseInteraction(parsed.value.object) == null);
}

test "discord getInteractionOption extracts value" {
    const json =
        \\{"data":{"name":"ask","options":[{"name":"prompt","value":"what is 2+2?","type":3}]}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const val = DiscordChannel.getInteractionOption(parsed.value.object, "prompt");
    try std.testing.expectEqualStrings("what is 2+2?", val.?);
}

test "discord getInteractionOption missing option returns null" {
    const json =
        \\{"data":{"name":"ask","options":[{"name":"prompt","value":"hello","type":3}]}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(DiscordChannel.getInteractionOption(parsed.value.object, "nonexistent") == null);
}

test "discord getInteractionOption no options array returns null" {
    const json =
        \\{"data":{"name":"status"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(DiscordChannel.getInteractionOption(parsed.value.object, "key") == null);
}

test "discord getInteractionOption remember command two options" {
    const json =
        \\{"data":{"name":"remember","options":[{"name":"key","value":"foo","type":3},{"name":"value","value":"bar","type":3}]}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("foo", DiscordChannel.getInteractionOption(parsed.value.object, "key").?);
    try std.testing.expectEqualStrings("bar", DiscordChannel.getInteractionOption(parsed.value.object, "value").?);
}

test "discord SLASH_COMMANDS_JSON ask has required prompt option" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, DiscordChannel.SLASH_COMMANDS_JSON, .{});
    defer parsed.deinit();
    const ask_cmd = parsed.value.array.items[0].object;
    const options = ask_cmd.get("options").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), options.len);
    try std.testing.expectEqualStrings("prompt", options[0].object.get("name").?.string);
    try std.testing.expect(options[0].object.get("required").?.bool);
}

test "discord SLASH_COMMANDS_JSON remember has two required options" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, DiscordChannel.SLASH_COMMANDS_JSON, .{});
    defer parsed.deinit();
    const remember_cmd = parsed.value.array.items[1].object;
    const options = remember_cmd.get("options").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), options.len);
    try std.testing.expectEqualStrings("key", options[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("value", options[1].object.get("name").?.string);
}

test "discord SLASH_COMMANDS_JSON status has no options" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, DiscordChannel.SLASH_COMMANDS_JSON, .{});
    defer parsed.deinit();
    const status_cmd = parsed.value.array.items[3].object;
    try std.testing.expect(status_cmd.get("options") == null);
}

// ════════════════════════════════════════════════════════════════════════════
// Thread Support Tests
// ════════════════════════════════════════════════════════════════════════════

test "discord createThreadUrl builds correct endpoint" {
    var buf: [512]u8 = undefined;
    const url = try DiscordChannel.createThreadUrl(&buf, "chan_123", "msg_456");
    try std.testing.expectEqualStrings("https://discord.com/api/v10/channels/chan_123/messages/msg_456/threads", url);
}

test "discord createThreadUrl with different ids" {
    var buf: [512]u8 = undefined;
    const url = try DiscordChannel.createThreadUrl(&buf, "999", "888");
    try std.testing.expectEqualStrings("https://discord.com/api/v10/channels/999/messages/888/threads", url);
}

test "discord createThreadUrl buffer too small returns error" {
    var buf: [10]u8 = undefined;
    const result = DiscordChannel.createThreadUrl(&buf, "chan_123", "msg_456");
    try std.testing.expect(if (result) |_| false else |_| true);
}

test "discord hasMessageReference detects thread message" {
    const json =
        \\{"content":"hello","message_reference":{"channel_id":"thread_1","message_id":"ref_1"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(DiscordChannel.hasMessageReference(parsed.value.object));
}

test "discord hasMessageReference returns false for regular message" {
    const json =
        \\{"content":"hello","channel_id":"chan_1"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(!DiscordChannel.hasMessageReference(parsed.value.object));
}

test "discord getMessageReferenceChannelId extracts channel" {
    const json =
        \\{"content":"hello","message_reference":{"channel_id":"thread_42","message_id":"ref_1"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const ref_chan = DiscordChannel.getMessageReferenceChannelId(parsed.value.object);
    try std.testing.expectEqualStrings("thread_42", ref_chan.?);
}

test "discord getMessageReferenceChannelId returns null without reference" {
    const json =
        \\{"content":"hello"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(DiscordChannel.getMessageReferenceChannelId(parsed.value.object) == null);
}

test "discord getMessageReferenceChannelId returns null for non-object reference" {
    const json =
        \\{"content":"hello","message_reference":"not_an_object"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(DiscordChannel.getMessageReferenceChannelId(parsed.value.object) == null);
}

test "discord turn count increment and get" {
    var ch = DiscordChannel.init(std.testing.allocator, "tok", null, false);
    defer {
        var it = ch.turn_counts.keyIterator();
        while (it.next()) |key_ptr| ch.allocator.free(key_ptr.*);
        ch.turn_counts.deinit(std.testing.allocator);
    }

    // Initially zero
    try std.testing.expectEqual(@as(u32, 0), ch.getTurnCount("chan_1"));

    // Increment
    try std.testing.expectEqual(@as(u32, 1), ch.incrementTurnCount("chan_1"));
    try std.testing.expectEqual(@as(u32, 1), ch.getTurnCount("chan_1"));

    // Increment again
    try std.testing.expectEqual(@as(u32, 2), ch.incrementTurnCount("chan_1"));
    try std.testing.expectEqual(@as(u32, 2), ch.getTurnCount("chan_1"));
}

test "discord turn count reset" {
    var ch = DiscordChannel.init(std.testing.allocator, "tok", null, false);
    defer {
        var it = ch.turn_counts.keyIterator();
        while (it.next()) |key_ptr| ch.allocator.free(key_ptr.*);
        ch.turn_counts.deinit(std.testing.allocator);
    }

    _ = ch.incrementTurnCount("chan_1");
    _ = ch.incrementTurnCount("chan_1");
    _ = ch.incrementTurnCount("chan_1");
    try std.testing.expectEqual(@as(u32, 3), ch.getTurnCount("chan_1"));

    ch.resetTurnCount("chan_1");
    try std.testing.expectEqual(@as(u32, 0), ch.getTurnCount("chan_1"));
}

test "discord turn count per channel isolation" {
    var ch = DiscordChannel.init(std.testing.allocator, "tok", null, false);
    defer {
        var it = ch.turn_counts.keyIterator();
        while (it.next()) |key_ptr| ch.allocator.free(key_ptr.*);
        ch.turn_counts.deinit(std.testing.allocator);
    }

    _ = ch.incrementTurnCount("chan_a");
    _ = ch.incrementTurnCount("chan_a");
    _ = ch.incrementTurnCount("chan_b");

    try std.testing.expectEqual(@as(u32, 2), ch.getTurnCount("chan_a"));
    try std.testing.expectEqual(@as(u32, 1), ch.getTurnCount("chan_b"));
}

test "discord turn count reset nonexistent is safe" {
    var ch = DiscordChannel.init(std.testing.allocator, "tok", null, false);
    defer ch.turn_counts.deinit(std.testing.allocator);

    ch.resetTurnCount("nonexistent"); // should not crash
}

test "discord auto_thread_after defaults to disabled" {
    const ch = DiscordChannel.init(std.testing.allocator, "tok", null, false);
    try std.testing.expectEqual(@as(u32, 0), ch.auto_thread_after);
}
