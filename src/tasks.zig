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
    /// Optional per-step retry policy override.
    retry_policy: StepRetryPolicy = StepRetryPolicy.inherit,
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

// ── Step-level retry policy ────────────────────────────────────────
// Per-step retry config that can override the task-level policy.

pub const StepRetryPolicy = struct {
    /// Maximum retries for this specific step (null = inherit task policy).
    max_retries: ?u32 = null,
    /// Base backoff in nanoseconds (null = inherit task policy).
    backoff_base_ns: ?u64 = null,
    /// Max backoff cap in nanoseconds (null = inherit task policy).
    backoff_max_ns: ?u64 = null,

    pub const inherit: StepRetryPolicy = .{};

    /// Resolve this step policy against a parent task-level RetryPolicy.
    /// Fields set to null fall through to the parent.
    pub fn resolve(self: StepRetryPolicy, parent: RetryPolicy) RetryPolicy {
        return .{
            .max_retries = self.max_retries orelse parent.max_retries,
            .backoff_base_ns = self.backoff_base_ns orelse parent.backoff_base_ns,
            .backoff_max_ns = self.backoff_max_ns orelse parent.backoff_max_ns,
        };
    }
};

// ── Verifier hook ──────────────────────────────────────────────────
// A config-gated hook point invoked after each step completes.

pub const VerifyResult = enum {
    /// Step output accepted — proceed to next step.
    accept,
    /// Step output rejected — retry if policy allows.
    reject,
    /// Step output rejected — skip to next step.
    skip,
    /// Step output rejected — abort the entire task.
    abort,

    pub fn isRetryable(self: VerifyResult) bool {
        return self == .reject;
    }
};

/// Signature for a verifier hook callback.
/// Receives the completed step record and the task id.
/// Returns a VerifyResult controlling what happens next.
pub const VerifierHookFn = *const fn (task_id: []const u8, step: *const StepRecord) VerifyResult;

pub const VerifierConfig = struct {
    /// Whether the verifier hook is active.
    enabled: bool = false,
    /// Optional hook function. When null (even if enabled), verification is skipped.
    hook: ?VerifierHookFn = null,

    pub const disabled: VerifierConfig = .{};

    /// Run the verifier if enabled and a hook is set. Returns .accept when disabled.
    pub fn verify(self: VerifierConfig, task_id: []const u8, step: *const StepRecord) VerifyResult {
        if (!self.enabled) return .accept;
        const hook = self.hook orelse return .accept;
        return hook(task_id, step);
    }
};

// ── Step retry helpers ─────────────────────────────────────────────

/// Determine whether a step should be retried given its current state
/// and the effective retry policy.
pub fn shouldRetryStep(step: *const StepRecord, policy: RetryPolicy) bool {
    if (step.status != .failed) return false;
    return step.retries < policy.max_retries;
}

/// Record a retry attempt on a step: increment counter, reset to .running.
/// Returns the backoff delay in nanoseconds the caller should wait.
pub fn recordStepRetry(step: *StepRecord, policy: RetryPolicy) u64 {
    const delay = policy.backoffFor(step.retries);
    step.retries += 1;
    step.status = .running;
    step.last_error = null;
    return delay;
}

/// Mark a step as failed with an error message.
pub fn failStep(step: *StepRecord, err_msg: ?[]const u8) void {
    step.status = .failed;
    step.last_error = err_msg;
}

/// Mark a step as completed successfully.
pub fn completeStep(step: *StepRecord) void {
    step.status = .completed;
    step.last_error = null;
}

/// Apply a VerifyResult to a step and task, returning whether the task
/// should continue advancing. When reject + retries remain, the step
/// is reset for retry. When reject + no retries, the step stays failed.
pub fn applyVerifyResult(
    step: *StepRecord,
    result: VerifyResult,
    policy: RetryPolicy,
) enum { continue_task, retry_step, step_failed, task_aborted } {
    return switch (result) {
        .accept => .continue_task,
        .skip => {
            step.status = .skipped;
            return .continue_task;
        },
        .reject => {
            failStep(step, "rejected by verifier");
            if (shouldRetryStep(step, policy)) {
                _ = recordStepRetry(step, policy);
                return .retry_step;
            }
            return .step_failed;
        },
        .abort => {
            failStep(step, "aborted by verifier");
            return .task_aborted;
        },
    };
}

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
    /// Verifier configuration for this task (disabled by default).
    verifier: VerifierConfig = VerifierConfig.disabled,
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

