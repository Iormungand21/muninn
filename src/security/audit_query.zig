const std = @import("std");
const Allocator = std.mem.Allocator;
const audit = @import("audit.zig");
const AuditEventType = audit.AuditEventType;

/// A parsed audit event record from JSONL.
pub const ParsedEvent = struct {
    timestamp_s: i64,
    event_id: u64,
    event_type: []const u8,
    actor_channel: ?[]const u8,
    actor_user_id: ?[]const u8,
    actor_username: ?[]const u8,
    action_command: ?[]const u8,
    action_risk_level: ?[]const u8,
    action_approved: ?bool,
    action_allowed: ?bool,
    result_success: ?bool,
    result_exit_code: ?i32,
    result_duration_ms: ?u64,
    result_error: ?[]const u8,
    security_policy_violation: bool,
    raw_line: []const u8,

    pub fn actorDisplay(self: *const ParsedEvent) []const u8 {
        if (self.actor_username) |u| return u;
        if (self.actor_user_id) |u| return u;
        if (self.actor_channel) |c| return c;
        return "(unknown)";
    }
};

/// Search filter criteria.
pub const SearchFilter = struct {
    actor: ?[]const u8 = null,
    action: ?[]const u8 = null,
    event_type: ?[]const u8 = null,
    since_s: ?i64 = null,
};

/// Stats accumulator for audit events.
pub const AuditStats = struct {
    total_events: u64 = 0,
    by_action: std.StringArrayHashMap(u64),
    by_actor: std.StringArrayHashMap(u64),

    pub fn init(allocator: Allocator) AuditStats {
        return .{
            .by_action = std.StringArrayHashMap(u64).init(allocator),
            .by_actor = std.StringArrayHashMap(u64).init(allocator),
        };
    }

    pub fn deinit(self: *AuditStats) void {
        for (self.by_action.keys()) |k| self.by_action.allocator.free(k);
        self.by_action.deinit();
        for (self.by_actor.keys()) |k| self.by_actor.allocator.free(k);
        self.by_actor.deinit();
    }
};

