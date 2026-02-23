//! Episodic-to-semantic memory consolidation.
//!
//! Identifies old episodic records that have not yet been consolidated,
//! clusters them by shared keys / overlapping content, and produces a
//! single semantic summary record per cluster. Source episodic records
//! are then marked as consolidated so they are not processed again.
//!
//! This is a v1 heuristic implementation — no LLM calls required.
//! Clustering uses key-prefix grouping and content overlap detection.

const std = @import("std");
const root = @import("root.zig");
const Memory = root.Memory;
const MemoryCategory = root.MemoryCategory;
const MemoryEntry = root.MemoryEntry;
const MemoryKind = root.MemoryKind;
const RetentionTier = root.RetentionTier;
const TypedRecord = root.TypedRecord;
const SqliteMemory = root.SqliteMemory;
const sqlite = root.sqlite;
const c = sqlite.c;

/// Default age threshold for consolidation candidates (7 days in seconds).
pub const DEFAULT_AGE_THRESHOLD_SECS: i64 = 7 * 24 * 60 * 60;

/// Minimum cluster size to trigger consolidation.
const MIN_CLUSTER_SIZE: usize = 2;

/// Maximum number of candidates to process per consolidation run.
const MAX_CANDIDATES: usize = 500;

/// Result of a consolidation run.
pub const ConsolidationReport = struct {
    candidates_found: u64 = 0,
    clusters_formed: u64 = 0,
    semantic_records_created: u64 = 0,
    sources_marked: u64 = 0,
};

/// A consolidation candidate: an episodic record eligible for consolidation.
pub const Candidate = struct {
    key: []const u8,
    content: []const u8,
    created_at: []const u8,
    session_id: ?[]const u8,

    pub fn deinit(self: *const Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.content);
        allocator.free(self.created_at);
        if (self.session_id) |sid| allocator.free(sid);
    }
};

/// A cluster of related episodic records to be consolidated.
pub const Cluster = struct {
    /// Shared prefix used as the cluster key.
    group_key: []const u8,
    /// Indices into the candidates array.
    member_indices: []usize,

    pub fn deinit(self: *const Cluster, allocator: std.mem.Allocator) void {
        allocator.free(self.group_key);
        allocator.free(self.member_indices);
    }
};

// ── Core API ─────────────────────────────────────────────────────

/// Find episodic records older than `age_threshold_secs` that are not
/// yet marked as consolidated. Works via the SqliteMemory backend.
///
/// Returns owned Candidate slice; caller must deinit each and free the slice.
pub fn findConsolidationCandidates(
    allocator: std.mem.Allocator,
    sqlite_mem: *SqliteMemory,
    age_threshold_secs: i64,
) ![]Candidate {
    const sql =
        "SELECT key, content, created_at, session_id FROM memories " ++
        "WHERE kind = 'episodic' " ++
        "AND created_at <= datetime('now', ?1) " ++
        "AND key NOT LIKE 'consolidated_%' " ++
        "AND content NOT LIKE '%[consolidated]%' " ++
        "ORDER BY created_at ASC " ++
        "LIMIT ?2";

    var stmt: ?*c.sqlite3_stmt = null;
    var rc = c.sqlite3_prepare_v2(sqlite_mem.db, sql, -1, &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);

    // Bind age threshold as a negative offset string, e.g. "-604800 seconds"
    var offset_buf: [32]u8 = undefined;
    const offset_str = std.fmt.bufPrint(&offset_buf, "-{d} seconds", .{@as(u64, @intCast(age_threshold_secs))}) catch return error.StepFailed;
    _ = c.sqlite3_bind_text(stmt, 1, offset_str.ptr, @intCast(offset_str.len), sqlite.SQLITE_STATIC);
    _ = c.sqlite3_bind_int(stmt, 2, @intCast(MAX_CANDIDATES));

    var candidates: std.ArrayList(Candidate) = .empty;
    errdefer {
        for (candidates.items) |*cand| cand.deinit(allocator);
        candidates.deinit(allocator);
    }

    while (true) {
        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) break;
        if (rc != c.SQLITE_ROW) return error.StepFailed;

        const key = try dupeColumnText(stmt.?, 0, allocator);
        errdefer allocator.free(key);
        const content = try dupeColumnText(stmt.?, 1, allocator);
        errdefer allocator.free(content);
        const created_at = try dupeColumnText(stmt.?, 2, allocator);
        errdefer allocator.free(created_at);
        const session_id = dupeColumnTextNullable(stmt.?, 3, allocator) catch null;

        try candidates.append(allocator, .{
            .key = key,
            .content = content,
            .created_at = created_at,
            .session_id = session_id,
        });
    }

    return candidates.toOwnedSlice(allocator);
}

