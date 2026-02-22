# S2-AGENT-001

## Goal
Add a verifier hook and step-level retry policy scaffold for agent tasks.

## Scope
- Add verifier config/hook point in agent dispatch flow (disabled by default is fine).
- Add step-level retry policy types/helpers (can live in `src/tasks.zig` or agent module).
- Minimal/no change to current response behavior when disabled.

## Acceptance
- Hook exists and is config-gated
- Retry policy helpers tested/documented
