//! Federated task routing handshake and heartbeat message flow.
//!
//! Defines types and state transitions for establishing and maintaining
//! sync connections between muninn (edge) and huginn (cloud) nodes.
//! Includes degraded-mode and offline markers in the protocol state.
//!
//! No transport wiring — these are pure data types and state-transition
//! helpers for future transport integration (WebSocket, HTTP long-poll, etc.).

const std = @import("std");
const protocol = @import("protocol.zig");

// ── Handshake phase ─────────────────────────────────────────────────
// State machine for the connection handshake lifecycle.

pub const HandshakePhase = enum {
    /// No handshake in progress.
    idle,
    /// Initiator has sent a handshake init; awaiting response.
    init_sent,
    /// Responder has received an init; processing.
    init_received,
    /// Responder has sent an ack back; awaiting confirmation.
    ack_sent,
    /// Handshake completed successfully — sync channel is open.
    established,
    /// Peer explicitly rejected the handshake.
    rejected,
    /// Handshake failed due to timeout or error.
    failed,

    pub fn toString(self: HandshakePhase) []const u8 {
        return switch (self) {
            .idle => "idle",
            .init_sent => "init_sent",
            .init_received => "init_received",
            .ack_sent => "ack_sent",
            .established => "established",
            .rejected => "rejected",
            .failed => "failed",
        };
    }

    pub fn fromString(s: []const u8) ?HandshakePhase {
        if (std.mem.eql(u8, s, "idle")) return .idle;
        if (std.mem.eql(u8, s, "init_sent")) return .init_sent;
        if (std.mem.eql(u8, s, "init_received")) return .init_received;
        if (std.mem.eql(u8, s, "ack_sent")) return .ack_sent;
        if (std.mem.eql(u8, s, "established")) return .established;
        if (std.mem.eql(u8, s, "rejected")) return .rejected;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        return null;
    }

    /// Returns true for terminal states (no further transitions expected).
    pub fn isTerminal(self: HandshakePhase) bool {
        return self == .established or self == .rejected or self == .failed;
    }

    /// Returns true if the handshake is actively in progress.
    pub fn isInProgress(self: HandshakePhase) bool {
        return self == .init_sent or self == .init_received or self == .ack_sent;
    }
};

// ── Handshake intent ────────────────────────────────────────────────
// What the initiating node wants from the connection.

pub const HandshakeIntent = enum {
    /// Full bidirectional sync of events, tasks, and memories.
    sync,
    /// Delegate planning/tasks to the peer (muninn -> huginn).
    delegate,
    /// Observe-only: receive events without pushing changes.
    observe,

    pub fn toString(self: HandshakeIntent) []const u8 {
        return switch (self) {
            .sync => "sync",
            .delegate => "delegate",
            .observe => "observe",
        };
    }

    pub fn fromString(s: []const u8) ?HandshakeIntent {
        if (std.mem.eql(u8, s, "sync")) return .sync;
        if (std.mem.eql(u8, s, "delegate")) return .delegate;
        if (std.mem.eql(u8, s, "observe")) return .observe;
        return null;
    }
};

// ── Node health ─────────────────────────────────────────────────────
// Reported health of a sync participant.

pub const NodeHealth = enum {
    /// Node is fully operational.
    healthy,
    /// Node is running but with reduced capability (e.g. low resources).
    degraded,
    /// Node is unreachable or has declared itself offline.
    offline,
    /// Health status not yet determined.
    unknown,

    pub fn toString(self: NodeHealth) []const u8 {
        return switch (self) {
            .healthy => "healthy",
            .degraded => "degraded",
            .offline => "offline",
            .unknown => "unknown",
        };
    }

    pub fn fromString(s: []const u8) ?NodeHealth {
        if (std.mem.eql(u8, s, "healthy")) return .healthy;
        if (std.mem.eql(u8, s, "degraded")) return .degraded;
        if (std.mem.eql(u8, s, "offline")) return .offline;
        if (std.mem.eql(u8, s, "unknown")) return .unknown;
        return null;
    }

    /// Returns true if the node can participate in sync.
    pub fn canSync(self: NodeHealth) bool {
        return self == .healthy or self == .degraded;
    }
};

