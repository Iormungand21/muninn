//! Conflict resolution policy helpers for synced tasks and memories.
//!
//! When a sync envelope arrives carrying a delta that conflicts with local
//! state (concurrent edits, overlapping creates, etc.), the resolver applies
//! a deterministic precedence chain to choose a winner without human
//! intervention.
//!
//! ## Precedence rules (applied in order until one is decisive)
//!
//! **Tasks:**
//!   1. Source ownership — the node that owns the workspace wins updates.
//!   2. `updated_at` — most recently updated record wins.
//!   3. Tie-break: prefer local (avoids unnecessary state churn).
//!
//! **Memories:**
//!   1. `last_confirmed_at` — most recently confirmed record wins.
//!   2. `confidence` — higher confidence value wins.
//!   3. `updated_at` — most recently updated record wins.
//!   4. Tie-break: prefer local.

const std = @import("std");
const protocol = @import("protocol.zig");

// ── Conflict side ──────────────────────────────────────────────────
// Identifies which side of a conflict a record belongs to.

pub const ConflictSide = enum {
    /// The record already present on the receiving node.
    local,
    /// The incoming record from the sync envelope.
    remote,

    pub fn toString(self: ConflictSide) []const u8 {
        return switch (self) {
            .local => "local",
            .remote => "remote",
        };
    }

    pub fn fromString(s: []const u8) ?ConflictSide {
        if (std.mem.eql(u8, s, "local")) return .local;
        if (std.mem.eql(u8, s, "remote")) return .remote;
        return null;
    }
};

// ── Conflict outcome ───────────────────────────────────────────────

pub const ConflictOutcome = enum {
    /// Accept the local version; discard the remote delta.
    accept_local,
    /// Accept the remote version; overwrite local state.
    accept_remote,

    pub fn toString(self: ConflictOutcome) []const u8 {
        return switch (self) {
            .accept_local => "accept_local",
            .accept_remote => "accept_remote",
        };
    }

    pub fn fromString(s: []const u8) ?ConflictOutcome {
        if (std.mem.eql(u8, s, "accept_local")) return .accept_local;
        if (std.mem.eql(u8, s, "accept_remote")) return .accept_remote;
        return null;
    }

    /// The winning side.
    pub fn winner(self: ConflictOutcome) ConflictSide {
        return switch (self) {
            .accept_local => .local,
            .accept_remote => .remote,
        };
    }
};

// ── Conflict record ────────────────────────────────────────────────
// A lightweight view of one side of a conflict carrying only the
// fields needed for resolution.  Timestamps are ISO-8601 strings
// compared lexicographically (which is correct for ISO-8601 in UTC).

pub const ConflictRecord = struct {
    /// Which side this record represents.
    side: ConflictSide,
    /// The node that produced this record.
    node_id: []const u8,
    /// ISO-8601 timestamp of last update.
    updated_at: []const u8,
    /// ISO-8601 timestamp of last explicit confirmation (may be null).
    last_confirmed_at: ?[]const u8 = null,
    /// Confidence value in [0.0, 1.0] (relevant for memories).
    confidence: f64 = 1.0,
    /// Whether this node is the designated owner of the workspace
    /// containing the record.
    is_source_owner: bool = false,
};

// ── Individual resolution helpers ──────────────────────────────────
// Each helper returns a decisive outcome or null if the criterion
// cannot break the tie.

/// Resolve by source ownership: the designated owner wins.
/// If both or neither are owners, returns null (indecisive).
pub fn resolveBySourceOwnership(local: *const ConflictRecord, remote: *const ConflictRecord) ?ConflictOutcome {
    if (local.is_source_owner and !remote.is_source_owner) return .accept_local;
    if (remote.is_source_owner and !local.is_source_owner) return .accept_remote;
    return null;
}

/// Resolve by `last_confirmed_at`: most recently confirmed wins.
/// Null timestamps lose to non-null.  Equal timestamps are indecisive.
pub fn resolveByConfirmedAt(local: *const ConflictRecord, remote: *const ConflictRecord) ?ConflictOutcome {
    const l = local.last_confirmed_at;
    const r = remote.last_confirmed_at;

    if (l == null and r == null) return null;
    if (l != null and r == null) return .accept_local;
    if (l == null and r != null) return .accept_remote;

    const order = std.mem.order(u8, l.?, r.?);
    return switch (order) {
        .gt => .accept_local,
        .lt => .accept_remote,
        .eq => null,
    };
}

/// Resolve by confidence: higher value wins.
/// Equal values (within epsilon) are indecisive.
pub fn resolveByConfidence(local: *const ConflictRecord, remote: *const ConflictRecord) ?ConflictOutcome {
    const epsilon = 1e-9;
    const diff = local.confidence - remote.confidence;
    if (diff > epsilon) return .accept_local;
    if (diff < -epsilon) return .accept_remote;
    return null;
}

