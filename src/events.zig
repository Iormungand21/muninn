//! Structured event timeline primitives for observability and replay.
//!
//! Provides typed event records with IDs, timestamps, severity levels,
//! and session/task correlation fields. These are the core schema types
//! for the persistent event timeline — no emission or storage logic here.

const std = @import("std");

// ── Event kind ─────────────────────────────────────────────────────
// Classifies what happened in the system.

pub const EventKind = enum {
    /// An agent session started.
    agent_start,
    /// An agent session ended.
    agent_end,
    /// A task was created or transitioned state.
    task_lifecycle,
    /// A tool was invoked.
    tool_call,
    /// An LLM request was sent.
    llm_request,
    /// An LLM response was received.
    llm_response,
    /// A memory record was written.
    memory_write,
    /// A memory record was read/recalled.
    memory_read,
    /// A user or channel message arrived.
    message_in,
    /// A response message was sent.
    message_out,
    /// A system-level event (config change, health check, etc.).
    system,
    /// An error or warning condition.
    err,

    pub fn toString(self: EventKind) []const u8 {
        return switch (self) {
            .agent_start => "agent_start",
            .agent_end => "agent_end",
            .task_lifecycle => "task_lifecycle",
            .tool_call => "tool_call",
            .llm_request => "llm_request",
            .llm_response => "llm_response",
            .memory_write => "memory_write",
            .memory_read => "memory_read",
            .message_in => "message_in",
            .message_out => "message_out",
            .system => "system",
            .err => "error",
        };
    }

    pub fn fromString(s: []const u8) ?EventKind {
        if (std.mem.eql(u8, s, "agent_start")) return .agent_start;
        if (std.mem.eql(u8, s, "agent_end")) return .agent_end;
        if (std.mem.eql(u8, s, "task_lifecycle")) return .task_lifecycle;
        if (std.mem.eql(u8, s, "tool_call")) return .tool_call;
        if (std.mem.eql(u8, s, "llm_request")) return .llm_request;
        if (std.mem.eql(u8, s, "llm_response")) return .llm_response;
        if (std.mem.eql(u8, s, "memory_write")) return .memory_write;
        if (std.mem.eql(u8, s, "memory_read")) return .memory_read;
        if (std.mem.eql(u8, s, "message_in")) return .message_in;
        if (std.mem.eql(u8, s, "message_out")) return .message_out;
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "error")) return .err;
        return null;
    }
};

// ── Event severity ─────────────────────────────────────────────────

pub const EventSeverity = enum {
    /// Fine-grained diagnostic detail.
    trace,
    /// Developer-oriented diagnostic info.
    debug,
    /// Normal operational events.
    info,
    /// Potentially harmful situations.
    warn,
    /// Error conditions that may need attention.
    err,

    pub fn toString(self: EventSeverity) []const u8 {
        return switch (self) {
            .trace => "trace",
            .debug => "debug",
            .info => "info",
            .warn => "warn",
            .err => "error",
        };
    }

    pub fn fromString(s: []const u8) ?EventSeverity {
        if (std.mem.eql(u8, s, "trace")) return .trace;
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "info")) return .info;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "error")) return .err;
        return null;
    }

    /// Returns a numeric level for comparison (higher = more severe).
    pub fn level(self: EventSeverity) u8 {
        return switch (self) {
            .trace => 0,
            .debug => 1,
            .info => 2,
            .warn => 3,
            .err => 4,
        };
    }
};

// ── Event correlation ──────────────────────────────────────────────
// Links an event to its session, task, and causal chain.

pub const EventCorrelation = struct {
    /// Active session identifier.
    session_id: ?[]const u8 = null,
    /// Task identifier this event belongs to.
    task_id: ?[]const u8 = null,
    /// Step name within a multi-step task.
    step_name: ?[]const u8 = null,
    /// Parent event ID for causal chaining.
    parent_event_id: ?[]const u8 = null,
    /// Channel that originated or received the event.
    channel: ?[]const u8 = null,
};

// ── Event record ───────────────────────────────────────────────────
// The main structured event for the persistent timeline.

