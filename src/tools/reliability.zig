//! Tool reliability wrapper — retries, timeouts, and health tracking.
//!
//! Provides a `ToolPolicy` configuration (max retries, timeout, backoff),
//! a `ToolHealth` state tracker (consecutive failures, circuit-breaker state),
//! and a `reliableExecute` wrapper that applies the policy to any `Tool.execute` call.
//!
//! Designed for incremental adoption: individual tools opt-in by attaching a
//! policy and health tracker, then routing calls through `reliableExecute`.
//! Tools without a policy continue to work unchanged.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const JsonValue = root.JsonValue;

// ── Policy ─────────────────────────────────────────────────────────
// Per-tool reliability configuration. Immutable once created.

pub const ToolPolicy = struct {
    /// Maximum number of retry attempts after the initial call (0 = no retries).
    max_retries: u32 = 2,

    /// Timeout per individual attempt in nanoseconds.
    /// null means no timeout (use the tool's own default).
    timeout_ns: ?u64 = 30 * std.time.ns_per_s,

    /// Base delay between retries in nanoseconds (doubles on each retry).
    backoff_base_ns: u64 = 500 * std.time.ns_per_ms,

    /// Maximum backoff cap in nanoseconds.
    backoff_max_ns: u64 = 10 * std.time.ns_per_s,

    /// Number of consecutive failures before the tool is considered unhealthy
    /// (circuit-breaker trips to `.open`).
    failure_threshold: u32 = 5,

    /// How long to stay in `.open` state before allowing a probe (half-open),
    /// in nanoseconds.
    recovery_window_ns: u64 = 60 * std.time.ns_per_s,

    /// A policy that disables retries and circuit-breaking.
    /// Useful as a default for tools that haven't opted in.
    pub const none: ToolPolicy = .{
        .max_retries = 0,
        .timeout_ns = null,
        .backoff_base_ns = 0,
        .backoff_max_ns = 0,
        .failure_threshold = 0,
        .recovery_window_ns = 0,
    };

    /// Compute backoff delay for a given attempt (0-indexed).
    /// Uses exponential backoff clamped to `backoff_max_ns`.
    pub fn backoffFor(self: ToolPolicy, attempt: u32) u64 {
        if (self.backoff_base_ns == 0) return 0;
        const shift: u6 = @intCast(@min(attempt, 30));
        const delay = self.backoff_base_ns *| (@as(u64, 1) << shift);
        return @min(delay, self.backoff_max_ns);
    }
};

// ── Health state ───────────────────────────────────────────────────
// Mutable per-tool health tracker. Lives alongside the tool instance.

pub const CircuitState = enum {
    /// Normal operation — requests flow through.
    closed,
    /// Too many failures — requests are rejected immediately.
    open,
    /// Probing — one request is allowed through to test recovery.
    half_open,

    pub fn toString(self: CircuitState) []const u8 {
        return switch (self) {
            .closed => "closed",
            .open => "open",
            .half_open => "half_open",
        };
    }
};

pub const ToolHealth = struct {
    /// Current circuit-breaker state.
    state: CircuitState = .closed,

    /// Count of consecutive failures (resets on success).
    consecutive_failures: u32 = 0,

    /// Total successes since creation (monotonic counter).
    total_successes: u64 = 0,

    /// Total failures since creation (monotonic counter).
    total_failures: u64 = 0,

    /// Timestamp (ns, from nanoTimestamp) when the circuit opened.
    /// Used to decide when to transition to half_open.
    opened_at_ns: ?i128 = null,

    /// Record a successful call. Resets failure count, closes circuit.
    pub fn recordSuccess(self: *ToolHealth) void {
        self.consecutive_failures = 0;
        self.total_successes += 1;
        self.state = .closed;
        self.opened_at_ns = null;
    }

    /// Record a failed call. Increments counters and may trip the circuit.
    pub fn recordFailure(self: *ToolHealth, policy: ToolPolicy) void {
        self.consecutive_failures += 1;
        self.total_failures += 1;

        if (policy.failure_threshold > 0 and
            self.consecutive_failures >= policy.failure_threshold and
            self.state == .closed)
        {
            self.state = .open;
            self.opened_at_ns = std.time.nanoTimestamp();
        }
    }

    /// Check whether a request should be allowed through.
    /// Returns true if allowed, false if the circuit is open and
    /// the recovery window has not elapsed.
    pub fn allowRequest(self: *ToolHealth, policy: ToolPolicy) bool {
        switch (self.state) {
            .closed => return true,
            .half_open => return true, // one probe allowed
            .open => {
                if (policy.recovery_window_ns == 0) return false;
                const opened = self.opened_at_ns orelse return true;
                const now = std.time.nanoTimestamp();
                if (now - opened >= @as(i128, @intCast(policy.recovery_window_ns))) {
                    self.state = .half_open;
                    return true;
                }
                return false;
            },
        }
    }

    /// Returns true when the circuit is fully healthy (closed, no recent failures).
    pub fn isHealthy(self: *const ToolHealth) bool {
        return self.state == .closed and self.consecutive_failures == 0;
    }
};

