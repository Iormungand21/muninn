# H3-ORCH-001

## Goal
Prepare `huginn` daemon for planner/executor/verifier orchestration.

## Scope
- Add orchestrator pipeline structs/interfaces for planner/executor/verifier stages.
- Integrate a no-op/default path in daemon or agent dispatch so behavior is unchanged unless enabled.
- Keep task orchestration minimal and safe.

## Acceptance
- Pipeline interfaces/types exist and compile
- Default runtime behavior unchanged when feature disabled
