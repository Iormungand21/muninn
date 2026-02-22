//! Offline queue and deferred sync-out skeleton.
//!
//! Provides queue item types for deferring outbound requests, events, and
//! sync payloads when the network is unavailable. Items are persisted as
//! JSONL on disk so they survive process restarts.
//!
//! This module is a schema + persistence skeleton — no network transport
//! or automatic drain loop is implemented yet.

const std = @import("std");
const config_types = @import("config_types.zig");

// ── Queue item kind ────────────────────────────────────────────────
// Classifies what payload is being deferred.

pub const QueueItemKind = enum {
    /// An outbound LLM or API request that could not be sent.
    request,
    /// A structured event destined for a remote collector.
    event,
    /// A sync payload for huginn or another federated peer.
    sync,
    /// A channel message that could not be delivered.
    message,

    pub fn toString(self: QueueItemKind) []const u8 {
        return switch (self) {
            .request => "request",
            .event => "event",
            .sync => "sync",
            .message => "message",
        };
    }

    pub fn fromString(s: []const u8) ?QueueItemKind {
        if (std.mem.eql(u8, s, "request")) return .request;
        if (std.mem.eql(u8, s, "event")) return .event;
        if (std.mem.eql(u8, s, "sync")) return .sync;
        if (std.mem.eql(u8, s, "message")) return .message;
        return null;
    }
};

// ── Queue item priority ────────────────────────────────────────────

pub const QueuePriority = enum {
    /// Best-effort delivery; may be dropped if the queue overflows.
    low,
    /// Normal delivery priority.
    normal,
    /// Elevated priority; drained before normal items.
    high,

    pub fn toString(self: QueuePriority) []const u8 {
        return switch (self) {
            .low => "low",
            .normal => "normal",
            .high => "high",
        };
    }

    pub fn fromString(s: []const u8) ?QueuePriority {
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "normal")) return .normal;
        if (std.mem.eql(u8, s, "high")) return .high;
        return null;
    }

    /// Numeric level for comparison (higher = more urgent).
    pub fn level(self: QueuePriority) u8 {
        return switch (self) {
            .low => 0,
            .normal => 1,
            .high => 2,
        };
    }
};

// ── Queue item status ──────────────────────────────────────────────

pub const QueueItemStatus = enum {
    /// Waiting to be sent.
    pending,
    /// Currently being transmitted (claimed by drain loop).
    in_flight,
    /// Successfully delivered and acknowledged.
    delivered,
    /// Delivery failed after exhausting retries.
    failed,

    pub fn toString(self: QueueItemStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .in_flight => "in_flight",
            .delivered => "delivered",
            .failed => "failed",
        };
    }

    pub fn fromString(s: []const u8) ?QueueItemStatus {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "in_flight")) return .in_flight;
        if (std.mem.eql(u8, s, "delivered")) return .delivered;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        return null;
    }

    /// Returns true for terminal states.
    pub fn isTerminal(self: QueueItemStatus) bool {
        return self == .delivered or self == .failed;
    }
};

// ── Queue item record ──────────────────────────────────────────────
// The main record for a deferred outbound payload.

pub const QueueItem = struct {
    /// Unique item identifier.
    id: []const u8,
    /// What kind of payload is deferred.
    kind: QueueItemKind,
    /// Delivery priority.
    priority: QueuePriority = .normal,
    /// Current delivery status.
    status: QueueItemStatus = .pending,
    /// Number of delivery attempts made.
    attempts: u32 = 0,
    /// Maximum delivery attempts before marking failed (0 = unlimited).
    max_attempts: u32 = 5,
    /// ISO-8601 timestamp when the item was enqueued.
    enqueued_at: []const u8,
    /// ISO-8601 timestamp of the last delivery attempt (null if never attempted).
    last_attempt_at: ?[]const u8 = null,
    /// Target destination identifier (URL, peer ID, channel, etc.).
    destination: ?[]const u8 = null,
    /// The serialized payload body (JSON string, opaque to the queue).
    payload: ?[]const u8 = null,
    /// Last error message from a failed delivery attempt.
    last_error: ?[]const u8 = null,

    /// Returns true if the item can still be retried.
    pub fn canRetry(self: *const QueueItem) bool {
        if (self.status.isTerminal()) return false;
        if (self.max_attempts == 0) return true; // unlimited
        return self.attempts < self.max_attempts;
    }

    /// Returns true if the item has been delivered or permanently failed.
    pub fn isFinished(self: *const QueueItem) bool {
        return self.status.isTerminal();
    }
};