// ── Connection state ────────────────────────────────────────────────
// Tracks the full state of a federation connection to a peer.

pub const ConnectionState = struct {
    /// Current handshake phase.
    phase: HandshakePhase = .idle,
    /// Peer node ID.
    peer_node_id: []const u8,
    /// Peer node role.
    peer_role: protocol.NodeRole = .unknown,
    /// Local node health as last reported.
    local_health: NodeHealth = .unknown,
    /// Peer health as last reported via heartbeat.
    peer_health: NodeHealth = .unknown,
    /// Negotiated intent (set after handshake completes).
    intent: HandshakeIntent = .sync,
    /// Negotiated schema version (set after handshake completes).
    schema_version: protocol.SchemaVersion = .{},
    /// Number of consecutive heartbeat misses from the peer.
    missed_heartbeats: u32 = 0,
    /// Maximum consecutive misses before marking peer offline.
    max_missed_heartbeats: u32 = 3,
    /// ISO-8601 timestamp of last successful heartbeat exchange.
    last_heartbeat_at: ?[]const u8 = null,
    /// ISO-8601 timestamp when the connection was established.
    established_at: ?[]const u8 = null,
    /// Reason for rejection or failure (if applicable).
    failure_reason: ?[]const u8 = null,

    /// Returns true if the connection is ready for sync traffic.
    pub fn isReady(self: *const ConnectionState) bool {
        return self.phase == .established and
            self.local_health.canSync() and
            self.peer_health.canSync();
    }

    /// Returns true if the peer appears to have gone offline.
    pub fn isPeerUnresponsive(self: *const ConnectionState) bool {
        return self.missed_heartbeats >= self.max_missed_heartbeats;
    }
};

// ── Handshake init message ──────────────────────────────────────────
// Sent by the initiator to start a federation handshake.

pub const HandshakeInit = struct {
    /// Unique handshake session ID.
    handshake_id: []const u8,
    /// Initiator node ID.
    node_id: []const u8,
    /// Initiator node role.
    node_role: protocol.NodeRole = .muninn,
    /// Protocol schema version offered by the initiator.
    schema_version: protocol.SchemaVersion = .{},
    /// What the initiator wants from this connection.
    intent: HandshakeIntent = .sync,
    /// Current health of the initiator.
    health: NodeHealth = .healthy,
    /// ISO-8601 timestamp of the init message.
    timestamp: []const u8,
    /// Proposed heartbeat interval in seconds (0 = no heartbeat).
    heartbeat_interval_s: u32 = 30,
};

// ── Handshake response message ──────────────────────────────────────
// Sent by the responder after receiving a HandshakeInit.

pub const HandshakeResponse = struct {
    /// The handshake_id from the init message being responded to.
    handshake_id: []const u8,
    /// Responder node ID.
    node_id: []const u8,
    /// Responder node role.
    node_role: protocol.NodeRole = .huginn,
    /// Whether the handshake is accepted.
    accepted: bool,
    /// Negotiated schema version (responder's version).
    schema_version: protocol.SchemaVersion = .{},
    /// Responder's current health.
    health: NodeHealth = .healthy,
    /// ISO-8601 timestamp of the response.
    timestamp: []const u8,
    /// Agreed heartbeat interval in seconds.
    heartbeat_interval_s: u32 = 30,
    /// Reason for rejection (if not accepted).
    reject_reason: ?[]const u8 = null,
};

// ── Heartbeat message ───────────────────────────────────────────────
// Periodic liveness and status probe between connected peers.

pub const Heartbeat = struct {
    /// Sender node ID.
    node_id: []const u8,
    /// Sender's current health.
    health: NodeHealth = .healthy,
    /// Monotonic heartbeat sequence (per connection, not per node).
    sequence: u64,
    /// ISO-8601 timestamp of the heartbeat.
    timestamp: []const u8,
    /// Sender's last applied sync sequence (for gap detection).
    last_sync_sequence: u64 = 0,
    /// Number of items queued for sync-out (backpressure signal).
    pending_sync_count: u32 = 0,
};

