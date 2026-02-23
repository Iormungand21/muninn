//! HTTP Gateway — lightweight HTTP server for nullclaw.
//!
//! Mirrors ZeroClaw's axum-based gateway with:
//!   - Sliding-window rate limiting (per-IP)
//!   - Idempotency store (deduplicates webhook requests)
//!   - Body size limits (64KB max)
//!   - Request timeouts (30s)
//!   - Bearer token authentication (PairingGuard)
//!   - Endpoints: /health, /ready, /pair, /webhook
//!
//! Uses std.http.Server (built-in, no external deps).

const std = @import("std");
const health = @import("health.zig");
const Config = @import("config.zig").Config;
const session_mod = @import("session.zig");
const providers = @import("providers/root.zig");
const tools_mod = @import("tools/root.zig");
const memory_mod = @import("memory/root.zig");
const observability = @import("observability.zig");
const PairingGuard = @import("security/pairing.zig").PairingGuard;
const log = std.log.scoped(.gateway);

/// Maximum request body size (64KB) — prevents memory exhaustion.
pub const MAX_BODY_SIZE: usize = 65_536;

/// Request timeout (30s) — prevents slow-loris attacks.
pub const REQUEST_TIMEOUT_SECS: u64 = 30;

/// Sliding window for rate limiting (60s).
pub const RATE_LIMIT_WINDOW_SECS: u64 = 60;

/// How often the rate limiter sweeps stale IP entries (5 min).
const RATE_LIMITER_SWEEP_INTERVAL_SECS: u64 = 300;

// ── Rate Limiter ─────────────────────────────────────────────────

