//! Secret scoping and per-workspace approval policy primitives.
//!
//! Provides config types and lookup helpers for:
//! - Restricting which secrets are visible to which workspaces/channels
//! - Overriding global approval policy on a per-workspace basis
//!
//! These are skeleton primitives for later enforcement integration.
//! The types parse safely with backward-compatible defaults.

const std = @import("std");
const AutonomyLevel = @import("policy.zig").AutonomyLevel;

// ── Secret scope ────────────────────────────────────────────────────

/// Visibility scope for a secret (API key, token, etc.).
pub const SecretScope = enum {
    /// Available to all workspaces and channels.
    global,
    /// Restricted to the owning workspace only.
    workspace,
    /// Restricted to a specific channel type (e.g. telegram, discord).
    channel,

    pub fn default() SecretScope {
        return .global;
    }

    pub fn toString(self: SecretScope) []const u8 {
        return switch (self) {
            .global => "global",
            .workspace => "workspace",
            .channel => "channel",
        };
    }

    pub fn fromString(s: []const u8) ?SecretScope {
        if (std.mem.eql(u8, s, "global")) return .global;
        if (std.mem.eql(u8, s, "workspace")) return .workspace;
        if (std.mem.eql(u8, s, "channel")) return .channel;
        return null;
    }
};

/// A secret entry with scope restrictions.
/// When `scope` is `.global`, the secret is available everywhere.
/// When `.workspace`, only workspaces listed in `allowed_workspaces` may access it
/// (empty list = owning workspace only).
/// When `.channel`, only channels listed in `allowed_channels` may access it.
pub const ScopedSecretEntry = struct {
    /// Identifier for this secret (e.g. "openai_api_key", "telegram_bot_token").
    name: []const u8 = "",
    /// Visibility scope.
    scope: SecretScope = .global,
    /// Workspace IDs that may access this secret (scope = .workspace).
    /// Empty means only the owning workspace.
    allowed_workspaces: []const []const u8 = &.{},
    /// Channel identifiers that may access this secret (scope = .channel).
    /// Empty means all channels (when scope != .channel).
    allowed_channels: []const []const u8 = &.{},
};

// ── Workspace approval policy ───────────────────────────────────────

/// Per-workspace overrides for the global approval/autonomy policy.
/// Any `null` field means "inherit from global defaults".
pub const WorkspaceApprovalPolicy = struct {
    /// Workspace identifier this policy applies to.
    workspace_id: []const u8 = "",
    /// Override global autonomy level for this workspace.
    autonomy: ?AutonomyLevel = null,
    /// Override whether medium-risk commands require approval.
    require_approval_for_medium_risk: ?bool = null,
    /// Override whether high-risk commands are blocked.
    block_high_risk_commands: ?bool = null,
    /// Override the per-hour rate limit.
    max_actions_per_hour: ?u32 = null,
    /// Additional allowed commands (merged with global allowlist during enforcement).
    additional_commands: []const []const u8 = &.{},
};

// ── Lookup helpers (skeletons for later enforcement) ────────────────

/// Check whether a scoped secret is accessible from the given workspace and channel.
///
/// Rules:
/// - `.global` scope: always accessible.
/// - `.workspace` scope: accessible if `workspace_id` is in `allowed_workspaces`,
///   or if `allowed_workspaces` is empty (owning workspace — caller must verify ownership).
/// - `.channel` scope: accessible if `channel_id` is in `allowed_channels`,
///   or if `allowed_channels` is empty (all channels).
pub fn isSecretAccessible(
    entry: *const ScopedSecretEntry,
    workspace_id: []const u8,
    channel_id: []const u8,
) bool {
    switch (entry.scope) {
        .global => return true,
        .workspace => {
            if (entry.allowed_workspaces.len == 0) {
                // Empty list = owning workspace only; caller verifies ownership.
                // Skeleton: return true so that the owning-workspace check can be
                // layered on top by the enforcement code.
                return true;
            }
            for (entry.allowed_workspaces) |ws| {
                if (std.mem.eql(u8, ws, workspace_id)) return true;
            }
            return false;
        },
        .channel => {
            if (entry.allowed_channels.len == 0) return true;
            for (entry.allowed_channels) |ch| {
                if (std.mem.eql(u8, ch, channel_id)) return true;
            }
            return false;
        },
    }
}

/// Find the workspace-specific approval policy for the given workspace ID.
/// Returns null if no override exists (use global defaults).
pub fn findWorkspacePolicy(
    policies: []const WorkspaceApprovalPolicy,
    workspace_id: []const u8,
) ?*const WorkspaceApprovalPolicy {
    for (policies) |*p| {
        if (std.mem.eql(u8, p.workspace_id, workspace_id)) return p;
    }
    return null;
}