// ── Heartbeat ack ───────────────────────────────────────────────────
// Response to a heartbeat.

pub const HeartbeatAck = struct {
    /// Node ID of the acknowledger.
    node_id: []const u8,
    /// Acknowledger's current health.
    health: NodeHealth = .healthy,
    /// The heartbeat sequence being acknowledged.
    sequence: u64,
    /// ISO-8601 timestamp of the ack.
    timestamp: []const u8,
    /// Acknowledger's last applied sync sequence.
    last_sync_sequence: u64 = 0,
};

// ── State transition helpers ────────────────────────────────────────
// Pure functions that compute the next connection state given an event.
// These return a new phase (and optional side-effects via struct fields)
// without performing I/O.

/// Result of a state transition attempt.
pub const TransitionResult = struct {
    /// The new handshake phase after the transition.
    next_phase: HandshakePhase,
    /// Whether the transition was valid.
    valid: bool,
    /// Optional reason for invalid transitions.
    reason: ?[]const u8 = null,
};

/// Transition: initiator sends a handshake init.
/// Valid from: idle, failed (retry).
pub fn transitionSendInit(current: HandshakePhase) TransitionResult {
    return switch (current) {
        .idle, .failed => .{ .next_phase = .init_sent, .valid = true },
        else => .{
            .next_phase = current,
            .valid = false,
            .reason = "can only send init from idle or failed state",
        },
    };
}

/// Transition: responder receives a handshake init.
/// Valid from: idle.
pub fn transitionReceiveInit(current: HandshakePhase) TransitionResult {
    return switch (current) {
        .idle => .{ .next_phase = .init_received, .valid = true },
        else => .{
            .next_phase = current,
            .valid = false,
            .reason = "can only receive init in idle state",
        },
    };
}

/// Transition: responder sends an accept response.
/// Valid from: init_received.
pub fn transitionSendAccept(current: HandshakePhase) TransitionResult {
    return switch (current) {
        .init_received => .{ .next_phase = .ack_sent, .valid = true },
        else => .{
            .next_phase = current,
            .valid = false,
            .reason = "can only send accept from init_received state",
        },
    };
}

/// Transition: responder sends a reject response.
/// Valid from: init_received.
pub fn transitionSendReject(current: HandshakePhase) TransitionResult {
    return switch (current) {
        .init_received => .{ .next_phase = .rejected, .valid = true },
        else => .{
            .next_phase = current,
            .valid = false,
            .reason = "can only send reject from init_received state",
        },
    };
}

/// Transition: initiator receives an accept response.
/// Valid from: init_sent.
pub fn transitionReceiveAccept(current: HandshakePhase) TransitionResult {
    return switch (current) {
        .init_sent => .{ .next_phase = .established, .valid = true },
        else => .{
            .next_phase = current,
            .valid = false,
            .reason = "can only receive accept in init_sent state",
        },
    };
}

/// Transition: initiator receives a reject response.
/// Valid from: init_sent.
pub fn transitionReceiveReject(current: HandshakePhase) TransitionResult {
    return switch (current) {
        .init_sent => .{ .next_phase = .rejected, .valid = true },
        else => .{
            .next_phase = current,
            .valid = false,
            .reason = "can only receive reject in init_sent state",
        },
    };
}

/// Transition: responder receives confirmation (initiator's first sync/heartbeat).
/// Valid from: ack_sent.
pub fn transitionConfirmEstablished(current: HandshakePhase) TransitionResult {
    return switch (current) {
        .ack_sent => .{ .next_phase = .established, .valid = true },
        else => .{
            .next_phase = current,
            .valid = false,
            .reason = "can only confirm established from ack_sent state",
        },
    };
}