/// Cluster related candidates by shared key prefix.
///
/// Grouping heuristic (v1): extract a "group key" from each candidate's
/// key by taking everything up to the last `_` separator, or the full
/// key if no separator is found. Candidates sharing the same group key
/// form a cluster. Singletons are excluded (need MIN_CLUSTER_SIZE).
///
/// Returns owned Cluster slice; caller must deinit each and free the slice.
pub fn clusterCandidates(
    allocator: std.mem.Allocator,
    candidates: []const Candidate,
) ![]Cluster {
    // Group candidate indices by their prefix (managed HashMap keeps allocator)
    var groups = std.StringHashMap(std.ArrayList(usize)).init(allocator);
    defer {
        var it = groups.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        groups.deinit();
    }

    for (candidates, 0..) |cand, i| {
        const gk = extractGroupKey(cand.key);
        const gop = try groups.getOrPut(gk);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(allocator, i);
    }

    // Collect clusters that meet minimum size
    var clusters: std.ArrayList(Cluster) = .empty;
    errdefer {
        for (clusters.items) |*cl| cl.deinit(allocator);
        clusters.deinit(allocator);
    }

    var it = groups.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.items.len < MIN_CLUSTER_SIZE) continue;

        const group_key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(group_key);
        const member_indices = try entry.value_ptr.toOwnedSlice(allocator);

        try clusters.append(allocator, .{
            .group_key = group_key,
            .member_indices = member_indices,
        });
    }

    return clusters.toOwnedSlice(allocator);
}

/// Produce a semantic summary record from a cluster of episodic records.
/// Returns the content string for the new semantic memory.
///
/// v1 heuristic: concatenate unique content lines, prefix with cluster key.
pub fn consolidateCluster(
    allocator: std.mem.Allocator,
    cluster: Cluster,
    candidates: []const Candidate,
) ![]const u8 {
    // Collect unique content fragments (managed HashMap keeps allocator)
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    for (cluster.member_indices) |idx| {
        if (idx >= candidates.len) continue;
        const content = std.mem.trim(u8, candidates[idx].content, " \t\n\r");
        if (content.len == 0) continue;
        const gop = try seen.getOrPut(content);
        if (!gop.found_existing) {
            try parts.append(allocator, content);
        }
    }

    // Build summary
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "[consolidated] ");
    try buf.appendSlice(allocator, cluster.group_key);
    try buf.appendSlice(allocator, ": ");

    for (parts.items, 0..) |part, i| {
        if (i > 0) try buf.appendSlice(allocator, "; ");
        try buf.appendSlice(allocator, part);
    }

    return buf.toOwnedSlice(allocator);
}

