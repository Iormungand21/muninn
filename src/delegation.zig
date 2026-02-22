//! Remote planning delegation client stub.
//!
//! Allows muninn to request plans from huginn (or another remote planner).
//! Defines the request/response API shape and a client stub with an HTTP
//! transport placeholder — no production auth or retry logic yet.

const std = @import("std");
const config_types = @import("config_types.zig");

// ── Plan request kind ──────────────────────────────────────────────
// Classifies what kind of plan is being requested.

pub const PlanRequestKind = enum {
    /// Break a high-level goal into concrete steps.
    task_plan,
    /// Produce a strategic direction or architectural decision.
    strategy,
    /// Decompose a large task into independent sub-tasks.
    decomposition,

    pub fn toString(self: PlanRequestKind) []const u8 {
        return switch (self) {
            .task_plan => "task_plan",
            .strategy => "strategy",
            .decomposition => "decomposition",
        };
    }

    pub fn fromString(s: []const u8) ?PlanRequestKind {
        if (std.mem.eql(u8, s, "task_plan")) return .task_plan;
        if (std.mem.eql(u8, s, "strategy")) return .strategy;
        if (std.mem.eql(u8, s, "decomposition")) return .decomposition;
        return null;
    }
};

// ── Plan request priority ──────────────────────────────────────────

pub const PlanPriority = enum {
    /// Background planning — no urgency.
    low,
    /// Standard planning request.
    normal,
    /// Time-sensitive — planner should prioritize.
    high,

    pub fn toString(self: PlanPriority) []const u8 {
        return switch (self) {
            .low => "low",
            .normal => "normal",
            .high => "high",
        };
    }

    pub fn fromString(s: []const u8) ?PlanPriority {
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "normal")) return .normal;
        if (std.mem.eql(u8, s, "high")) return .high;
        return null;
    }

    /// Numeric level for comparison (higher = more urgent).
    pub fn level(self: PlanPriority) u8 {
        return switch (self) {
            .low => 0,
            .normal => 1,
            .high => 2,
        };
    }
};

// ── Plan response status ───────────────────────────────────────────

pub const PlanResponseStatus = enum {
    /// The plan was successfully generated and returned.
    accepted,
    /// The planner declined the request (unsupported, out of scope, etc.).
    rejected,
    /// The plan is still being generated (async polling).
    pending,
    /// An error occurred during planning.
    err,

    pub fn toString(self: PlanResponseStatus) []const u8 {
        return switch (self) {
            .accepted => "accepted",
            .rejected => "rejected",
            .pending => "pending",
            .err => "error",
        };
    }

    pub fn fromString(s: []const u8) ?PlanResponseStatus {
        if (std.mem.eql(u8, s, "accepted")) return .accepted;
        if (std.mem.eql(u8, s, "rejected")) return .rejected;
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "error")) return .err;
        return null;
    }

    /// Returns true for terminal states (no further polling needed).
    pub fn isTerminal(self: PlanResponseStatus) bool {
        return self == .accepted or self == .rejected or self == .err;
    }
};

// ── Plan request ───────────────────────────────────────────────────
// The payload muninn sends to huginn asking for a plan.

pub const PlanRequest = struct {
    /// Unique request identifier.
    id: []const u8,
    /// What kind of plan is requested.
    kind: PlanRequestKind,
    /// The high-level goal or objective to plan for.
    goal: []const u8,
    /// Priority of this planning request.
    priority: PlanPriority = .normal,
    /// ISO-8601 timestamp when the request was created.
    requested_at: []const u8,
    /// Optional context or background information for the planner.
    context: ?[]const u8 = null,
    /// Optional constraints the planner should respect.
    constraints: ?[]const u8 = null,
    /// Optional workspace identifier scoping the plan.
    workspace_id: ?[]const u8 = null,
};

// ── Plan step ──────────────────────────────────────────────────────
// A single step in a returned plan.

pub const PlanStep = struct {
    /// Step sequence number (1-based).
    seq: u32,
    /// Short description of what this step accomplishes.
    summary: []const u8,
    /// Optional detailed instructions.
    detail: ?[]const u8 = null,
    /// Estimated effort in minutes (0 = unknown).
    estimated_minutes: u32 = 0,
};