/// Transition: timeout or error causes failure.
/// Valid from any in-progress state.
pub fn transitionFail(current: HandshakePhase) TransitionResult {
    if (current.isInProgress()) {
        return .{ .next_phase = .failed, .valid = true };
    }
    return .{
        .next_phase = current,
        .valid = false,
        .reason = "can only fail from an in-progress state",
    };
}

/// Transition: connection is torn down (reset to idle).
/// Valid from any state except idle.
pub fn transitionReset(current: HandshakePhase) TransitionResult {
    return switch (current) {
        .idle => .{
            .next_phase = .idle,
            .valid = false,
            .reason = "already idle",
        },
        else => .{ .next_phase = .idle, .valid = true },
    };
}

/// Process a heartbeat miss on a connection state.
/// Returns the updated health assessment of the peer.
pub fn processHeartbeatMiss(state: *ConnectionState) NodeHealth {
    state.missed_heartbeats += 1;
    if (state.isPeerUnresponsive()) {
        state.peer_health = .offline;
    } else {
        state.peer_health = .degraded;
    }
    return state.peer_health;
}

/// Process a successful heartbeat on a connection state.
/// Resets the miss counter and updates peer health.
pub fn processHeartbeatSuccess(state: *ConnectionState, reported_health: NodeHealth, timestamp: []const u8) void {
    state.missed_heartbeats = 0;
    state.peer_health = reported_health;
    state.last_heartbeat_at = timestamp;
}

// ── JSONL serialization ─────────────────────────────────────────────
// Stack-buffer serialization for handshake/heartbeat messages.

/// Serialize a HandshakeInit into a JSON line within the provided buffer.
/// Returns the written slice, or null if the buffer is too small.
pub fn serializeHandshakeInit(buf: []u8, init: *const HandshakeInit) ?[]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    w.writeAll("{\"handshake_id\":\"") catch return null;
    w.writeAll(init.handshake_id) catch return null;
    w.writeAll("\",\"node_id\":\"") catch return null;
    w.writeAll(init.node_id) catch return null;
    w.writeAll("\",\"node_role\":\"") catch return null;
    w.writeAll(init.node_role.toString()) catch return null;
    w.writeAll("\",\"schema_version\":\"") catch return null;
    w.print("{d}.{d}", .{ init.schema_version.major, init.schema_version.minor }) catch return null;
    w.writeAll("\",\"intent\":\"") catch return null;
    w.writeAll(init.intent.toString()) catch return null;
    w.writeAll("\",\"health\":\"") catch return null;
    w.writeAll(init.health.toString()) catch return null;
    w.writeAll("\",\"timestamp\":\"") catch return null;
    w.writeAll(init.timestamp) catch return null;
    w.writeAll("\",\"heartbeat_interval_s\":") catch return null;
    w.print("{d}", .{init.heartbeat_interval_s}) catch return null;
    w.writeByte('}') catch return null;
    return fbs.getWritten();
}

/// Serialize a Heartbeat into a JSON line within the provided buffer.
/// Returns the written slice, or null if the buffer is too small.
pub fn serializeHeartbeat(buf: []u8, hb: *const Heartbeat) ?[]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    w.writeAll("{\"node_id\":\"") catch return null;
    w.writeAll(hb.node_id) catch return null;
    w.writeAll("\",\"health\":\"") catch return null;
    w.writeAll(hb.health.toString()) catch return null;
    w.writeAll("\",\"sequence\":") catch return null;
    w.print("{d}", .{hb.sequence}) catch return null;
    w.writeAll(",\"timestamp\":\"") catch return null;
    w.writeAll(hb.timestamp) catch return null;
    w.writeAll("\",\"last_sync_sequence\":") catch return null;
    w.print("{d}", .{hb.last_sync_sequence}) catch return null;
    w.writeAll(",\"pending_sync_count\":") catch return null;
    w.print("{d}", .{hb.pending_sync_count}) catch return null;
    w.writeByte('}') catch return null;
    return fbs.getWritten();
}

// ── Tests ───────────────────────────────────────────────────────────

