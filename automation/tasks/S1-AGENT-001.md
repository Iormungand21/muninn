# S1-AGENT-001

## Goal
Add persistent task state machine primitives for long-running work.

## Scope
- Add `src/tasks.zig` with task status enums and task record structs.
- Add basic serialization-ready fields (timestamps/status/steps/retries).
- No daemon integration yet.

## Acceptance
- Task structs and enums exist and are importable
- Includes minimal unit tests for enum/string or default initialization behavior where practical
