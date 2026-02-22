//! JSONL file sink for the structured event timeline.
//!
//! Provides a minimal append-only store that serializes EventRecord
//! instances as one JSON object per line. Designed for local replay
//! and debugging — not a production database.

const std = @import("std");
const events = @import("events.zig");
const EventRecord = events.EventRecord;
const EventKind = events.EventKind;
const EventSeverity = events.EventSeverity;

// ── Event store ────────────────────────────────────────────────────
// Append-only JSONL sink backed by a filesystem path.

pub const EventStore = struct {
    /// Path to the JSONL log file.
    path: []const u8,
    /// Minimum severity to persist (events below this are dropped).
    min_severity: EventSeverity = .trace,

    /// Append a single event record as a JSONL line.
    /// Uses a stack buffer to avoid allocation; events that exceed the
    /// buffer are silently dropped (best-effort logging).
    pub fn append(self: *EventStore, record: *const EventRecord) void {
        if (record.severity.level() < self.min_severity.level()) return;

        var buf: [4096]u8 = undefined;
        const line = serializeEvent(&buf, record) orelse return;
        self.writeLine(line);
    }

    /// Flush is a no-op — each append writes directly.
    pub fn flush(_: *EventStore) void {}

    // ── Internal ───────────────────────────────────────────────────

    fn writeLine(self: *EventStore, line: []const u8) void {
        const file = std.fs.cwd().openFile(self.path, .{ .mode = .write_only }) catch {
            const new_file = std.fs.cwd().createFile(self.path, .{ .truncate = false }) catch return;
            defer new_file.close();
            new_file.seekFromEnd(0) catch return;
            new_file.writeAll(line) catch {};
            new_file.writeAll("\n") catch {};
            return;
        };
        defer file.close();
        file.seekFromEnd(0) catch return;
        file.writeAll(line) catch {};
        file.writeAll("\n") catch {};
    }
};

/// Serialize an EventRecord into a JSON line within the provided buffer.
/// Returns the written slice, or null if the buffer is too small.
pub fn serializeEvent(buf: []u8, record: *const EventRecord) ?[]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    w.writeAll("{\"id\":\"") catch return null;
    w.writeAll(record.id) catch return null;
    w.writeAll("\",\"kind\":\"") catch return null;
    w.writeAll(record.kind.toString()) catch return null;
    w.writeAll("\",\"severity\":\"") catch return null;
    w.writeAll(record.severity.toString()) catch return null;
    w.writeAll("\",\"timestamp\":\"") catch return null;
    w.writeAll(record.timestamp) catch return null;
    w.writeByte('"') catch return null;

    if (record.duration_ns > 0) {
        w.print(",\"duration_ns\":{d}", .{record.duration_ns}) catch return null;
    }

    // Correlation fields
    if (record.correlation.session_id) |v| {
        w.writeAll(",\"session_id\":\"") catch return null;
        w.writeAll(v) catch return null;
        w.writeByte('"') catch return null;
    }
    if (record.correlation.task_id) |v| {
        w.writeAll(",\"task_id\":\"") catch return null;
        w.writeAll(v) catch return null;
        w.writeByte('"') catch return null;
    }
    if (record.correlation.step_name) |v| {
        w.writeAll(",\"step_name\":\"") catch return null;
        w.writeAll(v) catch return null;
        w.writeByte('"') catch return null;
    }
    if (record.correlation.parent_event_id) |v| {
        w.writeAll(",\"parent_event_id\":\"") catch return null;
        w.writeAll(v) catch return null;
        w.writeByte('"') catch return null;
    }
    if (record.correlation.channel) |v| {
        w.writeAll(",\"channel\":\"") catch return null;
        w.writeAll(v) catch return null;
        w.writeByte('"') catch return null;
    }

    // Optional fields
    if (record.source) |v| {
        w.writeAll(",\"source\":\"") catch return null;
        w.writeAll(v) catch return null;
        w.writeByte('"') catch return null;
    }
    if (record.summary) |v| {
        w.writeAll(",\"summary\":\"") catch return null;
        w.writeAll(v) catch return null;
        w.writeByte('"') catch return null;
    }
    if (record.detail) |v| {
        w.writeAll(",\"detail\":\"") catch return null;
        w.writeAll(v) catch return null;
        w.writeByte('"') catch return null;
    }

    w.writeByte('}') catch return null;

    return fbs.getWritten();
}