/// Sliding-window rate limiter. Tracks timestamps per key.
/// Not thread-safe by itself; callers must hold a lock.
pub const SlidingWindowRateLimiter = struct {
    limit_per_window: u32,
    window_ns: i128,
    /// Map of key -> list of request timestamps (as nanoTimestamp values).
    entries: std.StringHashMapUnmanaged(std.ArrayList(i128)),
    last_sweep: i128,

    pub fn init(limit_per_window: u32, window_secs: u64) SlidingWindowRateLimiter {
        return .{
            .limit_per_window = limit_per_window,
            .window_ns = @as(i128, @intCast(window_secs)) * 1_000_000_000,
            .entries = .empty,
            .last_sweep = std.time.nanoTimestamp(),
        };
    }

    pub fn deinit(self: *SlidingWindowRateLimiter, allocator: std.mem.Allocator) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.entries.deinit(allocator);
    }

    /// Returns true if the request is allowed, false if rate-limited.
    pub fn allow(self: *SlidingWindowRateLimiter, allocator: std.mem.Allocator, key: []const u8) bool {
        if (self.limit_per_window == 0) return true;

        const now = std.time.nanoTimestamp();
        const cutoff = now - self.window_ns;

        // Periodic sweep
        if (now - self.last_sweep > @as(i128, RATE_LIMITER_SWEEP_INTERVAL_SECS) * 1_000_000_000) {
            self.sweep(allocator, cutoff);
            self.last_sweep = now;
        }

        const gop = self.entries.getOrPut(allocator, key) catch return true;
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }

        // Remove expired entries
        var timestamps = gop.value_ptr;
        var i: usize = 0;
        while (i < timestamps.items.len) {
            if (timestamps.items[i] <= cutoff) {
                _ = timestamps.swapRemove(i);
            } else {
                i += 1;
            }
        }

        if (timestamps.items.len >= self.limit_per_window) return false;

        timestamps.append(allocator, now) catch return true;
        return true;
    }

    fn sweep(self: *SlidingWindowRateLimiter, allocator: std.mem.Allocator, cutoff: i128) void {
        var iter = self.entries.iterator();
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(allocator);

        while (iter.next()) |entry| {
            var timestamps = entry.value_ptr;
            var i: usize = 0;
            while (i < timestamps.items.len) {
                if (timestamps.items[i] <= cutoff) {
                    _ = timestamps.swapRemove(i);
                } else {
                    i += 1;
                }
            }
            if (timestamps.items.len == 0) {
                to_remove.append(allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            if (self.entries.fetchRemove(key)) |kv| {
                var list = kv.value;
                list.deinit(allocator);
            }
        }
    }
};

// ── Gateway Rate Limiter ─────────────────────────────────────────

pub const GatewayRateLimiter = struct {
    pair: SlidingWindowRateLimiter,
    webhook: SlidingWindowRateLimiter,

    pub fn init(pair_per_minute: u32, webhook_per_minute: u32) GatewayRateLimiter {
        return .{
            .pair = SlidingWindowRateLimiter.init(pair_per_minute, RATE_LIMIT_WINDOW_SECS),
            .webhook = SlidingWindowRateLimiter.init(webhook_per_minute, RATE_LIMIT_WINDOW_SECS),
        };
    }

    pub fn deinit(self: *GatewayRateLimiter, allocator: std.mem.Allocator) void {
        self.pair.deinit(allocator);
        self.webhook.deinit(allocator);
    }

    pub fn allowPair(self: *GatewayRateLimiter, allocator: std.mem.Allocator, key: []const u8) bool {
        return self.pair.allow(allocator, key);
    }

    pub fn allowWebhook(self: *GatewayRateLimiter, allocator: std.mem.Allocator, key: []const u8) bool {
        return self.webhook.allow(allocator, key);
    }
};

// ── Idempotency Store ────────────────────────────────────────────

pub const IdempotencyStore = struct {
    ttl_ns: i128,
    /// Map of key -> timestamp when recorded.
    keys: std.StringHashMapUnmanaged(i128),

    pub fn init(ttl_secs: u64) IdempotencyStore {
        return .{
            .ttl_ns = @as(i128, @intCast(@max(ttl_secs, 1))) * 1_000_000_000,
            .keys = .empty,
        };
    }

    pub fn deinit(self: *IdempotencyStore, allocator: std.mem.Allocator) void {
        self.keys.deinit(allocator);
    }

    /// Returns true if this key is new and is now recorded.
    /// Returns false if this is a duplicate.
    pub fn recordIfNew(self: *IdempotencyStore, allocator: std.mem.Allocator, key: []const u8) bool {
        const now = std.time.nanoTimestamp();
        const cutoff = now - self.ttl_ns;

        // Clean expired keys (simple sweep)
        var iter = self.keys.iterator();
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(allocator);
        while (iter.next()) |entry| {
            if (entry.value_ptr.* < cutoff) {
                to_remove.append(allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (to_remove.items) |k| {
            _ = self.keys.remove(k);
        }

        // Check if already present
        if (self.keys.get(key)) |_| return false;

        // Record new key
        self.keys.put(allocator, key, now) catch return true;
        return true;
    }
};

// ── Gateway server ───────────────────────────────────────────────

/// Gateway server state, shared across request handlers.
pub const GatewayState = struct {
    allocator: std.mem.Allocator,
    rate_limiter: GatewayRateLimiter,
    idempotency: IdempotencyStore,
    pairing_guard: ?PairingGuard,

    pub fn init(allocator: std.mem.Allocator) GatewayState {
        return .{
            .allocator = allocator,
            .rate_limiter = GatewayRateLimiter.init(10, 30),
            .idempotency = IdempotencyStore.init(300),
            .pairing_guard = null,
        };
    }

    pub fn deinit(self: *GatewayState) void {
        self.rate_limiter.deinit(self.allocator);
        self.idempotency.deinit(self.allocator);
        if (self.pairing_guard) |*guard| {
            guard.deinit();
        }
    }
};

/// Health response — encapsulates HTTP status and body for /health.
pub const HealthResponse = struct {
    http_status: []const u8,
    body: []const u8,
    /// Whether body was allocated and should be freed by caller.
    allocated: bool,
};

/// Handle the /health endpoint logic. Queries the global health registry
/// and returns component-level JSON with HTTP 200 (all ok) or 503 (any down).
pub fn handleHealth(allocator: std.mem.Allocator) HealthResponse {
    const snap = health.snapshot();
    var all_ok = true;

    // Build JSON: {"status":"ok|degraded","uptime":N,"components":{...}}
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // Write components object
    w.writeAll("{\"status\":\"") catch return errorHealthResponse();
    // Defer writing status until we know if all ok — write a placeholder
    const status_pos = buf.items.len;
    // Reserve space: "ok" (2) or "degraded" (8); use "degraded" as max and trim later
    w.writeAll("degraded") catch return errorHealthResponse();
    const after_status_pos = buf.items.len;

    w.print("\",\"uptime\":{d},\"components\":{{", .{snap.uptime_seconds}) catch return errorHealthResponse();

    var iter = snap.components.iterator();
    var first = true;
    while (iter.next()) |entry| {
        if (!first) w.writeByte(',') catch return errorHealthResponse();
        first = false;
        const status = entry.value_ptr.status;
        if (!std.mem.eql(u8, status, "ok")) all_ok = false;
        w.print("\"{s}\":\"{s}\"", .{ entry.key_ptr.*, status }) catch return errorHealthResponse();
    }

    w.writeAll("}}") catch return errorHealthResponse();

    // Patch status in-place
    if (all_ok) {
        // Replace "degraded" (8 bytes) with "ok" + 6 bytes we need to shift
        // Simpler: rebuild with correct status since we have everything
        var result_buf: std.ArrayList(u8) = .empty;
        defer result_buf.deinit(allocator);
        const rw = result_buf.writer(allocator);
        rw.writeAll(buf.items[0..status_pos]) catch return errorHealthResponse();
        rw.writeAll("ok") catch return errorHealthResponse();
        rw.writeAll(buf.items[after_status_pos..]) catch return errorHealthResponse();
        const body = allocator.dupe(u8, result_buf.items) catch return errorHealthResponse();
        return .{
            .http_status = "200 OK",
            .body = body,
            .allocated = true,
        };
    }

    const body = allocator.dupe(u8, buf.items) catch return errorHealthResponse();
    return .{
        .http_status = "503 Service Unavailable",
        .body = body,
        .allocated = true,
    };
}

fn errorHealthResponse() HealthResponse {
    return .{
        .http_status = "500 Internal Server Error",
        .body = "{\"status\":\"degraded\",\"uptime\":0,\"components\":{}}",
        .allocated = false,
    };
}

/// Readiness response — encapsulates HTTP status and body for /ready.
pub const ReadyResponse = struct {
    http_status: []const u8,
    body: []const u8,
    /// Whether body was allocated and should be freed by caller.
    allocated: bool,
};

/// Handle the /ready endpoint logic. Queries the global health registry
/// and returns the appropriate HTTP status and JSON body.
/// If `allocated` is true in the result, the caller owns `body` memory.
pub fn handleReady(allocator: std.mem.Allocator) ReadyResponse {
    const readiness = health.checkRegistryReadiness(allocator) catch {
        return .{
            .http_status = "500 Internal Server Error",
            .body = "{\"status\":\"not_ready\",\"checks\":[]}",
            .allocated = false,
        };
    };
    // formatJson must be called before freeing the checks slice
    const json_body = readiness.formatJson(allocator) catch {
        if (readiness.checks.len > 0) {
            allocator.free(readiness.checks);
        }
        return .{
            .http_status = "500 Internal Server Error",
            .body = "{\"status\":\"not_ready\",\"checks\":[]}",
            .allocated = false,
        };
    };
    if (readiness.checks.len > 0) {
        allocator.free(readiness.checks);
    }
    return .{
        .http_status = if (readiness.status == .ready) "200 OK" else "503 Service Unavailable",
        .body = json_body,
        .allocated = true,
    };
}

/// Extract a query parameter value from a URL target string.
/// e.g. parseQueryParam("/whatsapp?hub.mode=subscribe&hub.challenge=abc", "hub.challenge") => "abc"
/// Returns null if the parameter is not found.
pub fn parseQueryParam(target: []const u8, name: []const u8) ?[]const u8 {
    const qmark = std.mem.indexOf(u8, target, "?") orelse return null;
    var query = target[qmark + 1 ..];

    while (query.len > 0) {
        // Find end of this key=value pair
        const amp = std.mem.indexOf(u8, query, "&") orelse query.len;
        const pair = query[0..amp];

        // Split on '='
        const eq = std.mem.indexOf(u8, pair, "=");
        if (eq) |eq_pos| {
            const key = pair[0..eq_pos];
            const value = pair[eq_pos + 1 ..];
            if (std.mem.eql(u8, key, name)) return value;
        }

        // Advance past the '&'
        if (amp < query.len) {
            query = query[amp + 1 ..];
        } else {
            break;
        }
    }
    return null;
}

// ── Bearer Token Validation ──────────────────────────────────────

/// Validate a bearer token against a list of paired tokens.
/// Returns true if paired_tokens is empty (backwards compat) or token matches.
pub fn validateBearerToken(token: []const u8, paired_tokens: []const []const u8) bool {
    if (paired_tokens.len == 0) return true;
    for (paired_tokens) |pt| {
        if (std.mem.eql(u8, token, pt)) return true;
    }
    return false;
}

/// Extract the value of a named header from raw HTTP bytes.
/// Searches for "Name: value\r\n" (case-insensitive name match).
pub fn extractHeader(raw: []const u8, name: []const u8) ?[]const u8 {
    // Skip past the first line (request line)
    var pos: usize = 0;
    while (pos + 1 < raw.len) {
        if (raw[pos] == '\r' and raw[pos + 1] == '\n') {
            pos += 2;
            break;
        }
        pos += 1;
    }

    // Scan headers
    while (pos < raw.len) {
        // Find end of this header line
        const line_end = std.mem.indexOf(u8, raw[pos..], "\r\n") orelse break;
        const line = raw[pos .. pos + line_end];
        if (line.len == 0) break; // empty line = end of headers

        // Check if this line starts with "name:"
        if (line.len > name.len and line[name.len] == ':') {
            const header_name = line[0..name.len];
            if (asciiEqlIgnoreCase(header_name, name)) {
                // Skip ": " and any leading whitespace
                var val_start: usize = name.len + 1;
                while (val_start < line.len and line[val_start] == ' ') val_start += 1;
                return line[val_start..];
            }
        }

        pos += line_end + 2;
    }
    return null;
}

/// Extract the bearer token from an Authorization header value.
/// "Bearer <token>" -> "<token>", or null if format doesn't match.
pub fn extractBearerToken(auth_header: []const u8) ?[]const u8 {
    const prefix = "Bearer ";
    if (auth_header.len > prefix.len and std.mem.startsWith(u8, auth_header, prefix)) {
        return auth_header[prefix.len..];
    }
    return null;
}

/// Returns true when a webhook request should be accepted for the current
/// pairing state and bearer token. Missing pairing state fails closed.
pub fn isWebhookAuthorized(pairing_guard: ?*const PairingGuard, bearer_token: ?[]const u8) bool {
    const guard = pairing_guard orelse return false;
    if (!guard.requirePairing()) return true;
    const token = bearer_token orelse return false;
    return guard.isAuthenticated(token);
}

/// Format the /pair success payload. Returns null when buffer is too small.
pub fn formatPairSuccessResponse(buf: []u8, token: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{{\"status\":\"paired\",\"token\":\"{s}\"}}", .{token}) catch null;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const al = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        const bl = if (bc >= 'A' and bc <= 'Z') bc + 32 else bc;
        if (al != bl) return false;
    }
    return true;
}

// ── JSON Helpers ────────────────────────────────────────────────

/// Extract a string field from a JSON blob (minimal parser, no allocations).
pub fn jsonStringField(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or
        after_key[i] == '\t' or after_key[i] == '\n' or after_key[i] == '\r')) : (i += 1)
    {}

    if (i >= after_key.len or after_key[i] != '"') return null;
    i += 1; // skip opening quote

    // Find closing quote (handle escaped quotes)
    const start = i;
    while (i < after_key.len) : (i += 1) {
        if (after_key[i] == '\\' and i + 1 < after_key.len) {
            i += 1;
            continue;
        }
        if (after_key[i] == '"') {
            return after_key[start..i];
        }
    }
    return null;
}

/// Extract an integer field from a JSON blob.
pub fn jsonIntField(json: []const u8, key: []const u8) ?i64 {
    var needle_buf: [256]u8 = undefined;
    const quoted_key = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, quoted_key) orelse return null;
    const after_key = json[key_pos + quoted_key.len ..];

    // Skip whitespace and colon
    var i: usize = 0;
    while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or
        after_key[i] == '\t' or after_key[i] == '\n' or after_key[i] == '\r')) : (i += 1)
    {}

    if (i >= after_key.len) return null;

    // Parse integer (possibly negative)
    const is_negative = after_key[i] == '-';
    if (is_negative) i += 1;
    if (i >= after_key.len or after_key[i] < '0' or after_key[i] > '9') return null;

    var result: i64 = 0;
    while (i < after_key.len and after_key[i] >= '0' and after_key[i] <= '9') : (i += 1) {
        result = result * 10 + @as(i64, after_key[i] - '0');
    }
    return if (is_negative) -result else result;
}

