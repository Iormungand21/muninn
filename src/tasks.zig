//! Persistent task state machine primitives for long-running work.
//!
//! Provides status enums, step tracking, and a TaskRecord struct with
//! serialization-ready fields (timestamps, status, steps, retries).
//! This module is schema-only — no daemon integration or persistence logic.

const std = @import("std");

// ── Task status ────────────────────────────────────────────────────
// Represents the lifecycle state of a task.

pub const TaskStatus = enum {
    /// Task has been created but not yet started.
    pending,
    /// Task is currently being executed.
    running,
    /// Task completed successfully.
    completed,
    /// Task failed after exhausting retries.
    failed,
    /// Task was cancelled by user or system.
    cancelled,
    /// Task is waiting on an external dependency or condition.
    blocked,

    pub fn toString(self: TaskStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .running => "running",
            .completed => "completed",
            .failed => "failed",
            .cancelled => "cancelled",
            .blocked => "blocked",
        };
    }

    pub fn fromString(s: []const u8) ?TaskStatus {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "running")) return .running;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        if (std.mem.eql(u8, s, "cancelled")) return .cancelled;
        if (std.mem.eql(u8, s, "blocked")) return .blocked;
        return null;
    }

    /// Returns true for terminal states that cannot transition further.
    pub fn isTerminal(self: TaskStatus) bool {
        return switch (self) {
            .completed, .failed, .cancelled => true,
            .pending, .running, .blocked => false,
        };
    }
};

// ── Task priority ──────────────────────────────────────────────────

pub const TaskPriority = enum {
    low,
    normal,
    high,
    critical,

    pub fn toString(self: TaskPriority) []const u8 {
        return switch (self) {
            .low => "low",
            .normal => "normal",
            .high => "high",
            .critical => "critical",
        };
    }

    pub fn fromString(s: []const u8) ?TaskPriority {
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "normal")) return .normal;
        if (std.mem.eql(u8, s, "high")) return .high;
        if (std.mem.eql(u8, s, "critical")) return .critical;
        return null;
    }
};

// ── Step record ────────────────────────────────────────────────────
// Tracks individual steps within a multi-step task.

pub const StepStatus = enum {
    pending,
    running,
    completed,
    failed,
    skipped,

    pub fn toString(self: StepStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .running => "running",
            .completed => "completed",
            .failed => "failed",
            .skipped => "skipped",
        };
    }

    pub fn fromString(s: []const u8) ?StepStatus {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "running")) return .running;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        if (std.mem.eql(u8, s, "skipped")) return .skipped;
        return null;
    }
};

pub const StepRecord = struct {
    /// Step name or label.
    name: []const u8,
    /// Current status of this step.
    status: StepStatus = .pending,
    /// Number of retry attempts made for this step.
    retries: u32 = 0,
    /// Optional error message from the last failure.
    last_error: ?[]const u8 = null,
    /// ISO-8601 timestamp when this step started.
    started_at: ?[]const u8 = null,
    /// ISO-8601 timestamp when this step finished.
    finished_at: ?[]const u8 = null,
};

// ── Retry policy ───────────────────────────────────────────────────

pub const RetryPolicy = struct {
    /// Maximum number of retry attempts (0 = no retries).
    max_retries: u32 = 3,
    /// Base delay between retries in nanoseconds.
    backoff_base_ns: u64 = 1 * std.time.ns_per_s,
    /// Maximum backoff cap in nanoseconds.
    backoff_max_ns: u64 = 30 * std.time.ns_per_s,

    pub const none: RetryPolicy = .{
        .max_retries = 0,
        .backoff_base_ns = 0,
        .backoff_max_ns = 0,
    };

    /// Compute backoff delay for a given attempt (0-indexed).
    pub fn backoffFor(self: RetryPolicy, attempt: u32) u64 {
        if (self.backoff_base_ns == 0) return 0;
        const shift: u6 = @intCast(@min(attempt, 30));
        const delay = self.backoff_base_ns *| (@as(u64, 1) << shift);
        return @min(delay, self.backoff_max_ns);
    }
};

// ── Task record ────────────────────────────────────────────────────
// The main persistent record for a long-running task.

pub const TaskRecord = struct {
    /// Unique task identifier.
    id: []const u8,
    /// Human-readable task name.
    name: []const u8,
    /// Current lifecycle status.
    status: TaskStatus = .pending,
    /// Task priority level.
    priority: TaskPriority = .normal,
    /// Number of retry attempts made at the task level.
    retries: u32 = 0,
    /// Retry policy governing this task.
    retry_policy: RetryPolicy = .{},
    /// Individual steps (slice; empty for single-step tasks).
    steps: []const StepRecord = &.{},
    /// Index of the current step being executed (0-based).
    current_step: u32 = 0,
    /// Optional description or context.
    description: ?[]const u8 = null,
    /// Optional error message from the last failure.
    last_error: ?[]const u8 = null,
    /// ISO-8601 creation timestamp.
    created_at: []const u8,
    /// ISO-8601 last-updated timestamp.
    updated_at: []const u8,
    /// ISO-8601 timestamp when the task started executing.
    started_at: ?[]const u8 = null,
    /// ISO-8601 timestamp when the task reached a terminal state.
    finished_at: ?[]const u8 = null,

    /// Returns true if the task is in a terminal state.
    pub fn isFinished(self: *const TaskRecord) bool {
        return self.status.isTerminal();
    }

    /// Returns the fraction of completed steps (0.0 to 1.0).
    /// Returns 1.0 for tasks with no steps.
    pub fn progress(self: *const TaskRecord) f64 {
        if (self.steps.len == 0) {
            return if (self.status == .completed) 1.0 else 0.0;
        }
        var done: usize = 0;
        for (self.steps) |step| {
            if (step.status == .completed or step.status == .skipped) {
                done += 1;
            }
        }
        return @as(f64, @floatFromInt(done)) / @as(f64, @floatFromInt(self.steps.len));
    }
};

