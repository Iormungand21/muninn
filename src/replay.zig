//! Replay mode: JSONL event parsing, stats computation, and budget metrics.
//!
//! Provides types and logic for replaying event timelines from JSONL files,
//! computing session statistics, and summarizing cost/latency budgets.

const std = @import("std");
const events = @import("events.zig");
const EventRecord = events.EventRecord;
const EventKind = events.EventKind;
const EventSeverity = events.EventSeverity;
const events_store = @import("events_store.zig");
const cost_mod = @import("cost.zig");

// ── Replay types ──────────────────────────────────────────────────

/// A replay cursor position within a session's event stream.
pub const ReplayPosition = struct {
    /// Index into the event list (0-based).
    index: usize = 0,
    /// Whether the replay has reached the end.
    finished: bool = false,
};

/// Summary statistics for a replayed session.
pub const SessionSummary = struct {
    session_id: []const u8,
    event_count: usize = 0,
    error_count: usize = 0,
    warning_count: usize = 0,
    total_duration_ns: u64 = 0,
    tool_call_count: usize = 0,
    llm_request_count: usize = 0,
    first_timestamp: ?[]const u8 = null,
    last_timestamp: ?[]const u8 = null,

    /// Returns true if any errors were recorded.
    pub fn hasErrors(self: *const SessionSummary) bool {
        return self.error_count > 0;
    }

    /// Returns true if any warnings or errors were recorded.
    pub fn hasIssues(self: *const SessionSummary) bool {
        return self.error_count > 0 or self.warning_count > 0;
    }

    /// Returns total duration in milliseconds (from nanoseconds).
    pub fn durationMs(self: *const SessionSummary) u64 {
        return self.total_duration_ns / std.time.ns_per_ms;
    }
};

/// A loaded replay session with events and summary.
pub const ReplaySession = struct {
    session_id: []const u8,
    /// Loaded events. Empty in skeleton implementation.
    events: []const EventRecord = &.{},
    summary: SessionSummary,
    position: ReplayPosition = .{},

    /// Advance the replay by one event.
    pub fn step(self: *ReplaySession) ?*const EventRecord {
        if (self.position.index >= self.events.len) {
            self.position.finished = true;
            return null;
        }
        const evt = &self.events[self.position.index];
        self.position.index += 1;
        if (self.position.index >= self.events.len) {
            self.position.finished = true;
        }
        return evt;
    }

    /// Reset replay to the beginning.
    pub fn reset(self: *ReplaySession) void {
        self.position = .{};
    }

    /// Returns progress as a fraction [0.0, 1.0].
    pub fn progress(self: *const ReplaySession) f64 {
        if (self.events.len == 0) return 1.0;
        return @as(f64, @floatFromInt(self.position.index)) /
            @as(f64, @floatFromInt(self.events.len));
    }
};

// ── Budget summary ────────────────────────────────────────────────

/// Budget status indicator.
pub const BudgetStatus = enum {
    /// Within limits, no concern.
    ok,
    /// Approaching limit (above warning threshold).
    warning,
    /// Limit exceeded.
    exceeded,
    /// No budget configured / tracking disabled.
    unconfigured,

    pub fn toString(self: BudgetStatus) []const u8 {
        return switch (self) {
            .ok => "ok",
            .warning => "warning",
            .exceeded => "exceeded",
            .unconfigured => "unconfigured",
        };
    }

    pub fn fromString(s: []const u8) ?BudgetStatus {
        if (std.mem.eql(u8, s, "ok")) return .ok;
        if (std.mem.eql(u8, s, "warning")) return .warning;
        if (std.mem.eql(u8, s, "exceeded")) return .exceeded;
        if (std.mem.eql(u8, s, "unconfigured")) return .unconfigured;
        return null;
    }
};