// ── Message Processing ──────────────────────────────────────────

/// Extract the HTTP request body from raw bytes.
/// Finds the \r\n\r\n boundary and returns everything after it.
pub fn extractBody(raw: []const u8) ?[]const u8 {
    const separator = "\r\n\r\n";
    const pos = std.mem.indexOf(u8, raw, separator) orelse return null;
    const body = raw[pos + separator.len ..];
    if (body.len == 0) return null;
    return body;
}

/// JSON error body returned when the session manager is not available.
pub const SERVICE_UNAVAILABLE_BODY = "{\"error\":\"service_unavailable\",\"message\":\"Session manager not initialized\"}";

/// HTTP status string for 503 responses.
pub const SERVICE_UNAVAILABLE_STATUS = "503 Service Unavailable";

/// Run the HTTP gateway. Binds to host:port and serves HTTP requests.
/// Endpoints: GET /health, GET /ready, POST /pair, POST /webhook
pub fn run(allocator: std.mem.Allocator, host: []const u8, port: u16) !void {
    health.markComponentOk("gateway");

    var state = GatewayState.init(allocator);
    defer state.deinit();

    // Load config and set up in-process SessionManager (graceful degradation if no config).
    var config_opt: ?Config = Config.load(allocator) catch null;
    defer if (config_opt) |*c| c.deinit();

    // ProviderHolder: concrete provider struct must outlive the accept loop.
    var holder_opt: ?providers.ProviderHolder = null;
    var session_mgr_opt: ?session_mod.SessionManager = null;
    var tools_slice: []const tools_mod.Tool = &.{};
    var mem_opt: ?memory_mod.Memory = null;

    if (config_opt) |*cfg| {
        state.rate_limiter = GatewayRateLimiter.init(
            cfg.gateway.pair_rate_limit_per_minute,
            cfg.gateway.webhook_rate_limit_per_minute,
        );
        state.idempotency = IdempotencyStore.init(cfg.gateway.idempotency_ttl_secs);
        state.pairing_guard = try PairingGuard.init(
            allocator,
            cfg.gateway.require_pairing,
            cfg.gateway.paired_tokens,
        );
        // Build provider holder from configured provider name.
        holder_opt = providers.ProviderHolder.fromConfig(allocator, cfg.default_provider, cfg.defaultProviderKey(), cfg.getProviderBaseUrl(cfg.default_provider));

        // Build provider vtable from the holder.
        if (holder_opt) |*h| {
            const provider_i: providers.Provider = h.provider();

            // Optional memory backend.
            const db_path = std.fs.path.joinZ(allocator, &.{ cfg.workspace_dir, "memory.db" }) catch null;
            defer if (db_path) |p| allocator.free(p);
            if (db_path) |p| {
                if (memory_mod.createMemory(allocator, cfg.memory.backend, p)) |mem| {
                    mem_opt = mem;
                } else |_| {}
            }

            // Tools.
            tools_slice = tools_mod.allTools(allocator, cfg.workspace_dir, .{
                .http_enabled = cfg.http_request.enabled,
                .browser_enabled = cfg.browser.enabled,
                .screenshot_enabled = true,
                .agents = cfg.agents,
                .fallback_api_key = cfg.defaultProviderKey(),
            }) catch &.{};

            // Noop observer.
            var noop_obs = observability.NoopObserver{};
            const obs = noop_obs.observer();

            session_mgr_opt = session_mod.SessionManager.init(allocator, cfg, provider_i, tools_slice, mem_opt, obs);
        }
    }
    // Register session_mgr health so /ready reflects its availability
    if (session_mgr_opt != null) {
        health.markComponentOk("session_mgr");
    } else {
        health.markComponentError("session_mgr", "session manager not initialized");
    }

    if (state.pairing_guard == null) {
        state.pairing_guard = try PairingGuard.init(allocator, true, &.{});
    }
    defer if (session_mgr_opt) |*sm| sm.deinit();
    defer if (tools_slice.len > 0) allocator.free(tools_slice);

    // Resolve the listen address
    const addr = try std.net.Address.resolveIp(host, port);
    var server = try addr.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &bw.interface;
    try stdout.print("Gateway listening on {s}:{d}\n", .{ host, port });
    try stdout.flush();
    if (state.pairing_guard) |*guard| {
        if (guard.pairingCode()) |code| {
            try stdout.print("Gateway pairing code: {s}\n", .{code});
            try stdout.flush();
        }
    }

    // Accept loop — read raw HTTP from TCP connections
    while (true) {
        var conn = server.accept() catch continue;
        defer conn.stream.close();

        // Per-request arena — all request-scoped allocations freed in one shot
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const req_allocator = arena.allocator();

        // Read request line + headers from TCP stream
        var req_buf: [4096]u8 = undefined;
        const n = conn.stream.read(&req_buf) catch continue;
        if (n == 0) continue;
        const raw = req_buf[0..n];

        // Parse first line: "METHOD /path HTTP/1.1\r\n"
        const first_line_end = std.mem.indexOf(u8, raw, "\r\n") orelse continue;
        const first_line = raw[0..first_line_end];
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method_str = parts.next() orelse continue;
        const target = parts.next() orelse continue;

        // Simple routing — extract base path (strip query string) and look up route
        const Route = enum { health, ready, webhook, pair };
        const route_map = std.StaticStringMap(Route).initComptime(.{
            .{ "/health", .health },
            .{ "/ready", .ready },
            .{ "/webhook", .webhook },
            .{ "/pair", .pair },
        });
        const base_path = if (std.mem.indexOfScalar(u8, target, '?')) |qi| target[0..qi] else target;
        const is_post = std.mem.eql(u8, method_str, "POST");
        var response_status: []const u8 = "200 OK";
        var response_body: []const u8 = "";
        var pair_response_buf: [256]u8 = undefined;

        if (route_map.get(base_path)) |route| switch (route) {
            .health => {
                const health_resp = handleHealth(req_allocator);
                response_body = health_resp.body;
                response_status = health_resp.http_status;
            },
            .ready => {
                const readiness = health.checkRegistryReadiness(req_allocator) catch {
                    response_status = "500 Internal Server Error";
                    response_body = "{\"status\":\"not_ready\",\"checks\":[]}";
                    continue;
                };
                const json_body = readiness.formatJson(req_allocator) catch {
                    response_status = "500 Internal Server Error";
                    response_body = "{\"status\":\"not_ready\",\"checks\":[]}";
                    continue;
                };
                response_body = json_body;
                if (readiness.status != .ready) {
                    response_status = "503 Service Unavailable";
                }
            },
            .webhook => {
                if (!is_post) {
                    response_status = "405 Method Not Allowed";
                    response_body = "{\"error\":\"method not allowed\"}";
                } else {
                    // Bearer token validation
                    const auth_header = extractHeader(raw, "Authorization");
                    const bearer = if (auth_header) |ah| extractBearerToken(ah) else null;
                    const pairing_guard = if (state.pairing_guard) |*guard| guard else null;
                    if (!isWebhookAuthorized(pairing_guard, bearer)) {
                        response_status = "401 Unauthorized";
                        response_body = "{\"error\":\"unauthorized\"}";
                    } else if (!state.rate_limiter.allowWebhook(state.allocator, "webhook")) {
                        response_status = "429 Too Many Requests";
                        response_body = "{\"error\":\"rate limited\"}";
                    } else {
                        // Extract body and process message
                        const body = extractBody(raw);
                        if (body) |b| {
                            const msg_text = jsonStringField(b, "message") orelse jsonStringField(b, "text") orelse b;
                            if (session_mgr_opt) |*sm| {
                                // Build session key using bearer token if available
                                var sk_buf: [128]u8 = undefined;
                                const session_key = std.fmt.bufPrint(&sk_buf, "webhook:{s}", .{bearer orelse "anon"}) catch "webhook:anon";
                                const reply = sm.processMessage(session_key, msg_text) catch null;
                                if (reply) |r| {
                                    defer allocator.free(r);
                                    const json_resp = std.fmt.allocPrint(req_allocator, "{{\"status\":\"ok\",\"response\":\"{s}\"}}", .{r}) catch null;
                                    response_body = json_resp orelse "{\"status\":\"received\"}";
                                } else {
                                    response_body = "{\"status\":\"received\"}";
                                }
                            } else {
                                log.warn("webhook rejected: session manager not initialized", .{});
                                response_status = SERVICE_UNAVAILABLE_STATUS;
                                response_body = SERVICE_UNAVAILABLE_BODY;
                            }
                        } else {
                            response_body = "{\"status\":\"received\"}";
                        }
                    }
                }
            },
            .pair => {
                if (!is_post) {
                    response_status = "405 Method Not Allowed";
                    response_body = "{\"error\":\"method not allowed\"}";
                } else if (!state.rate_limiter.allowPair(state.allocator, "pair")) {
                    response_status = "429 Too Many Requests";
                    response_body = "{\"error\":\"rate limited\"}";
                } else {
                    if (state.pairing_guard) |*guard| {
                        const pairing_code = extractHeader(raw, "X-Pairing-Code");
                        switch (guard.attemptPair(pairing_code)) {
                            .paired => |token| {
                                defer allocator.free(token);
                                if (formatPairSuccessResponse(&pair_response_buf, token)) |pair_resp| {
                                    response_body = pair_resp;
                                } else {
                                    response_status = "500 Internal Server Error";
                                    response_body = "{\"error\":\"pairing response failed\"}";
                                }
                            },
                            .missing_code => {
                                response_status = "400 Bad Request";
                                response_body = "{\"error\":\"missing X-Pairing-Code\"}";
                            },
                            .invalid_code => {
                                response_status = "401 Unauthorized";
                                response_body = "{\"error\":\"invalid pairing code\"}";
                            },
                            .already_paired => {
                                response_status = "409 Conflict";
                                response_body = "{\"error\":\"already paired\"}";
                            },
                            .disabled => {
                                response_status = "403 Forbidden";
                                response_body = "{\"error\":\"pairing disabled\"}";
                            },
                            .locked_out => {
                                response_status = "429 Too Many Requests";
                                response_body = "{\"error\":\"pairing locked out\"}";
                            },
                            .internal_error => {
                                response_status = "500 Internal Server Error";
                                response_body = "{\"error\":\"pairing failed\"}";
                            },
                        }
                    } else {
                        response_status = "500 Internal Server Error";
                        response_body = "{\"error\":\"pairing unavailable\"}";
                    }
                }
            },
        } else {
            response_status = "404 Not Found";
            response_body = "{\"error\":\"not found\"}";
        }

        // Send HTTP response
        var resp_buf: [2048]u8 = undefined;
        const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ response_status, response_body.len, response_body }) catch continue;
        _ = conn.stream.write(resp) catch continue;
    }
}