/// Resolve the effective autonomy level for a workspace.
/// Workspace override takes precedence over the global default.
pub fn resolveAutonomy(
    global: AutonomyLevel,
    workspace_policy: ?*const WorkspaceApprovalPolicy,
) AutonomyLevel {
    if (workspace_policy) |wp| {
        if (wp.autonomy) |level| return level;
    }
    return global;
}

/// Resolve whether medium-risk commands require approval for a workspace.
pub fn resolveApprovalForMediumRisk(
    global: bool,
    workspace_policy: ?*const WorkspaceApprovalPolicy,
) bool {
    if (workspace_policy) |wp| {
        if (wp.require_approval_for_medium_risk) |v| return v;
    }
    return global;
}

/// Resolve whether high-risk commands are blocked for a workspace.
pub fn resolveBlockHighRisk(
    global: bool,
    workspace_policy: ?*const WorkspaceApprovalPolicy,
) bool {
    if (workspace_policy) |wp| {
        if (wp.block_high_risk_commands) |v| return v;
    }
    return global;
}

/// Resolve the effective rate limit for a workspace.
pub fn resolveMaxActionsPerHour(
    global: u32,
    workspace_policy: ?*const WorkspaceApprovalPolicy,
) u32 {
    if (workspace_policy) |wp| {
        if (wp.max_actions_per_hour) |v| return v;
    }
    return global;
}

// ── Tests ───────────────────────────────────────────────────────────

test "SecretScope default is global" {
    try std.testing.expectEqual(SecretScope.global, SecretScope.default());
}

test "SecretScope toString roundtrip" {
    const scopes = [_]SecretScope{ .global, .workspace, .channel };
    for (scopes) |s| {
        const str = s.toString();
        try std.testing.expect(str.len > 0);
        try std.testing.expect(SecretScope.fromString(str).? == s);
    }
    try std.testing.expect(SecretScope.fromString("bogus") == null);
    try std.testing.expect(SecretScope.fromString("") == null);
}

test "SecretScope toString values" {
    try std.testing.expectEqualStrings("global", SecretScope.global.toString());
    try std.testing.expectEqualStrings("workspace", SecretScope.workspace.toString());
    try std.testing.expectEqualStrings("channel", SecretScope.channel.toString());
}

test "ScopedSecretEntry defaults" {
    const entry = ScopedSecretEntry{};
    try std.testing.expectEqual(SecretScope.global, entry.scope);
    try std.testing.expectEqual(@as(usize, 0), entry.allowed_workspaces.len);
    try std.testing.expectEqual(@as(usize, 0), entry.allowed_channels.len);
}

test "isSecretAccessible: global scope always accessible" {
    const entry = ScopedSecretEntry{ .name = "api_key", .scope = .global };
    try std.testing.expect(isSecretAccessible(&entry, "ws1", "telegram"));
    try std.testing.expect(isSecretAccessible(&entry, "", ""));
    try std.testing.expect(isSecretAccessible(&entry, "any", "any"));
}

test "isSecretAccessible: workspace scope empty list" {
    const entry = ScopedSecretEntry{ .name = "key", .scope = .workspace };
    // Empty allowed_workspaces = owning workspace only (skeleton returns true)
    try std.testing.expect(isSecretAccessible(&entry, "owner_ws", "telegram"));
}

test "isSecretAccessible: workspace scope with explicit list" {
    const allowed = [_][]const u8{ "ws_alpha", "ws_beta" };
    const entry = ScopedSecretEntry{
        .name = "restricted_key",
        .scope = .workspace,
        .allowed_workspaces = &allowed,
    };
    try std.testing.expect(isSecretAccessible(&entry, "ws_alpha", "any"));
    try std.testing.expect(isSecretAccessible(&entry, "ws_beta", "any"));
    try std.testing.expect(!isSecretAccessible(&entry, "ws_gamma", "any"));
    try std.testing.expect(!isSecretAccessible(&entry, "", "any"));
}

test "isSecretAccessible: channel scope empty list" {
    const entry = ScopedSecretEntry{ .name = "key", .scope = .channel };
    // Empty allowed_channels = all channels
    try std.testing.expect(isSecretAccessible(&entry, "ws1", "telegram"));
    try std.testing.expect(isSecretAccessible(&entry, "ws1", "discord"));
}

test "isSecretAccessible: channel scope with explicit list" {
    const allowed = [_][]const u8{ "telegram", "slack" };
    const entry = ScopedSecretEntry{
        .name = "bot_token",
        .scope = .channel,
        .allowed_channels = &allowed,
    };
    try std.testing.expect(isSecretAccessible(&entry, "ws1", "telegram"));
    try std.testing.expect(isSecretAccessible(&entry, "ws1", "slack"));
    try std.testing.expect(!isSecretAccessible(&entry, "ws1", "discord"));
    try std.testing.expect(!isSecretAccessible(&entry, "ws1", "irc"));
}

