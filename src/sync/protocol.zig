//! Shared sync protocol types and schema versioning for huginn <-> muninn.
//!
//! Defines the wire-level payload shapes for bidirectional sync between
//! nodes.  Every sync message is wrapped in a `SyncEnvelope` carrying
//! node identity, a monotonic sequence number, a schema version, and a
//! typed delta payload (event, task, or memory).

const std = @import("std");

// ── Schema version ──────────────────────────────────────────────────
// Explicit protocol version using semver-style major.minor.
// Major bump = breaking wire change; minor bump = additive fields only.

pub const SCHEMA_VERSION_MAJOR: u16 = 1;
pub const SCHEMA_VERSION_MINOR: u16 = 0;

pub const SchemaVersion = struct {
    major: u16 = SCHEMA_VERSION_MAJOR,
    minor: u16 = SCHEMA_VERSION_MINOR,

    /// Format as "major.minor" into a stack buffer.
    pub fn format(self: SchemaVersion, buf: []u8) ?[]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        w.print("{d}.{d}", .{ self.major, self.minor }) catch return null;
        return fbs.getWritten();
    }

    /// Returns true if `other` is wire-compatible (same major, equal or lower minor).
    pub fn isCompatible(self: SchemaVersion, other: SchemaVersion) bool {
        return self.major == other.major and other.minor <= self.minor;
    }
};

// ── Node role ───────────────────────────────────────────────────────
// Identifies the role of a sync participant.

pub const NodeRole = enum {
    /// Edge device running muninn.
    muninn,
    /// Cloud/server running huginn.
    huginn,
    /// Unknown or third-party node.
    unknown,

    pub fn toString(self: NodeRole) []const u8 {
        return switch (self) {
            .muninn => "muninn",
            .huginn => "huginn",
            .unknown => "unknown",
        };
    }

    pub fn fromString(s: []const u8) ?NodeRole {
        if (std.mem.eql(u8, s, "muninn")) return .muninn;
        if (std.mem.eql(u8, s, "huginn")) return .huginn;
        if (std.mem.eql(u8, s, "unknown")) return .unknown;
        return null;
    }
};

// ── Delta kind ──────────────────────────────────────────────────────
// Classifies the type of change being synced.

pub const DeltaKind = enum {
    /// An event timeline entry (observability / audit).
    event,
    /// A task lifecycle change.
    task,
    /// A memory record create/update/delete.
    memory,

    pub fn toString(self: DeltaKind) []const u8 {
        return switch (self) {
            .event => "event",
            .task => "task",
            .memory => "memory",
        };
    }

    pub fn fromString(s: []const u8) ?DeltaKind {
        if (std.mem.eql(u8, s, "event")) return .event;
        if (std.mem.eql(u8, s, "task")) return .task;
        if (std.mem.eql(u8, s, "memory")) return .memory;
        return null;
    }
};

// ── Delta operation ─────────────────────────────────────────────────
// The CRUD-like operation the delta represents.

pub const DeltaOp = enum {
    /// New record creation.
    create,
    /// Field-level update to an existing record.
    update,
    /// Soft or hard delete.
    delete,

    pub fn toString(self: DeltaOp) []const u8 {
        return switch (self) {
            .create => "create",
            .update => "update",
            .delete => "delete",
        };
    }

    pub fn fromString(s: []const u8) ?DeltaOp {
        if (std.mem.eql(u8, s, "create")) return .create;
        if (std.mem.eql(u8, s, "update")) return .update;
        if (std.mem.eql(u8, s, "delete")) return .delete;
        return null;
    }
};

// ── Sync direction ──────────────────────────────────────────────────

pub const SyncDirection = enum {
    /// muninn -> huginn (edge pushes to cloud).
    push,
    /// huginn -> muninn (cloud pushes to edge).
    pull,
    /// Both directions in a single exchange.
    bidirectional,

    pub fn toString(self: SyncDirection) []const u8 {
        return switch (self) {
            .push => "push",
            .pull => "pull",
            .bidirectional => "bidirectional",
        };
    }

    pub fn fromString(s: []const u8) ?SyncDirection {
        if (std.mem.eql(u8, s, "push")) return .push;
        if (std.mem.eql(u8, s, "pull")) return .pull;
        if (std.mem.eql(u8, s, "bidirectional")) return .bidirectional;
        return null;
    }
};

