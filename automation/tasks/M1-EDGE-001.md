# M1-EDGE-001

## Goal
Create lean defaults for `muninn` edge mode: compact logs and bounded queueing.

## Scope
- Add config/profile defaults or helper constants for compact event logging and strict task queue caps.
- Document edge-mode constraints in code comments/docs.
- Avoid platform-specific hardware changes in this task.

## Acceptance
- Edge defaults are codified in config/profile helpers or docs
- No heavy runtime overhead added