// ── StepRetryPolicy tests ──────────────────────────────────────────

test "StepRetryPolicy.inherit defaults all to null" {
    const sp = StepRetryPolicy.inherit;
    try std.testing.expect(sp.max_retries == null);
    try std.testing.expect(sp.backoff_base_ns == null);
    try std.testing.expect(sp.backoff_max_ns == null);
}

test "StepRetryPolicy.resolve inherits from parent when null" {
    const parent = RetryPolicy{
        .max_retries = 5,
        .backoff_base_ns = 2000,
        .backoff_max_ns = 60000,
    };
    const sp = StepRetryPolicy.inherit;
    const resolved = sp.resolve(parent);
    try std.testing.expectEqual(@as(u32, 5), resolved.max_retries);
    try std.testing.expectEqual(@as(u64, 2000), resolved.backoff_base_ns);
    try std.testing.expectEqual(@as(u64, 60000), resolved.backoff_max_ns);
}

test "StepRetryPolicy.resolve overrides parent when set" {
    const parent = RetryPolicy{
        .max_retries = 5,
        .backoff_base_ns = 2000,
        .backoff_max_ns = 60000,
    };
    const sp = StepRetryPolicy{
        .max_retries = 1,
        .backoff_base_ns = null, // inherit
        .backoff_max_ns = 10000,
    };
    const resolved = sp.resolve(parent);
    try std.testing.expectEqual(@as(u32, 1), resolved.max_retries);
    try std.testing.expectEqual(@as(u64, 2000), resolved.backoff_base_ns); // inherited
    try std.testing.expectEqual(@as(u64, 10000), resolved.backoff_max_ns); // overridden
}

test "StepRetryPolicy.resolve full override" {
    const parent = RetryPolicy{};
    const sp = StepRetryPolicy{
        .max_retries = 10,
        .backoff_base_ns = 500,
        .backoff_max_ns = 5000,
    };
    const resolved = sp.resolve(parent);
    try std.testing.expectEqual(@as(u32, 10), resolved.max_retries);
    try std.testing.expectEqual(@as(u64, 500), resolved.backoff_base_ns);
    try std.testing.expectEqual(@as(u64, 5000), resolved.backoff_max_ns);
}

// ── VerifyResult tests ─────────────────────────────────────────────

test "VerifyResult.isRetryable" {
    try std.testing.expect(VerifyResult.reject.isRetryable());
    try std.testing.expect(!VerifyResult.accept.isRetryable());
    try std.testing.expect(!VerifyResult.skip.isRetryable());
    try std.testing.expect(!VerifyResult.abort.isRetryable());
}

// ── VerifierConfig tests ───────────────────────────────────────────

test "VerifierConfig.disabled returns accept" {
    const vc = VerifierConfig.disabled;
    try std.testing.expect(!vc.enabled);
    try std.testing.expect(vc.hook == null);
    const step = StepRecord{ .name = "s1", .status = .completed };
    try std.testing.expect(vc.verify("task-1", &step) == .accept);
}

test "VerifierConfig enabled but no hook returns accept" {
    const vc = VerifierConfig{ .enabled = true, .hook = null };
    const step = StepRecord{ .name = "s1", .status = .completed };
    try std.testing.expect(vc.verify("task-1", &step) == .accept);
}

fn testRejectHook(_: []const u8, _: *const StepRecord) VerifyResult {
    return .reject;
}

fn testAcceptHook(_: []const u8, _: *const StepRecord) VerifyResult {
    return .accept;
}

fn testAbortHook(_: []const u8, _: *const StepRecord) VerifyResult {
    return .abort;
}

fn testSkipHook(_: []const u8, _: *const StepRecord) VerifyResult {
    return .skip;
}

test "VerifierConfig enabled with hook invokes it" {
    const vc = VerifierConfig{ .enabled = true, .hook = testRejectHook };
    const step = StepRecord{ .name = "s1", .status = .completed };
    try std.testing.expect(vc.verify("task-1", &step) == .reject);
}