test "HandshakePhase toString roundtrip" {
    const phases = [_]HandshakePhase{
        .idle,        .init_sent,    .init_received,
        .ack_sent,    .established,  .rejected,
        .failed,
    };
    for (phases) |p| {
        const str = p.toString();
        try std.testing.expect(HandshakePhase.fromString(str).? == p);
    }
    try std.testing.expect(HandshakePhase.fromString("bogus") == null);
}

test "HandshakePhase isTerminal" {
    try std.testing.expect(HandshakePhase.established.isTerminal());
    try std.testing.expect(HandshakePhase.rejected.isTerminal());
    try std.testing.expect(HandshakePhase.failed.isTerminal());
    try std.testing.expect(!HandshakePhase.idle.isTerminal());
    try std.testing.expect(!HandshakePhase.init_sent.isTerminal());
    try std.testing.expect(!HandshakePhase.init_received.isTerminal());
    try std.testing.expect(!HandshakePhase.ack_sent.isTerminal());
}

test "HandshakePhase isInProgress" {
    try std.testing.expect(HandshakePhase.init_sent.isInProgress());
    try std.testing.expect(HandshakePhase.init_received.isInProgress());
    try std.testing.expect(HandshakePhase.ack_sent.isInProgress());
    try std.testing.expect(!HandshakePhase.idle.isInProgress());
    try std.testing.expect(!HandshakePhase.established.isInProgress());
    try std.testing.expect(!HandshakePhase.rejected.isInProgress());
    try std.testing.expect(!HandshakePhase.failed.isInProgress());
}

test "HandshakeIntent toString roundtrip" {
    const intents = [_]HandshakeIntent{ .sync, .delegate, .observe };
    for (intents) |i| {
        const str = i.toString();
        try std.testing.expect(HandshakeIntent.fromString(str).? == i);
    }
    try std.testing.expect(HandshakeIntent.fromString("bogus") == null);
}

test "NodeHealth toString roundtrip" {
    const healths = [_]NodeHealth{ .healthy, .degraded, .offline, .unknown };
    for (healths) |h| {
        const str = h.toString();
        try std.testing.expect(NodeHealth.fromString(str).? == h);
    }
    try std.testing.expect(NodeHealth.fromString("bogus") == null);
}

test "NodeHealth canSync" {
    try std.testing.expect(NodeHealth.healthy.canSync());
    try std.testing.expect(NodeHealth.degraded.canSync());
    try std.testing.expect(!NodeHealth.offline.canSync());
    try std.testing.expect(!NodeHealth.unknown.canSync());
}

test "ConnectionState defaults" {
    const cs = ConnectionState{ .peer_node_id = "huginn-01" };
    try std.testing.expect(cs.phase == .idle);
    try std.testing.expect(cs.peer_role == .unknown);
    try std.testing.expect(cs.local_health == .unknown);
    try std.testing.expect(cs.peer_health == .unknown);
    try std.testing.expect(cs.intent == .sync);
    try std.testing.expect(cs.missed_heartbeats == 0);
    try std.testing.expect(cs.max_missed_heartbeats == 3);
    try std.testing.expect(cs.last_heartbeat_at == null);
    try std.testing.expect(cs.established_at == null);
    try std.testing.expect(cs.failure_reason == null);
}

test "ConnectionState isReady" {
    var cs = ConnectionState{ .peer_node_id = "huginn-01" };
    // Not ready by default (idle + unknown health).
    try std.testing.expect(!cs.isReady());

    // Established but unknown health — not ready.
    cs.phase = .established;
    try std.testing.expect(!cs.isReady());

    // Healthy local + healthy peer + established — ready.
    cs.local_health = .healthy;
    cs.peer_health = .healthy;
    try std.testing.expect(cs.isReady());

    // Degraded still allows sync.
    cs.local_health = .degraded;
    try std.testing.expect(cs.isReady());

    // Offline blocks sync.
    cs.peer_health = .offline;
    try std.testing.expect(!cs.isReady());
}