// ── JSONL serialization ────────────────────────────────────────────
// Mirrors events_store.zig: stack-buffer, no allocation, best-effort.

/// Serialize a QueueItem into a JSON line within the provided buffer.
/// Returns the written slice, or null if the buffer is too small.
pub fn serializeItem(buf: []u8, item: *const QueueItem) ?[]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    w.writeAll("{\"id\":\"") catch return null;
    w.writeAll(item.id) catch return null;
    w.writeAll("\",\"kind\":\"") catch return null;
    w.writeAll(item.kind.toString()) catch return null;
    w.writeAll("\",\"priority\":\"") catch return null;
    w.writeAll(item.priority.toString()) catch return null;
    w.writeAll("\",\"status\":\"") catch return null;
    w.writeAll(item.status.toString()) catch return null;
    w.print("\",\"attempts\":{d}", .{item.attempts}) catch return null;
    w.print(",\"max_attempts\":{d}", .{item.max_attempts}) catch return null;
    w.writeAll(",\"enqueued_at\":\"") catch return null;
    w.writeAll(item.enqueued_at) catch return null;
    w.writeByte('"') catch return null;

    if (item.last_attempt_at) |v| {
        w.writeAll(",\"last_attempt_at\":\"") catch return null;
        w.writeAll(v) catch return null;
        w.writeByte('"') catch return null;
    }
    if (item.destination) |v| {
        w.writeAll(",\"destination\":\"") catch return null;
        w.writeAll(v) catch return null;
        w.writeByte('"') catch return null;
    }
    if (item.payload) |v| {
        w.writeAll(",\"payload\":\"") catch return null;
        w.writeAll(v) catch return null;
        w.writeByte('"') catch return null;
    }
    if (item.last_error) |v| {
        w.writeAll(",\"last_error\":\"") catch return null;
        w.writeAll(v) catch return null;
        w.writeByte('"') catch return null;
    }

    w.writeByte('}') catch return null;
    return fbs.getWritten();
}

// ── Offline queue store ────────────────────────────────────────────
// Append-only JSONL persistence for queued items.