// ── Tests ──────────────────────────────────────────────────────────

test "TaskStatus toString roundtrip" {
    const statuses = [_]TaskStatus{ .pending, .running, .completed, .failed, .cancelled, .blocked };
    for (statuses) |s| {
        const str = s.toString();
        try std.testing.expect(TaskStatus.fromString(str).? == s);
    }
    try std.testing.expect(TaskStatus.fromString("bogus") == null);
}

test "TaskStatus isTerminal" {
    try std.testing.expect(TaskStatus.completed.isTerminal());
    try std.testing.expect(TaskStatus.failed.isTerminal());
    try std.testing.expect(TaskStatus.cancelled.isTerminal());
    try std.testing.expect(!TaskStatus.pending.isTerminal());
    try std.testing.expect(!TaskStatus.running.isTerminal());
    try std.testing.expect(!TaskStatus.blocked.isTerminal());
}

test "TaskPriority toString roundtrip" {
    const priorities = [_]TaskPriority{ .low, .normal, .high, .critical };
    for (priorities) |p| {
        const str = p.toString();
        try std.testing.expect(TaskPriority.fromString(str).? == p);
    }
    try std.testing.expect(TaskPriority.fromString("bogus") == null);
}

test "StepStatus toString roundtrip" {
    const statuses = [_]StepStatus{ .pending, .running, .completed, .failed, .skipped };
    for (statuses) |s| {
        const str = s.toString();
        try std.testing.expect(StepStatus.fromString(str).? == s);
    }
    try std.testing.expect(StepStatus.fromString("bogus") == null);
}

test "StepRecord defaults" {
    const step = StepRecord{ .name = "fetch-data" };
    try std.testing.expect(step.status == .pending);
    try std.testing.expectEqual(@as(u32, 0), step.retries);
    try std.testing.expect(step.last_error == null);
    try std.testing.expect(step.started_at == null);
    try std.testing.expect(step.finished_at == null);
}

test "RetryPolicy.none disables retries" {
    const p = RetryPolicy.none;
    try std.testing.expectEqual(@as(u32, 0), p.max_retries);
    try std.testing.expectEqual(@as(u64, 0), p.backoff_base_ns);
}

test "RetryPolicy backoffFor exponential clamped" {
    const p = RetryPolicy{
        .backoff_base_ns = 1000,
        .backoff_max_ns = 10000,
    };
    try std.testing.expectEqual(@as(u64, 1000), p.backoffFor(0));
    try std.testing.expectEqual(@as(u64, 2000), p.backoffFor(1));
    try std.testing.expectEqual(@as(u64, 4000), p.backoffFor(2));
    try std.testing.expectEqual(@as(u64, 10000), p.backoffFor(4));
}

test "RetryPolicy backoffFor zero base returns zero" {
    const p = RetryPolicy{ .backoff_base_ns = 0 };
    try std.testing.expectEqual(@as(u64, 0), p.backoffFor(5));
}

test "TaskRecord defaults" {
    const task = TaskRecord{
        .id = "task-001",
        .name = "build-report",
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    };
    try std.testing.expect(task.status == .pending);
    try std.testing.expect(task.priority == .normal);
    try std.testing.expectEqual(@as(u32, 0), task.retries);
    try std.testing.expectEqual(@as(u32, 0), task.current_step);
    try std.testing.expect(task.description == null);
    try std.testing.expect(task.last_error == null);
    try std.testing.expect(task.started_at == null);
    try std.testing.expect(task.finished_at == null);
    try std.testing.expect(!task.isFinished());
}

test "TaskRecord isFinished" {
    const done = TaskRecord{
        .id = "t1",
        .name = "done-task",
        .status = .completed,
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    };
    try std.testing.expect(done.isFinished());

    const running = TaskRecord{
        .id = "t2",
        .name = "running-task",
        .status = .running,
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    };
    try std.testing.expect(!running.isFinished());
}

test "TaskRecord progress with no steps" {
    const pending_task = TaskRecord{
        .id = "t1",
        .name = "no-steps",
        .status = .pending,
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    };
    try std.testing.expectEqual(@as(f64, 0.0), pending_task.progress());

    const done_task = TaskRecord{
        .id = "t2",
        .name = "no-steps-done",
        .status = .completed,
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    };
    try std.testing.expectEqual(@as(f64, 1.0), done_task.progress());
}

test "TaskRecord progress with steps" {
    const steps = [_]StepRecord{
        .{ .name = "step-1", .status = .completed },
        .{ .name = "step-2", .status = .running },
        .{ .name = "step-3", .status = .pending },
        .{ .name = "step-4", .status = .skipped },
    };
    const task = TaskRecord{
        .id = "t3",
        .name = "multi-step",
        .steps = &steps,
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    };
    // 2 out of 4 steps are done (completed + skipped)
    try std.testing.expectEqual(@as(f64, 0.5), task.progress());
}
