# S1-TOOL-001

## Goal
Create a tool reliability wrapper skeleton for retries/timeouts/health state.

## Scope
- Add `src/tools/reliability.zig` with `ToolPolicy`, `ToolHealth`, and a wrapper API skeleton.
- Wire minimal integration point in `src/tools/root.zig` (import and TODO hook is acceptable).
- Do not refactor all tools yet.

## Acceptance
- New module compiles/syntax-valid
- Wrapper API is documented and ready for incremental adoption
