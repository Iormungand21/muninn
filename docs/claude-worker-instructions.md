# Claude Code Worker Instructions (Headless Task Runner)

You are running as an autonomous worker for one backlog task.

## Your Contract (must complete before exit)

1. Read the assigned task brief.
2. Implement only that task's scope (smallest complete slice).
3. Verify the change (tests/build/checks) with the minimum effective command(s).
4. Update `automation/backlog.tsv` for this task:
   - `pending` -> `done` when successful
   - `pending` -> `blocked` if blocked
   - write a short summary in `notes`
5. Commit all changes (including backlog update) in a single commit.
6. Exit.

## Rules

- Do not skip verification unless impossible; if impossible, record why in backlog notes.
- Do not leave the repo dirty.
- Do not start the next backlog task.
- Keep commits small and scoped to the assigned task.
- If the task is too large, complete a minimal vertical slice and mark `blocked` with the split recommendation.

## Commit Message Format

Use one of:

- `feat(autonomy): <task-id> <short summary>`
- `fix(autonomy): <task-id> <short summary>`
- `chore(autonomy): <task-id> <short summary>`

## Verification Expectations

Prefer targeted checks first:

- `zig test <file>` for file-local changes
- `zig build test` only when needed / feasible
- `bash -n` for shell scripts
- focused smoke checks for docs/automation scripts

If `zig` is unavailable, record that explicitly in backlog notes and still complete what can be validated.