// ── Ack status ──────────────────────────────────────────────────────
// Result of processing a sync envelope at the receiver.

pub const AckStatus = enum {
    /// Envelope accepted and applied.
    accepted,
    /// Envelope rejected (e.g. schema mismatch, validation failure).
    rejected,
    /// Conflict detected — needs resolution.
    conflict,
    /// Receiver encountered an internal error.
    err,

    pub fn toString(self: AckStatus) []const u8 {
        return switch (self) {
            .accepted => "accepted",
            .rejected => "rejected",
            .conflict => "conflict",
            .err => "error",
        };
    }

    pub fn fromString(s: []const u8) ?AckStatus {
        if (std.mem.eql(u8, s, "accepted")) return .accepted;
        if (std.mem.eql(u8, s, "rejected")) return .rejected;
        if (std.mem.eql(u8, s, "conflict")) return .conflict;
        if (std.mem.eql(u8, s, "error")) return .err;
        return null;
    }

    /// Returns true for terminal states (no retry expected).
    pub fn isTerminal(self: AckStatus) bool {
        return self == .accepted or self == .rejected;
    }
};

// ── Delta payloads ──────────────────────────────────────────────────
// Typed payloads carried inside a SyncEnvelope.

/// A delta describing an event timeline change.
pub const EventDelta = struct {
    /// The event record ID being synced.
    event_id: []const u8,
    /// CRUD operation.
    op: DeltaOp = .create,
    /// Event kind string (maps to events.EventKind).
    event_kind: ?[]const u8 = null,
    /// Event severity string.
    severity: ?[]const u8 = null,
    /// ISO-8601 timestamp of the original event.
    event_timestamp: ?[]const u8 = null,
    /// Summary text.
    summary: ?[]const u8 = null,
};

/// A delta describing a task lifecycle change.
pub const TaskDelta = struct {
    /// The task record ID being synced.
    task_id: []const u8,
    /// CRUD operation.
    op: DeltaOp = .create,
    /// Task status string (maps to tasks.TaskStatus).
    status: ?[]const u8 = null,
    /// Task priority string.
    priority: ?[]const u8 = null,
    /// Task goal or description.
    goal: ?[]const u8 = null,
    /// Workspace scope.
    workspace_id: ?[]const u8 = null,
};

/// A delta describing a memory record change.
pub const MemoryDelta = struct {
    /// The memory record ID being synced.
    memory_id: []const u8,
    /// CRUD operation.
    op: DeltaOp = .create,
    /// Memory kind string (maps to memory.MemoryKind).
    memory_kind: ?[]const u8 = null,
    /// Retention tier string.
    retention_tier: ?[]const u8 = null,
    /// Key for lookup.
    key: ?[]const u8 = null,
    /// Content body (may be large; omitted on delete).
    content: ?[]const u8 = null,
    /// Confidence value as string (e.g. "0.85").
    confidence: ?[]const u8 = null,
};

// ── Sync envelope ───────────────────────────────────────────────────
// The top-level wire message wrapping every sync exchange.

pub const SyncEnvelope = struct {
    /// Unique identifier for this sync message.
    id: []const u8,
    /// Identifier of the sending node.
    node_id: []const u8,
    /// Role of the sending node.
    node_role: NodeRole = .muninn,
    /// Monotonically increasing sequence number per node.
    /// Receivers use this to detect gaps and order messages.
    sequence: u64,
    /// Protocol schema version of this message.
    schema_version: SchemaVersion = .{},
    /// ISO-8601 timestamp when the message was created.
    timestamp: []const u8,
    /// Direction of this sync exchange.
    direction: SyncDirection = .push,
    /// What kind of delta this envelope carries.
    delta_kind: DeltaKind,
    /// Optional workspace scope.
    workspace_id: ?[]const u8 = null,

    // Exactly one of these should be populated (matching delta_kind).
    /// Event delta payload (when delta_kind == .event).
    event_delta: ?EventDelta = null,
    /// Task delta payload (when delta_kind == .task).
    task_delta: ?TaskDelta = null,
    /// Memory delta payload (when delta_kind == .memory).
    memory_delta: ?MemoryDelta = null,

    /// Returns true if the envelope has a payload matching its delta_kind.
    pub fn hasPayload(self: *const SyncEnvelope) bool {
        return switch (self.delta_kind) {
            .event => self.event_delta != null,
            .task => self.task_delta != null,
            .memory => self.memory_delta != null,
        };
    }

    /// Returns the record ID from the contained delta, or null if missing.
    pub fn deltaRecordId(self: *const SyncEnvelope) ?[]const u8 {
        if (self.event_delta) |d| return d.event_id;
        if (self.task_delta) |d| return d.task_id;
        if (self.memory_delta) |d| return d.memory_id;
        return null;
    }
};

