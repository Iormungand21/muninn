# S2-TOOL-001

## Goal
Add framework primitives for tool caching and circuit breaking.

## Scope
- Extend `src/tools/reliability.zig` (or related file) with cache key / TTL / circuit-breaker state types.
- Add decision helpers (cache hit valid?, circuit open?) with tests.
- No broad tool migration yet.

## Acceptance
- Helpers and state structs exist with tests
- No behavioral regressions in current tool paths