// ── Reliable execute wrapper ───────────────────────────────────────
// Applies policy (retries + circuit-breaker) around a Tool.execute call.

/// Execute a tool call with reliability wrapping.
///
/// - Checks circuit-breaker state before calling.
/// - Retries on failure up to `policy.max_retries` times with exponential backoff.
/// - Updates `health` on success/failure.
///
/// Returns the `ToolResult` from the first successful attempt, or the
/// last failure result if all attempts are exhausted or the circuit is open.
pub fn reliableExecute(
    tool: Tool,
    allocator: std.mem.Allocator,
    args: JsonObjectMap,
    policy: ToolPolicy,
    health: *ToolHealth,
) !ToolResult {
    // Circuit-breaker check
    if (!health.allowRequest(policy)) {
        return ToolResult.fail("tool circuit open — too many consecutive failures");
    }

    var last_result: ToolResult = ToolResult.fail("no attempts made");
    const total_attempts: u32 = 1 + policy.max_retries;

    for (0..total_attempts) |attempt_idx| {
        const attempt: u32 = @intCast(attempt_idx);

        // Backoff sleep between retries (not before first attempt)
        if (attempt > 0) {
            const delay = policy.backoffFor(attempt - 1);
            if (delay > 0) {
                std.Thread.sleep(delay);
            }
        }

        // Execute the underlying tool
        const result = tool.execute(allocator, args) catch |err| {
            health.recordFailure(policy);
            last_result = ToolResult.fail(@errorName(err));
            continue;
        };

        if (result.success) {
            health.recordSuccess();
            return result;
        }

        // Tool returned a failure result (not an error)
        health.recordFailure(policy);
        last_result = result;
    }

    return last_result;
}

/// Generate a Tool.VTable that dispatches `execute` to a named inner function.
///
/// Tools that wrap their core logic with `reliableExecute` need two vtables:
/// - The outer vtable (from `ToolVTable`) routes through the reliability wrapper.
/// - This inner vtable routes directly to the core logic, avoiding recursion.
///
/// Usage:
///   const inner_vtable = reliability.InnerVTable(@This(), @This().executeInner);
pub fn InnerVTable(comptime T: type, comptime innerFn: anytype) Tool.VTable {
    return .{
        .execute = &struct {
            fn f(ptr: *anyopaque, allocator: std.mem.Allocator, args: JsonObjectMap) anyerror!ToolResult {
                const self: *T = @ptrCast(@alignCast(ptr));
                return innerFn(self, allocator, args);
            }
        }.f,
        .name = &struct {
            fn f(_: *anyopaque) []const u8 {
                return T.tool_name;
            }
        }.f,
        .description = &struct {
            fn f(_: *anyopaque) []const u8 {
                return T.tool_description;
            }
        }.f,
        .parameters_json = &struct {
            fn f(_: *anyopaque) []const u8 {
                return T.tool_params;
            }
        }.f,
    };
}

// ── Cache types ───────────────────────────────────────────────────
// Tool result caching with TTL. Allows tools to skip redundant work
// when the same call is repeated within a short window.

/// Hash type used for cache key fingerprinting.
pub const CacheHash = u64;