// ── Plan response ──────────────────────────────────────────────────
// The payload huginn returns to muninn with the plan.

pub const PlanResponse = struct {
    /// The original request ID this response answers.
    request_id: []const u8,
    /// Outcome status of the planning request.
    status: PlanResponseStatus,
    /// ISO-8601 timestamp when the response was generated.
    responded_at: []const u8,
    /// The plan steps (empty if status is not accepted).
    steps: []const PlanStep = &.{},
    /// High-level rationale or summary from the planner.
    rationale: ?[]const u8 = null,
    /// Error message if status is err.
    error_message: ?[]const u8 = null,

    /// Returns true if the plan was accepted and contains steps.
    pub fn hasSteps(self: *const PlanResponse) bool {
        return self.status == .accepted and self.steps.len > 0;
    }

    /// Returns the number of plan steps.
    pub fn stepCount(self: *const PlanResponse) usize {
        return self.steps.len;
    }
};

// ── JSONL serialization ────────────────────────────────────────────
// Stack-buffer serialization for plan requests (no allocation).

/// Serialize a PlanRequest into a JSON line within the provided buffer.
/// Returns the written slice, or null if the buffer is too small.
pub fn serializeRequest(buf: []u8, req: *const PlanRequest) ?[]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    w.writeAll("{\"id\":\"") catch return null;
    w.writeAll(req.id) catch return null;
    w.writeAll("\",\"kind\":\"") catch return null;
    w.writeAll(req.kind.toString()) catch return null;
    w.writeAll("\",\"priority\":\"") catch return null;
    w.writeAll(req.priority.toString()) catch return null;
    w.writeAll("\",\"goal\":\"") catch return null;
    w.writeAll(req.goal) catch return null;
    w.writeAll("\",\"requested_at\":\"") catch return null;
    w.writeAll(req.requested_at) catch return null;
    w.writeByte('"') catch return null;

    if (req.context) |v| {
        w.writeAll(",\"context\":\"") catch return null;
        w.writeAll(v) catch return null;
        w.writeByte('"') catch return null;
    }
    if (req.constraints) |v| {
        w.writeAll(",\"constraints\":\"") catch return null;
        w.writeAll(v) catch return null;
        w.writeByte('"') catch return null;
    }
    if (req.workspace_id) |v| {
        w.writeAll(",\"workspace_id\":\"") catch return null;
        w.writeAll(v) catch return null;
        w.writeByte('"') catch return null;
    }

    w.writeByte('}') catch return null;
    return fbs.getWritten();
}

// ── Delegation client stub ─────────────────────────────────────────
// Placeholder client for remote plan delegation via HTTP.

pub const DelegationClient = struct {
    /// Base URL of the huginn planning endpoint.
    endpoint: []const u8,
    /// Request timeout in seconds.
    timeout_secs: u64 = 30,
    /// Optional API key for authentication (not enforced yet).
    api_key: ?[]const u8 = null,

    /// Submit a planning request to the remote planner.
    /// TODO(M4-DEL): Implement actual HTTP transport via http_util.curlPost.
    /// Stub returns a pending response.
    pub fn requestPlan(self: *const DelegationClient, req: *const PlanRequest) PlanResponse {
        _ = self;
        return .{
            .request_id = req.id,
            .status = .pending,
            .responded_at = req.requested_at,
            .rationale = "stub: remote transport not yet implemented",
        };
    }

    /// Poll for the status of a previously submitted plan request.
    /// TODO(M4-DEL): Implement actual HTTP polling via http_util.curlGet.
    /// Stub returns pending.
    pub fn checkStatus(self: *const DelegationClient, request_id: []const u8) PlanResponse {
        _ = self;
        return .{
            .request_id = request_id,
            .status = .pending,
            .responded_at = "1970-01-01T00:00:00Z",
            .rationale = "stub: polling not yet implemented",
        };
    }

    /// Check whether the remote planner endpoint is reachable.
    /// TODO(M4-DEL): Implement health check via http_util.curlGet.
    /// Stub always returns false (no transport).
    pub fn isReachable(self: *const DelegationClient) bool {
        _ = self;
        return false;
    }

    /// Returns the configured endpoint URL.
    pub fn getEndpoint(self: *const DelegationClient) []const u8 {
        return self.endpoint;
    }

    /// Returns true if an API key is configured.
    pub fn hasApiKey(self: *const DelegationClient) bool {
        return self.api_key != null;
    }
};