test "ConnectionState isPeerUnresponsive" {
    var cs = ConnectionState{ .peer_node_id = "huginn-01" };
    try std.testing.expect(!cs.isPeerUnresponsive());

    cs.missed_heartbeats = 2;
    try std.testing.expect(!cs.isPeerUnresponsive());

    cs.missed_heartbeats = 3;
    try std.testing.expect(cs.isPeerUnresponsive());

    cs.missed_heartbeats = 10;
    try std.testing.expect(cs.isPeerUnresponsive());
}

test "HandshakeInit defaults" {
    const init = HandshakeInit{
        .handshake_id = "hs-001",
        .node_id = "muninn-01",
        .timestamp = "2026-02-22T14:00:00Z",
    };
    try std.testing.expect(init.node_role == .muninn);
    try std.testing.expect(init.schema_version.major == protocol.SCHEMA_VERSION_MAJOR);
    try std.testing.expect(init.intent == .sync);
    try std.testing.expect(init.health == .healthy);
    try std.testing.expect(init.heartbeat_interval_s == 30);
}

test "HandshakeResponse defaults" {
    const resp = HandshakeResponse{
        .handshake_id = "hs-001",
        .node_id = "huginn-01",
        .accepted = true,
        .timestamp = "2026-02-22T14:00:01Z",
    };
    try std.testing.expect(resp.node_role == .huginn);
    try std.testing.expect(resp.accepted);
    try std.testing.expect(resp.health == .healthy);
    try std.testing.expect(resp.heartbeat_interval_s == 30);
    try std.testing.expect(resp.reject_reason == null);
}

test "HandshakeResponse rejection" {
    const resp = HandshakeResponse{
        .handshake_id = "hs-002",
        .node_id = "huginn-01",
        .accepted = false,
        .timestamp = "2026-02-22T14:00:01Z",
        .reject_reason = "schema version incompatible",
    };
    try std.testing.expect(!resp.accepted);
    try std.testing.expectEqualStrings("schema version incompatible", resp.reject_reason.?);
}

test "Heartbeat defaults" {
    const hb = Heartbeat{
        .node_id = "muninn-01",
        .sequence = 1,
        .timestamp = "2026-02-22T14:01:00Z",
    };
    try std.testing.expect(hb.health == .healthy);
    try std.testing.expect(hb.last_sync_sequence == 0);
    try std.testing.expect(hb.pending_sync_count == 0);
}

test "HeartbeatAck defaults" {
    const ack = HeartbeatAck{
        .node_id = "huginn-01",
        .sequence = 1,
        .timestamp = "2026-02-22T14:01:01Z",
    };
    try std.testing.expect(ack.health == .healthy);
    try std.testing.expect(ack.last_sync_sequence == 0);
}

// ── State transition tests ──────────────────────────────────────────

test "transition: idle -> init_sent (send init)" {
    const r = transitionSendInit(.idle);
    try std.testing.expect(r.valid);
    try std.testing.expect(r.next_phase == .init_sent);
}

test "transition: failed -> init_sent (retry)" {
    const r = transitionSendInit(.failed);
    try std.testing.expect(r.valid);
    try std.testing.expect(r.next_phase == .init_sent);
}

test "transition: established -> init_sent (invalid)" {
    const r = transitionSendInit(.established);
    try std.testing.expect(!r.valid);
    try std.testing.expect(r.next_phase == .established);
    try std.testing.expect(r.reason != null);
}

test "transition: idle -> init_received (receive init)" {
    const r = transitionReceiveInit(.idle);
    try std.testing.expect(r.valid);
    try std.testing.expect(r.next_phase == .init_received);
}

test "transition: init_received -> ack_sent (send accept)" {
    const r = transitionSendAccept(.init_received);
    try std.testing.expect(r.valid);
    try std.testing.expect(r.next_phase == .ack_sent);
}

test "transition: init_received -> rejected (send reject)" {
    const r = transitionSendReject(.init_received);
    try std.testing.expect(r.valid);
    try std.testing.expect(r.next_phase == .rejected);
}