/// A cache key uniquely identifies a tool invocation by tool name + args hash.
pub const CacheKey = struct {
    /// Tool name (borrowed, must outlive the cache entry).
    tool_name: []const u8,
    /// FNV-1a hash of the serialised argument map.
    args_hash: CacheHash,

    pub fn eql(a: CacheKey, b: CacheKey) bool {
        return a.args_hash == b.args_hash and std.mem.eql(u8, a.tool_name, b.tool_name);
    }

    /// Build a cache key from a tool name and a JSON argument map.
    /// Uses FNV-1a over sorted key=value pairs for determinism.
    pub fn fromArgs(tool_name: []const u8, args: JsonObjectMap) CacheKey {
        return .{
            .tool_name = tool_name,
            .args_hash = hashArgs(args),
        };
    }
};

/// FNV-1a hash of a JSON ObjectMap for cache keying.
/// Keys are iterated in map order (deterministic for same insertion order).
/// For robustness, hashes each key and value as length-prefixed bytes.
fn hashArgs(args: JsonObjectMap) CacheHash {
    var h: u64 = 0xcbf29ce484222325; // FNV offset basis
    for (args.keys()) |key| {
        h = fnvMix(h, key);
    }
    for (args.values()) |val| {
        h = fnvMixValue(h, val);
    }
    return h;
}

fn fnvMix(h: u64, bytes: []const u8) u64 {
    var state = h;
    // Mix in length prefix to avoid collisions between "ab","c" and "a","bc"
    for (std.mem.asBytes(&@as(u64, bytes.len))) |b| {
        state ^= b;
        state *%= 0x100000001b3; // FNV prime
    }
    for (bytes) |b| {
        state ^= b;
        state *%= 0x100000001b3;
    }
    return state;
}

fn fnvMixValue(h: u64, val: JsonValue) u64 {
    return switch (val) {
        .string => |s| fnvMix(h, s),
        .integer => |i| fnvMix(h, std.mem.asBytes(&i)),
        .bool => |b| fnvMix(h, if (b) "T" else "F"),
        .null => fnvMix(h, "null"),
        .float => |f| fnvMix(h, std.mem.asBytes(&f)),
        .array => |arr| blk: {
            var state = h;
            for (arr.items) |item| {
                state = fnvMixValue(state, item);
            }
            break :blk state;
        },
        .object => |obj| blk: {
            var state = h;
            for (obj.keys(), obj.values()) |k, v| {
                state = fnvMix(state, k);
                state = fnvMixValue(state, v);
            }
            break :blk state;
        },
        .number_string => |s| fnvMix(h, s),
    };
}

/// A cached tool result with creation timestamp and TTL.
pub const CacheEntry = struct {
    /// The cached result.
    result: ToolResult,
    /// Timestamp (ns since epoch, from nanoTimestamp) when the entry was created.
    created_at_ns: i128,
    /// Time-to-live in nanoseconds. After this, the entry is stale.
    ttl_ns: u64,

    /// Returns true if the entry is still valid (not expired).
    pub fn isValid(self: *const CacheEntry) bool {
        return self.isValidAt(std.time.nanoTimestamp());
    }

    /// Returns true if the entry would be valid at the given timestamp.
    pub fn isValidAt(self: *const CacheEntry, now_ns: i128) bool {
        const age = now_ns - self.created_at_ns;
        return age >= 0 and age < @as(i128, @intCast(self.ttl_ns));
    }
};

/// Per-tool cache policy configuration.
pub const CachePolicy = struct {
    /// Whether caching is enabled for this tool.
    enabled: bool = false,
    /// Default TTL for cache entries in nanoseconds.
    default_ttl_ns: u64 = 30 * std.time.ns_per_s,
    /// Maximum number of entries to retain per tool.
    max_entries: u32 = 64,

    /// A policy that disables caching entirely.
    pub const none: CachePolicy = .{
        .enabled = false,
        .default_ttl_ns = 0,
        .max_entries = 0,
    };
};