// ── Tests ──────────────────────────────────────────────────────────

test "serializeEvent minimal record" {
    var buf: [4096]u8 = undefined;
    const record = EventRecord{
        .id = "evt-001",
        .kind = .system,
        .timestamp = "2026-01-01T00:00:00Z",
    };
    const line = serializeEvent(&buf, &record).?;

    try std.testing.expect(std.mem.indexOf(u8, line, "\"id\":\"evt-001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"kind\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"severity\":\"info\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"timestamp\":\"2026-01-01T00:00:00Z\"") != null);
    // No duration field when zero
    try std.testing.expect(std.mem.indexOf(u8, line, "duration_ns") == null);
    // No correlation fields when null
    try std.testing.expect(std.mem.indexOf(u8, line, "session_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "task_id") == null);
}

test "serializeEvent with duration" {
    var buf: [4096]u8 = undefined;
    const record = EventRecord{
        .id = "evt-002",
        .kind = .llm_request,
        .timestamp = "2026-01-01T00:00:00Z",
        .duration_ns = 250_000_000,
    };
    const line = serializeEvent(&buf, &record).?;

    try std.testing.expect(std.mem.indexOf(u8, line, "\"duration_ns\":250000000") != null);
}

test "serializeEvent with correlation" {
    var buf: [4096]u8 = undefined;
    const record = EventRecord{
        .id = "evt-003",
        .kind = .tool_call,
        .severity = .debug,
        .timestamp = "2026-02-22T14:00:00Z",
        .correlation = .{
            .session_id = "sess-abc",
            .task_id = "task-007",
            .step_name = "run-shell",
            .parent_event_id = "evt-002",
            .channel = "cli",
        },
        .source = "tools.shell",
        .summary = "ran ls",
        .detail = "ls -la",
    };
    const line = serializeEvent(&buf, &record).?;

    try std.testing.expect(std.mem.indexOf(u8, line, "\"session_id\":\"sess-abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"task_id\":\"task-007\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"step_name\":\"run-shell\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"parent_event_id\":\"evt-002\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"channel\":\"cli\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"source\":\"tools.shell\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"summary\":\"ran ls\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"detail\":\"ls -la\"") != null);
}

test "serializeEvent returns null on tiny buffer" {
    var buf: [8]u8 = undefined;
    const record = EventRecord{
        .id = "evt-001",
        .kind = .system,
        .timestamp = "2026-01-01T00:00:00Z",
    };
    try std.testing.expect(serializeEvent(&buf, &record) == null);
}

test "serializeEvent severity variants" {
    var buf: [4096]u8 = undefined;
    const severities = [_]events.EventSeverity{ .trace, .debug, .info, .warn, .err };
    const expected = [_][]const u8{ "trace", "debug", "info", "warn", "error" };

    for (severities, expected) |sev, exp| {
        const record = EventRecord{
            .id = "e",
            .kind = .system,
            .severity = sev,
            .timestamp = "2026-01-01T00:00:00Z",
        };
        const line = serializeEvent(&buf, &record).?;
        const needle = std.fmt.bufPrint(buf[3000..], "\"severity\":\"{s}\"", .{exp}) catch continue;
        try std.testing.expect(std.mem.indexOf(u8, line, needle) != null);
    }
}

test "EventStore creation" {
    var store = EventStore{ .path = "/tmp/nullclaw_events_test.jsonl" };
    // Verify default min_severity
    try std.testing.expect(store.min_severity == .trace);
    // Flush is a no-op
    store.flush();
}

test "EventStore append writes to file" {
    const test_path = "/tmp/nullclaw_events_store_test.jsonl";
    // Clean up any previous test file
    std.fs.cwd().deleteFile(test_path) catch {};

    var store = EventStore{ .path = test_path };
    const record = EventRecord{
        .id = "evt-test-001",
        .kind = .agent_start,
        .timestamp = "2026-02-22T14:00:00Z",
        .summary = "test event",
    };
    store.append(&record);

    // Verify the file was created and contains the event
    const file = std.fs.cwd().openFile(test_path, .{}) catch |e| {
        std.debug.print("Failed to open test file: {}\n", .{e});
        return error.TestFailed;
    };
    defer file.close();
    var read_buf: [4096]u8 = undefined;
    const bytes_read = file.readAll(&read_buf) catch return error.TestFailed;
    const contents = read_buf[0..bytes_read];

    try std.testing.expect(std.mem.indexOf(u8, contents, "\"id\":\"evt-test-001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"kind\":\"agent_start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"summary\":\"test event\"") != null);
    // Line should end with newline
    try std.testing.expect(contents.len > 0 and contents[contents.len - 1] == '\n');

    // Clean up
    std.fs.cwd().deleteFile(test_path) catch {};
}

test "EventStore append multiple events" {
    const test_path = "/tmp/nullclaw_events_multi_test.jsonl";
    std.fs.cwd().deleteFile(test_path) catch {};

    var store = EventStore{ .path = test_path };
    const e1 = EventRecord{
        .id = "evt-m-001",
        .kind = .agent_start,
        .timestamp = "2026-01-01T00:00:00Z",
    };
    const e2 = EventRecord{
        .id = "evt-m-002",
        .kind = .tool_call,
        .timestamp = "2026-01-01T00:00:01Z",
    };
    store.append(&e1);
    store.append(&e2);

    const file = std.fs.cwd().openFile(test_path, .{}) catch return error.TestFailed;
    defer file.close();
    var read_buf: [8192]u8 = undefined;
    const bytes_read = file.readAll(&read_buf) catch return error.TestFailed;
    const contents = read_buf[0..bytes_read];

    // Should have two lines
    var line_count: usize = 0;
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (line.len > 0) line_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), line_count);

    try std.testing.expect(std.mem.indexOf(u8, contents, "evt-m-001") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "evt-m-002") != null);

    std.fs.cwd().deleteFile(test_path) catch {};
}