/// Budget metrics summary for diagnostics output.
pub const BudgetSummary = struct {
    /// Current session cost in USD.
    session_cost_usd: f64 = 0.0,
    /// Daily cost in USD.
    daily_cost_usd: f64 = 0.0,
    /// Monthly cost in USD.
    monthly_cost_usd: f64 = 0.0,
    /// Daily limit in USD (0 = unconfigured).
    daily_limit_usd: f64 = 0.0,
    /// Monthly limit in USD (0 = unconfigured).
    monthly_limit_usd: f64 = 0.0,
    /// Total tokens used in session.
    total_tokens: u64 = 0,
    /// Number of LLM requests in session.
    request_count: usize = 0,
    /// Overall budget status.
    status: BudgetStatus = .unconfigured,

    /// Returns daily usage as a percentage of limit (0-100+).
    /// Returns 0 if no daily limit is set.
    pub fn dailyUsagePercent(self: *const BudgetSummary) f64 {
        if (self.daily_limit_usd <= 0.0) return 0.0;
        return (self.daily_cost_usd / self.daily_limit_usd) * 100.0;
    }

    /// Returns monthly usage as a percentage of limit (0-100+).
    /// Returns 0 if no monthly limit is set.
    pub fn monthlyUsagePercent(self: *const BudgetSummary) f64 {
        if (self.monthly_limit_usd <= 0.0) return 0.0;
        return (self.monthly_cost_usd / self.monthly_limit_usd) * 100.0;
    }

    /// Format a one-line budget status string for diagnostics.
    /// Uses the provided stack buffer; returns the written slice.
    pub fn formatStatus(self: *const BudgetSummary, buf: []u8) []const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();

        switch (self.status) {
            .unconfigured => {
                w.writeAll("budget: not configured") catch return "budget: not configured";
            },
            .ok => {
                w.print("budget: ok (session=${d:.4}, daily=${d:.4}/{d:.2}, monthly=${d:.4}/{d:.2})", .{
                    self.session_cost_usd,
                    self.daily_cost_usd,
                    self.daily_limit_usd,
                    self.monthly_cost_usd,
                    self.monthly_limit_usd,
                }) catch return "budget: ok";
            },
            .warning => {
                w.print("budget: WARNING (daily {d:.0}% of ${d:.2} limit)", .{
                    self.dailyUsagePercent(),
                    self.daily_limit_usd,
                }) catch return "budget: warning";
            },
            .exceeded => {
                w.print("budget: EXCEEDED (daily ${d:.4} > ${d:.2} limit)", .{
                    self.daily_cost_usd,
                    self.daily_limit_usd,
                }) catch return "budget: exceeded";
            },
        }

        return fbs.getWritten();
    }
};

// ── Event deserialization ─────────────────────────────────────────

/// Deserialize a single JSON line into an EventRecord.
/// All string fields are duped into the provided allocator.
pub fn deserializeEvent(allocator: std.mem.Allocator, line: []const u8) !EventRecord {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidFormat,
    };

    const id_str = switch (obj.get("id") orelse return error.MissingField) {
        .string => |s| s,
        else => return error.InvalidFormat,
    };
    const kind_str = switch (obj.get("kind") orelse return error.MissingField) {
        .string => |s| s,
        else => return error.InvalidFormat,
    };
    const ts_str = switch (obj.get("timestamp") orelse return error.MissingField) {
        .string => |s| s,
        else => return error.InvalidFormat,
    };

    const kind = EventKind.fromString(kind_str) orelse return error.InvalidFormat;

    var severity: EventSeverity = .info;
    if (obj.get("severity")) |sev_val| {
        const sev_str = switch (sev_val) {
            .string => |s| s,
            else => return error.InvalidFormat,
        };
        severity = EventSeverity.fromString(sev_str) orelse return error.InvalidFormat;
    }

    var duration_ns: u64 = 0;
    if (obj.get("duration_ns")) |dur_val| {
        duration_ns = switch (dur_val) {
            .integer => |i| @intCast(i),
            else => return error.InvalidFormat,
        };
    }

    const correlation = events.EventCorrelation{
        .session_id = if (obj.get("session_id")) |v| try dupeJsonStr(allocator, v) else null,
        .task_id = if (obj.get("task_id")) |v| try dupeJsonStr(allocator, v) else null,
        .step_name = if (obj.get("step_name")) |v| try dupeJsonStr(allocator, v) else null,
        .parent_event_id = if (obj.get("parent_event_id")) |v| try dupeJsonStr(allocator, v) else null,
        .channel = if (obj.get("channel")) |v| try dupeJsonStr(allocator, v) else null,
    };

    return .{
        .id = try allocator.dupe(u8, id_str),
        .kind = kind,
        .severity = severity,
        .timestamp = try allocator.dupe(u8, ts_str),
        .correlation = correlation,
        .duration_ns = duration_ns,
        .summary = if (obj.get("summary")) |v| try dupeJsonStr(allocator, v) else null,
        .detail = if (obj.get("detail")) |v| try dupeJsonStr(allocator, v) else null,
        .source = if (obj.get("source")) |v| try dupeJsonStr(allocator, v) else null,
    };
}