pub const OfflineQueue = struct {
    /// Path to the JSONL queue file.
    path: []const u8,
    /// Maximum items the queue may hold (0 = unlimited).
    max_items: u32 = 0,
    /// Number of items currently tracked (in-memory counter; skeleton only).
    item_count: u32 = 0,

    /// Enqueue a single item to the persistent store.
    /// TODO(M3-OFF): Full implementation would check max_items, dedup by ID,
    /// and maintain an in-memory index for fast dequeue-by-priority.
    pub fn enqueue(self: *OfflineQueue, item: *const QueueItem) bool {
        if (self.max_items > 0 and self.item_count >= self.max_items) {
            return false; // queue full
        }

        var buf: [4096]u8 = undefined;
        const line = serializeItem(&buf, item) orelse return false;
        self.writeLine(line);
        self.item_count += 1;
        return true;
    }

    /// Dequeue the next pending item.
    /// TODO(M3-OFF): Full implementation would read JSONL, parse, and return
    /// the highest-priority pending item, marking it as in_flight on disk.
    /// Skeleton returns null (no in-memory index yet).
    pub fn dequeue(_: *OfflineQueue) ?QueueItem {
        return null;
    }

    /// Return the current queue depth.
    pub fn depth(self: *const OfflineQueue) u32 {
        return self.item_count;
    }

    /// Returns true when the queue has reached its capacity.
    pub fn isFull(self: *const OfflineQueue) bool {
        if (self.max_items == 0) return false;
        return self.item_count >= self.max_items;
    }

    /// Returns remaining slots before the queue is full (0 = unlimited or full).
    pub fn remainingSlots(self: *const OfflineQueue) u32 {
        if (self.max_items == 0) return 0; // unlimited — signal with 0
        if (self.item_count >= self.max_items) return 0;
        return self.max_items - self.item_count;
    }

    /// Flush is a no-op — each enqueue writes directly.
    /// TODO(M3-OFF): Batch writes for higher throughput.
    pub fn flush(_: *OfflineQueue) void {}

    // ── Internal ───────────────────────────────────────────────────

    fn writeLine(self: *OfflineQueue, line: []const u8) void {
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

// ── Factory helpers ────────────────────────────────────────────────

/// Create an OfflineQueue from an OfflineQueueConfig.
pub fn offlineQueueFromConfig(cfg: config_types.OfflineQueueConfig) OfflineQueue {
    return .{
        .path = cfg.path,
        .max_items = cfg.max_items,
    };
}

/// Create an OfflineQueue with edge-appropriate defaults.
/// Small capacity to bound disk usage on constrained devices.
pub fn edgeOfflineQueue(path: []const u8) OfflineQueue {
    return .{
        .path = path,
        .max_items = 32,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "QueueItemKind toString roundtrip" {
    const kinds = [_]QueueItemKind{ .request, .event, .sync, .message };
    for (kinds) |k| {
        const str = k.toString();
        try std.testing.expect(QueueItemKind.fromString(str).? == k);
    }
    try std.testing.expect(QueueItemKind.fromString("bogus") == null);
}

test "QueuePriority toString roundtrip" {
    const priorities = [_]QueuePriority{ .low, .normal, .high };
    for (priorities) |p| {
        const str = p.toString();
        try std.testing.expect(QueuePriority.fromString(str).? == p);
    }
    try std.testing.expect(QueuePriority.fromString("bogus") == null);
}

test "QueuePriority level ordering" {
    try std.testing.expect(QueuePriority.low.level() < QueuePriority.normal.level());
    try std.testing.expect(QueuePriority.normal.level() < QueuePriority.high.level());
}

test "QueueItemStatus toString roundtrip" {
    const statuses = [_]QueueItemStatus{ .pending, .in_flight, .delivered, .failed };
    for (statuses) |s| {
        const str = s.toString();
        try std.testing.expect(QueueItemStatus.fromString(str).? == s);
    }
    try std.testing.expect(QueueItemStatus.fromString("bogus") == null);
}

test "QueueItemStatus isTerminal" {
    try std.testing.expect(QueueItemStatus.delivered.isTerminal());
    try std.testing.expect(QueueItemStatus.failed.isTerminal());
    try std.testing.expect(!QueueItemStatus.pending.isTerminal());
    try std.testing.expect(!QueueItemStatus.in_flight.isTerminal());
}

test "QueueItem defaults" {
    const item = QueueItem{
        .id = "q-001",
        .kind = .request,
        .enqueued_at = "2026-02-22T14:00:00Z",
    };
    try std.testing.expect(item.priority == .normal);
    try std.testing.expect(item.status == .pending);
    try std.testing.expectEqual(@as(u32, 0), item.attempts);
    try std.testing.expectEqual(@as(u32, 5), item.max_attempts);
    try std.testing.expect(item.destination == null);
    try std.testing.expect(item.payload == null);
    try std.testing.expect(item.last_error == null);
    try std.testing.expect(item.last_attempt_at == null);
    try std.testing.expect(!item.isFinished());
    try std.testing.expect(item.canRetry());
}

test "QueueItem canRetry with attempts exhausted" {
    const item = QueueItem{
        .id = "q-002",
        .kind = .sync,
        .status = .pending,
        .attempts = 5,
        .max_attempts = 5,
        .enqueued_at = "2026-02-22T14:00:00Z",
    };
    try std.testing.expect(!item.canRetry());
}

test "QueueItem canRetry unlimited" {
    const item = QueueItem{
        .id = "q-003",
        .kind = .event,
        .status = .pending,
        .attempts = 100,
        .max_attempts = 0, // unlimited
        .enqueued_at = "2026-02-22T14:00:00Z",
    };
    try std.testing.expect(item.canRetry());
}

test "QueueItem canRetry terminal status" {
    const delivered = QueueItem{
        .id = "q-004",
        .kind = .message,
        .status = .delivered,
        .enqueued_at = "2026-02-22T14:00:00Z",
    };
    try std.testing.expect(!delivered.canRetry());

    const failed = QueueItem{
        .id = "q-005",
        .kind = .request,
        .status = .failed,
        .enqueued_at = "2026-02-22T14:00:00Z",
    };
    try std.testing.expect(!failed.canRetry());
}

test "QueueItem isFinished" {
    const pending = QueueItem{
        .id = "q-010",
        .kind = .request,
        .status = .pending,
        .enqueued_at = "2026-02-22T14:00:00Z",
    };
    try std.testing.expect(!pending.isFinished());

    const delivered = QueueItem{
        .id = "q-011",
        .kind = .request,
        .status = .delivered,
        .enqueued_at = "2026-02-22T14:00:00Z",
    };
    try std.testing.expect(delivered.isFinished());
}

test "QueueItem full construction" {
    const item = QueueItem{
        .id = "q-100",
        .kind = .sync,
        .priority = .high,
        .status = .in_flight,
        .attempts = 2,
        .max_attempts = 10,
        .enqueued_at = "2026-02-22T14:00:00Z",
        .last_attempt_at = "2026-02-22T14:01:00Z",
        .destination = "huginn-peer-1",
        .payload = "{\"task\":\"sync-memories\"}",
        .last_error = "connection refused",
    };
    try std.testing.expectEqualStrings("q-100", item.id);
    try std.testing.expect(item.kind == .sync);
    try std.testing.expect(item.priority == .high);
    try std.testing.expect(item.status == .in_flight);
    try std.testing.expectEqual(@as(u32, 2), item.attempts);
    try std.testing.expectEqualStrings("huginn-peer-1", item.destination.?);
    try std.testing.expectEqualStrings("{\"task\":\"sync-memories\"}", item.payload.?);
    try std.testing.expectEqualStrings("connection refused", item.last_error.?);
    try std.testing.expect(item.canRetry());
    try std.testing.expect(!item.isFinished());
}

test "serializeItem minimal record" {
    var buf: [4096]u8 = undefined;
    const item = QueueItem{
        .id = "q-001",
        .kind = .request,
        .enqueued_at = "2026-02-22T14:00:00Z",
    };
    const line = serializeItem(&buf, &item).?;

    try std.testing.expect(std.mem.indexOf(u8, line, "\"id\":\"q-001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"kind\":\"request\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"priority\":\"normal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"status\":\"pending\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"attempts\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"enqueued_at\":\"2026-02-22T14:00:00Z\"") != null);
    // Optional fields should be absent
    try std.testing.expect(std.mem.indexOf(u8, line, "destination") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "payload") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "last_error") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "last_attempt_at") == null);
}

test "serializeItem with all optional fields" {
    var buf: [4096]u8 = undefined;
    const item = QueueItem{
        .id = "q-100",
        .kind = .sync,
        .priority = .high,
        .status = .in_flight,
        .attempts = 2,
        .max_attempts = 10,
        .enqueued_at = "2026-02-22T14:00:00Z",
        .last_attempt_at = "2026-02-22T14:01:00Z",
        .destination = "huginn",
        .payload = "sync-data",
        .last_error = "timeout",
    };
    const line = serializeItem(&buf, &item).?;

    try std.testing.expect(std.mem.indexOf(u8, line, "\"destination\":\"huginn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"payload\":\"sync-data\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"last_error\":\"timeout\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"last_attempt_at\":\"2026-02-22T14:01:00Z\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"attempts\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"max_attempts\":10") != null);
}

test "serializeItem returns null on tiny buffer" {
    var buf: [8]u8 = undefined;
    const item = QueueItem{
        .id = "q-001",
        .kind = .request,
        .enqueued_at = "2026-02-22T14:00:00Z",
    };
    try std.testing.expect(serializeItem(&buf, &item) == null);
}

test "serializeItem kind variants" {
    var buf: [4096]u8 = undefined;
    const kinds = [_]QueueItemKind{ .request, .event, .sync, .message };
    const expected = [_][]const u8{ "request", "event", "sync", "message" };

    for (kinds, expected) |k, exp| {
        const item = QueueItem{
            .id = "q",
            .kind = k,
            .enqueued_at = "2026-01-01T00:00:00Z",
        };
        const line = serializeItem(&buf, &item).?;
        const needle = std.fmt.bufPrint(buf[3000..], "\"kind\":\"{s}\"", .{exp}) catch continue;
        try std.testing.expect(std.mem.indexOf(u8, line, needle) != null);
    }
}

test "OfflineQueue creation" {
    var queue = OfflineQueue{ .path = "/tmp/nullclaw_offline_test.jsonl" };
    try std.testing.expectEqualStrings("/tmp/nullclaw_offline_test.jsonl", queue.path);
    try std.testing.expectEqual(@as(u32, 0), queue.max_items);
    try std.testing.expectEqual(@as(u32, 0), queue.depth());
    try std.testing.expect(!queue.isFull());
    queue.flush();
}

test "OfflineQueue enqueue writes to file" {
    const test_path = "/tmp/nullclaw_offline_enqueue_test.jsonl";
    std.fs.cwd().deleteFile(test_path) catch {};

    var queue = OfflineQueue{ .path = test_path };
    const item = QueueItem{
        .id = "q-test-001",
        .kind = .event,
        .enqueued_at = "2026-02-22T14:00:00Z",
        .destination = "remote-collector",
    };
    const ok = queue.enqueue(&item);
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(u32, 1), queue.depth());

    // Verify the file was created and contains the item
    const file = std.fs.cwd().openFile(test_path, .{}) catch return error.TestFailed;
    defer file.close();
    var read_buf: [4096]u8 = undefined;
    const bytes_read = file.readAll(&read_buf) catch return error.TestFailed;
    const contents = read_buf[0..bytes_read];

    try std.testing.expect(std.mem.indexOf(u8, contents, "\"id\":\"q-test-001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"kind\":\"event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"destination\":\"remote-collector\"") != null);
    try std.testing.expect(contents.len > 0 and contents[contents.len - 1] == '\n');

    std.fs.cwd().deleteFile(test_path) catch {};
}

