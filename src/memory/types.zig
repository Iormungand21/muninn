//! Typed memory record schema and metadata primitives.
//!
//! Provides a richer type system on top of the existing MemoryEntry,
//! enabling future tasks (episodic/semantic split, confidence decay,
//! SQLite migration) to work with well-defined record kinds and tiers.
//! This module is schema-only — no storage logic or migrations.
//!
//! ## Integration TODOs (S2-MEM-001)
//! - Add EpisodicMeta / SemanticMeta fields to TypedRecord (requires migration)
//! - Populate decay params from MemoryKind via decay.defaultParamsForKind()
//! - Apply decayConfidence() during recall/search ranking in backends
//! - Wire reinforceConfidence() into memory_store when updating semantic facts
//! - Add consolidated flag tracking for episodic -> semantic consolidation

const std = @import("std");

// ── Memory kind ────────────────────────────────────────────────────
// Classifies what a memory record represents.

pub const MemoryKind = enum {
    /// A discrete event with a timestamp (e.g. conversation turn, tool call).
    episodic,
    /// A distilled fact or rule (e.g. "user prefers dark mode").
    semantic,
    /// A procedural how-to or skill recipe.
    procedural,
    /// Raw ingested data not yet classified.
    raw,

    pub fn toString(self: MemoryKind) []const u8 {
        return switch (self) {
            .episodic => "episodic",
            .semantic => "semantic",
            .procedural => "procedural",
            .raw => "raw",
        };
    }

    pub fn fromString(s: []const u8) ?MemoryKind {
        if (std.mem.eql(u8, s, "episodic")) return .episodic;
        if (std.mem.eql(u8, s, "semantic")) return .semantic;
        if (std.mem.eql(u8, s, "procedural")) return .procedural;
        if (std.mem.eql(u8, s, "raw")) return .raw;
        return null;
    }
};

// ── Retention tier ─────────────────────────────────────────────────
// Controls how aggressively a record is kept or pruned.

pub const RetentionTier = enum {
    /// Pinned by user or system — never auto-pruned.
    pinned,
    /// Important context — long TTL, decays slowly.
    long_term,
    /// Session-scoped or recent — moderate TTL.
    short_term,
    /// Ephemeral scratch data — pruned first.
    ephemeral,

    pub fn toString(self: RetentionTier) []const u8 {
        return switch (self) {
            .pinned => "pinned",
            .long_term => "long_term",
            .short_term => "short_term",
            .ephemeral => "ephemeral",
        };
    }

    pub fn fromString(s: []const u8) ?RetentionTier {
        if (std.mem.eql(u8, s, "pinned")) return .pinned;
        if (std.mem.eql(u8, s, "long_term")) return .long_term;
        if (std.mem.eql(u8, s, "short_term")) return .short_term;
        if (std.mem.eql(u8, s, "ephemeral")) return .ephemeral;
        return null;
    }
};

// ── Source metadata ────────────────────────────────────────────────
// Tracks where a memory record originated.

pub const SourceMeta = struct {
    /// Originating channel (e.g. "telegram", "slack", "cli").
    channel: ?[]const u8 = null,
    /// Identifier of the user or agent that produced the record.
    author: ?[]const u8 = null,
    /// Tool or skill that generated this record (e.g. "web_search").
    tool: ?[]const u8 = null,
    /// Conversation or session that produced this record.
    session_id: ?[]const u8 = null,
    /// Free-form provenance tag (e.g. commit hash, URL).
    ref: ?[]const u8 = null,
};

// ── Confidence ─────────────────────────────────────────────────────

/// Confidence score in [0.0, 1.0]. Used for decay and relevance ranking.
pub const Confidence = struct {
    value: f64 = 1.0,

    pub fn init(v: f64) Confidence {
        return .{ .value = std.math.clamp(v, 0.0, 1.0) };
    }

    /// Returns true when confidence has decayed below the usable threshold.
    pub fn isExpired(self: Confidence, threshold: f64) bool {
        return self.value < threshold;
    }
};

// ── Typed memory record ────────────────────────────────────────────
// Enriched record that wraps the existing MemoryEntry fields with
// kind, tier, source, and confidence metadata.

pub const TypedRecord = struct {
    /// Unique identifier (same semantics as MemoryEntry.id).
    id: []const u8,
    /// Lookup key (same semantics as MemoryEntry.key).
    key: []const u8,
    /// The stored content payload.
    content: []const u8,
    /// What this record represents.
    kind: MemoryKind = .raw,
    /// How long this record should be retained.
    tier: RetentionTier = .short_term,
    /// Where this record came from.
    source: SourceMeta = .{},
    /// Current confidence level.
    confidence: Confidence = .{},
    /// ISO-8601 creation timestamp.
    created_at: []const u8,
    /// ISO-8601 last-updated timestamp.
    updated_at: []const u8,

    /// Free all allocator-owned strings. Caller must ensure the allocator
    /// matches the one used to create the slices.
    pub fn deinit(self: *const TypedRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.key);
        allocator.free(self.content);
        allocator.free(self.created_at);
        allocator.free(self.updated_at);
        if (self.source.channel) |v| allocator.free(v);
        if (self.source.author) |v| allocator.free(v);
        if (self.source.tool) |v| allocator.free(v);
        if (self.source.session_id) |v| allocator.free(v);
        if (self.source.ref) |v| allocator.free(v);
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "MemoryKind toString roundtrip" {
    const kinds = [_]MemoryKind{ .episodic, .semantic, .procedural, .raw };
    for (kinds) |kind| {
        const s = kind.toString();
        try std.testing.expect(MemoryKind.fromString(s).? == kind);
    }
    try std.testing.expect(MemoryKind.fromString("bogus") == null);
}

test "RetentionTier toString roundtrip" {
    const tiers = [_]RetentionTier{ .pinned, .long_term, .short_term, .ephemeral };
    for (tiers) |tier| {
        const s = tier.toString();
        try std.testing.expect(RetentionTier.fromString(s).? == tier);
    }
    try std.testing.expect(RetentionTier.fromString("bogus") == null);
}

test "Confidence clamps to [0,1]" {
    const low = Confidence.init(-0.5);
    try std.testing.expectEqual(@as(f64, 0.0), low.value);

    const high = Confidence.init(2.0);
    try std.testing.expectEqual(@as(f64, 1.0), high.value);

    const mid = Confidence.init(0.75);
    try std.testing.expectEqual(@as(f64, 0.75), mid.value);
}

test "Confidence isExpired" {
    const c = Confidence.init(0.3);
    try std.testing.expect(c.isExpired(0.5));
    try std.testing.expect(!c.isExpired(0.2));
}

test "TypedRecord default fields" {
    const rec = TypedRecord{
        .id = "id-1",
        .key = "k",
        .content = "hello",
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    };
    try std.testing.expect(rec.kind == .raw);
    try std.testing.expect(rec.tier == .short_term);
    try std.testing.expectEqual(@as(f64, 1.0), rec.confidence.value);
    try std.testing.expect(rec.source.channel == null);
}

test "SourceMeta fields" {
    const meta = SourceMeta{
        .channel = "telegram",
        .author = "user-42",
        .tool = "web_search",
        .session_id = "sess-abc",
        .ref = "https://example.com",
    };
    try std.testing.expectEqualStrings("telegram", meta.channel.?);
    try std.testing.expectEqualStrings("user-42", meta.author.?);
    try std.testing.expectEqualStrings("web_search", meta.tool.?);
}