fn dupeJsonStr(allocator: std.mem.Allocator, val: std.json.Value) ![]const u8 {
    return switch (val) {
        .string => |s| try allocator.dupe(u8, s),
        else => error.InvalidFormat,
    };
}

// ── Event loading ────────────────────────────────────────────────

/// Load events from JSONL content (one JSON object per line).
/// Returns an owned slice of EventRecords; caller must free each
/// record with record.deinit(allocator) and the slice itself.
pub fn loadEvents(allocator: std.mem.Allocator, content: []const u8) ![]EventRecord {
    var list: std.ArrayListUnmanaged(EventRecord) = .empty;
    errdefer {
        for (list.items) |*rec| rec.deinit(allocator);
        list.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const rec = try deserializeEvent(allocator, line);
        try list.append(allocator, rec);
    }

    return list.toOwnedSlice(allocator);
}

// ── Event processing ─────────────────────────────────────────────

/// Update a SessionSummary by processing a single event.
pub fn processEvent(summary: *SessionSummary, record: *const EventRecord) void {
    summary.event_count += 1;

    // Severity counters
    if (record.severity == .err) summary.error_count += 1;
    if (record.severity == .warn) summary.warning_count += 1;

    // Kind counters
    if (record.kind == .tool_call) summary.tool_call_count += 1;
    if (record.kind == .llm_request) summary.llm_request_count += 1;

    // Duration accumulation
    summary.total_duration_ns += record.duration_ns;

    // Timestamp tracking
    if (summary.first_timestamp == null) {
        summary.first_timestamp = record.timestamp;
    }
    summary.last_timestamp = record.timestamp;
}

/// Compute a SessionSummary from a slice of events.
pub fn computeStats(session_id: []const u8, event_list: []const EventRecord) SessionSummary {
    var summary = SessionSummary{ .session_id = session_id };
    for (event_list) |*rec| {
        processEvent(&summary, rec);
    }
    return summary;
}

// ── Replay loader ────────────────────────────────────────────────

/// Load a replay session from a JSONL event file.
/// Reads the file, parses each line into an EventRecord, and computes stats.
/// Returns an error if the file cannot be read or parsed.
pub fn loadReplaySession(allocator: std.mem.Allocator, session_id: []const u8, path: []const u8) !ReplaySession {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);
    defer allocator.free(content);

    const loaded = try loadEvents(allocator, content);
    const summary = computeStats(session_id, loaded);

    return .{
        .session_id = session_id,
        .events = loaded,
        .summary = summary,
    };
}

/// Build a budget summary from a CostTracker.
/// Integration point for status/doctor to report budget metrics.
pub fn buildBudgetSummary(tracker: *const cost_mod.CostTracker) BudgetSummary {
    if (!tracker.enabled) {
        return .{ .status = .unconfigured };
    }

    const cs = tracker.getSummary();

    // Determine overall status from the tracker's own budget check
    const check = tracker.checkBudget(0.0);
    const budget_status: BudgetStatus = switch (check) {
        .allowed => .ok,
        .warning => .warning,
        .exceeded => .exceeded,
    };

    return .{
        .session_cost_usd = cs.session_cost_usd,
        .daily_cost_usd = cs.daily_cost_usd,
        .monthly_cost_usd = cs.monthly_cost_usd,
        .daily_limit_usd = tracker.daily_limit_usd,
        .monthly_limit_usd = tracker.monthly_limit_usd,
        .total_tokens = cs.total_tokens,
        .request_count = cs.request_count,
        .status = budget_status,
    };
}