/// Parse a single JSONL line into a ParsedEvent.
/// Returns null if the line is empty or cannot be parsed.
pub fn parseEventLine(allocator: Allocator, line: []const u8) ?ParsedEvent {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch return null;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };

    const timestamp_s: i64 = if (obj.get("timestamp_s")) |v| switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => return null,
    } else return null;

    const event_id: u64 = if (obj.get("event_id")) |v| switch (v) {
        .integer => |i| @intCast(i),
        .float => |f| @intFromFloat(f),
        else => 0,
    } else 0;

    const event_type = if (obj.get("event_type")) |v| switch (v) {
        .string => |s| allocator.dupe(u8, s) catch return null,
        else => allocator.dupe(u8, "unknown") catch return null,
    } else allocator.dupe(u8, "unknown") catch return null;

    // Parse actor
    var actor_channel: ?[]const u8 = null;
    var actor_user_id: ?[]const u8 = null;
    var actor_username: ?[]const u8 = null;
    if (obj.get("actor")) |actor_val| {
        if (actor_val == .object) {
            const actor_obj = actor_val.object;
            if (actor_obj.get("channel")) |v| if (v == .string) {
                actor_channel = allocator.dupe(u8, v.string) catch null;
            };
            if (actor_obj.get("user_id")) |v| if (v == .string) {
                actor_user_id = allocator.dupe(u8, v.string) catch null;
            };
            if (actor_obj.get("username")) |v| if (v == .string) {
                actor_username = allocator.dupe(u8, v.string) catch null;
            };
        }
    }

    // Parse action
    var action_command: ?[]const u8 = null;
    var action_risk_level: ?[]const u8 = null;
    var action_approved: ?bool = null;
    var action_allowed: ?bool = null;
    if (obj.get("action")) |action_val| {
        if (action_val == .object) {
            const action_obj = action_val.object;
            if (action_obj.get("command")) |v| if (v == .string) {
                action_command = allocator.dupe(u8, v.string) catch null;
            };
            if (action_obj.get("risk_level")) |v| if (v == .string) {
                action_risk_level = allocator.dupe(u8, v.string) catch null;
            };
            if (action_obj.get("approved")) |v| if (v == .bool) {
                action_approved = v.bool;
            };
            if (action_obj.get("allowed")) |v| if (v == .bool) {
                action_allowed = v.bool;
            };
        }
    }

    // Parse result
    var result_success: ?bool = null;
    var result_exit_code: ?i32 = null;
    var result_duration_ms: ?u64 = null;
    var result_error: ?[]const u8 = null;
    if (obj.get("result")) |result_val| {
        if (result_val == .object) {
            const result_obj = result_val.object;
            if (result_obj.get("success")) |v| if (v == .bool) {
                result_success = v.bool;
            };
            if (result_obj.get("exit_code")) |v| switch (v) {
                .integer => |i| {
                    result_exit_code = @intCast(i);
                },
                else => {},
            };
            if (result_obj.get("duration_ms")) |v| switch (v) {
                .integer => |i| {
                    result_duration_ms = @intCast(i);
                },
                else => {},
            };
            if (result_obj.get("error")) |v| if (v == .string) {
                result_error = allocator.dupe(u8, v.string) catch null;
            };
        }
    }

    // Parse security
    var policy_violation = false;
    if (obj.get("security")) |sec_val| {
        if (sec_val == .object) {
            if (sec_val.object.get("policy_violation")) |v| if (v == .bool) {
                policy_violation = v.bool;
            };
        }
    }

    const raw_dupe = allocator.dupe(u8, trimmed) catch return null;

    return .{
        .timestamp_s = timestamp_s,
        .event_id = event_id,
        .event_type = event_type,
        .actor_channel = actor_channel,
        .actor_user_id = actor_user_id,
        .actor_username = actor_username,
        .action_command = action_command,
        .action_risk_level = action_risk_level,
        .action_approved = action_approved,
        .action_allowed = action_allowed,
        .result_success = result_success,
        .result_exit_code = result_exit_code,
        .result_duration_ms = result_duration_ms,
        .result_error = result_error,
        .security_policy_violation = policy_violation,
        .raw_line = raw_dupe,
    };
}

/// Free a ParsedEvent's owned strings.
pub fn freeParsedEvent(allocator: Allocator, ev: *const ParsedEvent) void {
    allocator.free(ev.event_type);
    if (ev.actor_channel) |s| allocator.free(s);
    if (ev.actor_user_id) |s| allocator.free(s);
    if (ev.actor_username) |s| allocator.free(s);
    if (ev.action_command) |s| allocator.free(s);
    if (ev.action_risk_level) |s| allocator.free(s);
    if (ev.result_error) |s| allocator.free(s);
    allocator.free(ev.raw_line);
}

/// Check whether a ParsedEvent matches the given filter.
fn matchesFilter(ev: *const ParsedEvent, filter: *const SearchFilter) bool {
    if (filter.since_s) |since| {
        if (ev.timestamp_s < since) return false;
    }
    if (filter.actor) |actor_pat| {
        const matches_channel = if (ev.actor_channel) |c| containsInsensitive(c, actor_pat) else false;
        const matches_uid = if (ev.actor_user_id) |u| containsInsensitive(u, actor_pat) else false;
        const matches_uname = if (ev.actor_username) |u| containsInsensitive(u, actor_pat) else false;
        if (!matches_channel and !matches_uid and !matches_uname) return false;
    }
    if (filter.action) |action_pat| {
        const matches_cmd = if (ev.action_command) |c| containsInsensitive(c, action_pat) else false;
        const matches_type = containsInsensitive(ev.event_type, action_pat);
        if (!matches_cmd and !matches_type) return false;
    }
    if (filter.event_type) |et| {
        if (!std.mem.eql(u8, ev.event_type, et)) return false;
    }
    return true;
}