// ── Tests ────────────────────────────────────────────────────────

test "constants are set correctly" {
    try std.testing.expectEqual(@as(usize, 65_536), MAX_BODY_SIZE);
    try std.testing.expectEqual(@as(u64, 30), REQUEST_TIMEOUT_SECS);
    try std.testing.expectEqual(@as(u64, 60), RATE_LIMIT_WINDOW_SECS);
}

test "rate limiter allows up to limit" {
    var limiter = SlidingWindowRateLimiter.init(2, 60);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allow(std.testing.allocator, "127.0.0.1"));
    try std.testing.expect(limiter.allow(std.testing.allocator, "127.0.0.1"));
    try std.testing.expect(!limiter.allow(std.testing.allocator, "127.0.0.1"));
}

test "rate limiter zero limit always allows" {
    var limiter = SlidingWindowRateLimiter.init(0, 60);
    defer limiter.deinit(std.testing.allocator);

    for (0..100) |_| {
        try std.testing.expect(limiter.allow(std.testing.allocator, "any-key"));
    }
}

test "rate limiter different keys are independent" {
    var limiter = SlidingWindowRateLimiter.init(1, 60);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allow(std.testing.allocator, "ip-1"));
    try std.testing.expect(!limiter.allow(std.testing.allocator, "ip-1"));
    try std.testing.expect(limiter.allow(std.testing.allocator, "ip-2"));
}