// ── Sync acknowledgement ────────────────────────────────────────────

pub const SyncAck = struct {
    /// The envelope ID being acknowledged.
    envelope_id: []const u8,
    /// The node ID of the acknowledger.
    node_id: []const u8,
    /// Outcome status.
    status: AckStatus,
    /// The sequence number that was acknowledged.
    sequence: u64,
    /// ISO-8601 timestamp of the acknowledgement.
    timestamp: []const u8,
    /// Optional reason (for rejected/conflict/error).
    reason: ?[]const u8 = null,

    /// Returns true if the ack indicates success.
    pub fn isSuccess(self: *const SyncAck) bool {
        return self.status == .accepted;
    }
};

// ── JSONL serialization ─────────────────────────────────────────────
// Stack-buffer serialization for sync envelopes (no allocation).

/// Serialize a SyncEnvelope into a JSON line within the provided buffer.
/// Returns the written slice, or null if the buffer is too small.
pub fn serializeEnvelope(buf: []u8, env: *const SyncEnvelope) ?[]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    w.writeAll("{\"id\":\"") catch return null;
    w.writeAll(env.id) catch return null;
    w.writeAll("\",\"node_id\":\"") catch return null;
    w.writeAll(env.node_id) catch return null;
    w.writeAll("\",\"node_role\":\"") catch return null;
    w.writeAll(env.node_role.toString()) catch return null;
    w.writeAll("\",\"sequence\":") catch return null;
    w.print("{d}", .{env.sequence}) catch return null;
    w.writeAll(",\"schema_version\":\"") catch return null;
    w.print("{d}.{d}", .{ env.schema_version.major, env.schema_version.minor }) catch return null;
    w.writeAll("\",\"timestamp\":\"") catch return null;
    w.writeAll(env.timestamp) catch return null;
    w.writeAll("\",\"direction\":\"") catch return null;
    w.writeAll(env.direction.toString()) catch return null;
    w.writeAll("\",\"delta_kind\":\"") catch return null;
    w.writeAll(env.delta_kind.toString()) catch return null;
    w.writeByte('"') catch return null;

    if (env.workspace_id) |v| {
        w.writeAll(",\"workspace_id\":\"") catch return null;
        w.writeAll(v) catch return null;
        w.writeByte('"') catch return null;
    }

    // Serialize the matching delta payload
    if (env.event_delta) |d| {
        w.writeAll(",\"event_delta\":{\"event_id\":\"") catch return null;
        w.writeAll(d.event_id) catch return null;
        w.writeAll("\",\"op\":\"") catch return null;
        w.writeAll(d.op.toString()) catch return null;
        w.writeByte('"') catch return null;
        if (d.event_kind) |v| {
            w.writeAll(",\"event_kind\":\"") catch return null;
            w.writeAll(v) catch return null;
            w.writeByte('"') catch return null;
        }
        if (d.severity) |v| {
            w.writeAll(",\"severity\":\"") catch return null;
            w.writeAll(v) catch return null;
            w.writeByte('"') catch return null;
        }
        if (d.event_timestamp) |v| {
            w.writeAll(",\"event_timestamp\":\"") catch return null;
            w.writeAll(v) catch return null;
            w.writeByte('"') catch return null;
        }
        if (d.summary) |v| {
            w.writeAll(",\"summary\":\"") catch return null;
            w.writeAll(v) catch return null;
            w.writeByte('"') catch return null;
        }
        w.writeByte('}') catch return null;
    }

    if (env.task_delta) |d| {
        w.writeAll(",\"task_delta\":{\"task_id\":\"") catch return null;
        w.writeAll(d.task_id) catch return null;
        w.writeAll("\",\"op\":\"") catch return null;
        w.writeAll(d.op.toString()) catch return null;
        w.writeByte('"') catch return null;
        if (d.status) |v| {
            w.writeAll(",\"status\":\"") catch return null;
            w.writeAll(v) catch return null;
            w.writeByte('"') catch return null;
        }
        if (d.priority) |v| {
            w.writeAll(",\"priority\":\"") catch return null;
            w.writeAll(v) catch return null;
            w.writeByte('"') catch return null;
        }
        if (d.goal) |v| {
            w.writeAll(",\"goal\":\"") catch return null;
            w.writeAll(v) catch return null;
            w.writeByte('"') catch return null;
        }
        if (d.workspace_id) |v| {
            w.writeAll(",\"workspace_id\":\"") catch return null;
            w.writeAll(v) catch return null;
            w.writeByte('"') catch return null;
        }
        w.writeByte('}') catch return null;
    }

    if (env.memory_delta) |d| {
        w.writeAll(",\"memory_delta\":{\"memory_id\":\"") catch return null;
        w.writeAll(d.memory_id) catch return null;
        w.writeAll("\",\"op\":\"") catch return null;
        w.writeAll(d.op.toString()) catch return null;
        w.writeByte('"') catch return null;
        if (d.memory_kind) |v| {
            w.writeAll(",\"memory_kind\":\"") catch return null;
            w.writeAll(v) catch return null;
            w.writeByte('"') catch return null;
        }
        if (d.retention_tier) |v| {
            w.writeAll(",\"retention_tier\":\"") catch return null;
            w.writeAll(v) catch return null;
            w.writeByte('"') catch return null;
        }
        if (d.key) |v| {
            w.writeAll(",\"key\":\"") catch return null;
            w.writeAll(v) catch return null;
            w.writeByte('"') catch return null;
        }
        if (d.content) |v| {
            w.writeAll(",\"content\":\"") catch return null;
            w.writeAll(v) catch return null;
            w.writeByte('"') catch return null;
        }
        if (d.confidence) |v| {
            w.writeAll(",\"confidence\":\"") catch return null;
            w.writeAll(v) catch return null;
            w.writeByte('"') catch return null;
        }
        w.writeByte('}') catch return null;
    }

    w.writeByte('}') catch return null;
    return fbs.getWritten();
}