/// Build a session summary from pre-computed event counts.
/// For computing stats from actual events, use computeStats() instead.
pub fn summarizeSession(
    session_id: []const u8,
    event_count: usize,
    error_count: usize,
    warning_count: usize,
    tool_calls: usize,
    llm_requests: usize,
    total_duration_ns: u64,
) SessionSummary {
    return .{
        .session_id = session_id,
        .event_count = event_count,
        .error_count = error_count,
        .warning_count = warning_count,
        .tool_call_count = tool_calls,
        .llm_request_count = llm_requests,
        .total_duration_ns = total_duration_ns,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "ReplayPosition defaults" {
    const pos = ReplayPosition{};
    try std.testing.expectEqual(@as(usize, 0), pos.index);
    try std.testing.expect(!pos.finished);
}

test "SessionSummary defaults" {
    const s = SessionSummary{ .session_id = "s1" };
    try std.testing.expectEqualStrings("s1", s.session_id);
    try std.testing.expectEqual(@as(usize, 0), s.event_count);
    try std.testing.expectEqual(@as(usize, 0), s.error_count);
    try std.testing.expect(!s.hasErrors());
    try std.testing.expect(!s.hasIssues());
    try std.testing.expectEqual(@as(u64, 0), s.durationMs());
}

test "SessionSummary hasErrors and hasIssues" {
    const with_errors = SessionSummary{
        .session_id = "s2",
        .error_count = 3,
    };
    try std.testing.expect(with_errors.hasErrors());
    try std.testing.expect(with_errors.hasIssues());

    const with_warnings = SessionSummary{
        .session_id = "s3",
        .warning_count = 2,
    };
    try std.testing.expect(!with_warnings.hasErrors());
    try std.testing.expect(with_warnings.hasIssues());
}

test "SessionSummary durationMs" {
    const s = SessionSummary{
        .session_id = "s4",
        .total_duration_ns = 1_500_000_000, // 1.5 seconds
    };
    try std.testing.expectEqual(@as(u64, 1500), s.durationMs());
}

test "ReplaySession empty session" {
    var session = ReplaySession{
        .session_id = "test-sess",
        .summary = .{ .session_id = "test-sess" },
    };
    try std.testing.expectEqualStrings("test-sess", session.session_id);
    try std.testing.expectEqual(@as(usize, 0), session.events.len);
    try std.testing.expect(session.progress() == 1.0);
    try std.testing.expect(session.step() == null);
    try std.testing.expect(session.position.finished);
}

test "ReplaySession step through events" {
    const test_events = [_]EventRecord{
        .{ .id = "e1", .kind = .agent_start, .timestamp = "2026-01-01T00:00:00Z" },
        .{ .id = "e2", .kind = .tool_call, .timestamp = "2026-01-01T00:00:01Z" },
        .{ .id = "e3", .kind = .agent_end, .timestamp = "2026-01-01T00:00:02Z" },
    };
    var session = ReplaySession{
        .session_id = "test-replay",
        .events = &test_events,
        .summary = .{ .session_id = "test-replay", .event_count = 3 },
    };

    try std.testing.expect(session.progress() == 0.0);
    try std.testing.expect(!session.position.finished);

    // Step 1
    const evt1 = session.step().?;
    try std.testing.expectEqualStrings("e1", evt1.id);
    try std.testing.expect(!session.position.finished);

    // Step 2
    const evt2 = session.step().?;
    try std.testing.expectEqualStrings("e2", evt2.id);
    try std.testing.expect(!session.position.finished);

    // Step 3 (last event)
    const evt3 = session.step().?;
    try std.testing.expectEqualStrings("e3", evt3.id);
    try std.testing.expect(session.position.finished);
    try std.testing.expect(session.progress() == 1.0);

    // Step 4 (past end)
    try std.testing.expect(session.step() == null);
}

test "ReplaySession reset" {
    const test_events = [_]EventRecord{
        .{ .id = "e1", .kind = .system, .timestamp = "2026-01-01T00:00:00Z" },
    };
    var session = ReplaySession{
        .session_id = "test-reset",
        .events = &test_events,
        .summary = .{ .session_id = "test-reset", .event_count = 1 },
    };

    _ = session.step();
    try std.testing.expect(session.position.finished);

    session.reset();
    try std.testing.expectEqual(@as(usize, 0), session.position.index);
    try std.testing.expect(!session.position.finished);

    // Can step again after reset
    const evt = session.step().?;
    try std.testing.expectEqualStrings("e1", evt.id);
}

test "BudgetStatus toString roundtrip" {
    const statuses = [_]BudgetStatus{ .ok, .warning, .exceeded, .unconfigured };
    for (statuses) |s| {
        const str = s.toString();
        try std.testing.expect(BudgetStatus.fromString(str).? == s);
    }
    try std.testing.expect(BudgetStatus.fromString("bogus") == null);
}

test "BudgetSummary defaults" {
    const b = BudgetSummary{};
    try std.testing.expect(b.status == .unconfigured);
    try std.testing.expect(b.session_cost_usd == 0.0);
    try std.testing.expect(b.dailyUsagePercent() == 0.0);
    try std.testing.expect(b.monthlyUsagePercent() == 0.0);
}

test "BudgetSummary usage percentages" {
    const b = BudgetSummary{
        .daily_cost_usd = 5.0,
        .daily_limit_usd = 10.0,
        .monthly_cost_usd = 30.0,
        .monthly_limit_usd = 100.0,
        .status = .ok,
    };
    try std.testing.expect(@abs(b.dailyUsagePercent() - 50.0) < 0.01);
    try std.testing.expect(@abs(b.monthlyUsagePercent() - 30.0) < 0.01);
}

test "BudgetSummary usage percent with zero limit" {
    const b = BudgetSummary{
        .daily_cost_usd = 5.0,
        .daily_limit_usd = 0.0,
        .status = .ok,
    };
    try std.testing.expect(b.dailyUsagePercent() == 0.0);
}

test "BudgetSummary formatStatus unconfigured" {
    const b = BudgetSummary{};
    var buf: [256]u8 = undefined;
    const line = b.formatStatus(&buf);
    try std.testing.expectEqualStrings("budget: not configured", line);
}

test "BudgetSummary formatStatus ok" {
    const b = BudgetSummary{
        .session_cost_usd = 0.05,
        .daily_cost_usd = 1.0,
        .daily_limit_usd = 10.0,
        .monthly_cost_usd = 5.0,
        .monthly_limit_usd = 100.0,
        .status = .ok,
    };
    var buf: [256]u8 = undefined;
    const line = b.formatStatus(&buf);
    try std.testing.expect(std.mem.startsWith(u8, line, "budget: ok"));
    try std.testing.expect(std.mem.indexOf(u8, line, "session=") != null);
}

test "BudgetSummary formatStatus warning" {
    const b = BudgetSummary{
        .daily_cost_usd = 8.5,
        .daily_limit_usd = 10.0,
        .status = .warning,
    };
    var buf: [256]u8 = undefined;
    const line = b.formatStatus(&buf);
    try std.testing.expect(std.mem.startsWith(u8, line, "budget: WARNING"));
}

test "BudgetSummary formatStatus exceeded" {
    const b = BudgetSummary{
        .daily_cost_usd = 12.0,
        .daily_limit_usd = 10.0,
        .status = .exceeded,
    };
    var buf: [256]u8 = undefined;
    const line = b.formatStatus(&buf);
    try std.testing.expect(std.mem.startsWith(u8, line, "budget: EXCEEDED"));
}

test "loadReplaySession with file" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/nullclaw_replay_load_test.jsonl";

    // Write sample JSONL
    {
        const file = try std.fs.cwd().createFile(test_path, .{});
        defer file.close();
        try file.writeAll(
            \\{"id":"e1","kind":"agent_start","severity":"info","timestamp":"2026-01-01T00:00:00Z"}
            \\{"id":"e2","kind":"tool_call","severity":"info","timestamp":"2026-01-01T00:00:01Z","duration_ns":100000000}
            \\
        );
    }
    defer std.fs.cwd().deleteFile(test_path) catch {};

    const session = try loadReplaySession(allocator, "sess-001", test_path);
    defer allocator.free(session.events);
    defer for (session.events) |*e| e.deinit(allocator);

    try std.testing.expectEqualStrings("sess-001", session.session_id);
    try std.testing.expectEqual(@as(usize, 2), session.events.len);
    try std.testing.expectEqual(@as(usize, 2), session.summary.event_count);
    try std.testing.expectEqual(@as(usize, 1), session.summary.tool_call_count);
    try std.testing.expect(!session.position.finished);
}

test "buildBudgetSummary disabled tracker" {
    var tracker = cost_mod.CostTracker.init(std.testing.allocator, "/tmp", false, 10.0, 100.0, 80);
    defer tracker.deinit();

    const summary = buildBudgetSummary(&tracker);
    try std.testing.expect(summary.status == .unconfigured);
}

test "buildBudgetSummary enabled with no usage" {
    var tracker = cost_mod.CostTracker.init(std.testing.allocator, "/tmp", true, 10.0, 100.0, 80);
    defer tracker.deinit();

    const summary = buildBudgetSummary(&tracker);
    try std.testing.expect(summary.status == .ok);
    try std.testing.expect(summary.session_cost_usd == 0.0);
    try std.testing.expect(summary.daily_limit_usd == 10.0);
    try std.testing.expect(summary.monthly_limit_usd == 100.0);
}

test "buildBudgetSummary with usage" {
    var tracker = cost_mod.CostTracker.init(std.testing.allocator, "/tmp", true, 10.0, 100.0, 80);
    defer tracker.deinit();

    const usage = cost_mod.TokenUsage.init("test-model", 1000, 500, 1.0, 2.0);
    try tracker.recordUsage(usage);

    const summary = buildBudgetSummary(&tracker);
    try std.testing.expect(summary.status == .ok);
    try std.testing.expect(summary.session_cost_usd > 0.0);
    try std.testing.expectEqual(@as(usize, 1), summary.request_count);
    try std.testing.expect(summary.total_tokens > 0);
}

test "buildBudgetSummary exceeded budget" {
    var tracker = cost_mod.CostTracker.init(std.testing.allocator, "/tmp", true, 0.001, 100.0, 80);
    defer tracker.deinit();

    const usage = cost_mod.TokenUsage.init("test-model", 10000, 5000, 1.0, 2.0);
    try tracker.recordUsage(usage);

    const summary = buildBudgetSummary(&tracker);
    try std.testing.expect(summary.status == .exceeded);
}

test "summarizeSession builds correct summary" {
    const s = summarizeSession("sess-x", 100, 5, 10, 30, 20, 5_000_000_000);
    try std.testing.expectEqualStrings("sess-x", s.session_id);
    try std.testing.expectEqual(@as(usize, 100), s.event_count);
    try std.testing.expectEqual(@as(usize, 5), s.error_count);
    try std.testing.expectEqual(@as(usize, 10), s.warning_count);
    try std.testing.expectEqual(@as(usize, 30), s.tool_call_count);
    try std.testing.expectEqual(@as(usize, 20), s.llm_request_count);
    try std.testing.expectEqual(@as(u64, 5_000_000_000), s.total_duration_ns);
    try std.testing.expect(s.hasErrors());
    try std.testing.expect(s.hasIssues());
    try std.testing.expectEqual(@as(u64, 5000), s.durationMs());
}

test "deserializeEvent minimal" {
    const allocator = std.testing.allocator;
    const line = "{\"id\":\"e1\",\"kind\":\"system\",\"severity\":\"info\",\"timestamp\":\"2026-01-01T00:00:00Z\"}";
    const rec = try deserializeEvent(allocator, line);
    defer rec.deinit(allocator);

    try std.testing.expectEqualStrings("e1", rec.id);
    try std.testing.expect(rec.kind == .system);
    try std.testing.expect(rec.severity == .info);
    try std.testing.expectEqualStrings("2026-01-01T00:00:00Z", rec.timestamp);
    try std.testing.expectEqual(@as(u64, 0), rec.duration_ns);
    try std.testing.expect(rec.summary == null);
    try std.testing.expect(rec.correlation.session_id == null);
}

test "deserializeEvent full fields" {
    const allocator = std.testing.allocator;
    const line =
        \\{"id":"e2","kind":"tool_call","severity":"debug","timestamp":"2026-02-01T12:00:00Z","duration_ns":500000000,"session_id":"s1","task_id":"t1","step_name":"step1","parent_event_id":"e0","channel":"cli","source":"tools.shell","summary":"ran ls","detail":"ls -la"}
    ;
    const rec = try deserializeEvent(allocator, line);
    defer rec.deinit(allocator);

    try std.testing.expectEqualStrings("e2", rec.id);
    try std.testing.expect(rec.kind == .tool_call);
    try std.testing.expect(rec.severity == .debug);
    try std.testing.expectEqual(@as(u64, 500_000_000), rec.duration_ns);
    try std.testing.expectEqualStrings("s1", rec.correlation.session_id.?);
    try std.testing.expectEqualStrings("t1", rec.correlation.task_id.?);
    try std.testing.expectEqualStrings("step1", rec.correlation.step_name.?);
    try std.testing.expectEqualStrings("e0", rec.correlation.parent_event_id.?);
    try std.testing.expectEqualStrings("cli", rec.correlation.channel.?);
    try std.testing.expectEqualStrings("tools.shell", rec.source.?);
    try std.testing.expectEqualStrings("ran ls", rec.summary.?);
    try std.testing.expectEqualStrings("ls -la", rec.detail.?);
}

test "deserializeEvent invalid JSON" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.SyntaxError, deserializeEvent(allocator, "not json"));
}

