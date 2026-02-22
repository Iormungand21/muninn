# X1-SYNC-001

## Goal
Define shared sync protocol types and schema versioning for `huginn` <-> `muninn`.

## Scope
- Add `src/sync/types.zig` and/or `src/sync/protocol.zig` with event/task/memory delta payloads.
- Include node ID, sequence, schema version, timestamps.
- Add `docs/sync-protocol.md` skeleton documenting payloads.

## Acceptance
- Shared protocol types exist
- Versioning fields are explicit