test "WorkspaceApprovalPolicy defaults" {
    const policy = WorkspaceApprovalPolicy{};
    try std.testing.expectEqualStrings("", policy.workspace_id);
    try std.testing.expect(policy.autonomy == null);
    try std.testing.expect(policy.require_approval_for_medium_risk == null);
    try std.testing.expect(policy.block_high_risk_commands == null);
    try std.testing.expect(policy.max_actions_per_hour == null);
    try std.testing.expectEqual(@as(usize, 0), policy.additional_commands.len);
}

test "findWorkspacePolicy: found" {
    const policies = [_]WorkspaceApprovalPolicy{
        .{ .workspace_id = "dev", .autonomy = .full },
        .{ .workspace_id = "prod", .autonomy = .read_only },
    };
    const found = findWorkspacePolicy(&policies, "prod").?;
    try std.testing.expectEqualStrings("prod", found.workspace_id);
    try std.testing.expect(found.autonomy.? == .read_only);
}

test "findWorkspacePolicy: not found returns null" {
    const policies = [_]WorkspaceApprovalPolicy{
        .{ .workspace_id = "dev" },
    };
    try std.testing.expect(findWorkspacePolicy(&policies, "staging") == null);
}

test "findWorkspacePolicy: empty list returns null" {
    const policies = [_]WorkspaceApprovalPolicy{};
    try std.testing.expect(findWorkspacePolicy(&policies, "any") == null);
}

test "resolveAutonomy: no override uses global" {
    try std.testing.expectEqual(AutonomyLevel.supervised, resolveAutonomy(.supervised, null));
    try std.testing.expectEqual(AutonomyLevel.full, resolveAutonomy(.full, null));
}

test "resolveAutonomy: workspace override takes precedence" {
    const wp = WorkspaceApprovalPolicy{ .workspace_id = "prod", .autonomy = .read_only };
    try std.testing.expectEqual(AutonomyLevel.read_only, resolveAutonomy(.full, &wp));
}

test "resolveAutonomy: null override inherits global" {
    const wp = WorkspaceApprovalPolicy{ .workspace_id = "dev" };
    try std.testing.expectEqual(AutonomyLevel.supervised, resolveAutonomy(.supervised, &wp));
}

test "resolveApprovalForMediumRisk: no override" {
    try std.testing.expect(resolveApprovalForMediumRisk(true, null));
    try std.testing.expect(!resolveApprovalForMediumRisk(false, null));
}

test "resolveApprovalForMediumRisk: override" {
    const wp = WorkspaceApprovalPolicy{
        .workspace_id = "dev",
        .require_approval_for_medium_risk = false,
    };
    try std.testing.expect(!resolveApprovalForMediumRisk(true, &wp));
}

test "resolveBlockHighRisk: no override" {
    try std.testing.expect(resolveBlockHighRisk(true, null));
    try std.testing.expect(!resolveBlockHighRisk(false, null));
}

test "resolveBlockHighRisk: override" {
    const wp = WorkspaceApprovalPolicy{
        .workspace_id = "staging",
        .block_high_risk_commands = false,
    };
    try std.testing.expect(!resolveBlockHighRisk(true, &wp));
}

test "resolveMaxActionsPerHour: no override" {
    try std.testing.expectEqual(@as(u32, 20), resolveMaxActionsPerHour(20, null));
}

test "resolveMaxActionsPerHour: override" {
    const wp = WorkspaceApprovalPolicy{
        .workspace_id = "dev",
        .max_actions_per_hour = 100,
    };
    try std.testing.expectEqual(@as(u32, 100), resolveMaxActionsPerHour(20, &wp));
}

test "end-to-end: lookup then resolve" {
    const policies = [_]WorkspaceApprovalPolicy{
        .{ .workspace_id = "dev", .autonomy = .full, .max_actions_per_hour = 100 },
        .{ .workspace_id = "prod", .autonomy = .read_only, .block_high_risk_commands = true },
    };
    // Dev workspace
    const dev = findWorkspacePolicy(&policies, "dev");
    try std.testing.expectEqual(AutonomyLevel.full, resolveAutonomy(.supervised, dev));
    try std.testing.expectEqual(@as(u32, 100), resolveMaxActionsPerHour(20, dev));
    // Prod workspace
    const prod = findWorkspacePolicy(&policies, "prod");
    try std.testing.expectEqual(AutonomyLevel.read_only, resolveAutonomy(.supervised, prod));
    try std.testing.expect(resolveBlockHighRisk(false, prod));
    // Unknown workspace — falls back to global
    const unknown = findWorkspacePolicy(&policies, "staging");
    try std.testing.expectEqual(AutonomyLevel.supervised, resolveAutonomy(.supervised, unknown));
    try std.testing.expectEqual(@as(u32, 20), resolveMaxActionsPerHour(20, unknown));
}