test "deserializeEvent missing id" {
    const allocator = std.testing.allocator;
    const line = "{\"kind\":\"system\",\"severity\":\"info\",\"timestamp\":\"2026-01-01T00:00:00Z\"}";
    try std.testing.expectError(error.MissingField, deserializeEvent(allocator, line));
}

test "loadEvents parses JSONL content" {
    const allocator = std.testing.allocator;
    const content =
        \\{"id":"e1","kind":"agent_start","severity":"info","timestamp":"2026-01-01T00:00:00Z"}
        \\{"id":"e2","kind":"tool_call","severity":"info","timestamp":"2026-01-01T00:00:01Z"}
        \\{"id":"e3","kind":"agent_end","severity":"info","timestamp":"2026-01-01T00:00:02Z"}
        \\
    ;
    const loaded = try loadEvents(allocator, content);
    defer {
        for (loaded) |*e| e.deinit(allocator);
        allocator.free(loaded);
    }

    try std.testing.expectEqual(@as(usize, 3), loaded.len);
    try std.testing.expectEqualStrings("e1", loaded[0].id);
    try std.testing.expect(loaded[0].kind == .agent_start);
    try std.testing.expectEqualStrings("e2", loaded[1].id);
    try std.testing.expect(loaded[1].kind == .tool_call);
    try std.testing.expectEqualStrings("e3", loaded[2].id);
    try std.testing.expect(loaded[2].kind == .agent_end);
}