/// Bounded tool result cache using a HashMap.
/// Stores CacheEntry values keyed by CacheKey.
/// When max_entries is reached, the oldest entry is evicted.
pub const ToolCache = struct {
    const EntryMapContext = struct {
        pub fn hash(_: @This(), key: CacheKey) u64 {
            // Combine tool_name hash with args_hash
            var h: u64 = key.args_hash;
            for (key.tool_name) |b| {
                h ^= b;
                h *%= 0x100000001b3;
            }
            return h;
        }

        pub fn eql(_: @This(), a: CacheKey, b: CacheKey) bool {
            return CacheKey.eql(a, b);
        }
    };

    const EntryMap = std.HashMap(CacheKey, CacheEntry, EntryMapContext, 80);
    const InsertionList = std.ArrayListUnmanaged(CacheKey);

    /// Stored entries keyed by (tool_name, args_hash).
    entries: EntryMap,
    /// Insertion-order tracking for LRU eviction (oldest index).
    insertion_order: InsertionList,
    /// Allocator used for internal storage.
    allocator: std.mem.Allocator,
    /// Cache policy (TTL, max entries).
    policy: CachePolicy,
    /// Cache hit counter (monotonic).
    hits: u64 = 0,
    /// Cache miss counter (monotonic).
    misses: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, policy: CachePolicy) ToolCache {
        return .{
            .entries = EntryMap.init(allocator),
            .insertion_order = .{},
            .allocator = allocator,
            .policy = policy,
        };
    }

    pub fn deinit(self: *ToolCache) void {
        self.entries.deinit();
        self.insertion_order.deinit(self.allocator);
    }

    /// Look up a cache entry. Returns null if not found or expired.
    pub fn get(self: *ToolCache, key: CacheKey) ?ToolResult {
        return self.getAt(key, std.time.nanoTimestamp());
    }

    /// Look up a cache entry at a given timestamp. Returns null if not found or expired.
    pub fn getAt(self: *ToolCache, key: CacheKey, now_ns: i128) ?ToolResult {
        const entry = self.entries.get(key) orelse {
            self.misses += 1;
            return null;
        };
        if (!entry.isValidAt(now_ns)) {
            self.misses += 1;
            return null;
        }
        self.hits += 1;
        return entry.result;
    }

    /// Store a result in the cache. Evicts the oldest entry if at capacity.
    pub fn put(self: *ToolCache, key: CacheKey, result: ToolResult) void {
        self.putAt(key, result, std.time.nanoTimestamp());
    }

    /// Store a result in the cache at a given timestamp.
    pub fn putAt(self: *ToolCache, key: CacheKey, result: ToolResult, now_ns: i128) void {
        if (!self.policy.enabled) return;

        // Evict oldest if at capacity (and not updating an existing key)
        if (self.entries.get(key) == null and
            self.policy.max_entries > 0 and
            self.entries.count() >= self.policy.max_entries)
        {
            self.evictOldest();
        }

        self.entries.put(key, .{
            .result = result,
            .created_at_ns = now_ns,
            .ttl_ns = self.policy.default_ttl_ns,
        }) catch return; // silently fail on OOM — cache is best-effort
        self.insertion_order.append(self.allocator, key) catch return;
    }

    /// Remove all entries from the cache and reset counters.
    pub fn clear(self: *ToolCache) void {
        self.entries.clearRetainingCapacity();
        self.insertion_order.clearRetainingCapacity();
    }

    /// Remove all entries and free backing memory.
    pub fn clearAndFree(self: *ToolCache) void {
        self.entries.clearAndFree();
        self.insertion_order.clearAndFree(self.allocator);
    }

    /// Number of entries currently stored.
    pub fn count(self: *const ToolCache) u32 {
        return @intCast(self.entries.count());
    }

    /// Cache hit rate as a fraction [0.0, 1.0]. Returns 0.0 if no lookups.
    pub fn hitRate(self: *const ToolCache) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }

    fn evictOldest(self: *ToolCache) void {
        while (self.insertion_order.items.len > 0) {
            const oldest_key = self.insertion_order.orderedRemove(0);
            // Only evict if still in map (might have been overwritten)
            if (self.entries.get(oldest_key) != null) {
                _ = self.entries.remove(oldest_key);
                return;
            }
        }
    }
};

// ── Combined decision helpers ─────────────────────────────────────