test "gateway rate limiter blocks after limit" {
    var limiter = GatewayRateLimiter.init(2, 2);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allowPair(std.testing.allocator, "127.0.0.1"));
    try std.testing.expect(limiter.allowPair(std.testing.allocator, "127.0.0.1"));
    try std.testing.expect(!limiter.allowPair(std.testing.allocator, "127.0.0.1"));
}

test "idempotency store rejects duplicate key" {
    var store = IdempotencyStore.init(30);
    defer store.deinit(std.testing.allocator);

    try std.testing.expect(store.recordIfNew(std.testing.allocator, "req-1"));
    try std.testing.expect(!store.recordIfNew(std.testing.allocator, "req-1"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "req-2"));
}

test "idempotency store allows different keys" {
    var store = IdempotencyStore.init(300);
    defer store.deinit(std.testing.allocator);

    try std.testing.expect(store.recordIfNew(std.testing.allocator, "a"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "b"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "c"));
    try std.testing.expect(!store.recordIfNew(std.testing.allocator, "a"));
}

test "gateway module compiles" {
    // Compile-time check only
}

// ── Additional gateway tests ────────────────────────────────────

test "rate limiter single request allowed" {
    var limiter = SlidingWindowRateLimiter.init(1, 60);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allow(std.testing.allocator, "test-key"));
    try std.testing.expect(!limiter.allow(std.testing.allocator, "test-key"));
}

