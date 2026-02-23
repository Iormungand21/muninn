//! Remote planning delegation client.
//!
//! Allows muninn to request plans from huginn (or another remote planner).
//! Defines the request/response API shape and an HTTP transport client
//! using curl subprocess via http_util.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config_types = @import("config_types.zig");
const http_util = @import("http_util.zig");

const log = std.log.scoped(.delegation);

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

// ── Response parsing ───────────────────────────────────────────────

/// Parsed plan response with backing memory management.
/// Call `deinit()` when the response is no longer needed.
pub const ParsedPlanResponse = struct {
    response: PlanResponse,
    /// Backing JSON parse state — must stay alive while response fields are used.
    _parsed: std.json.Parsed(std.json.Value),
    /// Heap-allocated HTTP response body (null for test-provided literals).
    _raw_body: ?[]u8,
    _allocator: Allocator,
    /// Heap-allocated steps array (null when no steps parsed).
    _steps_buf: ?[]PlanStep,

    pub fn deinit(self: *ParsedPlanResponse) void {
        if (self._steps_buf) |s| self._allocator.free(s);
        self._parsed.deinit();
        if (self._raw_body) |b| self._allocator.free(b);
    }
};

/// Parse a JSON response body into a ParsedPlanResponse.
/// `raw_body` is optional heap memory to be freed on deinit (from curl responses).
pub fn parsePlanResponse(allocator: Allocator, body: []const u8, raw_body: ?[]u8) !ParsedPlanResponse {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch
        return error.InvalidJson;
    errdefer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidResponse,
    };

    // Required fields
    const request_id = blk: {
        const v = obj.get("request_id") orelse return error.MissingField;
        break :blk switch (v) {
            .string => |s| s,
            else => return error.InvalidField,
        };
    };

    const status = blk: {
        const v = obj.get("status") orelse return error.MissingField;
        const s = switch (v) {
            .string => |s| s,
            else => return error.InvalidField,
        };
        break :blk PlanResponseStatus.fromString(s) orelse return error.InvalidField;
    };

    const responded_at = blk: {
        const v = obj.get("responded_at") orelse return error.MissingField;
        break :blk switch (v) {
            .string => |s| s,
            else => return error.InvalidField,
        };
    };

    // Optional string fields
    const rationale: ?[]const u8 = if (obj.get("rationale")) |v| switch (v) {
        .string => |s| s,
        else => null,
    } else null;

    const error_message: ?[]const u8 = if (obj.get("error_message")) |v| switch (v) {
        .string => |s| s,
        else => null,
    } else null;

    // Parse steps array
    var steps_buf: ?[]PlanStep = null;
    var steps_slice: []const PlanStep = &.{};
    if (obj.get("steps")) |steps_val| {
        switch (steps_val) {
            .array => |arr| {
                if (arr.items.len > 0) {
                    const buf = try allocator.alloc(PlanStep, arr.items.len);
                    errdefer allocator.free(buf);
                    for (arr.items, 0..) |item, i| {
                        const step_obj = switch (item) {
                            .object => |o| o,
                            else => return error.InvalidField,
                        };
                        buf[i] = .{
                            .seq = blk: {
                                const v = step_obj.get("seq") orelse return error.MissingField;
                                const n = switch (v) {
                                    .integer => |n| n,
                                    else => return error.InvalidField,
                                };
                                break :blk std.math.cast(u32, n) orelse return error.InvalidField;
                            },
                            .summary = blk: {
                                const v = step_obj.get("summary") orelse return error.MissingField;
                                break :blk switch (v) {
                                    .string => |s| s,
                                    else => return error.InvalidField,
                                };
                            },
                            .detail = if (step_obj.get("detail")) |v| switch (v) {
                                .string => |s| s,
                                else => null,
                            } else null,
                            .estimated_minutes = blk: {
                                if (step_obj.get("estimated_minutes")) |v| {
                                    const n = switch (v) {
                                        .integer => |n| n,
                                        else => break :blk @as(u32, 0),
                                    };
                                    break :blk std.math.cast(u32, n) orelse 0;
                                }
                                break :blk 0;
                            },
                        };
                    }
                    steps_buf = buf;
                    steps_slice = buf;
                }
            },
            else => {},
        }
    }

    return .{
        .response = .{
            .request_id = request_id,
            .status = status,
            .responded_at = responded_at,
            .steps = steps_slice,
            .rationale = rationale,
            .error_message = error_message,
        },
        ._parsed = parsed,
        ._raw_body = raw_body,
        ._allocator = allocator,
        ._steps_buf = steps_buf,
    };
}

