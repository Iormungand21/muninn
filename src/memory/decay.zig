//! Confidence decay and recency scoring primitives for episodic/semantic memory.
//!
//! Provides decay models that reduce confidence over time, plus metadata
//! structs that capture the distinct characteristics of episodic vs semantic
//! memories. This module is computation-only — no storage or I/O.
//!
//! ## Integration TODOs
//! - Wire decayConfidence into recall/search ranking (memory backends)
//! - Apply kind-specific default params in TypedRecord construction
//! - Add decay pass to hygiene sweep (prune records below expiry threshold)
//! - Persist DecayParams per-record in SQLite schema (future migration)

const std = @import("std");
const types = @import("types.zig");
const Confidence = types.Confidence;
const MemoryKind = types.MemoryKind;

// ── Decay model ──────────────────────────────────────────────────

/// Selects the mathematical model used for confidence decay.
pub const DecayModel = enum {
    /// confidence = initial * exp(-lambda * t), lambda = ln(2) / half_life.
    /// Smooth, never reaches zero. Good default for most memories.
    exponential,
    /// confidence = initial - (rate * t), clamped to floor.
    /// Deterministic linear drain. Useful for ephemeral scratch data.
    linear,
    /// confidence stays at initial until t >= threshold, then drops to floor.
    /// Binary freshness gate. Useful for session-scoped data.
    step,

    pub fn toString(self: DecayModel) []const u8 {
        return switch (self) {
            .exponential => "exponential",
            .linear => "linear",
            .step => "step",
        };
    }

    pub fn fromString(s: []const u8) ?DecayModel {
        if (std.mem.eql(u8, s, "exponential")) return .exponential;
        if (std.mem.eql(u8, s, "linear")) return .linear;
        if (std.mem.eql(u8, s, "step")) return .step;
        return null;
    }
};

// ── Decay parameters ─────────────────────────────────────────────

/// Configuration for a decay curve. All durations are in seconds.
pub const DecayParams = struct {
    model: DecayModel = .exponential,
    /// For exponential: seconds until confidence halves.
    /// For linear: ignored (use rate instead).
    /// For step: seconds until the step triggers.
    half_life_secs: f64 = 7.0 * 24.0 * 3600.0, // 7 days default
    /// For linear: confidence units lost per second.
    /// Ignored by exponential and step models.
    linear_rate: f64 = 0.0,
    /// Minimum confidence after decay (never goes below this).
    floor: f64 = 0.0,
};

/// Suggested defaults per memory kind. Downstream consumers can override.
pub fn defaultParamsForKind(kind: MemoryKind) DecayParams {
    return switch (kind) {
        // Episodic events decay relatively fast — 3 day half-life.
        .episodic => .{
            .model = .exponential,
            .half_life_secs = 3.0 * 24.0 * 3600.0,
            .floor = 0.05,
        },
        // Semantic facts are durable — 30 day half-life with a higher floor.
        .semantic => .{
            .model = .exponential,
            .half_life_secs = 30.0 * 24.0 * 3600.0,
            .floor = 0.2,
        },
        // Procedural recipes: moderate — 14 day half-life.
        .procedural => .{
            .model = .exponential,
            .half_life_secs = 14.0 * 24.0 * 3600.0,
            .floor = 0.1,
        },
        // Raw/unclassified: aggressive linear decay.
        .raw => .{
            .model = .linear,
            .linear_rate = 1.0 / (2.0 * 24.0 * 3600.0), // ~0 in 2 days
            .floor = 0.0,
        },
    };
}

// ── Core decay computation ───────────────────────────────────────

