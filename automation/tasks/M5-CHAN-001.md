# M5-CHAN-001

## Goal
Add Discord thread support for long conversations.

## Scope
- In `src/channels/discord.zig`:
  - Detect when an incoming message is in a thread (has `message_reference` field).
  - When replying to a thread message, send the response to the same thread.
  - Add `createThread()` helper: POST to `/channels/{id}/messages/{msg_id}/threads` with auto-archive duration.
  - Optionally auto-create threads when a conversation exceeds a configurable turn count (default: 5 turns).
  - Track per-channel conversation turn counts.
- Add `auto_thread_after` config field to DiscordConfig (default: 0 = disabled).
- Add tests for thread detection, thread creation URL building, and turn counting.

## Acceptance
- Thread messages get in-thread replies
- `createThread()` helper works with correct API endpoint
- Auto-threading configurable and disabled by default
- Tests cover thread detection and URL building
- All existing Discord tests still pass