test "transition: init_sent -> established (receive accept)" {
    const r = transitionReceiveAccept(.init_sent);
    try std.testing.expect(r.valid);
    try std.testing.expect(r.next_phase == .established);
}

test "transition: init_sent -> rejected (receive reject)" {
    const r = transitionReceiveReject(.init_sent);
    try std.testing.expect(r.valid);
    try std.testing.expect(r.next_phase == .rejected);
}

test "transition: ack_sent -> established (confirm)" {
    const r = transitionConfirmEstablished(.ack_sent);
    try std.testing.expect(r.valid);
    try std.testing.expect(r.next_phase == .established);
}

test "transition: in-progress -> failed (timeout)" {
    const in_progress = [_]HandshakePhase{ .init_sent, .init_received, .ack_sent };
    for (in_progress) |p| {
        const r = transitionFail(p);
        try std.testing.expect(r.valid);
        try std.testing.expect(r.next_phase == .failed);
    }
}

test "transition: idle -> failed (invalid)" {
    const r = transitionFail(.idle);
    try std.testing.expect(!r.valid);
    try std.testing.expect(r.next_phase == .idle);
}

test "transition: established -> failed (invalid)" {
    const r = transitionFail(.established);
    try std.testing.expect(!r.valid);
}

test "transition: any -> idle (reset)" {
    const non_idle = [_]HandshakePhase{
        .init_sent, .init_received, .ack_sent,
        .established, .rejected, .failed,
    };
    for (non_idle) |p| {
        const r = transitionReset(p);
        try std.testing.expect(r.valid);
        try std.testing.expect(r.next_phase == .idle);
    }
}

test "transition: idle -> idle (reset invalid)" {
    const r = transitionReset(.idle);
    try std.testing.expect(!r.valid);
    try std.testing.expect(r.reason != null);
}

// ── Heartbeat processing tests ──────────────────────────────────────

test "processHeartbeatMiss degrades then offlines" {
    var cs = ConnectionState{
        .peer_node_id = "huginn-01",
        .phase = .established,
        .local_health = .healthy,
        .peer_health = .healthy,
    };

    // First miss: degraded.
    const h1 = processHeartbeatMiss(&cs);
    try std.testing.expect(h1 == .degraded);
    try std.testing.expect(cs.missed_heartbeats == 1);

    // Second miss: still degraded.
    const h2 = processHeartbeatMiss(&cs);
    try std.testing.expect(h2 == .degraded);
    try std.testing.expect(cs.missed_heartbeats == 2);

    // Third miss: offline.
    const h3 = processHeartbeatMiss(&cs);
    try std.testing.expect(h3 == .offline);
    try std.testing.expect(cs.missed_heartbeats == 3);
    try std.testing.expect(!cs.isReady());
}

test "processHeartbeatSuccess resets misses" {
    var cs = ConnectionState{
        .peer_node_id = "huginn-01",
        .phase = .established,
        .local_health = .healthy,
        .peer_health = .degraded,
        .missed_heartbeats = 2,
    };

    processHeartbeatSuccess(&cs, .healthy, "2026-02-22T14:05:00Z");
    try std.testing.expect(cs.missed_heartbeats == 0);
    try std.testing.expect(cs.peer_health == .healthy);
    try std.testing.expectEqualStrings("2026-02-22T14:05:00Z", cs.last_heartbeat_at.?);
    try std.testing.expect(cs.isReady());
}

// ── Full handshake flow test ────────────────────────────────────────

test "full handshake flow: initiator side" {
    // Simulate the initiator (muninn) side of a successful handshake.
    var phase: HandshakePhase = .idle;

    // Step 1: Send init.
    const r1 = transitionSendInit(phase);
    try std.testing.expect(r1.valid);
    phase = r1.next_phase;
    try std.testing.expect(phase == .init_sent);

    // Step 2: Receive accept from responder.
    const r2 = transitionReceiveAccept(phase);
    try std.testing.expect(r2.valid);
    phase = r2.next_phase;
    try std.testing.expect(phase == .established);
    try std.testing.expect(phase.isTerminal());
}