test "loadEvents empty content" {
    const allocator = std.testing.allocator;
    const loaded = try loadEvents(allocator, "");
    defer allocator.free(loaded);
    try std.testing.expectEqual(@as(usize, 0), loaded.len);
}

test "processEvent increments counters" {
    var summary = SessionSummary{ .session_id = "s1" };

    const e1 = EventRecord{ .id = "e1", .kind = .tool_call, .severity = .info, .timestamp = "t1", .duration_ns = 100 };
    processEvent(&summary, &e1);
    try std.testing.expectEqual(@as(usize, 1), summary.event_count);
    try std.testing.expectEqual(@as(usize, 1), summary.tool_call_count);
    try std.testing.expectEqual(@as(u64, 100), summary.total_duration_ns);
    try std.testing.expectEqualStrings("t1", summary.first_timestamp.?);
    try std.testing.expectEqualStrings("t1", summary.last_timestamp.?);

    const e2 = EventRecord{ .id = "e2", .kind = .llm_request, .severity = .err, .timestamp = "t2" };
    processEvent(&summary, &e2);
    try std.testing.expectEqual(@as(usize, 2), summary.event_count);
    try std.testing.expectEqual(@as(usize, 1), summary.error_count);
    try std.testing.expectEqual(@as(usize, 1), summary.llm_request_count);
    try std.testing.expectEqualStrings("t1", summary.first_timestamp.?);
    try std.testing.expectEqualStrings("t2", summary.last_timestamp.?);

    const e3 = EventRecord{ .id = "e3", .kind = .system, .severity = .warn, .timestamp = "t3" };
    processEvent(&summary, &e3);
    try std.testing.expectEqual(@as(usize, 1), summary.warning_count);
}