// ── Delegation client ──────────────────────────────────────────────
// HTTP client for remote plan delegation.

pub const DelegationClient = struct {
    /// Base URL of the huginn planning endpoint.
    endpoint: []const u8,
    /// Allocator for HTTP response memory.
    allocator: Allocator,
    /// Request timeout in seconds (for plan requests and polling).
    timeout_secs: u64 = 30,
    /// Health check timeout in seconds.
    health_timeout_secs: u64 = 5,
    /// Optional API key for authentication.
    api_key: ?[]const u8 = null,

    /// Submit a planning request to the remote planner via HTTP POST.
    pub fn requestPlan(self: *const DelegationClient, req: *const PlanRequest) !ParsedPlanResponse {
        // Serialize request body
        var body_buf: [8192]u8 = undefined;
        const body = serializeRequest(&body_buf, req) orelse return error.RequestTooLarge;

        // Build auth header
        var auth_buf: [512]u8 = undefined;
        var headers_buf: [1][]const u8 = undefined;
        var header_count: usize = 0;
        if (self.api_key) |key| {
            headers_buf[0] = std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{key}) catch
                return error.AuthHeaderTooLong;
            header_count = 1;
        }

        // Build timeout string
        var timeout_str_buf: [20]u8 = undefined;
        const timeout_str: ?[]const u8 = if (self.timeout_secs > 0)
            std.fmt.bufPrint(&timeout_str_buf, "{d}", .{self.timeout_secs}) catch unreachable
        else
            null;

        // POST to plan endpoint
        const raw_body = http_util.curlPostWithProxy(
            self.allocator,
            self.endpoint,
            body,
            headers_buf[0..header_count],
            null,
            timeout_str,
        ) catch |err| {
            log.err("plan request POST to {s} failed: {}", .{ self.endpoint, err });
            return error.HttpPostFailed;
        };

        return parsePlanResponse(self.allocator, raw_body, raw_body) catch |err| {
            self.allocator.free(raw_body);
            log.err("failed to parse plan response: {}", .{err});
            return error.InvalidResponse;
        };
    }

    /// Poll for the status of a previously submitted plan request via HTTP GET.
    pub fn checkStatus(self: *const DelegationClient, request_id: []const u8) !ParsedPlanResponse {
        // Build status URL: {endpoint}/status/{request_id}
        var url_buf: [1024]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/status/{s}", .{ self.endpoint, request_id }) catch
            return error.UrlTooLong;

        // Build auth header
        var auth_buf: [512]u8 = undefined;
        var headers_buf: [1][]const u8 = undefined;
        var header_count: usize = 0;
        if (self.api_key) |key| {
            headers_buf[0] = std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}", .{key}) catch
                return error.AuthHeaderTooLong;
            header_count = 1;
        }

        // Build timeout string
        var timeout_str_buf: [20]u8 = undefined;
        const timeout_str = std.fmt.bufPrint(&timeout_str_buf, "{d}", .{self.timeout_secs}) catch unreachable;

        // GET status endpoint
        const raw_body = http_util.curlGet(
            self.allocator,
            url,
            headers_buf[0..header_count],
            timeout_str,
        ) catch |err| {
            log.err("status poll GET for {s} failed: {}", .{ request_id, err });
            return error.HttpGetFailed;
        };

        return parsePlanResponse(self.allocator, raw_body, raw_body) catch |err| {
            self.allocator.free(raw_body);
            log.err("failed to parse status response: {}", .{err});
            return error.InvalidResponse;
        };
    }

    /// Check whether the remote planner endpoint is reachable via HTTP GET.
    pub fn isReachable(self: *const DelegationClient) bool {
        // Build health URL: {endpoint}/health
        var url_buf: [1024]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "{s}/health", .{self.endpoint}) catch return false;

        // Build timeout string
        var timeout_str_buf: [20]u8 = undefined;
        const timeout_str = std.fmt.bufPrint(&timeout_str_buf, "{d}", .{self.health_timeout_secs}) catch unreachable;

        // GET health endpoint — curl -sf will fail on non-2xx
        const resp = http_util.curlGet(self.allocator, url, &.{}, timeout_str) catch return false;
        self.allocator.free(resp);
        return true;
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
pub fn delegationClientFromConfig(allocator: Allocator, cfg: config_types.DelegationConfig) DelegationClient {
    return .{
        .endpoint = cfg.endpoint,
        .allocator = allocator,
        .timeout_secs = cfg.timeout_secs,
        .api_key = cfg.api_key,
    };
}