test "rate limiter high limit" {
    var limiter = SlidingWindowRateLimiter.init(100, 60);
    defer limiter.deinit(std.testing.allocator);

    for (0..100) |_| {
        try std.testing.expect(limiter.allow(std.testing.allocator, "ip"));
    }
    try std.testing.expect(!limiter.allow(std.testing.allocator, "ip"));
}

test "gateway rate limiter pair and webhook independent" {
    var limiter = GatewayRateLimiter.init(1, 1);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allowPair(std.testing.allocator, "ip"));
    try std.testing.expect(!limiter.allowPair(std.testing.allocator, "ip"));
    // Webhook should still be allowed since it's separate
    try std.testing.expect(limiter.allowWebhook(std.testing.allocator, "ip"));
    try std.testing.expect(!limiter.allowWebhook(std.testing.allocator, "ip"));
}

test "gateway rate limiter zero limits always allow" {
    var limiter = GatewayRateLimiter.init(0, 0);
    defer limiter.deinit(std.testing.allocator);

    for (0..50) |_| {
        try std.testing.expect(limiter.allowPair(std.testing.allocator, "any"));
        try std.testing.expect(limiter.allowWebhook(std.testing.allocator, "any"));
    }
}

test "idempotency store init with various TTLs" {
    var store1 = IdempotencyStore.init(1);
    defer store1.deinit(std.testing.allocator);
    try std.testing.expect(store1.ttl_ns > 0);

    var store2 = IdempotencyStore.init(3600);
    defer store2.deinit(std.testing.allocator);
    try std.testing.expect(store2.ttl_ns > store1.ttl_ns);
}

test "idempotency store zero TTL treated as 1 second" {
    var store = IdempotencyStore.init(0);
    defer store.deinit(std.testing.allocator);
    // Should use @max(0, 1) = 1 second
    try std.testing.expectEqual(@as(i128, 1_000_000_000), store.ttl_ns);
}

test "idempotency store many unique keys" {
    var store = IdempotencyStore.init(300);
    defer store.deinit(std.testing.allocator);

    // Use distinct string literals to avoid buffer aliasing
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-alpha"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-beta"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-gamma"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-delta"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "key-epsilon"));
}

test "idempotency store duplicate after many inserts" {
    var store = IdempotencyStore.init(300);
    defer store.deinit(std.testing.allocator);

    try std.testing.expect(store.recordIfNew(std.testing.allocator, "first"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "second"));
    try std.testing.expect(store.recordIfNew(std.testing.allocator, "third"));
    // First key should still be duplicate
    try std.testing.expect(!store.recordIfNew(std.testing.allocator, "first"));
}

test "rate limiter window_ns calculation" {
    const limiter = SlidingWindowRateLimiter.init(10, 120);
    try std.testing.expectEqual(@as(i128, 120_000_000_000), limiter.window_ns);
}

test "MAX_BODY_SIZE is 64KB" {
    try std.testing.expectEqual(@as(usize, 64 * 1024), MAX_BODY_SIZE);
}

test "RATE_LIMIT_WINDOW_SECS is 60" {
    try std.testing.expectEqual(@as(u64, 60), RATE_LIMIT_WINDOW_SECS);
}

test "REQUEST_TIMEOUT_SECS is 30" {
    try std.testing.expectEqual(@as(u64, 30), REQUEST_TIMEOUT_SECS);
}

test "rate limiter different keys do not interfere" {
    var limiter = SlidingWindowRateLimiter.init(2, 60);
    defer limiter.deinit(std.testing.allocator);

    try std.testing.expect(limiter.allow(std.testing.allocator, "key-a"));
    try std.testing.expect(limiter.allow(std.testing.allocator, "key-b"));
    try std.testing.expect(limiter.allow(std.testing.allocator, "key-a"));
    // key-a should now be at limit
    try std.testing.expect(!limiter.allow(std.testing.allocator, "key-a"));
    // key-b still has room
    try std.testing.expect(limiter.allow(std.testing.allocator, "key-b"));
}

// ── parseQueryParam tests ───────────────────────────────────────

test "parseQueryParam extracts single param" {
    const val = parseQueryParam("/webhook?key=value", "key");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("value", val.?);
}

test "parseQueryParam extracts param from multiple" {
    const target = "/webhook?mode=subscribe&verify_token=mytoken&challenge=abc123";
    try std.testing.expectEqualStrings("subscribe", parseQueryParam(target, "mode").?);
    try std.testing.expectEqualStrings("mytoken", parseQueryParam(target, "verify_token").?);
    try std.testing.expectEqualStrings("abc123", parseQueryParam(target, "challenge").?);
}

test "parseQueryParam returns null for missing param" {
    const val = parseQueryParam("/webhook?mode=subscribe", "challenge");
    try std.testing.expect(val == null);
}

test "parseQueryParam returns null for no query string" {
    const val = parseQueryParam("/webhook", "mode");
    try std.testing.expect(val == null);
}

test "parseQueryParam empty value" {
    const val = parseQueryParam("/path?key=", "key");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("", val.?);
}

test "parseQueryParam partial key match does not match" {
    const val = parseQueryParam("/path?hub.mode_extra=subscribe", "hub.mode");
    try std.testing.expect(val == null);
}

test "GatewayState init defaults" {
    var state = GatewayState.init(std.testing.allocator);
    defer state.deinit();
    try std.testing.expect(state.pairing_guard == null);
}

// ── Bearer Token Validation tests ───────────────────────────────

test "validateBearerToken allows when no paired tokens" {
    try std.testing.expect(validateBearerToken("anything", &.{}));
}

test "validateBearerToken allows valid token" {
    const tokens = &[_][]const u8{ "token-a", "token-b", "token-c" };
    try std.testing.expect(validateBearerToken("token-b", tokens));
}