// ── Factory helpers ────────────────────────────────────────────────

/// Create a DelegationClient from a DelegationConfig.
pub fn delegationClientFromConfig(cfg: config_types.DelegationConfig) DelegationClient {
    return .{
        .endpoint = cfg.endpoint,
        .timeout_secs = cfg.timeout_secs,
        .api_key = cfg.api_key,
    };
}

/// Create a DelegationClient with edge-appropriate defaults.
/// Longer timeout to accommodate constrained networks.
pub fn edgeDelegationClient(endpoint: []const u8) DelegationClient {
    return .{
        .endpoint = endpoint,
        .timeout_secs = 60,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "PlanRequestKind toString roundtrip" {
    const kinds = [_]PlanRequestKind{ .task_plan, .strategy, .decomposition };
    for (kinds) |k| {
        const str = k.toString();
        try std.testing.expect(PlanRequestKind.fromString(str).? == k);
    }
    try std.testing.expect(PlanRequestKind.fromString("bogus") == null);
}

test "PlanPriority toString roundtrip" {
    const priorities = [_]PlanPriority{ .low, .normal, .high };
    for (priorities) |p| {
        const str = p.toString();
        try std.testing.expect(PlanPriority.fromString(str).? == p);
    }
    try std.testing.expect(PlanPriority.fromString("bogus") == null);
}

test "PlanPriority level ordering" {
    try std.testing.expect(PlanPriority.low.level() < PlanPriority.normal.level());
    try std.testing.expect(PlanPriority.normal.level() < PlanPriority.high.level());
}

test "PlanResponseStatus toString roundtrip" {
    const statuses = [_]PlanResponseStatus{ .accepted, .rejected, .pending, .err };
    for (statuses) |s| {
        const str = s.toString();
        try std.testing.expect(PlanResponseStatus.fromString(str).? == s);
    }
    try std.testing.expect(PlanResponseStatus.fromString("bogus") == null);
}

test "PlanResponseStatus error maps to string 'error'" {
    try std.testing.expectEqualStrings("error", PlanResponseStatus.err.toString());
    try std.testing.expect(PlanResponseStatus.fromString("error").? == .err);
}

test "PlanResponseStatus isTerminal" {
    try std.testing.expect(PlanResponseStatus.accepted.isTerminal());
    try std.testing.expect(PlanResponseStatus.rejected.isTerminal());
    try std.testing.expect(PlanResponseStatus.err.isTerminal());
    try std.testing.expect(!PlanResponseStatus.pending.isTerminal());
}

test "PlanRequest defaults" {
    const req = PlanRequest{
        .id = "plan-001",
        .kind = .task_plan,
        .goal = "deploy new feature",
        .requested_at = "2026-02-22T14:00:00Z",
    };
    try std.testing.expect(req.priority == .normal);
    try std.testing.expect(req.context == null);
    try std.testing.expect(req.constraints == null);
    try std.testing.expect(req.workspace_id == null);
}

test "PlanRequest full construction" {
    const req = PlanRequest{
        .id = "plan-100",
        .kind = .decomposition,
        .goal = "refactor auth module",
        .priority = .high,
        .requested_at = "2026-02-22T15:00:00Z",
        .context = "auth is currently monolithic",
        .constraints = "must preserve API compatibility",
        .workspace_id = "ws-main",
    };
    try std.testing.expectEqualStrings("plan-100", req.id);
    try std.testing.expect(req.kind == .decomposition);
    try std.testing.expect(req.priority == .high);
    try std.testing.expectEqualStrings("refactor auth module", req.goal);
    try std.testing.expectEqualStrings("auth is currently monolithic", req.context.?);
    try std.testing.expectEqualStrings("must preserve API compatibility", req.constraints.?);
    try std.testing.expectEqualStrings("ws-main", req.workspace_id.?);
}

test "PlanStep defaults" {
    const step = PlanStep{
        .seq = 1,
        .summary = "Create schema migration",
    };
    try std.testing.expectEqual(@as(u32, 1), step.seq);
    try std.testing.expectEqualStrings("Create schema migration", step.summary);
    try std.testing.expect(step.detail == null);
    try std.testing.expectEqual(@as(u32, 0), step.estimated_minutes);
}

test "PlanStep full construction" {
    const step = PlanStep{
        .seq = 3,
        .summary = "Run integration tests",
        .detail = "Execute full test suite against staging",
        .estimated_minutes = 15,
    };
    try std.testing.expectEqual(@as(u32, 3), step.seq);
    try std.testing.expectEqualStrings("Run integration tests", step.summary);
    try std.testing.expectEqualStrings("Execute full test suite against staging", step.detail.?);
    try std.testing.expectEqual(@as(u32, 15), step.estimated_minutes);
}

test "PlanResponse defaults" {
    const resp = PlanResponse{
        .request_id = "plan-001",
        .status = .pending,
        .responded_at = "2026-02-22T14:00:00Z",
    };
    try std.testing.expect(resp.steps.len == 0);
    try std.testing.expect(resp.rationale == null);
    try std.testing.expect(resp.error_message == null);
    try std.testing.expect(!resp.hasSteps());
    try std.testing.expectEqual(@as(usize, 0), resp.stepCount());
}

test "PlanResponse accepted with steps" {
    const steps = [_]PlanStep{
        .{ .seq = 1, .summary = "Step one" },
        .{ .seq = 2, .summary = "Step two", .estimated_minutes = 10 },
    };
    const resp = PlanResponse{
        .request_id = "plan-002",
        .status = .accepted,
        .responded_at = "2026-02-22T14:05:00Z",
        .steps = &steps,
        .rationale = "straightforward two-step approach",
    };
    try std.testing.expect(resp.hasSteps());
    try std.testing.expectEqual(@as(usize, 2), resp.stepCount());
    try std.testing.expectEqualStrings("Step one", resp.steps[0].summary);
    try std.testing.expectEqualStrings("Step two", resp.steps[1].summary);
    try std.testing.expectEqualStrings("straightforward two-step approach", resp.rationale.?);
}

test "PlanResponse rejected has no steps" {
    const resp = PlanResponse{
        .request_id = "plan-003",
        .status = .rejected,
        .responded_at = "2026-02-22T14:00:00Z",
        .rationale = "goal is out of scope",
    };
    try std.testing.expect(!resp.hasSteps());
    try std.testing.expectEqual(@as(usize, 0), resp.stepCount());
}

test "PlanResponse error with message" {
    const resp = PlanResponse{
        .request_id = "plan-004",
        .status = .err,
        .responded_at = "2026-02-22T14:00:00Z",
        .error_message = "internal planner timeout",
    };
    try std.testing.expect(!resp.hasSteps());
    try std.testing.expect(resp.status.isTerminal());
    try std.testing.expectEqualStrings("internal planner timeout", resp.error_message.?);
}

test "serializeRequest minimal" {
    var buf: [4096]u8 = undefined;
    const req = PlanRequest{
        .id = "plan-001",
        .kind = .task_plan,
        .goal = "deploy feature",
        .requested_at = "2026-02-22T14:00:00Z",
    };
    const line = serializeRequest(&buf, &req).?;

    try std.testing.expect(std.mem.indexOf(u8, line, "\"id\":\"plan-001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"kind\":\"task_plan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"priority\":\"normal\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"goal\":\"deploy feature\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"requested_at\":\"2026-02-22T14:00:00Z\"") != null);
    // Optional fields should be absent
    try std.testing.expect(std.mem.indexOf(u8, line, "context") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "constraints") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "workspace_id") == null);
}