test "VerifierConfig disabled with hook still returns accept" {
    const vc = VerifierConfig{ .enabled = false, .hook = testRejectHook };
    const step = StepRecord{ .name = "s1", .status = .completed };
    try std.testing.expect(vc.verify("task-1", &step) == .accept);
}

test "VerifierConfig verify with accept hook" {
    const vc = VerifierConfig{ .enabled = true, .hook = testAcceptHook };
    const step = StepRecord{ .name = "s1", .status = .completed };
    try std.testing.expect(vc.verify("task-1", &step) == .accept);
}

// ── Step retry helper tests ────────────────────────────────────────

test "shouldRetryStep returns false for non-failed step" {
    const step = StepRecord{ .name = "s1", .status = .running };
    const policy = RetryPolicy{ .max_retries = 3 };
    try std.testing.expect(!shouldRetryStep(&step, policy));
}

test "shouldRetryStep returns true when retries remain" {
    const step = StepRecord{ .name = "s1", .status = .failed, .retries = 1 };
    const policy = RetryPolicy{ .max_retries = 3 };
    try std.testing.expect(shouldRetryStep(&step, policy));
}

test "shouldRetryStep returns false when retries exhausted" {
    const step = StepRecord{ .name = "s1", .status = .failed, .retries = 3 };
    const policy = RetryPolicy{ .max_retries = 3 };
    try std.testing.expect(!shouldRetryStep(&step, policy));
}

test "shouldRetryStep with zero-retry policy" {
    const step = StepRecord{ .name = "s1", .status = .failed, .retries = 0 };
    try std.testing.expect(!shouldRetryStep(&step, RetryPolicy.none));
}

test "recordStepRetry increments counter and sets running" {
    var step = StepRecord{ .name = "s1", .status = .failed, .retries = 0, .last_error = "oops" };
    const policy = RetryPolicy{ .backoff_base_ns = 1000, .backoff_max_ns = 10000 };
    const delay = recordStepRetry(&step, policy);
    try std.testing.expectEqual(@as(u32, 1), step.retries);
    try std.testing.expect(step.status == .running);
    try std.testing.expect(step.last_error == null);
    try std.testing.expectEqual(@as(u64, 1000), delay);
}

test "recordStepRetry exponential backoff" {
    var step = StepRecord{ .name = "s1", .status = .failed, .retries = 2 };
    const policy = RetryPolicy{ .backoff_base_ns = 100, .backoff_max_ns = 1000 };
    const delay = recordStepRetry(&step, policy);
    // attempt=2 -> 100 * 2^2 = 400
    try std.testing.expectEqual(@as(u64, 400), delay);
    try std.testing.expectEqual(@as(u32, 3), step.retries);
}

test "failStep sets status and error" {
    var step = StepRecord{ .name = "s1", .status = .running };
    failStep(&step, "connection timeout");
    try std.testing.expect(step.status == .failed);
    try std.testing.expectEqualStrings("connection timeout", step.last_error.?);
}

test "failStep with null error" {
    var step = StepRecord{ .name = "s1", .status = .running };
    failStep(&step, null);
    try std.testing.expect(step.status == .failed);
    try std.testing.expect(step.last_error == null);
}

test "completeStep sets status and clears error" {
    var step = StepRecord{ .name = "s1", .status = .running, .last_error = "old error" };
    completeStep(&step);
    try std.testing.expect(step.status == .completed);
    try std.testing.expect(step.last_error == null);
}

// ── applyVerifyResult tests ────────────────────────────────────────

test "applyVerifyResult accept continues task" {
    var step = StepRecord{ .name = "s1", .status = .completed };
    const policy = RetryPolicy{ .max_retries = 3 };
    const outcome = applyVerifyResult(&step, .accept, policy);
    try std.testing.expect(outcome == .continue_task);
}

test "applyVerifyResult skip marks step skipped" {
    var step = StepRecord{ .name = "s1", .status = .completed };
    const policy = RetryPolicy{ .max_retries = 3 };
    const outcome = applyVerifyResult(&step, .skip, policy);
    try std.testing.expect(outcome == .continue_task);
    try std.testing.expect(step.status == .skipped);
}