/// Case-insensitive substring check (ASCII only).
fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// Read all lines from audit log file.
fn readLogLines(allocator: Allocator, log_path: []const u8) ![][]const u8 {
    const file = std.fs.cwd().openFile(log_path, .{}) catch |err| {
        if (err == error.FileNotFound) return try allocator.alloc([]const u8, 0);
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 64 * 1024 * 1024); // 64MB max
    defer allocator.free(content);

    var lines: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (lines.items) |l| allocator.free(l);
        lines.deinit(allocator);
    }

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r");
        if (trimmed.len == 0) continue;
        try lines.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return lines.toOwnedSlice(allocator);
}

/// Search audit events by filter criteria.
/// Returns matching events sorted by timestamp ascending.
pub fn searchEvents(allocator: Allocator, log_path: []const u8, filter: *const SearchFilter) ![]ParsedEvent {
    const lines = try readLogLines(allocator, log_path);
    defer {
        for (lines) |l| allocator.free(l);
        allocator.free(lines);
    }

    var results: std.ArrayList(ParsedEvent) = .empty;
    errdefer {
        for (results.items) |*ev| freeParsedEvent(allocator, ev);
        results.deinit(allocator);
    }

    for (lines) |line| {
        if (parseEventLine(allocator, line)) |ev| {
            if (matchesFilter(&ev, filter)) {
                try results.append(allocator, ev);
            } else {
                freeParsedEvent(allocator, &ev);
            }
        }
    }

    return results.toOwnedSlice(allocator);
}

/// Return the last N events from the audit log.
pub fn tailEvents(allocator: Allocator, log_path: []const u8, count: usize) ![]ParsedEvent {
    const lines = try readLogLines(allocator, log_path);
    defer {
        for (lines) |l| allocator.free(l);
        allocator.free(lines);
    }

    // Take last `count` lines
    const start = if (lines.len > count) lines.len - count else 0;
    const tail_lines = lines[start..];

    var results: std.ArrayList(ParsedEvent) = .empty;
    errdefer {
        for (results.items) |*ev| freeParsedEvent(allocator, ev);
        results.deinit(allocator);
    }

    for (tail_lines) |line| {
        if (parseEventLine(allocator, line)) |ev| {
            try results.append(allocator, ev);
        }
    }

    return results.toOwnedSlice(allocator);
}

/// Compute aggregate stats from the entire audit log.
pub fn computeAuditStats(allocator: Allocator, log_path: []const u8) !AuditStats {
    const lines = try readLogLines(allocator, log_path);
    defer {
        for (lines) |l| allocator.free(l);
        allocator.free(lines);
    }

    var stats = AuditStats.init(allocator);
    errdefer stats.deinit();

    for (lines) |line| {
        if (parseEventLine(allocator, line)) |ev| {
            defer freeParsedEvent(allocator, &ev);
            stats.total_events += 1;

            // Count by event_type (used as "action type")
            const action_key = allocator.dupe(u8, ev.event_type) catch continue;
            const action_entry = stats.by_action.getOrPut(action_key) catch {
                allocator.free(action_key);
                continue;
            };
            if (action_entry.found_existing) {
                allocator.free(action_key);
                action_entry.value_ptr.* += 1;
            } else {
                action_entry.value_ptr.* = 1;
            }

            // Count by actor
            const actor_display = ev.actorDisplay();
            const actor_key = allocator.dupe(u8, actor_display) catch continue;
            const actor_entry = stats.by_actor.getOrPut(actor_key) catch {
                allocator.free(actor_key);
                continue;
            };
            if (actor_entry.found_existing) {
                allocator.free(actor_key);
                actor_entry.value_ptr.* += 1;
            } else {
                actor_entry.value_ptr.* = 1;
            }
        }
    }

    return stats;
}

