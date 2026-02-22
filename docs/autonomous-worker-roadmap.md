# Autonomous Claude Worker Roadmap

This document defines a queue-driven workflow for long-running development across multiple Claude Code sessions.

## Objective

Enable repeated, autonomous progress on a long task list by running a script that:

1. selects the next pending task,
2. launches Claude Code with explicit instructions,
3. asks Claude to implement + verify + commit + update backlog,
4. verifies outcomes,
5. exits cleanly for the next Claude run.

## Per-Repo Backlogs (Important)

Each repository owns its own autonomous queue.

- `huginn` repo -> `automation/backlog.tsv` (huginn + shared + huginn-side sync work)
- `muninn` repo -> `automation/backlog.tsv` (muninn + shared + muninn-side sync work)

Do **not** run a combined backlog across repos. That makes task ownership, verification, and commits ambiguous.

If a feature spans both repos (sync/delegation), create mirrored tasks with the same ID in both repos and implement each side independently.

## Principles

- One task per run by default (small, auditable increments)
- Repo-local backlog is the source of truth (`automation/backlog.tsv`)
- Each task has a dedicated brief (`automation/tasks/*.md`)
- Claude updates tracked backlog state and commits changes
- Runner script only manages selection, invocation, logs, and verification

## Backlog Model

Backlog file: `automation/backlog.tsv`

Columns (tab-separated):

1. `status` (`pending|done|blocked|skipped`)
2. `id` (stable task id; may be mirrored across repos)
3. `lane` (`shared|huginn|muninn|sync`)
4. `stage` (`S1|S2|S3|H1|H2|H3|M1|M2|M3|X1|X2|X3`)
5. `title`
6. `task_file` (path to detailed brief)
7. `notes` (short one-line outcome summary; edited by Claude)

## Execution Contract (Per Task)

Claude must, in a single run:

1. Implement the task defined in the task brief.
2. Run the smallest meaningful verification (tests/build/checks).
3. Update the corresponding backlog row:
   - `pending -> done` on success
   - `pending -> blocked` if blocked (with clear reason in `notes`)
4. Commit all changes (including backlog update) in one commit.
5. Exit.

## Verification by Runner Script

The runner validates:

- backlog row exists and starts as `pending`
- Claude command exits successfully
- git `HEAD` changed (new commit)
- backlog row is no longer `pending`
- working tree is clean (optional strict mode; enabled by default)

## Failure Handling

If Claude fails or exits without completing the contract:

- script records a log under `automation/runtime/runs/`
- script leaves backlog untouched (still `pending`) unless Claude changed it
- script exits non-zero
- next operator can inspect log and retry

## Task Sizing Guidelines

Good task size (for one run):

- 1-4 files changed (or a focused vertical slice)
- <1 hour runtime on target machine
- clear acceptance criteria
- easy to verify locally

Bad task size:

- whole subsystem rewrite
- mixed refactor + new feature + migration + docs all at once

## Suggested Run Cadence

- Run `scripts/claude-next-task.sh` repeatedly (one task per invocation)
- Review commits periodically
- Reorder backlog when priorities change
- Split blocked tasks into smaller follow-ups rather than forcing progress

## Bootstraping `muninn`

In the `muninn` repo, copy the same automation stack and use the template in this repo as a starting point:

- `automation/templates/muninn-backlog.tsv` -> `muninn/automation/backlog.tsv`

Then tailor task order and task briefs for `muninn` specifics.