/// Compute decayed confidence given elapsed time in seconds.
/// Returns a value in [params.floor, initial], clamped to [0, 1].
pub fn computeDecay(initial: f64, elapsed_secs: f64, params: DecayParams) f64 {
    if (elapsed_secs <= 0.0) return clampConfidence(initial);

    const raw = switch (params.model) {
        .exponential => blk: {
            if (params.half_life_secs <= 0.0) break :blk params.floor;
            const lambda = std.math.ln2 / params.half_life_secs;
            break :blk initial * @exp(-lambda * elapsed_secs);
        },
        .linear => blk: {
            break :blk initial - (params.linear_rate * elapsed_secs);
        },
        .step => blk: {
            if (elapsed_secs >= params.half_life_secs) break :blk params.floor;
            break :blk initial;
        },
    };

    return clampConfidence(@max(raw, params.floor));
}

/// Apply decay to a Confidence value, returning a new Confidence.
pub fn decayConfidence(conf: Confidence, elapsed_secs: f64, params: DecayParams) Confidence {
    return Confidence.init(computeDecay(conf.value, elapsed_secs, params));
}

// ── Recency scoring ──────────────────────────────────────────────

/// Compute a recency score in (0, 1] for ranking. More recent = higher score.
/// Uses exponential decay with the given half-life.
/// Returns 1.0 for elapsed <= 0, approaches 0 as elapsed -> infinity.
pub fn recencyScore(elapsed_secs: f64, half_life_secs: f64) f64 {
    if (elapsed_secs <= 0.0) return 1.0;
    if (half_life_secs <= 0.0) return 0.0;
    const lambda = std.math.ln2 / half_life_secs;
    return @exp(-lambda * elapsed_secs);
}

/// Convenience: compute recency from two unix timestamps (seconds).
pub fn recencyScoreFromTimestamps(created_at_unix: i64, now_unix: i64, half_life_secs: f64) f64 {
    const elapsed: f64 = @floatFromInt(@max(now_unix - created_at_unix, 0));
    return recencyScore(elapsed, half_life_secs);
}

// ── Episodic metadata ────────────────────────────────────────────

/// Extra metadata specific to episodic (event-based) memories.
/// Episodic memories represent discrete events anchored in time and context.
pub const EpisodicMeta = struct {
    /// Monotonic sequence number within a session (for ordering).
    sequence: u64 = 0,
    /// Unix timestamp of the event (seconds). Distinct from record created_at
    /// because the event may be recorded after it occurred.
    event_ts: i64 = 0,
    /// Duration of the event in seconds (0 for point-in-time events).
    duration_secs: u32 = 0,
    /// Whether this event has been consolidated into a semantic memory.
    consolidated: bool = false,
};

// ── Semantic metadata ────────────────────────────────────────────

/// Extra metadata specific to semantic (fact/rule) memories.
/// Semantic memories are distilled knowledge that can be reinforced over time.
pub const SemanticMeta = struct {
    /// How many times this fact has been independently confirmed/reinforced.
    reinforcement_count: u32 = 0,
    /// Unix timestamp of the last confirmation (seconds). 0 = never confirmed.
    last_confirmed_at: i64 = 0,
    /// Whether this was derived from consolidating episodic memories.
    derived_from_episodes: bool = false,
};

// ── Reinforcement ────────────────────────────────────────────────

/// Boost confidence when a semantic memory is reinforced (re-confirmed).
/// Each reinforcement adds a diminishing increment: boost / (1 + count).
/// Returns the new confidence value, clamped to [0, 1].
pub fn reinforceConfidence(conf: Confidence, reinforcement_count: u32, boost: f64) Confidence {
    const diminished = boost / (1.0 + @as(f64, @floatFromInt(reinforcement_count)));
    return Confidence.init(conf.value + diminished);
}

// ── Helpers ──────────────────────────────────────────────────────

fn clampConfidence(v: f64) f64 {
    return std.math.clamp(v, 0.0, 1.0);
}

// ── Tests ────────────────────────────────────────────────────────

test "DecayModel toString roundtrip" {
    const models = [_]DecayModel{ .exponential, .linear, .step };
    for (models) |model| {
        const s = model.toString();
        try std.testing.expect(DecayModel.fromString(s).? == model);
    }
    try std.testing.expect(DecayModel.fromString("bogus") == null);
}