/// Create a DelegationClient with edge-appropriate defaults.
/// Longer timeout to accommodate constrained networks.
pub fn edgeDelegationClient(allocator: Allocator, endpoint: []const u8) DelegationClient {
    return .{
        .endpoint = endpoint,
        .allocator = allocator,
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
        .allocator = std.testing.allocator,
    };
    try std.testing.expectEqualStrings("http://huginn.local:8080/plan", client.getEndpoint());
    try std.testing.expectEqual(@as(u64, 30), client.timeout_secs);
    try std.testing.expectEqual(@as(u64, 5), client.health_timeout_secs);
    try std.testing.expect(!client.hasApiKey());
}

test "DelegationClient with api key" {
    const client = DelegationClient{
        .endpoint = "http://huginn.local:8080/plan",
        .allocator = std.testing.allocator,
        .api_key = "secret-key-123",
        .timeout_secs = 60,
    };
    try std.testing.expect(client.hasApiKey());
    try std.testing.expectEqual(@as(u64, 60), client.timeout_secs);
}

test "delegationClientFromConfig" {
    const cfg = config_types.DelegationConfig{
        .endpoint = "http://huginn:9090/api/plan",
        .timeout_secs = 45,
        .api_key = "key-abc",
    };
    const client = delegationClientFromConfig(std.testing.allocator, cfg);
    try std.testing.expectEqualStrings("http://huginn:9090/api/plan", client.getEndpoint());
    try std.testing.expectEqual(@as(u64, 45), client.timeout_secs);
    try std.testing.expect(client.hasApiKey());
}

test "delegationClientFromConfig defaults" {
    const cfg = config_types.DelegationConfig{};
    const client = delegationClientFromConfig(std.testing.allocator, cfg);
    try std.testing.expectEqualStrings("http://localhost:8080/plan", client.getEndpoint());
    try std.testing.expectEqual(@as(u64, 30), client.timeout_secs);
    try std.testing.expect(!client.hasApiKey());
}

test "edgeDelegationClient" {
    const client = edgeDelegationClient(std.testing.allocator, "http://huginn-edge:8080/plan");
    try std.testing.expectEqualStrings("http://huginn-edge:8080/plan", client.getEndpoint());
    try std.testing.expectEqual(@as(u64, 60), client.timeout_secs);
    try std.testing.expect(!client.hasApiKey());
}

// ── parsePlanResponse tests ────────────────────────────────────────

test "parsePlanResponse accepted with steps" {
    const json =
        \\{"request_id":"plan-rt-001","status":"accepted","responded_at":"2026-02-22T14:00:00Z",
        \\"rationale":"two-step plan","steps":[{"seq":1,"summary":"First step","detail":"Do thing one","estimated_minutes":5},
        \\{"seq":2,"summary":"Second step"}]}
    ;
    var parsed = try parsePlanResponse(std.testing.allocator, json, null);
    defer parsed.deinit();

    const r = &parsed.response;
    try std.testing.expectEqualStrings("plan-rt-001", r.request_id);
    try std.testing.expect(r.status == .accepted);
    try std.testing.expectEqualStrings("2026-02-22T14:00:00Z", r.responded_at);
    try std.testing.expectEqualStrings("two-step plan", r.rationale.?);
    try std.testing.expect(r.error_message == null);
    try std.testing.expect(r.hasSteps());
    try std.testing.expectEqual(@as(usize, 2), r.stepCount());

    // Verify step contents
    try std.testing.expectEqual(@as(u32, 1), r.steps[0].seq);
    try std.testing.expectEqualStrings("First step", r.steps[0].summary);
    try std.testing.expectEqualStrings("Do thing one", r.steps[0].detail.?);
    try std.testing.expectEqual(@as(u32, 5), r.steps[0].estimated_minutes);

    try std.testing.expectEqual(@as(u32, 2), r.steps[1].seq);
    try std.testing.expectEqualStrings("Second step", r.steps[1].summary);
    try std.testing.expect(r.steps[1].detail == null);
    try std.testing.expectEqual(@as(u32, 0), r.steps[1].estimated_minutes);
}

test "parsePlanResponse pending no steps" {
    const json =
        \\{"request_id":"plan-rt-002","status":"pending","responded_at":"2026-02-22T14:01:00Z"}
    ;
    var parsed = try parsePlanResponse(std.testing.allocator, json, null);
    defer parsed.deinit();

    const r = &parsed.response;
    try std.testing.expectEqualStrings("plan-rt-002", r.request_id);
    try std.testing.expect(r.status == .pending);
    try std.testing.expect(!r.status.isTerminal());
    try std.testing.expect(!r.hasSteps());
    try std.testing.expect(r.rationale == null);
}

