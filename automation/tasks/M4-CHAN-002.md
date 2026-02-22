# M4-CHAN-002

## Goal
Add Discord Application Command (slash command) registration and handling.

## Scope
- In `src/channels/discord.zig`:
  - Add a `registerSlashCommands()` function that PUTs to Discord's bulk overwrite endpoint (`/applications/{app_id}/commands`).
  - Register 4 commands: `/ask` (prompt), `/remember` (key+value), `/forget` (key), `/status`.
  - Handle `INTERACTION_CREATE` gateway events (type 2 = application command).
  - Parse interaction data, route to appropriate tool/agent, respond with interaction response (type 4 or 5 for deferred).
  - Add `sendInteractionResponse()` and `sendFollowup()` REST helpers.
- Add config field `application_id` to DiscordConfig.
- Add tests for interaction payload parsing and response formatting.

## Acceptance
- Slash commands registered on startup when application_id configured
- INTERACTION_CREATE events handled for all 4 commands
- Deferred responses used for long-running operations
- Tests cover interaction parsing and response format
- All existing Discord tests still pass