test "computeDecay exponential halves at half-life" {
    const params = DecayParams{
        .model = .exponential,
        .half_life_secs = 100.0,
        .floor = 0.0,
    };
    const result = computeDecay(1.0, 100.0, params);
    // At exactly one half-life, should be ~0.5
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), result, 0.001);
}

test "computeDecay exponential quarters at two half-lives" {
    const params = DecayParams{
        .model = .exponential,
        .half_life_secs = 100.0,
        .floor = 0.0,
    };
    const result = computeDecay(1.0, 200.0, params);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), result, 0.001);
}

test "computeDecay exponential respects floor" {
    const params = DecayParams{
        .model = .exponential,
        .half_life_secs = 10.0,
        .floor = 0.3,
    };
    // After a very long time, should not go below floor
    const result = computeDecay(1.0, 1_000_000.0, params);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), result, 0.001);
}

test "computeDecay exponential zero half-life returns floor" {
    const params = DecayParams{
        .model = .exponential,
        .half_life_secs = 0.0,
        .floor = 0.1,
    };
    const result = computeDecay(1.0, 50.0, params);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), result, 0.001);
}

test "computeDecay linear drains to floor" {
    const params = DecayParams{
        .model = .linear,
        .linear_rate = 0.01, // lose 0.01 per second
        .floor = 0.0,
    };
    // After 50 seconds: 1.0 - 0.01*50 = 0.5
    const r1 = computeDecay(1.0, 50.0, params);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), r1, 0.001);

    // After 150 seconds: 1.0 - 0.01*150 = -0.5 -> clamped to floor 0.0
    const r2 = computeDecay(1.0, 150.0, params);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), r2, 0.001);
}

test "computeDecay linear respects floor" {
    const params = DecayParams{
        .model = .linear,
        .linear_rate = 0.1,
        .floor = 0.2,
    };
    // After 100s: 1.0 - 0.1*100 = -9.0 -> clamped to floor 0.2
    const result = computeDecay(1.0, 100.0, params);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), result, 0.001);
}

test "computeDecay step holds then drops" {
    const params = DecayParams{
        .model = .step,
        .half_life_secs = 60.0, // step threshold at 60s
        .floor = 0.0,
    };
    // Before threshold: unchanged
    const before = computeDecay(0.9, 59.0, params);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9), before, 0.001);

    // At threshold: drops to floor
    const at = computeDecay(0.9, 60.0, params);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), at, 0.001);

    // After threshold: still floor
    const after = computeDecay(0.9, 120.0, params);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), after, 0.001);
}

test "computeDecay zero elapsed returns initial" {
    const params = DecayParams{ .model = .exponential, .half_life_secs = 100.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), computeDecay(0.8, 0.0, params), 0.001);
}

test "computeDecay negative elapsed returns initial" {
    const params = DecayParams{ .model = .exponential, .half_life_secs = 100.0 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), computeDecay(0.8, -10.0, params), 0.001);
}

test "computeDecay clamps initial above 1" {
    const params = DecayParams{ .model = .exponential, .half_life_secs = 100.0 };
    // initial > 1.0 gets clamped
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), computeDecay(2.0, 0.0, params), 0.001);
}

test "decayConfidence wraps computeDecay" {
    const params = DecayParams{
        .model = .exponential,
        .half_life_secs = 100.0,
        .floor = 0.0,
    };
    const conf = Confidence.init(1.0);
    const decayed = decayConfidence(conf, 100.0, params);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), decayed.value, 0.001);
}

test "recencyScore full freshness at zero elapsed" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), recencyScore(0.0, 3600.0), 0.001);
}

test "recencyScore halves at half-life" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), recencyScore(3600.0, 3600.0), 0.001);
}

test "recencyScore zero half-life returns zero" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), recencyScore(100.0, 0.0), 0.001);
}