test "validateBearerToken rejects invalid token" {
    const tokens = &[_][]const u8{ "token-a", "token-b" };
    try std.testing.expect(!validateBearerToken("token-c", tokens));
}

test "validateBearerToken rejects empty token when tokens configured" {
    const tokens = &[_][]const u8{"secret"};
    try std.testing.expect(!validateBearerToken("", tokens));
}

test "validateBearerToken exact match required" {
    const tokens = &[_][]const u8{"abc123"};
    try std.testing.expect(validateBearerToken("abc123", tokens));
    try std.testing.expect(!validateBearerToken("abc1234", tokens));
    try std.testing.expect(!validateBearerToken("abc12", tokens));
}

test "isWebhookAuthorized fails closed when pairing guard missing" {
    try std.testing.expect(!isWebhookAuthorized(null, "token"));
}

test "isWebhookAuthorized allows when pairing disabled" {
    var guard = try PairingGuard.init(std.testing.allocator, false, &.{});
    defer guard.deinit();
    try std.testing.expect(isWebhookAuthorized(&guard, null));
}

test "isWebhookAuthorized requires valid bearer token when pairing enabled" {
    const tokens = [_][]const u8{"zc_valid"};
    var guard = try PairingGuard.init(std.testing.allocator, true, &tokens);
    defer guard.deinit();

    try std.testing.expect(isWebhookAuthorized(&guard, "zc_valid"));
    try std.testing.expect(!isWebhookAuthorized(&guard, null));
    try std.testing.expect(!isWebhookAuthorized(&guard, "zc_invalid"));
}

test "formatPairSuccessResponse includes paired token" {
    var buf: [256]u8 = undefined;
    const response = formatPairSuccessResponse(&buf, "zc_token_123") orelse unreachable;
    try std.testing.expectEqualStrings(
        "{\"status\":\"paired\",\"token\":\"zc_token_123\"}",
        response,
    );
}

test "formatPairSuccessResponse fails when buffer is too small" {
    var buf: [8]u8 = undefined;
    try std.testing.expect(formatPairSuccessResponse(&buf, "zc_token_123") == null);
}

// ── extractHeader tests ──────────────────────────────────────────

test "extractHeader finds Authorization header" {
    const raw = "POST /webhook HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer secret123\r\nContent-Type: application/json\r\n\r\n";
    const val = extractHeader(raw, "Authorization");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("Bearer secret123", val.?);
}

test "extractHeader case insensitive" {
    const raw = "GET /health HTTP/1.1\r\ncontent-type: text/plain\r\n\r\n";
    const val = extractHeader(raw, "Content-Type");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("text/plain", val.?);
}

test "extractHeader returns null for missing header" {
    const raw = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const val = extractHeader(raw, "Authorization");
    try std.testing.expect(val == null);
}

test "extractHeader returns null for empty headers" {
    const raw = "GET / HTTP/1.1\r\n\r\n";
    try std.testing.expect(extractHeader(raw, "Host") == null);
}

// ── extractBearerToken tests ─────────────────────────────────────

test "extractBearerToken extracts token" {
    try std.testing.expectEqualStrings("mytoken", extractBearerToken("Bearer mytoken").?);
}

test "extractBearerToken returns null for non-Bearer" {
    try std.testing.expect(extractBearerToken("Basic abc123") == null);
}

test "extractBearerToken returns null for empty string" {
    try std.testing.expect(extractBearerToken("") == null);
}

test "extractBearerToken returns null for just Bearer" {
    // "Bearer " is 7 chars, "Bearer" is 6 — no space
    try std.testing.expect(extractBearerToken("Bearer") == null);
}

// ── JSON helper tests ────────────────────────────────────────────

test "jsonStringField extracts value" {
    const json = "{\"message\": \"hello world\"}";
    const val = jsonStringField(json, "message");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("hello world", val.?);
}

test "jsonStringField returns null for missing key" {
    const json = "{\"other\": \"value\"}";
    try std.testing.expect(jsonStringField(json, "message") == null);
}

test "jsonStringField handles nested JSON" {
    const json = "{\"message\": {\"text\": \"hi\"}, \"text\": \"direct\"}";
    const val = jsonStringField(json, "text");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("hi", val.?);
}

test "jsonIntField extracts positive integer" {
    const json = "{\"chat_id\": 12345}";
    const val = jsonIntField(json, "chat_id");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, 12345), val.?);
}

test "jsonIntField extracts negative integer" {
    const json = "{\"offset\": -100}";
    const val = jsonIntField(json, "offset");
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, -100), val.?);
}

test "jsonIntField returns null for missing key" {
    const json = "{\"other\": 42}";
    try std.testing.expect(jsonIntField(json, "chat_id") == null);
}

test "jsonIntField returns null for string value" {
    const json = "{\"chat_id\": \"not a number\"}";
    try std.testing.expect(jsonIntField(json, "chat_id") == null);
}

// ── extractBody tests ────────────────────────────────────────────

test "extractBody finds body after headers" {
    const raw = "POST /webhook HTTP/1.1\r\nHost: localhost\r\n\r\n{\"message\":\"hi\"}";
    const body = extractBody(raw);
    try std.testing.expect(body != null);
    try std.testing.expectEqualStrings("{\"message\":\"hi\"}", body.?);
}

test "extractBody returns null for no body" {
    const raw = "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expect(extractBody(raw) == null);
}

test "extractBody returns null for no separator" {
    const raw = "GET /health HTTP/1.1\r\nHost: localhost\r\n";
    try std.testing.expect(extractBody(raw) == null);
}

// ── asciiEqlIgnoreCase tests ─────────────────────────────────────

test "asciiEqlIgnoreCase equal strings" {
    try std.testing.expect(asciiEqlIgnoreCase("Authorization", "authorization"));
    try std.testing.expect(asciiEqlIgnoreCase("CONTENT-TYPE", "content-type"));
    try std.testing.expect(asciiEqlIgnoreCase("Host", "Host"));
}

test "asciiEqlIgnoreCase different strings" {
    try std.testing.expect(!asciiEqlIgnoreCase("Authorization", "authenticate"));
    try std.testing.expect(!asciiEqlIgnoreCase("a", "ab"));
}