/// Parse a human-readable duration string like "7d", "24h", "30m" into seconds.
/// Returns null if the format is unrecognized.
pub fn parseDuration(s: []const u8) ?i64 {
    if (s.len < 2) return null;
    const suffix = s[s.len - 1];
    const num_str = s[0 .. s.len - 1];
    const num = std.fmt.parseInt(i64, num_str, 10) catch return null;
    return switch (suffix) {
        'd' => num * 86400,
        'h' => num * 3600,
        'm' => num * 60,
        's' => num,
        else => null,
    };
}

/// Format a Unix timestamp as a human-readable UTC string.
pub fn formatTimestamp(buf: []u8, timestamp_s: i64) []const u8 {
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(timestamp_s) };
    const day_secs = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const result = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch return "????-??-?? ??:??:??";
    return result;
}

/// CLI: print events in a formatted table.
pub fn printEvents(events: []const ParsedEvent) void {
    if (events.len == 0) {
        std.debug.print("No events found.\n", .{});
        return;
    }

    std.debug.print("{s:<20} {s:<6} {s:<20} {s:<16} {s}\n", .{
        "TIMESTAMP", "ID", "TYPE", "ACTOR", "COMMAND",
    });
    std.debug.print("{s}\n", .{"-" ** 80});

    for (events) |ev| {
        var ts_buf: [32]u8 = undefined;
        const ts = formatTimestamp(&ts_buf, ev.timestamp_s);
        const actor = ev.actorDisplay();
        const command = ev.action_command orelse "-";

        // Truncate command for display
        const cmd_display = if (command.len > 40) command[0..40] else command;

        std.debug.print("{s:<20} {d:<6} {s:<20} {s:<16} {s}\n", .{
            ts, ev.event_id, ev.event_type, actor, cmd_display,
        });
    }

    std.debug.print("\n{d} event(s)\n", .{events.len});
}

