//! Edge-mode profile defaults for resource-constrained deployments.
//!
//! Provides lean configuration constants for running muninn on edge devices
//! (Raspberry Pi, embedded boards, low-memory VMs) where memory, disk, and
//! CPU budgets are tight. The profile tunes two key subsystems:
//!
//!   1. **Compact event logging** — Higher min_severity (warn) and a smaller
//!      serialization buffer to reduce I/O and memory pressure.
//!   2. **Bounded task queue** — Strict caps on queued and concurrent tasks
//!      to prevent unbounded memory growth.
//!
//! These are compile-time constants and pure helpers; they add zero runtime
//! overhead when not referenced.

const std = @import("std");
const events = @import("events.zig");
const events_store = @import("events_store.zig");
const config_types = @import("config_types.zig");

// ── Edge event-log defaults ────────────────────────────────────────

/// Minimum severity for edge-mode event logging.
/// Only warnings and errors are persisted to reduce I/O on constrained storage.
pub const edge_min_severity: events.EventSeverity = .warn;

/// Serialization buffer size (bytes) for edge-mode event records.
/// Smaller than the default 4096 to reduce stack usage per append.
/// Sufficient for warn/error records which rarely carry large payloads.
pub const edge_event_buffer_size: usize = 1024;

/// Maximum event log file size in bytes before rotation is advisable.
/// 1 MiB — keeps disk footprint small on SD cards and flash storage.
pub const edge_max_log_bytes: u64 = 1 * 1024 * 1024;

/// Create an EventStore pre-configured for edge-mode constraints.
pub fn edgeEventStore(path: []const u8) events_store.EventStore {
    return .{
        .path = path,
        .min_severity = edge_min_severity,
    };
}

// ── Edge task-queue defaults ───────────────────────────────────────

/// Maximum number of tasks that may exist in the queue on edge devices.
/// Low cap prevents unbounded memory growth from queued task records.
pub const edge_max_tasks: u32 = 8;

/// Maximum number of tasks executing concurrently on edge devices.
/// Single-core or dual-core boards benefit from serial execution.
pub const edge_max_concurrent: u32 = 1;

/// Create a SchedulerConfig pre-configured for edge-mode constraints.
pub fn edgeSchedulerConfig() config_types.SchedulerConfig {
    return .{
        .enabled = true,
        .max_tasks = edge_max_tasks,
        .max_concurrent = edge_max_concurrent,
    };
}

// ── Edge agent defaults ────────────────────────────────────────────

/// Reduced context window for edge devices with limited memory.
pub const edge_token_limit: u64 = 32_000;

/// Fewer tool iterations to bound execution time and API cost.
pub const edge_max_tool_iterations: u32 = 10;

/// Shorter history to reduce memory consumption.
pub const edge_max_history_messages: u32 = 20;

/// Shorter idle timeout (10 min) to free resources sooner.
pub const edge_session_idle_timeout_secs: u64 = 600;

/// Create an AgentConfig pre-configured for edge-mode constraints.
pub fn edgeAgentConfig() config_types.AgentConfig {
    return .{
        .compact_context = true,
        .max_tool_iterations = edge_max_tool_iterations,
        .max_history_messages = edge_max_history_messages,
        .token_limit = edge_token_limit,
        .session_idle_timeout_secs = edge_session_idle_timeout_secs,
    };
}

// ── Composite edge profile ─────────────────────────────────────────

