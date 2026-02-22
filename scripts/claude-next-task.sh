#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKLOG="${BACKLOG:-$ROOT_DIR/automation/backlog.tsv}"
INSTR_DOC="${INSTR_DOC:-$ROOT_DIR/docs/claude-worker-instructions.md}"
RUNTIME_DIR="${RUNTIME_DIR:-$ROOT_DIR/automation/runtime}"
RUNS_DIR="$RUNTIME_DIR/runs"
LOCK_FILE="$RUNTIME_DIR/worker.lock"
STRICT_CLEAN="${STRICT_CLEAN:-1}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
CLAUDE_CMD="${CLAUDE_CMD:-claude -p}"
MAX_TASKS="${MAX_TASKS:-1}"
CURRENT_PROMPT_FILE=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--loop] [--max-tasks N] [--allow-dirty] [--no-strict-clean]

Environment overrides:
  CLAUDE_CMD     Command used to invoke Claude Code headlessly (default: 'claude -p')
  BACKLOG        Path to backlog.tsv
  INSTR_DOC      Path to worker instructions doc
  RUNTIME_DIR    Runtime logs/locks dir
  STRICT_CLEAN   1=require clean tree after run (default), 0=skip
  ALLOW_DIRTY    1=allow starting with dirty tree (default 0)
USAGE
}

LOOP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --loop)
      LOOP=1
      shift
      ;;
    --max-tasks)
      MAX_TASKS="$2"
      shift 2
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --no-strict-clean)
      STRICT_CLEAN=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

mkdir -p "$RUNS_DIR"

if [[ ! -f "$BACKLOG" ]]; then
  echo "Backlog not found: $BACKLOG" >&2
  exit 1
fi
if [[ ! -f "$INSTR_DOC" ]]; then
  echo "Instruction doc not found: $INSTR_DOC" >&2
  exit 1
fi

cd "$ROOT_DIR"

if [[ -e "$LOCK_FILE" ]]; then
  echo "Lock file exists: $LOCK_FILE" >&2
  echo "Remove it if no worker is running." >&2
  exit 1
fi

cleanup() {
  rm -f "$LOCK_FILE" "${CURRENT_PROMPT_FILE:-}" 2>/dev/null || true
}
trap cleanup EXIT

echo $$ > "$LOCK_FILE"

get_next_task_row() {
  awk -F '\t' '
    /^[[:space:]]*#/ { next }
    NF < 6 { next }
    $1 == "pending" { print; exit }
  ' "$BACKLOG"
}

get_task_field() {
  local row="$1"
  local idx="$2"
  printf '%s\n' "$row" | awk -F '\t' -v i="$idx" '{ print $i }'
}

verify_backlog_status() {
  local task_id="$1"
  awk -F '\t' -v id="$task_id" '
    /^[[:space:]]*#/ { next }
    $2 == id { print $1; found=1; exit }
    END { if (!found) exit 2 }
  ' "$BACKLOG"
}

run_one_task() {
  local row task_id lane stage title task_file
  row="$(get_next_task_row || true)"
  if [[ -z "$row" ]]; then
    echo "No pending tasks in $BACKLOG"
    return 10
  fi

  task_id="$(get_task_field "$row" 2)"
  lane="$(get_task_field "$row" 3)"
  stage="$(get_task_field "$row" 4)"
  title="$(get_task_field "$row" 5)"
  task_file="$(get_task_field "$row" 6)"

  if [[ ! -f "$ROOT_DIR/$task_file" ]]; then
    echo "Task file missing for $task_id: $task_file" >&2
    return 1
  fi

  if [[ "$ALLOW_DIRTY" != "1" ]] && [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is dirty before run. Commit/stash first, or pass --allow-dirty." >&2
    return 1
  fi

  local before_head after_head run_ts run_name log_file prompt_text prompt_escaped
  before_head="$(git rev-parse HEAD)"
  run_ts="$(date -u +%Y%m%dT%H%M%SZ)"
  run_name="${run_ts}_${task_id}"
  log_file="$RUNS_DIR/${run_name}.log"
  CURRENT_PROMPT_FILE="$RUNS_DIR/${run_name}.prompt.txt"

  cat > "$CURRENT_PROMPT_FILE" <<PROMPT
You are running in repository: $ROOT_DIR

Assigned backlog task:
- id: $task_id
- lane: $lane
- stage: $stage
- title: $title
- task_file: $task_file

Read and follow these instructions first:
- $INSTR_DOC

Then complete the assigned task from:
- $ROOT_DIR/$task_file

Backlog file to update:
- $BACKLOG

Requirements:
- Complete exactly this one task
- Run verification commands appropriate to the changes
- Update the backlog row for $task_id from pending -> done (or blocked with reason)
- Commit all changes in one commit
- Exit when finished
PROMPT

  {
    echo "=== Run $run_name ==="
    echo "Task: $task_id | $title"
    echo "Claude command: $CLAUDE_CMD"
    echo
  } > "$log_file"

  prompt_text="$(cat "$CURRENT_PROMPT_FILE")"
  prompt_escaped="$(printf '%q' "$prompt_text")"

  echo "Running task $task_id: $title"
  if ! bash -lc "$CLAUDE_CMD $prompt_escaped" >> "$log_file" 2>&1; then
    echo "Claude command failed. See log: $log_file" >&2
    return 1
  fi

  after_head="$(git rev-parse HEAD)"
  if [[ "$after_head" == "$before_head" ]]; then
    echo "No new commit detected after Claude run. See log: $log_file" >&2
    return 1
  fi

  local status
  if ! status="$(verify_backlog_status "$task_id")"; then
    echo "Could not find backlog row for task $task_id after run." >&2
    return 1
  fi
  if [[ "$status" == "pending" ]]; then
    echo "Backlog row for $task_id still pending after Claude run. See log: $log_file" >&2
    return 1
  fi

  if [[ "$STRICT_CLEAN" == "1" ]] && [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree not clean after Claude run (STRICT_CLEAN=1)." >&2
    echo "See log: $log_file" >&2
    return 1
  fi

  {
    echo
    echo "=== Verification ==="
    echo "Before HEAD: $before_head"
    echo "After  HEAD: $after_head"
    echo "Backlog status: $status"
    git --no-pager log --oneline -n 1
  } >> "$log_file"

  echo "Completed $task_id -> $status"
  echo "Commit: $(git rev-parse --short HEAD)"
  echo "Log: $log_file"
  return 0
}

tasks_done=0
while :; do
  if run_one_task; then
    tasks_done=$((tasks_done + 1))
  else
    rc=$?
    if [[ $rc -eq 10 ]]; then
      echo "Runner finished: no pending tasks."
      exit 0
    fi
    exit "$rc"
  fi

  if [[ "$LOOP" != "1" ]]; then
    break
  fi
  if [[ "$tasks_done" -ge "$MAX_TASKS" ]]; then
    break
  fi
done

echo "Runner finished after $tasks_done task(s)."