/// Check whether a cached result is available and the circuit is healthy.
/// Returns the cached result if valid, null otherwise.
/// Caller should fall through to live execution on null.
pub fn cachedOrAllow(
    cache: *ToolCache,
    health: *ToolHealth,
    policy: ToolPolicy,
    key: CacheKey,
) ?ToolResult {
    // Try cache first
    if (cache.get(key)) |result| {
        return result;
    }
    // No cache hit — check circuit
    if (!health.allowRequest(policy)) {
        return ToolResult.fail("tool circuit open — cached miss, live call blocked");
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────

test "ToolPolicy.none disables retries" {
    const p = ToolPolicy.none;
    try std.testing.expectEqual(@as(u32, 0), p.max_retries);
    try std.testing.expect(p.timeout_ns == null);
    try std.testing.expectEqual(@as(u64, 0), p.backoff_base_ns);
}

test "ToolPolicy backoffFor exponential clamped" {
    const p = ToolPolicy{
        .backoff_base_ns = 1000,
        .backoff_max_ns = 10000,
    };
    // attempt 0: 1000 * 2^0 = 1000
    try std.testing.expectEqual(@as(u64, 1000), p.backoffFor(0));
    // attempt 1: 1000 * 2^1 = 2000
    try std.testing.expectEqual(@as(u64, 2000), p.backoffFor(1));
    // attempt 2: 1000 * 2^2 = 4000
    try std.testing.expectEqual(@as(u64, 4000), p.backoffFor(2));
    // attempt 4: 1000 * 2^4 = 16000 -> clamped to 10000
    try std.testing.expectEqual(@as(u64, 10000), p.backoffFor(4));
}

test "ToolPolicy backoffFor zero base returns zero" {
    const p = ToolPolicy{ .backoff_base_ns = 0 };
    try std.testing.expectEqual(@as(u64, 0), p.backoffFor(5));
}

test "CircuitState toString" {
    try std.testing.expectEqualStrings("closed", CircuitState.closed.toString());
    try std.testing.expectEqualStrings("open", CircuitState.open.toString());
    try std.testing.expectEqualStrings("half_open", CircuitState.half_open.toString());
}

test "ToolHealth starts healthy" {
    const h = ToolHealth{};
    try std.testing.expect(h.isHealthy());
    try std.testing.expectEqual(@as(u32, 0), h.consecutive_failures);
    try std.testing.expectEqual(@as(u64, 0), h.total_successes);
    try std.testing.expectEqual(@as(u64, 0), h.total_failures);
}

test "ToolHealth recordSuccess resets failures" {
    var h = ToolHealth{ .consecutive_failures = 3, .state = .half_open };
    h.recordSuccess();
    try std.testing.expectEqual(@as(u32, 0), h.consecutive_failures);
    try std.testing.expect(h.state == .closed);
    try std.testing.expectEqual(@as(u64, 1), h.total_successes);
}

test "ToolHealth recordFailure increments counters" {
    const policy = ToolPolicy{ .failure_threshold = 5 };
    var h = ToolHealth{};
    h.recordFailure(policy);
    try std.testing.expectEqual(@as(u32, 1), h.consecutive_failures);
    try std.testing.expectEqual(@as(u64, 1), h.total_failures);
    try std.testing.expect(h.state == .closed);
}

test "ToolHealth circuit opens at threshold" {
    const policy = ToolPolicy{ .failure_threshold = 3 };
    var h = ToolHealth{};
    h.recordFailure(policy);
    h.recordFailure(policy);
    try std.testing.expect(h.state == .closed);
    h.recordFailure(policy);
    try std.testing.expect(h.state == .open);
    try std.testing.expect(h.opened_at_ns != null);
}

test "ToolHealth allowRequest closed always true" {
    const policy = ToolPolicy{};
    var h = ToolHealth{};
    try std.testing.expect(h.allowRequest(policy));
}

test "ToolHealth allowRequest open blocks" {
    const policy = ToolPolicy{ .recovery_window_ns = 60 * std.time.ns_per_s };
    var h = ToolHealth{
        .state = .open,
        .opened_at_ns = std.time.nanoTimestamp(),
    };
    try std.testing.expect(!h.allowRequest(policy));
}

test "ToolHealth allowRequest half_open allows" {
    const policy = ToolPolicy{};
    var h = ToolHealth{ .state = .half_open };
    try std.testing.expect(h.allowRequest(policy));
}

test "ToolHealth isHealthy false with failures" {
    var h = ToolHealth{ .consecutive_failures = 1 };
    try std.testing.expect(!h.isHealthy());
}

test "ToolHealth circuit opens then recovers on success" {
    const policy = ToolPolicy{ .failure_threshold = 2 };
    var h = ToolHealth{};
    h.recordFailure(policy);
    h.recordFailure(policy);
    try std.testing.expect(h.state == .open);

    // Simulate half-open transition
    h.state = .half_open;
    h.recordSuccess();
    try std.testing.expect(h.state == .closed);
    try std.testing.expect(h.isHealthy());
}

test "ToolHealth zero threshold never trips" {
    const policy = ToolPolicy{ .failure_threshold = 0 };
    var h = ToolHealth{};
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        h.recordFailure(policy);
    }
    try std.testing.expect(h.state == .closed);
    try std.testing.expectEqual(@as(u32, 100), h.consecutive_failures);
}

// ── Cache tests ───────────────────────────────────────────────────

test "CacheKey.eql matches same name and hash" {
    const a = CacheKey{ .tool_name = "shell", .args_hash = 42 };
    const b = CacheKey{ .tool_name = "shell", .args_hash = 42 };
    try std.testing.expect(a.eql(b));
}

test "CacheKey.eql differs on name" {
    const a = CacheKey{ .tool_name = "shell", .args_hash = 42 };
    const b = CacheKey{ .tool_name = "http", .args_hash = 42 };
    try std.testing.expect(!a.eql(b));
}

test "CacheKey.eql differs on hash" {
    const a = CacheKey{ .tool_name = "shell", .args_hash = 1 };
    const b = CacheKey{ .tool_name = "shell", .args_hash = 2 };
    try std.testing.expect(!a.eql(b));
}

test "CacheKey.fromArgs deterministic" {
    const parsed = try root.parseTestArgs("{\"cmd\":\"ls\"}");
    defer parsed.deinit();
    const k1 = CacheKey.fromArgs("shell", parsed.value.object);
    const k2 = CacheKey.fromArgs("shell", parsed.value.object);
    try std.testing.expect(k1.eql(k2));
}

test "CacheKey.fromArgs different args differ" {
    const p1 = try root.parseTestArgs("{\"cmd\":\"ls\"}");
    defer p1.deinit();
    const p2 = try root.parseTestArgs("{\"cmd\":\"pwd\"}");
    defer p2.deinit();
    const k1 = CacheKey.fromArgs("shell", p1.value.object);
    const k2 = CacheKey.fromArgs("shell", p2.value.object);
    try std.testing.expect(!k1.eql(k2));
}

test "CacheKey.fromArgs different tools differ" {
    const parsed = try root.parseTestArgs("{\"cmd\":\"ls\"}");
    defer parsed.deinit();
    const k1 = CacheKey.fromArgs("shell", parsed.value.object);
    const k2 = CacheKey.fromArgs("http", parsed.value.object);
    try std.testing.expect(!k1.eql(k2));
}

test "CacheEntry.isValidAt within TTL" {
    const entry = CacheEntry{
        .result = ToolResult.ok("cached"),
        .created_at_ns = 1000,
        .ttl_ns = 500,
    };
    try std.testing.expect(entry.isValidAt(1000)); // at creation
    try std.testing.expect(entry.isValidAt(1200)); // midway
    try std.testing.expect(entry.isValidAt(1499)); // just before expiry
}

test "CacheEntry.isValidAt expired" {
    const entry = CacheEntry{
        .result = ToolResult.ok("cached"),
        .created_at_ns = 1000,
        .ttl_ns = 500,
    };
    try std.testing.expect(!entry.isValidAt(1500)); // exactly at expiry
    try std.testing.expect(!entry.isValidAt(2000)); // well past
}

test "CacheEntry.isValidAt before creation" {
    const entry = CacheEntry{
        .result = ToolResult.ok("cached"),
        .created_at_ns = 1000,
        .ttl_ns = 500,
    };
    try std.testing.expect(!entry.isValidAt(500)); // before creation
}

test "CachePolicy.none disables caching" {
    const p = CachePolicy.none;
    try std.testing.expect(!p.enabled);
    try std.testing.expectEqual(@as(u64, 0), p.default_ttl_ns);
    try std.testing.expectEqual(@as(u32, 0), p.max_entries);
}

test "ToolCache put and get within TTL" {
    var cache = ToolCache.init(std.testing.allocator, .{
        .enabled = true,
        .default_ttl_ns = 1000,
        .max_entries = 4,
    });
    defer cache.deinit();

    const key = CacheKey{ .tool_name = "shell", .args_hash = 42 };
    cache.putAt(key, ToolResult.ok("hello"), 100);

    const result = cache.getAt(key, 200);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("hello", result.?.output);
    try std.testing.expectEqual(@as(u32, 1), cache.count());
}

test "ToolCache miss returns null" {
    var cache = ToolCache.init(std.testing.allocator, .{
        .enabled = true,
        .default_ttl_ns = 1000,
        .max_entries = 4,
    });
    defer cache.deinit();

    const key = CacheKey{ .tool_name = "shell", .args_hash = 99 };
    const result = cache.getAt(key, 100);
    try std.testing.expect(result == null);
}

test "ToolCache expired entry returns null" {
    var cache = ToolCache.init(std.testing.allocator, .{
        .enabled = true,
        .default_ttl_ns = 1000,
        .max_entries = 4,
    });
    defer cache.deinit();

    const key = CacheKey{ .tool_name = "shell", .args_hash = 42 };
    cache.putAt(key, ToolResult.ok("old"), 100);

    // Access well after TTL
    const result = cache.getAt(key, 1200);
    try std.testing.expect(result == null);
}

test "ToolCache evicts oldest when at capacity" {
    var cache = ToolCache.init(std.testing.allocator, .{
        .enabled = true,
        .default_ttl_ns = 10000,
        .max_entries = 2,
    });
    defer cache.deinit();

    const k1 = CacheKey{ .tool_name = "a", .args_hash = 1 };
    const k2 = CacheKey{ .tool_name = "a", .args_hash = 2 };
    const k3 = CacheKey{ .tool_name = "a", .args_hash = 3 };

    cache.putAt(k1, ToolResult.ok("first"), 100);
    cache.putAt(k2, ToolResult.ok("second"), 200);
    try std.testing.expectEqual(@as(u32, 2), cache.count());

    // This should evict k1
    cache.putAt(k3, ToolResult.ok("third"), 300);
    try std.testing.expectEqual(@as(u32, 2), cache.count());

    // k1 should be gone
    try std.testing.expect(cache.getAt(k1, 400) == null);
    // k2 and k3 should still be there
    try std.testing.expect(cache.getAt(k2, 400) != null);
    try std.testing.expect(cache.getAt(k3, 400) != null);
}

test "ToolCache disabled policy does not store" {
    var cache = ToolCache.init(std.testing.allocator, CachePolicy.none);
    defer cache.deinit();

    const key = CacheKey{ .tool_name = "shell", .args_hash = 1 };
    cache.putAt(key, ToolResult.ok("nope"), 100);
    try std.testing.expectEqual(@as(u32, 0), cache.count());
}

test "ToolCache clear removes all entries" {
    var cache = ToolCache.init(std.testing.allocator, .{
        .enabled = true,
        .default_ttl_ns = 10000,
        .max_entries = 10,
    });
    defer cache.deinit();

    cache.putAt(.{ .tool_name = "a", .args_hash = 1 }, ToolResult.ok("x"), 100);
    cache.putAt(.{ .tool_name = "a", .args_hash = 2 }, ToolResult.ok("y"), 200);
    try std.testing.expectEqual(@as(u32, 2), cache.count());

    cache.clear();
    try std.testing.expectEqual(@as(u32, 0), cache.count());
}

test "ToolCache hit rate tracking" {
    var cache = ToolCache.init(std.testing.allocator, .{
        .enabled = true,
        .default_ttl_ns = 10000,
        .max_entries = 10,
    });
    defer cache.deinit();

    // No lookups -> 0.0
    try std.testing.expectEqual(@as(f64, 0.0), cache.hitRate());

    const key = CacheKey{ .tool_name = "t", .args_hash = 1 };
    cache.putAt(key, ToolResult.ok("val"), 100);

    // 1 hit
    _ = cache.getAt(key, 200);
    try std.testing.expectEqual(@as(u64, 1), cache.hits);
    try std.testing.expectEqual(@as(u64, 0), cache.misses);

    // 1 miss
    _ = cache.getAt(.{ .tool_name = "t", .args_hash = 999 }, 200);
    try std.testing.expectEqual(@as(u64, 1), cache.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.misses);

    // Hit rate = 1/2 = 0.5
    try std.testing.expectEqual(@as(f64, 0.5), cache.hitRate());
}

test "ToolCache overwrite existing key does not evict" {
    var cache = ToolCache.init(std.testing.allocator, .{
        .enabled = true,
        .default_ttl_ns = 10000,
        .max_entries = 2,
    });
    defer cache.deinit();

    const k1 = CacheKey{ .tool_name = "a", .args_hash = 1 };
    const k2 = CacheKey{ .tool_name = "a", .args_hash = 2 };

    cache.putAt(k1, ToolResult.ok("v1"), 100);
    cache.putAt(k2, ToolResult.ok("v2"), 200);
    try std.testing.expectEqual(@as(u32, 2), cache.count());

    // Overwrite k1 — should not evict anything
    cache.putAt(k1, ToolResult.ok("v1-updated"), 300);
    try std.testing.expectEqual(@as(u32, 2), cache.count());

    // Both still accessible
    const r1 = cache.getAt(k1, 400);
    try std.testing.expect(r1 != null);
    try std.testing.expectEqualStrings("v1-updated", r1.?.output);
    try std.testing.expect(cache.getAt(k2, 400) != null);
}

test "cachedOrAllow returns cached result" {
    var cache = ToolCache.init(std.testing.allocator, .{
        .enabled = true,
        .default_ttl_ns = 60 * std.time.ns_per_s,
        .max_entries = 10,
    });
    defer cache.deinit();

    const policy = ToolPolicy{};
    var health = ToolHealth{};
    const key = CacheKey{ .tool_name = "test", .args_hash = 1 };

    // Use real timestamp so get() (which uses nanoTimestamp()) sees a valid entry
    cache.put(key, ToolResult.ok("from cache"));

    const result = cachedOrAllow(&cache, &health, policy, key);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("from cache", result.?.output);
}

test "cachedOrAllow returns null when no cache and circuit closed" {
    var cache = ToolCache.init(std.testing.allocator, .{
        .enabled = true,
        .default_ttl_ns = 10000,
        .max_entries = 10,
    });
    defer cache.deinit();

    const policy = ToolPolicy{};
    var health = ToolHealth{};
    const key = CacheKey{ .tool_name = "test", .args_hash = 1 };

    // No cache entry, circuit closed -> null (proceed with live call)
    const result = cachedOrAllow(&cache, &health, policy, key);
    try std.testing.expect(result == null);
}

test "cachedOrAllow returns error when no cache and circuit open" {
    var cache = ToolCache.init(std.testing.allocator, .{
        .enabled = true,
        .default_ttl_ns = 10000,
        .max_entries = 10,
    });
    defer cache.deinit();

    const policy = ToolPolicy{ .recovery_window_ns = 60 * std.time.ns_per_s };
    var health = ToolHealth{
        .state = .open,
        .opened_at_ns = std.time.nanoTimestamp(),
    };
    const key = CacheKey{ .tool_name = "test", .args_hash = 1 };

    const result = cachedOrAllow(&cache, &health, policy, key);
    try std.testing.expect(result != null);
    try std.testing.expect(!result.?.success); // failure result
}

test "hashArgs handles nested objects and arrays" {
    const p1 = try root.parseTestArgs("{\"a\":[1,2],\"b\":{\"x\":true}}");
    defer p1.deinit();
    const h1 = hashArgs(p1.value.object);

    // Same content should produce same hash
    const p2 = try root.parseTestArgs("{\"a\":[1,2],\"b\":{\"x\":true}}");
    defer p2.deinit();
    const h2 = hashArgs(p2.value.object);

    try std.testing.expectEqual(h1, h2);
}

test "hashArgs different values produce different hashes" {
    const p1 = try root.parseTestArgs("{\"v\":42}");
    defer p1.deinit();
    const p2 = try root.parseTestArgs("{\"v\":43}");
    defer p2.deinit();
    const h1 = hashArgs(p1.value.object);
    const h2 = hashArgs(p2.value.object);
    try std.testing.expect(h1 != h2);
}