test "OfflineQueue enqueue multiple items" {
    const test_path = "/tmp/nullclaw_offline_multi_test.jsonl";
    std.fs.cwd().deleteFile(test_path) catch {};

    var queue = OfflineQueue{ .path = test_path };
    const item1 = QueueItem{
        .id = "q-m-001",
        .kind = .request,
        .enqueued_at = "2026-01-01T00:00:00Z",
    };
    const item2 = QueueItem{
        .id = "q-m-002",
        .kind = .sync,
        .priority = .high,
        .enqueued_at = "2026-01-01T00:00:01Z",
    };
    try std.testing.expect(queue.enqueue(&item1));
    try std.testing.expect(queue.enqueue(&item2));
    try std.testing.expectEqual(@as(u32, 2), queue.depth());

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

    try std.testing.expect(std.mem.indexOf(u8, contents, "q-m-001") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "q-m-002") != null);

    std.fs.cwd().deleteFile(test_path) catch {};
}

test "OfflineQueue max_items enforcement" {
    const test_path = "/tmp/nullclaw_offline_cap_test.jsonl";
    std.fs.cwd().deleteFile(test_path) catch {};

    var queue = OfflineQueue{ .path = test_path, .max_items = 2 };
    try std.testing.expect(!queue.isFull());
    try std.testing.expectEqual(@as(u32, 2), queue.remainingSlots());

    const item1 = QueueItem{ .id = "q-c-001", .kind = .request, .enqueued_at = "2026-01-01T00:00:00Z" };
    const item2 = QueueItem{ .id = "q-c-002", .kind = .event, .enqueued_at = "2026-01-01T00:00:01Z" };
    const item3 = QueueItem{ .id = "q-c-003", .kind = .sync, .enqueued_at = "2026-01-01T00:00:02Z" };

    try std.testing.expect(queue.enqueue(&item1));
    try std.testing.expectEqual(@as(u32, 1), queue.remainingSlots());
    try std.testing.expect(queue.enqueue(&item2));
    try std.testing.expect(queue.isFull());
    try std.testing.expectEqual(@as(u32, 0), queue.remainingSlots());

    // Third item should be rejected
    try std.testing.expect(!queue.enqueue(&item3));
    try std.testing.expectEqual(@as(u32, 2), queue.depth());

    std.fs.cwd().deleteFile(test_path) catch {};
}