test "recencyScoreFromTimestamps" {
    const half_life: f64 = 3600.0;
    const now: i64 = 1_000_000;
    const created: i64 = now - 3600; // exactly one half-life ago
    const score = recencyScoreFromTimestamps(created, now, half_life);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), score, 0.001);
}

test "recencyScoreFromTimestamps future created clamps to 1" {
    const score = recencyScoreFromTimestamps(2_000_000, 1_000_000, 3600.0);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), score, 0.001);
}

test "defaultParamsForKind episodic has short half-life" {
    const p = defaultParamsForKind(.episodic);
    try std.testing.expect(p.model == .exponential);
    // 3 days in seconds
    try std.testing.expectApproxEqAbs(@as(f64, 3.0 * 24.0 * 3600.0), p.half_life_secs, 1.0);
    try std.testing.expect(p.floor > 0.0);
}

test "defaultParamsForKind semantic has long half-life" {
    const p = defaultParamsForKind(.semantic);
    try std.testing.expect(p.model == .exponential);
    // 30 days
    try std.testing.expectApproxEqAbs(@as(f64, 30.0 * 24.0 * 3600.0), p.half_life_secs, 1.0);
    // Higher floor than episodic
    try std.testing.expect(p.floor >= 0.2);
}

test "defaultParamsForKind raw uses linear" {
    const p = defaultParamsForKind(.raw);
    try std.testing.expect(p.model == .linear);
    try std.testing.expect(p.linear_rate > 0.0);
}

test "reinforceConfidence adds diminishing boost" {
    const base = Confidence.init(0.5);

    // First reinforcement (count=0): boost / 1 = 0.2
    const r1 = reinforceConfidence(base, 0, 0.2);
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), r1.value, 0.001);

    // Second reinforcement (count=1): boost / 2 = 0.1
    const r2 = reinforceConfidence(base, 1, 0.2);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), r2.value, 0.001);

    // Third reinforcement (count=2): boost / 3 ≈ 0.0667
    const r3 = reinforceConfidence(base, 2, 0.2);
    try std.testing.expectApproxEqAbs(@as(f64, 0.567), r3.value, 0.01);
}

test "reinforceConfidence clamps to 1.0" {
    const base = Confidence.init(0.95);
    const result = reinforceConfidence(base, 0, 0.2);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.value, 0.001);
}

test "EpisodicMeta defaults" {
    const meta = EpisodicMeta{};
    try std.testing.expectEqual(@as(u64, 0), meta.sequence);
    try std.testing.expectEqual(@as(i64, 0), meta.event_ts);
    try std.testing.expectEqual(@as(u32, 0), meta.duration_secs);
    try std.testing.expect(!meta.consolidated);
}

test "SemanticMeta defaults" {
    const meta = SemanticMeta{};
    try std.testing.expectEqual(@as(u32, 0), meta.reinforcement_count);
    try std.testing.expectEqual(@as(i64, 0), meta.last_confirmed_at);
    try std.testing.expect(!meta.derived_from_episodes);
}

test "end-to-end: episodic memory decays faster than semantic" {
    const episodic_params = defaultParamsForKind(.episodic);
    const semantic_params = defaultParamsForKind(.semantic);
    const initial = Confidence.init(1.0);
    const one_week: f64 = 7.0 * 24.0 * 3600.0;

    const episodic_after = decayConfidence(initial, one_week, episodic_params);
    const semantic_after = decayConfidence(initial, one_week, semantic_params);

    // After one week, episodic should be significantly lower than semantic
    try std.testing.expect(episodic_after.value < semantic_after.value);
    // Episodic at 7 days with 3-day half-life: ~0.2 (plus floor)
    try std.testing.expect(episodic_after.value < 0.3);
    // Semantic at 7 days with 30-day half-life: ~0.85
    try std.testing.expect(semantic_after.value > 0.8);
}
