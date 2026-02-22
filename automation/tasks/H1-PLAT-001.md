# H1-PLAT-001

## Goal
Optimize `huginn` bring-up for software-only Raspberry Pi use.

## Scope
- Add a software-first diagnostics mode or config flag to reduce hardware warning noise in `doctor`/status.
- Document/encode `huginn` profile defaults for software-only Pi bring-up.
- Preserve hardware support, just de-prioritize warnings and defaults.

## Acceptance
- `doctor` supports quieter software-only path (or equivalent config-driven behavior)
- Docs/config changes make Pi bring-up easier without touching hardware features