/// Mark source episodic records as consolidated by updating their content
/// to include a [consolidated] tag via direct SQL UPDATE.
pub fn markConsolidated(
    sqlite_mem: *SqliteMemory,
    candidates: []const Candidate,
    indices: []const usize,
) !u64 {
    var marked: u64 = 0;

    for (indices) |idx| {
        if (idx >= candidates.len) continue;
        const cand = candidates[idx];

        // Update content to include [consolidated] marker
        const sql = "UPDATE memories SET content = '[consolidated] ' || content, " ++
            "updated_at = datetime('now') " ++
            "WHERE key = ?1 AND kind = 'episodic'";

        var stmt: ?*c.sqlite3_stmt = null;
        var rc = c.sqlite3_prepare_v2(sqlite_mem.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) continue;
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, cand.key.ptr, @intCast(cand.key.len), sqlite.SQLITE_STATIC);

        rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) {
            if (c.sqlite3_changes(sqlite_mem.db) > 0) {
                marked += 1;
            }
        }
    }

    return marked;
}

/// Orchestrate the full consolidation pipeline:
/// find candidates → cluster → consolidate each cluster → mark sources.
pub fn runConsolidation(
    allocator: std.mem.Allocator,
    sqlite_mem: *SqliteMemory,
    age_threshold_secs: i64,
) ConsolidationReport {
    var report = ConsolidationReport{};

    // 1. Find candidates
    const candidates = findConsolidationCandidates(allocator, sqlite_mem, age_threshold_secs) catch return report;
    defer {
        for (candidates) |*cand| cand.deinit(allocator);
        allocator.free(candidates);
    }
    report.candidates_found = @intCast(candidates.len);
    if (candidates.len == 0) return report;

    // 2. Cluster candidates
    const clusters = clusterCandidates(allocator, candidates) catch return report;
    defer {
        for (clusters) |*cl| cl.deinit(allocator);
        allocator.free(clusters);
    }
    report.clusters_formed = @intCast(clusters.len);

    // 3. For each cluster: produce semantic summary and store it
    for (clusters) |cluster| {
        const summary = consolidateCluster(allocator, cluster, candidates) catch continue;
        defer allocator.free(summary);

        // Store the semantic summary via storeTyped
        const semantic_key_buf = std.fmt.allocPrint(
            allocator,
            "consolidated_{s}_{d}",
            .{ cluster.group_key, std.time.timestamp() },
        ) catch continue;
        defer allocator.free(semantic_key_buf);

        sqlite_mem.storeTyped(
            semantic_key_buf,
            summary,
            .core,
            null, // no session
            .semantic,
            .long_term,
            null, // source_channel
            null, // source_author
            0.8, // initial confidence for consolidated memory
        ) catch continue;
        report.semantic_records_created += 1;

        // 4. Mark source records as consolidated
        report.sources_marked += markConsolidated(sqlite_mem, candidates, cluster.member_indices) catch 0;
    }

    return report;
}

// ── Helpers ──────────────────────────────────────────────────────

/// Extract a group key from a record key.
/// Takes everything up to the last `_` separator.
/// Example: "event_session123_001" → "event_session123"
fn extractGroupKey(key: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, key, '_')) |pos| {
        if (pos > 0) return key[0..pos];
    }
    return key;
}

/// Duplicate column text from a SQLite statement.
fn dupeColumnText(stmt: *c.sqlite3_stmt, col: c_int, allocator: std.mem.Allocator) ![]const u8 {
    const raw = c.sqlite3_column_text(stmt, col);
    if (raw == null) return try allocator.dupe(u8, "");
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    return try allocator.dupe(u8, raw[0..len]);
}

/// Duplicate column text that may be NULL.
fn dupeColumnTextNullable(stmt: *c.sqlite3_stmt, col: c_int, allocator: std.mem.Allocator) !?[]const u8 {
    const col_type = c.sqlite3_column_type(stmt, col);
    if (col_type == c.SQLITE_NULL) return null;
    const raw = c.sqlite3_column_text(stmt, col);
    if (raw == null) return null;
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    return try allocator.dupe(u8, raw[0..len]);
}

// ── Tests ────────────────────────────────────────────────────────