test "full handshake flow: responder side" {
    // Simulate the responder (huginn) side of a successful handshake.
    var phase: HandshakePhase = .idle;

    // Step 1: Receive init.
    const r1 = transitionReceiveInit(phase);
    try std.testing.expect(r1.valid);
    phase = r1.next_phase;
    try std.testing.expect(phase == .init_received);

    // Step 2: Send accept.
    const r2 = transitionSendAccept(phase);
    try std.testing.expect(r2.valid);
    phase = r2.next_phase;
    try std.testing.expect(phase == .ack_sent);

    // Step 3: Receive confirmation (first heartbeat/sync).
    const r3 = transitionConfirmEstablished(phase);
    try std.testing.expect(r3.valid);
    phase = r3.next_phase;
    try std.testing.expect(phase == .established);
}

test "handshake rejection flow" {
    // Initiator sends, responder rejects.
    var init_phase: HandshakePhase = .idle;
    var resp_phase: HandshakePhase = .idle;

    const r1 = transitionSendInit(init_phase);
    init_phase = r1.next_phase;

    const r2 = transitionReceiveInit(resp_phase);
    resp_phase = r2.next_phase;

    // Responder rejects.
    const r3 = transitionSendReject(resp_phase);
    resp_phase = r3.next_phase;
    try std.testing.expect(resp_phase == .rejected);

    // Initiator receives rejection.
    const r4 = transitionReceiveReject(init_phase);
    init_phase = r4.next_phase;
    try std.testing.expect(init_phase == .rejected);
}

test "handshake timeout and retry flow" {
    var phase: HandshakePhase = .idle;

    // Send init.
    phase = transitionSendInit(phase).next_phase;
    try std.testing.expect(phase == .init_sent);

    // Timeout (fail).
    phase = transitionFail(phase).next_phase;
    try std.testing.expect(phase == .failed);

    // Retry from failed state.
    phase = transitionSendInit(phase).next_phase;
    try std.testing.expect(phase == .init_sent);
}

// ── Serialization tests ─────────────────────────────────────────────

test "serializeHandshakeInit" {
    var buf: [4096]u8 = undefined;
    const init = HandshakeInit{
        .handshake_id = "hs-001",
        .node_id = "muninn-01",
        .timestamp = "2026-02-22T14:00:00Z",
    };
    const line = serializeHandshakeInit(&buf, &init).?;

    try std.testing.expect(std.mem.indexOf(u8, line, "\"handshake_id\":\"hs-001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"node_id\":\"muninn-01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"node_role\":\"muninn\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"schema_version\":\"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"intent\":\"sync\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"health\":\"healthy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"heartbeat_interval_s\":30") != null);
}

test "serializeHandshakeInit returns null on tiny buffer" {
    var buf: [8]u8 = undefined;
    const init = HandshakeInit{
        .handshake_id = "hs-001",
        .node_id = "n",
        .timestamp = "2026-01-01T00:00:00Z",
    };
    try std.testing.expect(serializeHandshakeInit(&buf, &init) == null);
}

test "serializeHeartbeat" {
    var buf: [4096]u8 = undefined;
    const hb = Heartbeat{
        .node_id = "muninn-01",
        .health = .degraded,
        .sequence = 42,
        .timestamp = "2026-02-22T14:05:00Z",
        .last_sync_sequence = 100,
        .pending_sync_count = 5,
    };
    const line = serializeHeartbeat(&buf, &hb).?;

    try std.testing.expect(std.mem.indexOf(u8, line, "\"node_id\":\"muninn-01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"health\":\"degraded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"sequence\":42") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"last_sync_sequence\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"pending_sync_count\":5") != null);
}

test "serializeHeartbeat returns null on tiny buffer" {
    var buf: [8]u8 = undefined;
    const hb = Heartbeat{
        .node_id = "n",
        .sequence = 1,
        .timestamp = "2026-01-01T00:00:00Z",
    };
    try std.testing.expect(serializeHeartbeat(&buf, &hb) == null);
}