/// Serialize a SyncAck into a JSON line within the provided buffer.
/// Returns the written slice, or null if the buffer is too small.
pub fn serializeAck(buf: []u8, ack: *const SyncAck) ?[]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    w.writeAll("{\"envelope_id\":\"") catch return null;
    w.writeAll(ack.envelope_id) catch return null;
    w.writeAll("\",\"node_id\":\"") catch return null;
    w.writeAll(ack.node_id) catch return null;
    w.writeAll("\",\"status\":\"") catch return null;
    w.writeAll(ack.status.toString()) catch return null;
    w.writeAll("\",\"sequence\":") catch return null;
    w.print("{d}", .{ack.sequence}) catch return null;
    w.writeAll(",\"timestamp\":\"") catch return null;
    w.writeAll(ack.timestamp) catch return null;
    w.writeByte('"') catch return null;

    if (ack.reason) |v| {
        w.writeAll(",\"reason\":\"") catch return null;
        w.writeAll(v) catch return null;
        w.writeByte('"') catch return null;
    }

    w.writeByte('}') catch return null;
    return fbs.getWritten();
}

// ── Factory helpers ─────────────────────────────────────────────────

/// Create a SyncConfig-aware default schema version.
pub fn currentSchemaVersion() SchemaVersion {
    return .{};
}

// ── Tests ───────────────────────────────────────────────────────────

test "SchemaVersion format" {
    var buf: [32]u8 = undefined;
    const v = SchemaVersion{};
    const str = v.format(&buf).?;
    try std.testing.expectEqualStrings("1.0", str);
}

test "SchemaVersion format custom" {
    var buf: [32]u8 = undefined;
    const v = SchemaVersion{ .major = 2, .minor = 3 };
    const str = v.format(&buf).?;
    try std.testing.expectEqualStrings("2.3", str);
}

test "SchemaVersion isCompatible same version" {
    const v = SchemaVersion{ .major = 1, .minor = 2 };
    try std.testing.expect(v.isCompatible(v));
}

test "SchemaVersion isCompatible lower minor" {
    const v = SchemaVersion{ .major = 1, .minor = 2 };
    const older = SchemaVersion{ .major = 1, .minor = 1 };
    try std.testing.expect(v.isCompatible(older));
}