test "parsePlanResponse error with message" {
    const json =
        \\{"request_id":"plan-rt-003","status":"error","responded_at":"2026-02-22T14:02:00Z",
        \\"error_message":"planner overloaded"}
    ;
    var parsed = try parsePlanResponse(std.testing.allocator, json, null);
    defer parsed.deinit();

    const r = &parsed.response;
    try std.testing.expect(r.status == .err);
    try std.testing.expect(r.status.isTerminal());
    try std.testing.expectEqualStrings("planner overloaded", r.error_message.?);
    try std.testing.expect(!r.hasSteps());
}

test "parsePlanResponse rejected with rationale" {
    const json =
        \\{"request_id":"plan-rt-004","status":"rejected","responded_at":"2026-02-22T14:03:00Z",
        \\"rationale":"goal is out of scope"}
    ;
    var parsed = try parsePlanResponse(std.testing.allocator, json, null);
    defer parsed.deinit();

    const r = &parsed.response;
    try std.testing.expect(r.status == .rejected);
    try std.testing.expect(r.status.isTerminal());
    try std.testing.expectEqualStrings("goal is out of scope", r.rationale.?);
}

test "parsePlanResponse null optional fields" {
    const json =
        \\{"request_id":"plan-rt-005","status":"accepted","responded_at":"2026-02-22T14:04:00Z",
        \\"rationale":null,"error_message":null,"steps":[]}
    ;
    var parsed = try parsePlanResponse(std.testing.allocator, json, null);
    defer parsed.deinit();

    const r = &parsed.response;
    try std.testing.expect(r.rationale == null);
    try std.testing.expect(r.error_message == null);
    try std.testing.expect(!r.hasSteps());
}

test "parsePlanResponse invalid JSON" {
    const result = parsePlanResponse(std.testing.allocator, "not json{{{", null);
    try std.testing.expectError(error.InvalidJson, result);
}

test "parsePlanResponse missing required field" {
    // Missing status field
    const json =
        \\{"request_id":"plan-rt-006","responded_at":"2026-02-22T14:05:00Z"}
    ;
    const result = parsePlanResponse(std.testing.allocator, json, null);
    try std.testing.expectError(error.MissingField, result);
}

test "parsePlanResponse invalid status string" {
    const json =
        \\{"request_id":"plan-rt-007","status":"bogus","responded_at":"2026-02-22T14:06:00Z"}
    ;
    const result = parsePlanResponse(std.testing.allocator, json, null);
    try std.testing.expectError(error.InvalidField, result);
}

test "parsePlanResponse non-object root" {
    const result = parsePlanResponse(std.testing.allocator, "[1,2,3]", null);
    try std.testing.expectError(error.InvalidResponse, result);
}

test "parsePlanResponse step missing seq" {
    const json =
        \\{"request_id":"plan-rt-008","status":"accepted","responded_at":"2026-02-22T14:07:00Z",
        \\"steps":[{"summary":"no seq"}]}
    ;
    const result = parsePlanResponse(std.testing.allocator, json, null);
    try std.testing.expectError(error.MissingField, result);
}

test "parsePlanResponse serialize then parse roundtrip" {
    // Serialize a request, then parse a matching response
    var ser_buf: [4096]u8 = undefined;
    const req = PlanRequest{
        .id = "roundtrip-001",
        .kind = .strategy,
        .goal = "improve latency",
        .priority = .high,
        .requested_at = "2026-02-22T16:00:00Z",
        .context = "p99 is 500ms",
    };
    const body = serializeRequest(&ser_buf, &req).?;
    // Verify the serialized body is valid JSON
    const req_parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{}) catch
        return error.InvalidJson;
    defer req_parsed.deinit();

    // Build a response JSON referencing the same request ID
    const resp_json =
        \\{"request_id":"roundtrip-001","status":"accepted","responded_at":"2026-02-22T16:01:00Z",
        \\"steps":[{"seq":1,"summary":"Profile endpoints"},{"seq":2,"summary":"Add caching","estimated_minutes":30}],
        \\"rationale":"caching will reduce p99"}
    ;
    var parsed = try parsePlanResponse(std.testing.allocator, resp_json, null);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("roundtrip-001", parsed.response.request_id);
    try std.testing.expect(parsed.response.hasSteps());
    try std.testing.expectEqual(@as(usize, 2), parsed.response.stepCount());
}