/// Resolve by `updated_at`: most recently updated wins.
/// Equal timestamps are indecisive.
pub fn resolveByUpdatedAt(local: *const ConflictRecord, remote: *const ConflictRecord) ?ConflictOutcome {
    const order = std.mem.order(u8, local.updated_at, remote.updated_at);
    return switch (order) {
        .gt => .accept_local,
        .lt => .accept_remote,
        .eq => null,
    };
}

// ── Composite resolvers ────────────────────────────────────────────

/// Resolve a task conflict using the task precedence chain:
///   1. Source ownership
///   2. updated_at
///   3. Tie-break: accept local
pub fn resolveTask(local: *const ConflictRecord, remote: *const ConflictRecord) ConflictOutcome {
    if (resolveBySourceOwnership(local, remote)) |o| return o;
    if (resolveByUpdatedAt(local, remote)) |o| return o;
    return .accept_local;
}

/// Resolve a memory conflict using the memory precedence chain:
///   1. last_confirmed_at
///   2. confidence
///   3. updated_at
///   4. Tie-break: accept local
pub fn resolveMemory(local: *const ConflictRecord, remote: *const ConflictRecord) ConflictOutcome {
    if (resolveByConfirmedAt(local, remote)) |o| return o;
    if (resolveByConfidence(local, remote)) |o| return o;
    if (resolveByUpdatedAt(local, remote)) |o| return o;
    return .accept_local;
}

/// Top-level resolver: dispatches to resolveTask or resolveMemory
/// based on the delta kind.  Events are append-only and do not
/// conflict; they always accept the remote (idempotent merge).
pub fn resolve(kind: protocol.DeltaKind, local: *const ConflictRecord, remote: *const ConflictRecord) ConflictOutcome {
    return switch (kind) {
        .event => .accept_remote,
        .task => resolveTask(local, remote),
        .memory => resolveMemory(local, remote),
    };
}

// ── Tests ───────────────────────────────────────────────────────────

test "ConflictSide toString roundtrip" {
    const sides = [_]ConflictSide{ .local, .remote };
    for (sides) |s| {
        const str = s.toString();
        try std.testing.expect(ConflictSide.fromString(str).? == s);
    }
    try std.testing.expect(ConflictSide.fromString("bogus") == null);
}

test "ConflictOutcome toString roundtrip" {
    const outcomes = [_]ConflictOutcome{ .accept_local, .accept_remote };
    for (outcomes) |o| {
        const str = o.toString();
        try std.testing.expect(ConflictOutcome.fromString(str).? == o);
    }
    try std.testing.expect(ConflictOutcome.fromString("bogus") == null);
}

test "ConflictOutcome winner" {
    try std.testing.expect(ConflictOutcome.accept_local.winner() == .local);
    try std.testing.expect(ConflictOutcome.accept_remote.winner() == .remote);
}

test "resolveBySourceOwnership local owner wins" {
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z", .is_source_owner = true };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z", .is_source_owner = false };
    try std.testing.expect(resolveBySourceOwnership(&local, &remote).? == .accept_local);
}

test "resolveBySourceOwnership remote owner wins" {
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z", .is_source_owner = false };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z", .is_source_owner = true };
    try std.testing.expect(resolveBySourceOwnership(&local, &remote).? == .accept_remote);
}

test "resolveBySourceOwnership both owners indecisive" {
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z", .is_source_owner = true };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z", .is_source_owner = true };
    try std.testing.expect(resolveBySourceOwnership(&local, &remote) == null);
}

test "resolveBySourceOwnership neither owners indecisive" {
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z" };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z" };
    try std.testing.expect(resolveBySourceOwnership(&local, &remote) == null);
}

test "resolveByConfirmedAt local confirmed remote not" {
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z", .last_confirmed_at = "2026-01-02T00:00:00Z" };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z" };
    try std.testing.expect(resolveByConfirmedAt(&local, &remote).? == .accept_local);
}

test "resolveByConfirmedAt remote confirmed local not" {
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z" };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z", .last_confirmed_at = "2026-01-02T00:00:00Z" };
    try std.testing.expect(resolveByConfirmedAt(&local, &remote).? == .accept_remote);
}

test "resolveByConfirmedAt both confirmed newer wins" {
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z", .last_confirmed_at = "2026-01-03T00:00:00Z" };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z", .last_confirmed_at = "2026-01-02T00:00:00Z" };
    try std.testing.expect(resolveByConfirmedAt(&local, &remote).? == .accept_local);
}

test "resolveByConfirmedAt equal timestamps indecisive" {
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z", .last_confirmed_at = "2026-01-02T00:00:00Z" };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z", .last_confirmed_at = "2026-01-02T00:00:00Z" };
    try std.testing.expect(resolveByConfirmedAt(&local, &remote) == null);
}