test "EventStore min_severity filters events" {
    const test_path = "/tmp/nullclaw_events_filter_test.jsonl";
    std.fs.cwd().deleteFile(test_path) catch {};

    var store = EventStore{
        .path = test_path,
        .min_severity = .warn,
    };

    // This event (info) should be dropped
    const info_evt = EventRecord{
        .id = "evt-dropped",
        .kind = .system,
        .severity = .info,
        .timestamp = "2026-01-01T00:00:00Z",
    };
    store.append(&info_evt);

    // This event (warn) should be kept
    const warn_evt = EventRecord{
        .id = "evt-kept",
        .kind = .err,
        .severity = .warn,
        .timestamp = "2026-01-01T00:00:01Z",
    };
    store.append(&warn_evt);

    const file = std.fs.cwd().openFile(test_path, .{}) catch {
        // File might not exist if only the warn event was written
        // but we expect it to exist since warn >= warn
        return error.TestFailed;
    };
    defer file.close();
    var read_buf: [4096]u8 = undefined;
    const bytes_read = file.readAll(&read_buf) catch return error.TestFailed;
    const contents = read_buf[0..bytes_read];

    // Only the warn event should be present
    try std.testing.expect(std.mem.indexOf(u8, contents, "evt-dropped") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "evt-kept") != null);

    std.fs.cwd().deleteFile(test_path) catch {};
}