test "serializeRequest with all optional fields" {
    var buf: [4096]u8 = undefined;
    const req = PlanRequest{
        .id = "plan-100",
        .kind = .decomposition,
        .goal = "refactor auth",
        .priority = .high,
        .requested_at = "2026-02-22T15:00:00Z",
        .context = "monolithic auth",
        .constraints = "preserve API",
        .workspace_id = "ws-main",
    };
    const line = serializeRequest(&buf, &req).?;

    try std.testing.expect(std.mem.indexOf(u8, line, "\"context\":\"monolithic auth\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"constraints\":\"preserve API\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"workspace_id\":\"ws-main\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"priority\":\"high\"") != null);
}

test "serializeRequest returns null on tiny buffer" {
    var buf: [8]u8 = undefined;
    const req = PlanRequest{
        .id = "plan-001",
        .kind = .task_plan,
        .goal = "deploy",
        .requested_at = "2026-02-22T14:00:00Z",
    };
    try std.testing.expect(serializeRequest(&buf, &req) == null);
}

test "serializeRequest kind variants" {
    var buf: [4096]u8 = undefined;
    const kinds = [_]PlanRequestKind{ .task_plan, .strategy, .decomposition };
    const expected = [_][]const u8{ "task_plan", "strategy", "decomposition" };

    for (kinds, expected) |k, exp| {
        const req = PlanRequest{
            .id = "p",
            .kind = k,
            .goal = "test",
            .requested_at = "2026-01-01T00:00:00Z",
        };
        const line = serializeRequest(&buf, &req).?;
        const needle = std.fmt.bufPrint(buf[3000..], "\"kind\":\"{s}\"", .{exp}) catch continue;
        try std.testing.expect(std.mem.indexOf(u8, line, needle) != null);
    }
}