test "resolveByConfirmedAt both null indecisive" {
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z" };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z" };
    try std.testing.expect(resolveByConfirmedAt(&local, &remote) == null);
}

test "resolveByConfidence higher wins" {
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z", .confidence = 0.9 };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z", .confidence = 0.7 };
    try std.testing.expect(resolveByConfidence(&local, &remote).? == .accept_local);
}

test "resolveByConfidence lower loses" {
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z", .confidence = 0.5 };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z", .confidence = 0.8 };
    try std.testing.expect(resolveByConfidence(&local, &remote).? == .accept_remote);
}

test "resolveByConfidence equal indecisive" {
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z", .confidence = 0.75 };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z", .confidence = 0.75 };
    try std.testing.expect(resolveByConfidence(&local, &remote) == null);
}

test "resolveByUpdatedAt newer wins" {
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-02T00:00:00Z" };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z" };
    try std.testing.expect(resolveByUpdatedAt(&local, &remote).? == .accept_local);
}

test "resolveByUpdatedAt older loses" {
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z" };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-02T00:00:00Z" };
    try std.testing.expect(resolveByUpdatedAt(&local, &remote).? == .accept_remote);
}

test "resolveByUpdatedAt equal indecisive" {
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z" };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z" };
    try std.testing.expect(resolveByUpdatedAt(&local, &remote) == null);
}

test "resolveTask ownership trumps timestamp" {
    // Remote is newer but local is source owner — local wins.
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z", .is_source_owner = true };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-02T00:00:00Z", .is_source_owner = false };
    try std.testing.expect(resolveTask(&local, &remote) == .accept_local);
}

test "resolveTask falls through to timestamp" {
    // Neither is owner; remote is newer.
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z" };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-02T00:00:00Z" };
    try std.testing.expect(resolveTask(&local, &remote) == .accept_remote);
}

test "resolveTask tie-break is local" {
    // Neither owner, same timestamp — local wins by tie-break.
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z" };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z" };
    try std.testing.expect(resolveTask(&local, &remote) == .accept_local);
}

test "resolveMemory confirmed_at trumps confidence" {
    // Remote has higher confidence but local was confirmed more recently.
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z", .last_confirmed_at = "2026-01-03T00:00:00Z", .confidence = 0.5 };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z", .last_confirmed_at = "2026-01-02T00:00:00Z", .confidence = 0.9 };
    try std.testing.expect(resolveMemory(&local, &remote) == .accept_local);
}

test "resolveMemory falls through to confidence" {
    // Same confirmed_at; remote has higher confidence.
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z", .last_confirmed_at = "2026-01-02T00:00:00Z", .confidence = 0.6 };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z", .last_confirmed_at = "2026-01-02T00:00:00Z", .confidence = 0.9 };
    try std.testing.expect(resolveMemory(&local, &remote) == .accept_remote);
}

test "resolveMemory falls through to updated_at" {
    // Same confirmed_at, same confidence; local is newer.
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-02T00:00:00Z", .last_confirmed_at = "2026-01-01T00:00:00Z", .confidence = 0.8 };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z", .last_confirmed_at = "2026-01-01T00:00:00Z", .confidence = 0.8 };
    try std.testing.expect(resolveMemory(&local, &remote) == .accept_local);
}

test "resolveMemory tie-break is local" {
    // Everything equal — local wins.
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z", .last_confirmed_at = "2026-01-01T00:00:00Z", .confidence = 0.8 };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z", .last_confirmed_at = "2026-01-01T00:00:00Z", .confidence = 0.8 };
    try std.testing.expect(resolveMemory(&local, &remote) == .accept_local);
}

test "resolveMemory no confirmed_at falls through" {
    // Neither has confirmed_at; higher confidence wins.
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z", .confidence = 0.3 };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z", .confidence = 0.7 };
    try std.testing.expect(resolveMemory(&local, &remote) == .accept_remote);
}

test "resolve dispatches event to accept_remote" {
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z" };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z" };
    try std.testing.expect(resolve(.event, &local, &remote) == .accept_remote);
}

test "resolve dispatches task" {
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-02T00:00:00Z" };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z" };
    try std.testing.expect(resolve(.task, &local, &remote) == .accept_local);
}

test "resolve dispatches memory" {
    const local = ConflictRecord{ .side = .local, .node_id = "m-01", .updated_at = "2026-01-01T00:00:00Z", .confidence = 0.4 };
    const remote = ConflictRecord{ .side = .remote, .node_id = "h-01", .updated_at = "2026-01-01T00:00:00Z", .confidence = 0.9 };
    try std.testing.expect(resolve(.memory, &local, &remote) == .accept_remote);
}