/// Full edge-mode profile bundling all constrained defaults.
/// Use `EdgeProfile.apply*` helpers to selectively override individual
/// config structs, or read individual constants directly.
pub const EdgeProfile = struct {
    // Event log
    min_severity: events.EventSeverity = edge_min_severity,
    event_buffer_size: usize = edge_event_buffer_size,
    max_log_bytes: u64 = edge_max_log_bytes,

    // Task queue
    max_tasks: u32 = edge_max_tasks,
    max_concurrent: u32 = edge_max_concurrent,

    // Agent
    token_limit: u64 = edge_token_limit,
    max_tool_iterations: u32 = edge_max_tool_iterations,
    max_history_messages: u32 = edge_max_history_messages,
    session_idle_timeout_secs: u64 = edge_session_idle_timeout_secs,

    /// The singleton default edge profile.
    pub const default: EdgeProfile = .{};

    /// Apply edge task-queue caps to a SchedulerConfig.
    pub fn applyScheduler(self: *const EdgeProfile, sched: *config_types.SchedulerConfig) void {
        sched.max_tasks = self.max_tasks;
        sched.max_concurrent = self.max_concurrent;
    }

    /// Apply edge agent constraints to an AgentConfig.
    pub fn applyAgent(self: *const EdgeProfile, agent: *config_types.AgentConfig) void {
        agent.compact_context = true;
        agent.max_tool_iterations = self.max_tool_iterations;
        agent.max_history_messages = self.max_history_messages;
        agent.token_limit = self.token_limit;
        agent.session_idle_timeout_secs = self.session_idle_timeout_secs;
    }

    /// Build an EventStore using this profile's severity and the given path.
    pub fn eventStore(self: *const EdgeProfile, path: []const u8) events_store.EventStore {
        return .{
            .path = path,
            .min_severity = self.min_severity,
        };
    }

    /// Returns true when the profile's task queue is at capacity.
    pub fn isQueueFull(self: *const EdgeProfile, current_count: u32) bool {
        return current_count >= self.max_tasks;
    }

    /// Returns remaining task slots before the queue is full.
    pub fn remainingSlots(self: *const EdgeProfile, current_count: u32) u32 {
        if (current_count >= self.max_tasks) return 0;
        return self.max_tasks - current_count;
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "edge_min_severity is warn" {
    try std.testing.expect(edge_min_severity == .warn);
    try std.testing.expect(edge_min_severity.level() >= events.EventSeverity.warn.level());
}

test "edge_event_buffer_size smaller than default" {
    // Default EventStore uses 4096; edge should be smaller.
    try std.testing.expect(edge_event_buffer_size < 4096);
    // But large enough for a reasonable JSON record.
    try std.testing.expect(edge_event_buffer_size >= 512);
}

test "edge_max_log_bytes is 1 MiB" {
    try std.testing.expectEqual(@as(u64, 1_048_576), edge_max_log_bytes);
}

test "edge task queue caps" {
    try std.testing.expectEqual(@as(u32, 8), edge_max_tasks);
    try std.testing.expectEqual(@as(u32, 1), edge_max_concurrent);
    try std.testing.expect(edge_max_tasks <= 16); // strict cap
    try std.testing.expect(edge_max_concurrent <= edge_max_tasks);
}

test "edgeEventStore returns configured store" {
    const store = edgeEventStore("/tmp/edge.jsonl");
    try std.testing.expectEqualStrings("/tmp/edge.jsonl", store.path);
    try std.testing.expect(store.min_severity == .warn);
}

test "edgeSchedulerConfig returns bounded config" {
    const sched = edgeSchedulerConfig();
    try std.testing.expect(sched.enabled);
    try std.testing.expectEqual(@as(u32, 8), sched.max_tasks);
    try std.testing.expectEqual(@as(u32, 1), sched.max_concurrent);
}

test "edgeAgentConfig returns constrained config" {
    const agent = edgeAgentConfig();
    try std.testing.expect(agent.compact_context);
    try std.testing.expectEqual(@as(u32, 10), agent.max_tool_iterations);
    try std.testing.expectEqual(@as(u32, 20), agent.max_history_messages);
    try std.testing.expectEqual(@as(u64, 32_000), agent.token_limit);
    try std.testing.expectEqual(@as(u64, 600), agent.session_idle_timeout_secs);
}

test "EdgeProfile default matches constants" {
    const p = EdgeProfile.default;
    try std.testing.expect(p.min_severity == edge_min_severity);
    try std.testing.expectEqual(edge_event_buffer_size, p.event_buffer_size);
    try std.testing.expectEqual(edge_max_log_bytes, p.max_log_bytes);
    try std.testing.expectEqual(edge_max_tasks, p.max_tasks);
    try std.testing.expectEqual(edge_max_concurrent, p.max_concurrent);
    try std.testing.expectEqual(edge_token_limit, p.token_limit);
    try std.testing.expectEqual(edge_max_tool_iterations, p.max_tool_iterations);
    try std.testing.expectEqual(edge_max_history_messages, p.max_history_messages);
    try std.testing.expectEqual(edge_session_idle_timeout_secs, p.session_idle_timeout_secs);
}

test "EdgeProfile.applyScheduler mutates config" {
    const p = EdgeProfile.default;
    var sched = config_types.SchedulerConfig{}; // normal defaults: 64/4
    try std.testing.expectEqual(@as(u32, 64), sched.max_tasks);
    try std.testing.expectEqual(@as(u32, 4), sched.max_concurrent);

    p.applyScheduler(&sched);
    try std.testing.expectEqual(@as(u32, 8), sched.max_tasks);
    try std.testing.expectEqual(@as(u32, 1), sched.max_concurrent);
}

test "EdgeProfile.applyAgent mutates config" {
    const p = EdgeProfile.default;
    var agent = config_types.AgentConfig{};
    try std.testing.expect(!agent.compact_context);
    try std.testing.expectEqual(@as(u64, 128_000), agent.token_limit);

    p.applyAgent(&agent);
    try std.testing.expect(agent.compact_context);
    try std.testing.expectEqual(@as(u64, 32_000), agent.token_limit);
    try std.testing.expectEqual(@as(u32, 10), agent.max_tool_iterations);
    try std.testing.expectEqual(@as(u32, 20), agent.max_history_messages);
    try std.testing.expectEqual(@as(u64, 600), agent.session_idle_timeout_secs);
}

test "EdgeProfile.eventStore builds correctly" {
    const p = EdgeProfile.default;
    const store = p.eventStore("/var/log/edge.jsonl");
    try std.testing.expectEqualStrings("/var/log/edge.jsonl", store.path);
    try std.testing.expect(store.min_severity == .warn);
}

test "EdgeProfile.isQueueFull boundary" {
    const p = EdgeProfile.default;
    try std.testing.expect(!p.isQueueFull(0));
    try std.testing.expect(!p.isQueueFull(7));
    try std.testing.expect(p.isQueueFull(8));
    try std.testing.expect(p.isQueueFull(100));
}

test "EdgeProfile.remainingSlots" {
    const p = EdgeProfile.default;
    try std.testing.expectEqual(@as(u32, 8), p.remainingSlots(0));
    try std.testing.expectEqual(@as(u32, 3), p.remainingSlots(5));
    try std.testing.expectEqual(@as(u32, 0), p.remainingSlots(8));
    try std.testing.expectEqual(@as(u32, 0), p.remainingSlots(10));
}

test "edge buffer can serialize a warn event" {
    // Verify edge_event_buffer_size is large enough for a realistic warn record.
    var buf: [edge_event_buffer_size]u8 = undefined;
    const record = events.EventRecord{
        .id = "edge-evt-001",
        .kind = .err,
        .severity = .warn,
        .timestamp = "2026-02-22T14:00:00Z",
        .summary = "disk nearly full",
        .source = "health",
    };
    const line = events_store.serializeEvent(&buf, &record);
    try std.testing.expect(line != null);
    try std.testing.expect(std.mem.indexOf(u8, line.?, "\"severity\":\"warn\"") != null);
}

test "edge defaults vs normal defaults comparison" {
    // Edge scheduler is strictly smaller than normal defaults.
    const normal_sched = config_types.SchedulerConfig{};
    const edge_sched = edgeSchedulerConfig();
    try std.testing.expect(edge_sched.max_tasks < normal_sched.max_tasks);
    try std.testing.expect(edge_sched.max_concurrent < normal_sched.max_concurrent);

    // Edge agent token limit is smaller than normal.
    const normal_agent = config_types.AgentConfig{};
    const edge_agent = edgeAgentConfig();
    try std.testing.expect(edge_agent.token_limit < normal_agent.token_limit);
    try std.testing.expect(edge_agent.max_tool_iterations < normal_agent.max_tool_iterations);
    try std.testing.expect(edge_agent.max_history_messages < normal_agent.max_history_messages);
}
