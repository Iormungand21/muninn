//! Channel Loop — shared runtime dependencies for daemon-supervised channels.
//!
//! Contains `ChannelRuntime` (shared dependencies for message processing).

const std = @import("std");
const Config = @import("config.zig").Config;
const session_mod = @import("session.zig");
const providers = @import("providers/root.zig");
const memory_mod = @import("memory/root.zig");
const observability = @import("observability.zig");
const tools_mod = @import("tools/root.zig");
const mcp = @import("mcp.zig");

const log = std.log.scoped(.channel_loop);

// Re-export centralized ProviderHolder from providers module.
pub const ProviderHolder = providers.ProviderHolder;

// ════════════════════════════════════════════════════════════════════════════
// ChannelRuntime — container for polling-thread dependencies
// ════════════════════════════════════════════════════════════════════════════

pub const ChannelRuntime = struct {
    allocator: std.mem.Allocator,
    session_mgr: session_mod.SessionManager,
    provider_holder: *ProviderHolder,
    tools: []const tools_mod.Tool,
    mem: ?memory_mod.Memory,
    noop_obs: *observability.NoopObserver,

    /// Initialize the runtime from config.
    pub fn init(allocator: std.mem.Allocator, config: *const Config) !*ChannelRuntime {
        // Provider — heap-allocated for vtable pointer stability
        const holder = try allocator.create(ProviderHolder);
        errdefer allocator.destroy(holder);

        holder.* = ProviderHolder.fromConfig(allocator, config.default_provider, config.defaultProviderKey(), config.getProviderBaseUrl(config.default_provider));

        const provider_i = holder.provider();

        // MCP tools
        const mcp_tools: ?[]const tools_mod.Tool = if (config.mcp_servers.len > 0)
            mcp.initMcpTools(allocator, config.mcp_servers) catch |err| blk: {
                log.warn("MCP init failed: {}", .{err});
                break :blk null;
            }
        else
            null;

        // Tools
        const tools = tools_mod.allTools(allocator, config.workspace_dir, .{
            .http_enabled = config.http_request.enabled,
            .browser_enabled = config.browser.enabled,
            .screenshot_enabled = true,
            .mcp_tools = mcp_tools,
            .agents = config.agents,
            .fallback_api_key = config.defaultProviderKey(),
            .tools_config = config.tools,
        }) catch &.{};
        errdefer if (tools.len > 0) allocator.free(tools);

        // Optional memory backend
        var mem_opt: ?memory_mod.Memory = null;
        const db_path = std.fs.path.joinZ(allocator, &.{ config.workspace_dir, "memory.db" }) catch null;
        defer if (db_path) |p| allocator.free(p);
        if (db_path) |p| {
            if (memory_mod.createMemory(allocator, config.memory.backend, p)) |mem| {
                mem_opt = mem;
            } else |_| {}
        }

        // Noop observer (heap for vtable stability)
        const noop_obs = try allocator.create(observability.NoopObserver);
        errdefer allocator.destroy(noop_obs);
        noop_obs.* = .{};
        const obs = noop_obs.observer();

        // Session manager
        const session_mgr = session_mod.SessionManager.init(allocator, config, provider_i, tools, mem_opt, obs);

        // Self — heap-allocated so pointers remain stable
        const self = try allocator.create(ChannelRuntime);
        self.* = .{
            .allocator = allocator,
            .session_mgr = session_mgr,
            .provider_holder = holder,
            .tools = tools,
            .mem = mem_opt,
            .noop_obs = noop_obs,
        };
        return self;
    }

    pub fn deinit(self: *ChannelRuntime) void {
        const alloc = self.allocator;
        self.session_mgr.deinit();
        if (self.tools.len > 0) alloc.free(self.tools);
        alloc.destroy(self.noop_obs);
        alloc.destroy(self.provider_holder);
        alloc.destroy(self);
    }
};

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "ProviderHolder tagged union fields" {
    // Compile-time check that ProviderHolder has expected variants
    try std.testing.expect(@hasField(ProviderHolder, "openrouter"));
    try std.testing.expect(@hasField(ProviderHolder, "anthropic"));
    try std.testing.expect(@hasField(ProviderHolder, "openai"));
    try std.testing.expect(@hasField(ProviderHolder, "gemini"));
    try std.testing.expect(@hasField(ProviderHolder, "ollama"));
    try std.testing.expect(@hasField(ProviderHolder, "compatible"));
    try std.testing.expect(@hasField(ProviderHolder, "openai_codex"));
}