test "extractGroupKey splits on last underscore" {
    try std.testing.expectEqualStrings("event_session123", extractGroupKey("event_session123_001"));
    try std.testing.expectEqualStrings("event_session123", extractGroupKey("event_session123_002"));
    try std.testing.expectEqualStrings("event", extractGroupKey("event_123"));
    try std.testing.expectEqualStrings("noseparator", extractGroupKey("noseparator"));
}

test "clusterCandidates groups by prefix" {
    const allocator = std.testing.allocator;

    const candidates = [_]Candidate{
        .{ .key = "event_sess1_001", .content = "did thing A", .created_at = "2026-01-01T00:00:00Z", .session_id = null },
        .{ .key = "event_sess1_002", .content = "did thing B", .created_at = "2026-01-02T00:00:00Z", .session_id = null },
        .{ .key = "event_sess2_001", .content = "did thing C", .created_at = "2026-01-01T00:00:00Z", .session_id = null },
        .{ .key = "singleton_key", .content = "alone", .created_at = "2026-01-01T00:00:00Z", .session_id = null },
    };

    const clusters = try clusterCandidates(allocator, &candidates);
    defer {
        for (clusters) |*cl| cl.deinit(allocator);
        allocator.free(clusters);
    }

    // Should have 1 cluster (event_sess1 has 2 members; event_sess2 and singleton are singletons)
    try std.testing.expectEqual(@as(usize, 1), clusters.len);
    try std.testing.expectEqualStrings("event_sess1", clusters[0].group_key);
    try std.testing.expectEqual(@as(usize, 2), clusters[0].member_indices.len);
}

test "consolidateCluster produces summary" {
    const allocator = std.testing.allocator;

    const candidates = [_]Candidate{
        .{ .key = "event_sess1_001", .content = "did thing A", .created_at = "2026-01-01T00:00:00Z", .session_id = null },
        .{ .key = "event_sess1_002", .content = "did thing B", .created_at = "2026-01-02T00:00:00Z", .session_id = null },
    };

    const indices = [_]usize{ 0, 1 };
    const cluster = Cluster{
        .group_key = "event_sess1",
        .member_indices = @constCast(&indices),
    };

    const summary = try consolidateCluster(allocator, cluster, &candidates);
    defer allocator.free(summary);

    // Summary should contain the [consolidated] prefix and group key
    try std.testing.expect(std.mem.startsWith(u8, summary, "[consolidated] event_sess1: "));
    // Should contain both content fragments
    try std.testing.expect(std.mem.indexOf(u8, summary, "did thing A") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "did thing B") != null);
}

test "consolidateCluster deduplicates content" {
    const allocator = std.testing.allocator;

    const candidates = [_]Candidate{
        .{ .key = "event_sess1_001", .content = "same content", .created_at = "2026-01-01T00:00:00Z", .session_id = null },
        .{ .key = "event_sess1_002", .content = "same content", .created_at = "2026-01-02T00:00:00Z", .session_id = null },
        .{ .key = "event_sess1_003", .content = "different content", .created_at = "2026-01-03T00:00:00Z", .session_id = null },
    };

    const indices = [_]usize{ 0, 1, 2 };
    const cluster = Cluster{
        .group_key = "event_sess1",
        .member_indices = @constCast(&indices),
    };

    const summary = try consolidateCluster(allocator, cluster, &candidates);
    defer allocator.free(summary);

    // "same content" should appear exactly once
    const expected = "[consolidated] event_sess1: same content; different content";
    try std.testing.expectEqualStrings(expected, summary);
}

test "ConsolidationReport defaults to zero" {
    const report = ConsolidationReport{};
    try std.testing.expectEqual(@as(u64, 0), report.candidates_found);
    try std.testing.expectEqual(@as(u64, 0), report.clusters_formed);
    try std.testing.expectEqual(@as(u64, 0), report.semantic_records_created);
    try std.testing.expectEqual(@as(u64, 0), report.sources_marked);
}

