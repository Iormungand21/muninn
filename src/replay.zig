//! Replay mode skeleton and budget metrics summary.
//!
//! Provides types and stubs for replaying event timelines from JSONL files
//! and summarizing cost/latency budgets for diagnostics output.
//! Full event parsing is stubbed with TODO boundaries for future work.

const std = @import("std");
const events = @import("events.zig");
const EventRecord = events.EventRecord;
const EventKind = events.EventKind;
const EventSeverity = events.EventSeverity;
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
    /// TODO(S3-OBS): Full implementation would process the event and update state.
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

// ── Replay loader (skeleton) ──────────────────────────────────────

/// Load a replay session from a JSONL event file.
/// TODO(S3-OBS): Parse JSONL file line by line, deserialize each EventRecord,
/// and build the event list. Current skeleton returns an empty session.
pub fn loadReplaySession(session_id: []const u8, _path: []const u8) ReplaySession {
    _ = _path;
    // TODO(S3-OBS): Parse JSONL event file and populate events list.
    // Skeleton returns an empty session so callers can be wired up now.
    return .{
        .session_id = session_id,
        .summary = .{ .session_id = session_id },
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

/// Build a session summary from event counts.
/// TODO(S3-OBS): Accept a slice of EventRecord and compute from actual events.
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

test "loadReplaySession returns empty skeleton" {
    const session = loadReplaySession("sess-001", "/tmp/events.jsonl");
    try std.testing.expectEqualStrings("sess-001", session.session_id);
    try std.testing.expectEqual(@as(usize, 0), session.events.len);
    try std.testing.expectEqualStrings("sess-001", session.summary.session_id);
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