test "SchemaVersion isCompatible rejects higher minor" {
    const v = SchemaVersion{ .major = 1, .minor = 0 };
    const newer = SchemaVersion{ .major = 1, .minor = 1 };
    try std.testing.expect(!v.isCompatible(newer));
}

test "SchemaVersion isCompatible rejects different major" {
    const v1 = SchemaVersion{ .major = 1, .minor = 5 };
    const v2 = SchemaVersion{ .major = 2, .minor = 0 };
    try std.testing.expect(!v1.isCompatible(v2));
    try std.testing.expect(!v2.isCompatible(v1));
}

test "NodeRole toString roundtrip" {
    const roles = [_]NodeRole{ .muninn, .huginn, .unknown };
    for (roles) |r| {
        const str = r.toString();
        try std.testing.expect(NodeRole.fromString(str).? == r);
    }
    try std.testing.expect(NodeRole.fromString("bogus") == null);
}

test "DeltaKind toString roundtrip" {
    const kinds = [_]DeltaKind{ .event, .task, .memory };
    for (kinds) |k| {
        const str = k.toString();
        try std.testing.expect(DeltaKind.fromString(str).? == k);
    }
    try std.testing.expect(DeltaKind.fromString("bogus") == null);
}

test "DeltaOp toString roundtrip" {
    const ops = [_]DeltaOp{ .create, .update, .delete };
    for (ops) |o| {
        const str = o.toString();
        try std.testing.expect(DeltaOp.fromString(str).? == o);
    }
    try std.testing.expect(DeltaOp.fromString("bogus") == null);
}

test "SyncDirection toString roundtrip" {
    const dirs = [_]SyncDirection{ .push, .pull, .bidirectional };
    for (dirs) |d| {
        const str = d.toString();
        try std.testing.expect(SyncDirection.fromString(str).? == d);
    }
    try std.testing.expect(SyncDirection.fromString("bogus") == null);
}

test "AckStatus toString roundtrip" {
    const statuses = [_]AckStatus{ .accepted, .rejected, .conflict, .err };
    for (statuses) |s| {
        const str = s.toString();
        try std.testing.expect(AckStatus.fromString(str).? == s);
    }
    try std.testing.expect(AckStatus.fromString("bogus") == null);
}

test "AckStatus error maps to string 'error'" {
    try std.testing.expectEqualStrings("error", AckStatus.err.toString());
    try std.testing.expect(AckStatus.fromString("error").? == .err);
}

test "AckStatus isTerminal" {
    try std.testing.expect(AckStatus.accepted.isTerminal());
    try std.testing.expect(AckStatus.rejected.isTerminal());
    try std.testing.expect(!AckStatus.conflict.isTerminal());
    try std.testing.expect(!AckStatus.err.isTerminal());
}

test "EventDelta defaults" {
    const d = EventDelta{ .event_id = "evt-001" };
    try std.testing.expect(d.op == .create);
    try std.testing.expect(d.event_kind == null);
    try std.testing.expect(d.severity == null);
    try std.testing.expect(d.event_timestamp == null);
    try std.testing.expect(d.summary == null);
}

test "TaskDelta defaults" {
    const d = TaskDelta{ .task_id = "task-001" };
    try std.testing.expect(d.op == .create);
    try std.testing.expect(d.status == null);
    try std.testing.expect(d.priority == null);
    try std.testing.expect(d.goal == null);
    try std.testing.expect(d.workspace_id == null);
}

test "MemoryDelta defaults" {
    const d = MemoryDelta{ .memory_id = "mem-001" };
    try std.testing.expect(d.op == .create);
    try std.testing.expect(d.memory_kind == null);
    try std.testing.expect(d.retention_tier == null);
    try std.testing.expect(d.key == null);
    try std.testing.expect(d.content == null);
    try std.testing.expect(d.confidence == null);
}

test "SyncEnvelope defaults and hasPayload" {
    const env = SyncEnvelope{
        .id = "sync-001",
        .node_id = "node-muninn-01",
        .sequence = 1,
        .timestamp = "2026-02-22T14:00:00Z",
        .delta_kind = .event,
    };
    try std.testing.expect(env.node_role == .muninn);
    try std.testing.expect(env.direction == .push);
    try std.testing.expect(env.schema_version.major == SCHEMA_VERSION_MAJOR);
    try std.testing.expect(env.schema_version.minor == SCHEMA_VERSION_MINOR);
    try std.testing.expect(env.workspace_id == null);
    try std.testing.expect(!env.hasPayload());
    try std.testing.expect(env.deltaRecordId() == null);
}