test "computeStats from event slice" {
    const test_events = [_]EventRecord{
        .{ .id = "e1", .kind = .agent_start, .timestamp = "2026-01-01T00:00:00Z" },
        .{ .id = "e2", .kind = .tool_call, .timestamp = "2026-01-01T00:00:01Z", .duration_ns = 200_000_000 },
        .{ .id = "e3", .kind = .llm_request, .timestamp = "2026-01-01T00:00:02Z", .duration_ns = 500_000_000 },
        .{ .id = "e4", .kind = .err, .severity = .err, .timestamp = "2026-01-01T00:00:03Z" },
        .{ .id = "e5", .kind = .agent_end, .severity = .warn, .timestamp = "2026-01-01T00:00:04Z" },
    };
    const stats = computeStats("sess-test", &test_events);

    try std.testing.expectEqual(@as(usize, 5), stats.event_count);
    try std.testing.expectEqual(@as(usize, 1), stats.error_count);
    try std.testing.expectEqual(@as(usize, 1), stats.warning_count);
    try std.testing.expectEqual(@as(usize, 1), stats.tool_call_count);
    try std.testing.expectEqual(@as(usize, 1), stats.llm_request_count);
    try std.testing.expectEqual(@as(u64, 700_000_000), stats.total_duration_ns);
    try std.testing.expectEqualStrings("2026-01-01T00:00:00Z", stats.first_timestamp.?);
    try std.testing.expectEqualStrings("2026-01-01T00:00:04Z", stats.last_timestamp.?);
    try std.testing.expect(stats.hasErrors());
    try std.testing.expect(stats.hasIssues());
}