test "clusterCandidates empty input" {
    const allocator = std.testing.allocator;
    const candidates = [_]Candidate{};
    const clusters = try clusterCandidates(allocator, &candidates);
    defer allocator.free(clusters);
    try std.testing.expectEqual(@as(usize, 0), clusters.len);
}

test "clusterCandidates all singletons" {
    const allocator = std.testing.allocator;
    const candidates = [_]Candidate{
        .{ .key = "alpha", .content = "a", .created_at = "2026-01-01T00:00:00Z", .session_id = null },
        .{ .key = "beta", .content = "b", .created_at = "2026-01-01T00:00:00Z", .session_id = null },
        .{ .key = "gamma", .content = "c", .created_at = "2026-01-01T00:00:00Z", .session_id = null },
    };
    const clusters = try clusterCandidates(allocator, &candidates);
    defer allocator.free(clusters);
    // No underscores → each key is its own group → all singletons → no clusters
    try std.testing.expectEqual(@as(usize, 0), clusters.len);
}

test "findConsolidationCandidates with SQLite backend" {
    // Integration test: create an in-memory SQLite, insert episodic records, find candidates
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    // Insert some episodic records with old timestamps
    try mem.storeTyped("event_sess1_001", "thing A", .core, "sess1", .episodic, .short_term, null, null, 1.0);
    try mem.storeTyped("event_sess1_002", "thing B", .core, "sess1", .episodic, .short_term, null, null, 1.0);
    try mem.storeTyped("semantic_fact", "a fact", .core, null, .semantic, .long_term, null, null, 1.0);

    // With age threshold of 0 (all episodic records are candidates)
    const candidates = try findConsolidationCandidates(std.testing.allocator, &mem, 0);
    defer {
        for (candidates) |*cand| cand.deinit(std.testing.allocator);
        std.testing.allocator.free(candidates);
    }

    // Should find the 2 episodic records, not the semantic one
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
}

test "markConsolidated updates records" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    try mem.storeTyped("event_sess1_001", "thing A", .core, null, .episodic, .short_term, null, null, 1.0);
    try mem.storeTyped("event_sess1_002", "thing B", .core, null, .episodic, .short_term, null, null, 1.0);

    const candidates = [_]Candidate{
        .{ .key = "event_sess1_001", .content = "thing A", .created_at = "2026-01-01T00:00:00Z", .session_id = null },
        .{ .key = "event_sess1_002", .content = "thing B", .created_at = "2026-01-01T00:00:00Z", .session_id = null },
    };
    const indices = [_]usize{ 0, 1 };

    const marked = try markConsolidated(&mem, &candidates, &indices);
    try std.testing.expectEqual(@as(u64, 2), marked);

    // Verify content was updated
    const rec = (try mem.getTyped(std.testing.allocator, "event_sess1_001")).?;
    defer rec.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, rec.content, "[consolidated]"));
}

test "runConsolidation end-to-end" {
    var mem = try SqliteMemory.init(std.testing.allocator, ":memory:");
    defer mem.deinit();

    // Insert episodic records that share a prefix
    try mem.storeTyped("event_sess1_001", "observed A", .core, "sess1", .episodic, .short_term, null, null, 1.0);
    try mem.storeTyped("event_sess1_002", "observed B", .core, "sess1", .episodic, .short_term, null, null, 1.0);
    // Insert a non-episodic record (should be ignored)
    try mem.storeTyped("fact_important", "important fact", .core, null, .semantic, .long_term, null, null, 1.0);

    // Run consolidation with age_threshold=0 so all episodic records qualify
    const report = runConsolidation(std.testing.allocator, &mem, 0);

    try std.testing.expectEqual(@as(u64, 2), report.candidates_found);
    try std.testing.expectEqual(@as(u64, 1), report.clusters_formed);
    try std.testing.expectEqual(@as(u64, 1), report.semantic_records_created);
    try std.testing.expectEqual(@as(u64, 2), report.sources_marked);
}
