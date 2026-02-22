# M5-TOOL-001

## Goal
Add per-tool timeout configuration and tool usage analytics tracking.

## Scope
- In `src/config_types.zig`, add `ToolConfig` struct with optional per-tool timeout_ms settings (e.g., `tools.timeouts.shell = 30000`).
- In `src/tools/root.zig`, add a `ToolStats` struct tracking per-tool: invocation count, success count, failure count, total latency.
- Update the `Tool` execution path to:
  - Enforce per-tool timeout from config (default: 120s for shell, 60s for http_request, 30s for others).
  - Record execution stats after each tool call.
- Add `toolStats()` function returning current stats for all tools.
- Wire into `nullclaw status` output (add "Tools: N invocations, M failures" line).
- Add tests for stats tracking and timeout configuration.

## Acceptance
- Per-tool timeout configurable in config.json
- Tool stats tracked (count, success, failure, latency)
- Stats visible in `nullclaw status`
- Tests cover stats accumulation and timeout config parsing
- All existing tests still pass