test "SyncEnvelope with event delta" {
    const delta = EventDelta{
        .event_id = "evt-100",
        .op = .create,
        .event_kind = "task_lifecycle",
        .severity = "info",
        .event_timestamp = "2026-02-22T13:59:00Z",
        .summary = "task started",
    };
    const env = SyncEnvelope{
        .id = "sync-002",
        .node_id = "node-muninn-01",
        .sequence = 42,
        .timestamp = "2026-02-22T14:00:00Z",
        .delta_kind = .event,
        .event_delta = delta,
    };
    try std.testing.expect(env.hasPayload());
    try std.testing.expectEqualStrings("evt-100", env.deltaRecordId().?);
}

test "SyncEnvelope with task delta" {
    const delta = TaskDelta{
        .task_id = "task-200",
        .op = .update,
        .status = "in_progress",
        .goal = "deploy feature",
    };
    const env = SyncEnvelope{
        .id = "sync-003",
        .node_id = "node-huginn-01",
        .node_role = .huginn,
        .sequence = 7,
        .timestamp = "2026-02-22T14:00:00Z",
        .direction = .pull,
        .delta_kind = .task,
        .task_delta = delta,
    };
    try std.testing.expect(env.hasPayload());
    try std.testing.expect(env.node_role == .huginn);
    try std.testing.expect(env.direction == .pull);
    try std.testing.expectEqualStrings("task-200", env.deltaRecordId().?);
}

test "SyncEnvelope with memory delta" {
    const delta = MemoryDelta{
        .memory_id = "mem-300",
        .op = .create,
        .memory_kind = "episodic",
        .key = "session-notes",
        .content = "user prefers dark mode",
        .confidence = "0.9",
    };
    const env = SyncEnvelope{
        .id = "sync-004",
        .node_id = "node-muninn-02",
        .sequence = 1,
        .timestamp = "2026-02-22T14:00:00Z",
        .delta_kind = .memory,
        .memory_delta = delta,
        .workspace_id = "ws-main",
    };
    try std.testing.expect(env.hasPayload());
    try std.testing.expectEqualStrings("mem-300", env.deltaRecordId().?);
    try std.testing.expectEqualStrings("ws-main", env.workspace_id.?);
}

test "SyncAck defaults" {
    const ack = SyncAck{
        .envelope_id = "sync-001",
        .node_id = "node-huginn-01",
        .status = .accepted,
        .sequence = 1,
        .timestamp = "2026-02-22T14:00:01Z",
    };
    try std.testing.expect(ack.isSuccess());
    try std.testing.expect(ack.reason == null);
}

test "SyncAck rejected with reason" {
    const ack = SyncAck{
        .envelope_id = "sync-002",
        .node_id = "node-huginn-01",
        .status = .rejected,
        .sequence = 42,
        .timestamp = "2026-02-22T14:00:01Z",
        .reason = "schema version too new",
    };
    try std.testing.expect(!ack.isSuccess());
    try std.testing.expectEqualStrings("schema version too new", ack.reason.?);
}

test "SyncAck conflict" {
    const ack = SyncAck{
        .envelope_id = "sync-003",
        .node_id = "node-huginn-01",
        .status = .conflict,
        .sequence = 10,
        .timestamp = "2026-02-22T14:00:01Z",
        .reason = "concurrent update on task-200",
    };
    try std.testing.expect(!ack.isSuccess());
    try std.testing.expect(!ack.status.isTerminal());
}

test "serializeEnvelope minimal event" {
    var buf: [4096]u8 = undefined;
    const delta = EventDelta{ .event_id = "evt-001" };
    const env = SyncEnvelope{
        .id = "sync-001",
        .node_id = "node-m-01",
        .sequence = 1,
        .timestamp = "2026-02-22T14:00:00Z",
        .delta_kind = .event,
        .event_delta = delta,
    };
    const line = serializeEnvelope(&buf, &env).?;

    try std.testing.expect(std.mem.indexOf(u8, line, "\"id\":\"sync-001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"node_id\":\"node-m-01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"node_role\":\"muninn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"sequence\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"schema_version\":\"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"direction\":\"push\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"delta_kind\":\"event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"event_delta\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"event_id\":\"evt-001\"") != null);
    // No workspace_id in output
    try std.testing.expect(std.mem.indexOf(u8, line, "workspace_id") == null);
}