/// CLI: print audit stats.
pub fn printStats(stats: *const AuditStats) void {
    std.debug.print("Audit Log Statistics\n", .{});
    std.debug.print("====================\n\n", .{});
    std.debug.print("Total events: {d}\n\n", .{stats.total_events});

    if (stats.by_action.count() > 0) {
        std.debug.print("By event type:\n", .{});
        var action_iter = stats.by_action.iterator();
        while (action_iter.next()) |entry| {
            std.debug.print("  {s:<24} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        std.debug.print("\n", .{});
    }

    if (stats.by_actor.count() > 0) {
        std.debug.print("By actor:\n", .{});
        var actor_iter = stats.by_actor.iterator();
        while (actor_iter.next()) |entry| {
            std.debug.print("  {s:<24} {d}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn createTestLog(tmp_dir: std.testing.TmpDir, filename: []const u8, content: []const u8) ![]const u8 {
    const file = try tmp_dir.dir.createFile(filename, .{});
    defer file.close();
    try file.writeAll(content);
    return try tmp_dir.dir.realpathAlloc(testing.allocator, filename);
}

test "parseEventLine valid event" {
    const line =
        \\{"timestamp_s":1700000000,"event_id":1,"event_type":"command_execution","actor":{"channel":"discord","user_id":"u1","username":"alice"},"action":{"command":"ls","risk_level":"low","approved":false,"allowed":true},"result":{"success":true,"exit_code":0,"duration_ms":15},"security":{"policy_violation":false}}
    ;

    const ev = parseEventLine(testing.allocator, line) orelse return error.ParseFailed;
    defer freeParsedEvent(testing.allocator, &ev);

    try testing.expectEqual(@as(i64, 1700000000), ev.timestamp_s);
    try testing.expectEqual(@as(u64, 1), ev.event_id);
    try testing.expectEqualStrings("command_execution", ev.event_type);
    try testing.expectEqualStrings("discord", ev.actor_channel.?);
    try testing.expectEqualStrings("u1", ev.actor_user_id.?);
    try testing.expectEqualStrings("alice", ev.actor_username.?);
    try testing.expectEqualStrings("ls", ev.action_command.?);
    try testing.expectEqualStrings("low", ev.action_risk_level.?);
    try testing.expectEqual(@as(?bool, false), ev.action_approved);
    try testing.expectEqual(@as(?bool, true), ev.action_allowed);
    try testing.expectEqual(@as(?bool, true), ev.result_success);
    try testing.expectEqual(@as(?i32, 0), ev.result_exit_code);
    try testing.expectEqual(@as(?u64, 15), ev.result_duration_ms);
    try testing.expect(!ev.security_policy_violation);
}

test "parseEventLine empty line returns null" {
    try testing.expect(parseEventLine(testing.allocator, "") == null);
    try testing.expect(parseEventLine(testing.allocator, "   ") == null);
    try testing.expect(parseEventLine(testing.allocator, "\n") == null);
}

test "parseEventLine invalid json returns null" {
    try testing.expect(parseEventLine(testing.allocator, "not json") == null);
    try testing.expect(parseEventLine(testing.allocator, "{broken") == null);
}

test "parseEventLine minimal event" {
    const line =
        \\{"timestamp_s":100,"event_id":0,"event_type":"security_event","security":{"policy_violation":true}}
    ;
    const ev = parseEventLine(testing.allocator, line) orelse return error.ParseFailed;
    defer freeParsedEvent(testing.allocator, &ev);

    try testing.expectEqual(@as(i64, 100), ev.timestamp_s);
    try testing.expectEqualStrings("security_event", ev.event_type);
    try testing.expect(ev.actor_channel == null);
    try testing.expect(ev.action_command == null);
    try testing.expect(ev.result_success == null);
    try testing.expect(ev.security_policy_violation);
}

test "parseDuration valid formats" {
    try testing.expectEqual(@as(?i64, 604800), parseDuration("7d"));
    try testing.expectEqual(@as(?i64, 86400), parseDuration("1d"));
    try testing.expectEqual(@as(?i64, 3600), parseDuration("1h"));
    try testing.expectEqual(@as(?i64, 86400), parseDuration("24h"));
    try testing.expectEqual(@as(?i64, 1800), parseDuration("30m"));
    try testing.expectEqual(@as(?i64, 60), parseDuration("60s"));
}

test "parseDuration invalid formats" {
    try testing.expect(parseDuration("") == null);
    try testing.expect(parseDuration("d") == null);
    try testing.expect(parseDuration("abc") == null);
    try testing.expect(parseDuration("7x") == null);
}

test "containsInsensitive" {
    try testing.expect(containsInsensitive("Hello World", "hello"));
    try testing.expect(containsInsensitive("Hello World", "WORLD"));
    try testing.expect(containsInsensitive("discord", "disc"));
    try testing.expect(!containsInsensitive("discord", "slack"));
    try testing.expect(containsInsensitive("anything", ""));
    try testing.expect(!containsInsensitive("short", "toolongpattern"));
}

test "matchesFilter no criteria matches all" {
    const line =
        \\{"timestamp_s":100,"event_id":0,"event_type":"command_execution","security":{"policy_violation":false}}
    ;
    const ev = parseEventLine(testing.allocator, line) orelse return error.ParseFailed;
    defer freeParsedEvent(testing.allocator, &ev);

    var filter = SearchFilter{};
    try testing.expect(matchesFilter(&ev, &filter));
}

test "matchesFilter by since" {
    const line =
        \\{"timestamp_s":100,"event_id":0,"event_type":"command_execution","security":{"policy_violation":false}}
    ;
    const ev = parseEventLine(testing.allocator, line) orelse return error.ParseFailed;
    defer freeParsedEvent(testing.allocator, &ev);

    var filter_pass = SearchFilter{ .since_s = 50 };
    try testing.expect(matchesFilter(&ev, &filter_pass));

    var filter_fail = SearchFilter{ .since_s = 200 };
    try testing.expect(!matchesFilter(&ev, &filter_fail));
}

test "matchesFilter by actor" {
    const line =
        \\{"timestamp_s":100,"event_id":0,"event_type":"command_execution","actor":{"channel":"discord","username":"alice"},"security":{"policy_violation":false}}
    ;
    const ev = parseEventLine(testing.allocator, line) orelse return error.ParseFailed;
    defer freeParsedEvent(testing.allocator, &ev);

    var filter_match = SearchFilter{ .actor = "alice" };
    try testing.expect(matchesFilter(&ev, &filter_match));

    var filter_channel = SearchFilter{ .actor = "discord" };
    try testing.expect(matchesFilter(&ev, &filter_channel));

    var filter_no = SearchFilter{ .actor = "bob" };
    try testing.expect(!matchesFilter(&ev, &filter_no));
}

test "matchesFilter by action" {
    const line =
        \\{"timestamp_s":100,"event_id":0,"event_type":"command_execution","action":{"command":"git status","risk_level":"low","approved":false,"allowed":true},"security":{"policy_violation":false}}
    ;
    const ev = parseEventLine(testing.allocator, line) orelse return error.ParseFailed;
    defer freeParsedEvent(testing.allocator, &ev);

    var filter_cmd = SearchFilter{ .action = "git" };
    try testing.expect(matchesFilter(&ev, &filter_cmd));

    var filter_type = SearchFilter{ .action = "command_execution" };
    try testing.expect(matchesFilter(&ev, &filter_type));

    var filter_no = SearchFilter{ .action = "rm -rf" };
    try testing.expect(!matchesFilter(&ev, &filter_no));
}

test "searchEvents on file" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content =
        \\{"timestamp_s":100,"event_id":0,"event_type":"command_execution","actor":{"channel":"cli"},"action":{"command":"ls","risk_level":"low","approved":false,"allowed":true},"security":{"policy_violation":false}}
        \\{"timestamp_s":200,"event_id":1,"event_type":"auth_success","actor":{"channel":"discord","username":"bob"},"security":{"policy_violation":false}}
        \\{"timestamp_s":300,"event_id":2,"event_type":"command_execution","actor":{"channel":"discord","username":"alice"},"action":{"command":"git status","risk_level":"low","approved":false,"allowed":true},"security":{"policy_violation":false}}
    ;

    const path = try createTestLog(tmp_dir, "audit.log", content);
    defer testing.allocator.free(path);

    // Search all
    var filter_all = SearchFilter{};
    const all = try searchEvents(testing.allocator, path, &filter_all);
    defer {
        for (all) |*ev| freeParsedEvent(testing.allocator, ev);
        testing.allocator.free(all);
    }
    try testing.expectEqual(@as(usize, 3), all.len);

    // Search by actor
    var filter_alice = SearchFilter{ .actor = "alice" };
    const alice_results = try searchEvents(testing.allocator, path, &filter_alice);
    defer {
        for (alice_results) |*ev| freeParsedEvent(testing.allocator, ev);
        testing.allocator.free(alice_results);
    }
    try testing.expectEqual(@as(usize, 1), alice_results.len);

    // Search by action
    var filter_git = SearchFilter{ .action = "git" };
    const git_results = try searchEvents(testing.allocator, path, &filter_git);
    defer {
        for (git_results) |*ev| freeParsedEvent(testing.allocator, ev);
        testing.allocator.free(git_results);
    }
    try testing.expectEqual(@as(usize, 1), git_results.len);

    // Search by time range
    var filter_since = SearchFilter{ .since_s = 150 };
    const since_results = try searchEvents(testing.allocator, path, &filter_since);
    defer {
        for (since_results) |*ev| freeParsedEvent(testing.allocator, ev);
        testing.allocator.free(since_results);
    }
    try testing.expectEqual(@as(usize, 2), since_results.len);
}

test "searchEvents empty log" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try createTestLog(tmp_dir, "empty.log", "");
    defer testing.allocator.free(path);

    var filter = SearchFilter{};
    const results = try searchEvents(testing.allocator, path, &filter);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "searchEvents missing file returns empty" {
    var filter = SearchFilter{};
    const results = try searchEvents(testing.allocator, "/nonexistent/audit.log", &filter);
    defer testing.allocator.free(results);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "tailEvents returns last N" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content =
        \\{"timestamp_s":100,"event_id":0,"event_type":"a","security":{"policy_violation":false}}
        \\{"timestamp_s":200,"event_id":1,"event_type":"b","security":{"policy_violation":false}}
        \\{"timestamp_s":300,"event_id":2,"event_type":"c","security":{"policy_violation":false}}
        \\{"timestamp_s":400,"event_id":3,"event_type":"d","security":{"policy_violation":false}}
        \\{"timestamp_s":500,"event_id":4,"event_type":"e","security":{"policy_violation":false}}
    ;

    const path = try createTestLog(tmp_dir, "tail.log", content);
    defer testing.allocator.free(path);

    const tail = try tailEvents(testing.allocator, path, 3);
    defer {
        for (tail) |*ev| freeParsedEvent(testing.allocator, ev);
        testing.allocator.free(tail);
    }
    try testing.expectEqual(@as(usize, 3), tail.len);
    try testing.expectEqualStrings("c", tail[0].event_type);
    try testing.expectEqualStrings("d", tail[1].event_type);
    try testing.expectEqualStrings("e", tail[2].event_type);
}

test "tailEvents count larger than log" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content =
        \\{"timestamp_s":100,"event_id":0,"event_type":"only","security":{"policy_violation":false}}
    ;

    const path = try createTestLog(tmp_dir, "small.log", content);
    defer testing.allocator.free(path);

    const tail = try tailEvents(testing.allocator, path, 100);
    defer {
        for (tail) |*ev| freeParsedEvent(testing.allocator, ev);
        testing.allocator.free(tail);
    }
    try testing.expectEqual(@as(usize, 1), tail.len);
}

test "tailEvents empty log" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try createTestLog(tmp_dir, "empty.log", "");
    defer testing.allocator.free(path);

    const tail = try tailEvents(testing.allocator, path, 10);
    defer testing.allocator.free(tail);
    try testing.expectEqual(@as(usize, 0), tail.len);
}

test "computeAuditStats counts correctly" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content =
        \\{"timestamp_s":100,"event_id":0,"event_type":"command_execution","actor":{"channel":"cli"},"security":{"policy_violation":false}}
        \\{"timestamp_s":200,"event_id":1,"event_type":"command_execution","actor":{"channel":"discord","username":"alice"},"security":{"policy_violation":false}}
        \\{"timestamp_s":300,"event_id":2,"event_type":"auth_success","actor":{"channel":"discord","username":"alice"},"security":{"policy_violation":false}}
        \\{"timestamp_s":400,"event_id":3,"event_type":"command_execution","actor":{"channel":"cli"},"security":{"policy_violation":false}}
    ;

    const path = try createTestLog(tmp_dir, "stats.log", content);
    defer testing.allocator.free(path);

    var stats = try computeAuditStats(testing.allocator, path);
    defer stats.deinit();

    try testing.expectEqual(@as(u64, 4), stats.total_events);

    // By action type
    try testing.expectEqual(@as(u64, 3), stats.by_action.get("command_execution").?);
    try testing.expectEqual(@as(u64, 1), stats.by_action.get("auth_success").?);

    // By actor
    try testing.expectEqual(@as(u64, 2), stats.by_actor.get("alice").?);
    try testing.expectEqual(@as(u64, 2), stats.by_actor.get("cli").?);
}

test "computeAuditStats empty log" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try createTestLog(tmp_dir, "empty.log", "");
    defer testing.allocator.free(path);

    var stats = try computeAuditStats(testing.allocator, path);
    defer stats.deinit();

    try testing.expectEqual(@as(u64, 0), stats.total_events);
    try testing.expectEqual(@as(usize, 0), stats.by_action.count());
    try testing.expectEqual(@as(usize, 0), stats.by_actor.count());
}