pub const EventRecord = struct {
    /// Unique event identifier.
    id: []const u8,
    /// What kind of event occurred.
    kind: EventKind,
    /// Severity / log level.
    severity: EventSeverity = .info,
    /// ISO-8601 timestamp when the event occurred.
    timestamp: []const u8,
    /// Correlation fields linking to session/task context.
    correlation: EventCorrelation = .{},
    /// Duration in nanoseconds (for span-like events, 0 for instants).
    duration_ns: u64 = 0,
    /// Human-readable summary of what happened.
    summary: ?[]const u8 = null,
    /// Free-form detail payload (tool args, error message, etc.).
    detail: ?[]const u8 = null,
    /// Component or subsystem that emitted this event.
    source: ?[]const u8 = null,

    /// Returns true if this event has a non-zero duration (span-like).
    pub fn isSpan(self: *const EventRecord) bool {
        return self.duration_ns > 0;
    }

    /// Returns true if severity is warn or higher.
    pub fn isWarningOrAbove(self: *const EventRecord) bool {
        return self.severity.level() >= EventSeverity.warn.level();
    }

    /// Free all allocator-owned strings. Caller must ensure the allocator
    /// matches the one used to create the slices.
    pub fn deinit(self: *const EventRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.timestamp);
        if (self.summary) |v| allocator.free(v);
        if (self.detail) |v| allocator.free(v);
        if (self.source) |v| allocator.free(v);
        if (self.correlation.session_id) |v| allocator.free(v);
        if (self.correlation.task_id) |v| allocator.free(v);
        if (self.correlation.step_name) |v| allocator.free(v);
        if (self.correlation.parent_event_id) |v| allocator.free(v);
        if (self.correlation.channel) |v| allocator.free(v);
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "EventKind toString roundtrip" {
    const kinds = [_]EventKind{
        .agent_start, .agent_end,    .task_lifecycle, .tool_call,
        .llm_request, .llm_response, .memory_write,   .memory_read,
        .message_in,  .message_out,  .system,         .err,
    };
    for (kinds) |k| {
        const str = k.toString();
        try std.testing.expect(EventKind.fromString(str).? == k);
    }
    try std.testing.expect(EventKind.fromString("bogus") == null);
}

test "EventSeverity toString roundtrip" {
    const severities = [_]EventSeverity{ .trace, .debug, .info, .warn, .err };
    for (severities) |s| {
        const str = s.toString();
        try std.testing.expect(EventSeverity.fromString(str).? == s);
    }
    try std.testing.expect(EventSeverity.fromString("bogus") == null);
}

test "EventSeverity level ordering" {
    try std.testing.expect(EventSeverity.trace.level() < EventSeverity.debug.level());
    try std.testing.expect(EventSeverity.debug.level() < EventSeverity.info.level());
    try std.testing.expect(EventSeverity.info.level() < EventSeverity.warn.level());
    try std.testing.expect(EventSeverity.warn.level() < EventSeverity.err.level());
}

test "EventCorrelation defaults" {
    const corr = EventCorrelation{};
    try std.testing.expect(corr.session_id == null);
    try std.testing.expect(corr.task_id == null);
    try std.testing.expect(corr.step_name == null);
    try std.testing.expect(corr.parent_event_id == null);
    try std.testing.expect(corr.channel == null);
}

test "EventCorrelation with fields" {
    const corr = EventCorrelation{
        .session_id = "sess-001",
        .task_id = "task-042",
        .step_name = "fetch-data",
        .parent_event_id = "evt-099",
        .channel = "telegram",
    };
    try std.testing.expectEqualStrings("sess-001", corr.session_id.?);
    try std.testing.expectEqualStrings("task-042", corr.task_id.?);
    try std.testing.expectEqualStrings("fetch-data", corr.step_name.?);
    try std.testing.expectEqualStrings("evt-099", corr.parent_event_id.?);
    try std.testing.expectEqualStrings("telegram", corr.channel.?);
}

test "EventRecord defaults" {
    const evt = EventRecord{
        .id = "evt-001",
        .kind = .tool_call,
        .timestamp = "2026-01-15T10:30:00Z",
    };
    try std.testing.expect(evt.severity == .info);
    try std.testing.expectEqual(@as(u64, 0), evt.duration_ns);
    try std.testing.expect(evt.summary == null);
    try std.testing.expect(evt.detail == null);
    try std.testing.expect(evt.source == null);
    try std.testing.expect(evt.correlation.session_id == null);
    try std.testing.expect(!evt.isSpan());
    try std.testing.expect(!evt.isWarningOrAbove());
}

test "EventRecord isSpan" {
    const instant = EventRecord{
        .id = "e1",
        .kind = .system,
        .timestamp = "2026-01-01T00:00:00Z",
    };
    try std.testing.expect(!instant.isSpan());

    const span = EventRecord{
        .id = "e2",
        .kind = .llm_request,
        .timestamp = "2026-01-01T00:00:00Z",
        .duration_ns = 500 * std.time.ns_per_ms,
    };
    try std.testing.expect(span.isSpan());
}

test "EventRecord isWarningOrAbove" {
    const info_evt = EventRecord{
        .id = "e1",
        .kind = .system,
        .severity = .info,
        .timestamp = "2026-01-01T00:00:00Z",
    };
    try std.testing.expect(!info_evt.isWarningOrAbove());

    const warn_evt = EventRecord{
        .id = "e2",
        .kind = .system,
        .severity = .warn,
        .timestamp = "2026-01-01T00:00:00Z",
    };
    try std.testing.expect(warn_evt.isWarningOrAbove());

    const err_evt = EventRecord{
        .id = "e3",
        .kind = .err,
        .severity = .err,
        .timestamp = "2026-01-01T00:00:00Z",
    };
    try std.testing.expect(err_evt.isWarningOrAbove());
}

test "EventRecord full construction" {
    const evt = EventRecord{
        .id = "evt-100",
        .kind = .tool_call,
        .severity = .debug,
        .timestamp = "2026-02-22T14:00:00Z",
        .correlation = .{
            .session_id = "sess-abc",
            .task_id = "task-007",
            .step_name = "run-shell",
        },
        .duration_ns = 250 * std.time.ns_per_ms,
        .summary = "Executed shell command",
        .detail = "ls -la /tmp",
        .source = "tools.shell",
    };
    try std.testing.expectEqualStrings("evt-100", evt.id);
    try std.testing.expect(evt.kind == .tool_call);
    try std.testing.expect(evt.severity == .debug);
    try std.testing.expectEqualStrings("sess-abc", evt.correlation.session_id.?);
    try std.testing.expectEqualStrings("task-007", evt.correlation.task_id.?);
    try std.testing.expectEqualStrings("run-shell", evt.correlation.step_name.?);
    try std.testing.expect(evt.correlation.parent_event_id == null);
    try std.testing.expect(evt.isSpan());
    try std.testing.expect(!evt.isWarningOrAbove());
    try std.testing.expectEqualStrings("Executed shell command", evt.summary.?);
    try std.testing.expectEqualStrings("ls -la /tmp", evt.detail.?);
    try std.testing.expectEqualStrings("tools.shell", evt.source.?);
}