test "serializeEnvelope full task" {
    var buf: [4096]u8 = undefined;
    const delta = TaskDelta{
        .task_id = "task-200",
        .op = .update,
        .status = "running",
        .priority = "high",
        .goal = "deploy",
        .workspace_id = "ws-1",
    };
    const env = SyncEnvelope{
        .id = "sync-010",
        .node_id = "node-h-01",
        .node_role = .huginn,
        .sequence = 99,
        .timestamp = "2026-02-22T15:00:00Z",
        .direction = .pull,
        .delta_kind = .task,
        .task_delta = delta,
        .workspace_id = "ws-1",
    };
    const line = serializeEnvelope(&buf, &env).?;

    try std.testing.expect(std.mem.indexOf(u8, line, "\"node_role\":\"huginn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"sequence\":99") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"direction\":\"pull\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"task_delta\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"task_id\":\"task-200\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"op\":\"update\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"status\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"goal\":\"deploy\"") != null);
}

test "serializeEnvelope memory delta" {
    var buf: [4096]u8 = undefined;
    const delta = MemoryDelta{
        .memory_id = "mem-500",
        .op = .delete,
    };
    const env = SyncEnvelope{
        .id = "sync-020",
        .node_id = "node-m-02",
        .sequence = 5,
        .timestamp = "2026-02-22T16:00:00Z",
        .delta_kind = .memory,
        .memory_delta = delta,
    };
    const line = serializeEnvelope(&buf, &env).?;

    try std.testing.expect(std.mem.indexOf(u8, line, "\"memory_delta\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"memory_id\":\"mem-500\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"op\":\"delete\"") != null);
    // No optional fields for delete
    try std.testing.expect(std.mem.indexOf(u8, line, "memory_kind") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"content\"") == null);
}

test "serializeEnvelope returns null on tiny buffer" {
    var buf: [8]u8 = undefined;
    const env = SyncEnvelope{
        .id = "sync-001",
        .node_id = "n",
        .sequence = 1,
        .timestamp = "2026-01-01T00:00:00Z",
        .delta_kind = .event,
    };
    try std.testing.expect(serializeEnvelope(&buf, &env) == null);
}

test "serializeAck accepted" {
    var buf: [4096]u8 = undefined;
    const ack = SyncAck{
        .envelope_id = "sync-001",
        .node_id = "node-h-01",
        .status = .accepted,
        .sequence = 1,
        .timestamp = "2026-02-22T14:00:01Z",
    };
    const line = serializeAck(&buf, &ack).?;

    try std.testing.expect(std.mem.indexOf(u8, line, "\"envelope_id\":\"sync-001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"node_id\":\"node-h-01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"status\":\"accepted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"sequence\":1") != null);
    // No reason for accepted
    try std.testing.expect(std.mem.indexOf(u8, line, "reason") == null);
}

test "serializeAck with reason" {
    var buf: [4096]u8 = undefined;
    const ack = SyncAck{
        .envelope_id = "sync-002",
        .node_id = "node-h-01",
        .status = .conflict,
        .sequence = 42,
        .timestamp = "2026-02-22T14:00:01Z",
        .reason = "concurrent edit",
    };
    const line = serializeAck(&buf, &ack).?;

    try std.testing.expect(std.mem.indexOf(u8, line, "\"status\":\"conflict\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"reason\":\"concurrent edit\"") != null);
}

test "serializeAck returns null on tiny buffer" {
    var buf: [8]u8 = undefined;
    const ack = SyncAck{
        .envelope_id = "sync-001",
        .node_id = "n",
        .status = .accepted,
        .sequence = 1,
        .timestamp = "2026-01-01T00:00:00Z",
    };
    try std.testing.expect(serializeAck(&buf, &ack) == null);
}

test "currentSchemaVersion returns default" {
    const v = currentSchemaVersion();
    try std.testing.expectEqual(@as(u16, SCHEMA_VERSION_MAJOR), v.major);
    try std.testing.expectEqual(@as(u16, SCHEMA_VERSION_MINOR), v.minor);
}