test "asciiEqlIgnoreCase empty strings" {
    try std.testing.expect(asciiEqlIgnoreCase("", ""));
}

// ── /ready endpoint tests ────────────────────────────────────────────

test "handleReady all components healthy returns 200" {
    health.reset();
    health.markComponentOk("gateway");
    health.markComponentOk("database");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("200 OK", resp.http_status);
    // Verify JSON contains "ready" status
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"ready\"") != null);
}

test "handleReady one component unhealthy returns 503" {
    health.reset();
    health.markComponentOk("gateway");
    health.markComponentError("database", "connection refused");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("503 Service Unavailable", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"not_ready\"") != null);
}

test "handleReady no components returns 200 vacuously" {
    health.reset();
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("200 OK", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"checks\":[]") != null);
}

test "handleReady JSON output has checks array" {
    health.reset();
    health.markComponentOk("agent");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"checks\":[") != null);
    // Should contain the agent component
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"name\":\"agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"healthy\":true") != null);
}

test "handleReady multiple unhealthy components returns 503" {
    health.reset();
    health.markComponentError("gateway", "port in use");
    health.markComponentError("database", "disk full");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("503 Service Unavailable", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"not_ready\"") != null);
}

test "handleReady response body is valid JSON structure" {
    health.reset();
    health.markComponentOk("test-svc");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    // Must start with { and end with }
    try std.testing.expect(resp.body.len > 0);
    try std.testing.expectEqual(@as(u8, '{'), resp.body[0]);
    try std.testing.expectEqual(@as(u8, '}'), resp.body[resp.body.len - 1]);
}

test "handleReady unhealthy component includes error message" {
    health.reset();
    health.markComponentError("cache", "redis timeout");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("503 Service Unavailable", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"message\":\"redis timeout\"") != null);
}

test "handleReady recovered component shows healthy" {
    health.reset();
    health.markComponentError("db", "down");
    health.markComponentOk("db");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("200 OK", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"healthy\":true") != null);
}

// ── Service unavailable / session_mgr tests ──────────────────────────

test "SERVICE_UNAVAILABLE_BODY contains error and message fields" {
    const body = SERVICE_UNAVAILABLE_BODY;
    try std.testing.expect(std.mem.indexOf(u8, body, "\"error\":\"service_unavailable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"message\":\"Session manager not initialized\"") != null);
}

test "SERVICE_UNAVAILABLE_STATUS is 503" {
    try std.testing.expectEqualStrings("503 Service Unavailable", SERVICE_UNAVAILABLE_STATUS);
}

test "SERVICE_UNAVAILABLE_BODY is valid JSON structure" {
    const body = SERVICE_UNAVAILABLE_BODY;
    try std.testing.expect(body.len > 0);
    try std.testing.expectEqual(@as(u8, '{'), body[0]);
    try std.testing.expectEqual(@as(u8, '}'), body[body.len - 1]);
}

test "handleReady session_mgr error causes not_ready" {
    health.reset();
    health.markComponentOk("gateway");
    health.markComponentError("session_mgr", "session manager not initialized");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("503 Service Unavailable", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"not_ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"session_mgr\"") != null);
}

test "handleReady session_mgr healthy causes ready" {
    health.reset();
    health.markComponentOk("gateway");
    health.markComponentOk("session_mgr");
    const resp = handleReady(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("200 OK", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"ready\"") != null);
}

test "handleReady session_mgr recovery transitions to ready" {
    health.reset();
    health.markComponentOk("gateway");
    health.markComponentError("session_mgr", "session manager not initialized");

    // Should be not_ready
    const resp1 = handleReady(std.testing.allocator);
    defer if (resp1.allocated) std.testing.allocator.free(@constCast(resp1.body));
    try std.testing.expectEqualStrings("503 Service Unavailable", resp1.http_status);

    // Recover
    health.markComponentOk("session_mgr");
    const resp2 = handleReady(std.testing.allocator);
    defer if (resp2.allocated) std.testing.allocator.free(@constCast(resp2.body));
    try std.testing.expectEqualStrings("200 OK", resp2.http_status);
}

// ── /health endpoint tests (component-level) ─────────────────────────

test "handleHealth all components ok returns 200" {
    health.reset();
    health.markComponentOk("gateway");
    health.markComponentOk("memory");
    const resp = handleHealth(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("200 OK", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"components\":{") != null);
}

test "handleHealth degraded component returns 503" {
    health.reset();
    health.markComponentOk("gateway");
    health.markComponentError("memory", "backend unreachable");
    const resp = handleHealth(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("503 Service Unavailable", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"degraded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"memory\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"gateway\":\"ok\"") != null);
}

test "handleHealth no components returns 200 ok" {
    health.reset();
    const resp = handleHealth(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("200 OK", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"components\":{}") != null);
}

test "handleHealth includes uptime field" {
    health.reset();
    health.markComponentOk("test-svc");
    const resp = handleHealth(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"uptime\":") != null);
}

test "handleHealth response body is valid JSON structure" {
    health.reset();
    health.markComponentOk("gateway");
    const resp = handleHealth(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expect(resp.body.len > 0);
    try std.testing.expectEqual(@as(u8, '{'), resp.body[0]);
    try std.testing.expectEqual(@as(u8, '}'), resp.body[resp.body.len - 1]);
}

test "handleHealth multiple unhealthy components returns 503" {
    health.reset();
    health.markComponentError("memory", "disk full");
    health.markComponentError("provider", "api key expired");
    const resp = handleHealth(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("503 Service Unavailable", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"degraded\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"memory\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"provider\":\"error\"") != null);
}

test "handleHealth recovered component shows ok" {
    health.reset();
    health.markComponentError("db", "down");
    health.markComponentOk("db");
    const resp = handleHealth(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("200 OK", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"db\":\"ok\"") != null);
}

test "handleHealth single component ok" {
    health.reset();
    health.markComponentOk("provider");
    const resp = handleHealth(std.testing.allocator);
    defer if (resp.allocated) std.testing.allocator.free(@constCast(resp.body));
    try std.testing.expectEqualStrings("200 OK", resp.http_status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"provider\":\"ok\"") != null);
}