test "applyVerifyResult reject with retries remaining" {
    var step = StepRecord{ .name = "s1", .status = .completed, .retries = 0 };
    const policy = RetryPolicy{ .max_retries = 2, .backoff_base_ns = 100 };
    const outcome = applyVerifyResult(&step, .reject, policy);
    try std.testing.expect(outcome == .retry_step);
    try std.testing.expect(step.status == .running);
    try std.testing.expectEqual(@as(u32, 1), step.retries);
}

test "applyVerifyResult reject with retries exhausted" {
    var step = StepRecord{ .name = "s1", .status = .completed, .retries = 3 };
    const policy = RetryPolicy{ .max_retries = 3 };
    const outcome = applyVerifyResult(&step, .reject, policy);
    try std.testing.expect(outcome == .step_failed);
    try std.testing.expect(step.status == .failed);
}

test "applyVerifyResult abort fails step and aborts task" {
    var step = StepRecord{ .name = "s1", .status = .completed };
    const policy = RetryPolicy{ .max_retries = 10 };
    const outcome = applyVerifyResult(&step, .abort, policy);
    try std.testing.expect(outcome == .task_aborted);
    try std.testing.expect(step.status == .failed);
    try std.testing.expectEqualStrings("aborted by verifier", step.last_error.?);
}

// ── StepRecord retry_policy field test ─────────────────────────────

test "StepRecord default retry_policy is inherit" {
    const step = StepRecord{ .name = "s1" };
    try std.testing.expect(step.retry_policy.max_retries == null);
    try std.testing.expect(step.retry_policy.backoff_base_ns == null);
    try std.testing.expect(step.retry_policy.backoff_max_ns == null);
}

test "StepRecord with custom retry_policy" {
    const step = StepRecord{
        .name = "s1",
        .retry_policy = .{ .max_retries = 5 },
    };
    try std.testing.expectEqual(@as(?u32, 5), step.retry_policy.max_retries);
}

// ── TaskRecord verifier field test ─────────────────────────────────

test "TaskRecord default verifier is disabled" {
    const task = TaskRecord{
        .id = "t1",
        .name = "test-task",
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    };
    try std.testing.expect(!task.verifier.enabled);
    try std.testing.expect(task.verifier.hook == null);
}

test "TaskRecord with verifier enabled" {
    const task = TaskRecord{
        .id = "t1",
        .name = "verified-task",
        .verifier = .{ .enabled = true, .hook = testAcceptHook },
        .created_at = "2026-01-01T00:00:00Z",
        .updated_at = "2026-01-01T00:00:00Z",
    };
    try std.testing.expect(task.verifier.enabled);
    const step = StepRecord{ .name = "s1", .status = .completed };
    try std.testing.expect(task.verifier.verify(task.id, &step) == .accept);
}

// ── Integration: step retry + verifier ─────────────────────────────

test "full step retry cycle with verifier reject then accept" {
    // Simulate a step that gets rejected, retried, then accepted
    var step = StepRecord{ .name = "build", .status = .completed, .retries = 0 };
    const policy = RetryPolicy{ .max_retries = 2, .backoff_base_ns = 100, .backoff_max_ns = 1000 };

    // First verify: reject -> retry
    const r1 = applyVerifyResult(&step, .reject, policy);
    try std.testing.expect(r1 == .retry_step);
    try std.testing.expect(step.status == .running);
    try std.testing.expectEqual(@as(u32, 1), step.retries);

    // Step re-completes
    completeStep(&step);
    try std.testing.expect(step.status == .completed);

    // Second verify: accept
    const r2 = applyVerifyResult(&step, .accept, policy);
    try std.testing.expect(r2 == .continue_task);
}

test "step retry resolves per-step policy before checking" {
    const task_policy = RetryPolicy{ .max_retries = 1, .backoff_base_ns = 100, .backoff_max_ns = 1000 };
    var step = StepRecord{
        .name = "deploy",
        .status = .failed,
        .retries = 1,
        .retry_policy = .{ .max_retries = 5 }, // override: allow more retries
    };
    // With task policy (max 1), no retry
    try std.testing.expect(!shouldRetryStep(&step, task_policy));
    // With resolved step policy (max 5), retry allowed
    const resolved = step.retry_policy.resolve(task_policy);
    try std.testing.expect(shouldRetryStep(&step, resolved));
}