test "formatTimestamp produces valid output" {
    var buf: [32]u8 = undefined;
    const ts = formatTimestamp(&buf, 1700000000); // 2023-11-14 22:13:20 UTC
    try testing.expect(ts.len == 19);
    try testing.expect(ts[4] == '-');
    try testing.expect(ts[7] == '-');
    try testing.expect(ts[10] == ' ');
    try testing.expect(ts[13] == ':');
    try testing.expect(ts[16] == ':');
}

test "actorDisplay prefers username" {
    const line =
        \\{"timestamp_s":100,"event_id":0,"event_type":"a","actor":{"channel":"discord","user_id":"u1","username":"alice"},"security":{"policy_violation":false}}
    ;
    const ev = parseEventLine(testing.allocator, line) orelse return error.ParseFailed;
    defer freeParsedEvent(testing.allocator, &ev);
    try testing.expectEqualStrings("alice", ev.actorDisplay());
}

test "actorDisplay falls back to user_id" {
    const line =
        \\{"timestamp_s":100,"event_id":0,"event_type":"a","actor":{"channel":"discord","user_id":"u42"},"security":{"policy_violation":false}}
    ;
    const ev = parseEventLine(testing.allocator, line) orelse return error.ParseFailed;
    defer freeParsedEvent(testing.allocator, &ev);
    try testing.expectEqualStrings("u42", ev.actorDisplay());
}