test "serialize then deserialize roundtrip" {
    const allocator = std.testing.allocator;
    const original = EventRecord{
        .id = "rt-001",
        .kind = .tool_call,
        .severity = .debug,
        .timestamp = "2026-03-15T08:30:00Z",
        .duration_ns = 123_456_789,
        .correlation = .{ .session_id = "sess-rt", .task_id = "task-rt" },
        .source = "test",
        .summary = "roundtrip test",
        .detail = "payload data",
    };

    // Serialize
    var buf: [4096]u8 = undefined;
    const line = events_store.serializeEvent(&buf, &original) orelse return error.SerializeFailed;

    // Deserialize
    const restored = try deserializeEvent(allocator, line);
    defer restored.deinit(allocator);

    try std.testing.expectEqualStrings(original.id, restored.id);
    try std.testing.expect(original.kind == restored.kind);
    try std.testing.expect(original.severity == restored.severity);
    try std.testing.expectEqualStrings(original.timestamp, restored.timestamp);
    try std.testing.expectEqual(original.duration_ns, restored.duration_ns);
    try std.testing.expectEqualStrings("sess-rt", restored.correlation.session_id.?);
    try std.testing.expectEqualStrings("task-rt", restored.correlation.task_id.?);
    try std.testing.expectEqualStrings("test", restored.source.?);
    try std.testing.expectEqualStrings("roundtrip test", restored.summary.?);
    try std.testing.expectEqualStrings("payload data", restored.detail.?);
}

test "serialize write load computeStats roundtrip" {
    const allocator = std.testing.allocator;
    const test_path = "/tmp/nullclaw_replay_roundtrip_test.jsonl";
    std.fs.cwd().deleteFile(test_path) catch {};
    defer std.fs.cwd().deleteFile(test_path) catch {};

    // Write events to JSONL file via EventStore
    var store = events_store.EventStore{ .path = test_path };
    const e1 = EventRecord{ .id = "r1", .kind = .agent_start, .timestamp = "2026-01-01T00:00:00Z" };
    const e2 = EventRecord{ .id = "r2", .kind = .tool_call, .severity = .warn, .timestamp = "2026-01-01T00:00:01Z", .duration_ns = 300_000_000 };
    const e3 = EventRecord{ .id = "r3", .kind = .llm_request, .timestamp = "2026-01-01T00:00:02Z", .duration_ns = 600_000_000 };
    const e4 = EventRecord{ .id = "r4", .kind = .err, .severity = .err, .timestamp = "2026-01-01T00:00:03Z" };
    store.append(&e1);
    store.append(&e2);
    store.append(&e3);
    store.append(&e4);

    // Load and parse
    const content = try std.fs.cwd().readFileAlloc(allocator, test_path, 1024 * 1024);
    defer allocator.free(content);
    const loaded = try loadEvents(allocator, content);
    defer {
        for (loaded) |*e| e.deinit(allocator);
        allocator.free(loaded);
    }

    try std.testing.expectEqual(@as(usize, 4), loaded.len);

    // Compute stats
    const stats = computeStats("roundtrip-sess", loaded);
    try std.testing.expectEqual(@as(usize, 4), stats.event_count);
    try std.testing.expectEqual(@as(usize, 1), stats.error_count);
    try std.testing.expectEqual(@as(usize, 1), stats.warning_count);
    try std.testing.expectEqual(@as(usize, 1), stats.tool_call_count);
    try std.testing.expectEqual(@as(usize, 1), stats.llm_request_count);
    try std.testing.expectEqual(@as(u64, 900_000_000), stats.total_duration_ns);
    try std.testing.expectEqual(@as(u64, 900), stats.durationMs());
}