test "DelegationClient creation" {
    const client = DelegationClient{
        .endpoint = "http://huginn.local:8080/plan",
    };
    try std.testing.expectEqualStrings("http://huginn.local:8080/plan", client.getEndpoint());
    try std.testing.expectEqual(@as(u64, 30), client.timeout_secs);
    try std.testing.expect(!client.hasApiKey());
    try std.testing.expect(!client.isReachable());
}

test "DelegationClient with api key" {
    const client = DelegationClient{
        .endpoint = "http://huginn.local:8080/plan",
        .api_key = "secret-key-123",
        .timeout_secs = 60,
    };
    try std.testing.expect(client.hasApiKey());
    try std.testing.expectEqual(@as(u64, 60), client.timeout_secs);
}

test "DelegationClient requestPlan returns pending stub" {
    const client = DelegationClient{
        .endpoint = "http://huginn.local:8080/plan",
    };
    const req = PlanRequest{
        .id = "plan-stub-001",
        .kind = .task_plan,
        .goal = "build feature X",
        .requested_at = "2026-02-22T14:00:00Z",
    };
    const resp = client.requestPlan(&req);
    try std.testing.expectEqualStrings("plan-stub-001", resp.request_id);
    try std.testing.expect(resp.status == .pending);
    try std.testing.expect(!resp.hasSteps());
    try std.testing.expect(resp.rationale != null);
}

test "DelegationClient checkStatus returns pending stub" {
    const client = DelegationClient{
        .endpoint = "http://huginn.local:8080/plan",
    };
    const resp = client.checkStatus("plan-poll-001");
    try std.testing.expectEqualStrings("plan-poll-001", resp.request_id);
    try std.testing.expect(resp.status == .pending);
    try std.testing.expect(resp.rationale != null);
}

test "DelegationClient isReachable returns false (stub)" {
    const client = DelegationClient{
        .endpoint = "http://huginn.local:8080/plan",
    };
    try std.testing.expect(!client.isReachable());
}

test "delegationClientFromConfig" {
    const cfg = config_types.DelegationConfig{
        .endpoint = "http://huginn:9090/api/plan",
        .timeout_secs = 45,
        .api_key = "key-abc",
    };
    const client = delegationClientFromConfig(cfg);
    try std.testing.expectEqualStrings("http://huginn:9090/api/plan", client.getEndpoint());
    try std.testing.expectEqual(@as(u64, 45), client.timeout_secs);
    try std.testing.expect(client.hasApiKey());
}

test "delegationClientFromConfig defaults" {
    const cfg = config_types.DelegationConfig{};
    const client = delegationClientFromConfig(cfg);
    try std.testing.expectEqualStrings("http://localhost:8080/plan", client.getEndpoint());
    try std.testing.expectEqual(@as(u64, 30), client.timeout_secs);
    try std.testing.expect(!client.hasApiKey());
}

test "edgeDelegationClient" {
    const client = edgeDelegationClient("http://huginn-edge:8080/plan");
    try std.testing.expectEqualStrings("http://huginn-edge:8080/plan", client.getEndpoint());
    try std.testing.expectEqual(@as(u64, 60), client.timeout_secs);
    try std.testing.expect(!client.hasApiKey());
}
