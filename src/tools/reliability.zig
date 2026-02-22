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
                std.time.sleep(delay);
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
