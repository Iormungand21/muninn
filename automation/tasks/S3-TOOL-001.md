# S3-TOOL-001

## Goal
Adopt the reliability framework (retries + circuit breaker) in shell, http_request, and web_search tools.

## Scope
- In `src/tools/shell.zig`, `src/tools/http_request.zig`, and `src/tools/web_search.zig`:
  - Define a `ToolPolicy` with sensible defaults (e.g., shell: 0 retries; http_request: 2 retries, 30s timeout; web_search: 1 retry, 15s timeout).
  - Wrap the core execute logic with `reliability.reliableExecute()`.
  - Maintain a module-level or per-tool `ToolHealth` for circuit breaker state.
- Remove the TODO at `src/tools/root.zig:88-90` and replace with a comment noting which tools have adopted the framework.
- Add tests verifying that the reliability wrapper is invoked (mock or verify the ToolHealth state transitions).

## Acceptance
- 3 tools wrapped with `reliableExecute()`
- Each has appropriate retry/timeout policy
- Circuit breaker state tracked per tool
- TODO in root.zig resolved
- All existing tool tests still pass