test "actorDisplay falls back to channel" {
    const line =
        \\{"timestamp_s":100,"event_id":0,"event_type":"a","actor":{"channel":"webhook"},"security":{"policy_violation":false}}
    ;
    const ev = parseEventLine(testing.allocator, line) orelse return error.ParseFailed;
    defer freeParsedEvent(testing.allocator, &ev);
    try testing.expectEqualStrings("webhook", ev.actorDisplay());
}

test "actorDisplay returns unknown when no actor" {
    const line =
        \\{"timestamp_s":100,"event_id":0,"event_type":"a","security":{"policy_violation":false}}
    ;
    const ev = parseEventLine(testing.allocator, line) orelse return error.ParseFailed;
    defer freeParsedEvent(testing.allocator, &ev);
    try testing.expectEqualStrings("(unknown)", ev.actorDisplay());
}

test "searchEvents combined filter" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const content =
        \\{"timestamp_s":100,"event_id":0,"event_type":"command_execution","actor":{"channel":"discord","username":"alice"},"action":{"command":"ls","risk_level":"low","approved":false,"allowed":true},"security":{"policy_violation":false}}
        \\{"timestamp_s":200,"event_id":1,"event_type":"command_execution","actor":{"channel":"discord","username":"bob"},"action":{"command":"git push","risk_level":"high","approved":true,"allowed":true},"security":{"policy_violation":false}}
        \\{"timestamp_s":300,"event_id":2,"event_type":"auth_failure","actor":{"channel":"cli","username":"alice"},"security":{"policy_violation":true}}
    ;

    const path = try createTestLog(tmp_dir, "combined.log", content);
    defer testing.allocator.free(path);

    // Filter: alice + since 150 -> should get only event_id 2
    var filter = SearchFilter{ .actor = "alice", .since_s = 150 };
    const results = try searchEvents(testing.allocator, path, &filter);
    defer {
        for (results) |*ev| freeParsedEvent(testing.allocator, ev);
        testing.allocator.free(results);
    }
    try testing.expectEqual(@as(usize, 1), results.len);
    try testing.expectEqual(@as(u64, 2), results[0].event_id);
}