test "OfflineQueue dequeue returns null (skeleton)" {
    var queue = OfflineQueue{ .path = "/tmp/nullclaw_offline_deq_test.jsonl" };
    try std.testing.expect(queue.dequeue() == null);
}

test "OfflineQueue isFull unlimited" {
    var queue = OfflineQueue{ .path = "/tmp/test.jsonl", .max_items = 0 };
    queue.item_count = 1000;
    try std.testing.expect(!queue.isFull()); // unlimited never full
}

test "OfflineQueue remainingSlots unlimited" {
    const queue = OfflineQueue{ .path = "/tmp/test.jsonl", .max_items = 0 };
    try std.testing.expectEqual(@as(u32, 0), queue.remainingSlots());
}

test "offlineQueueFromConfig" {
    const cfg = config_types.OfflineQueueConfig{
        .path = "/data/offline.jsonl",
        .max_items = 100,
    };
    const queue = offlineQueueFromConfig(cfg);
    try std.testing.expectEqualStrings("/data/offline.jsonl", queue.path);
    try std.testing.expectEqual(@as(u32, 100), queue.max_items);
    try std.testing.expectEqual(@as(u32, 0), queue.depth());
}

test "edgeOfflineQueue" {
    const queue = edgeOfflineQueue("/tmp/edge_offline.jsonl");
    try std.testing.expectEqualStrings("/tmp/edge_offline.jsonl", queue.path);
    try std.testing.expectEqual(@as(u32, 32), queue.max_items);
}

test "offlineQueueFromConfig defaults" {
    const cfg = config_types.OfflineQueueConfig{};
    const queue = offlineQueueFromConfig(cfg);
    try std.testing.expectEqualStrings("offline_queue.jsonl", queue.path);
    try std.testing.expectEqual(@as(u32, 256), queue.max_items);
}
