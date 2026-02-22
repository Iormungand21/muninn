# M4-CHAN-001

## Goal
Implement Slack Socket Mode for real-time message receiving.

## Scope
- In `src/channels/slack.zig`:
  - Implement `vtableStart()`: open a WebSocket connection to Slack's Socket Mode URL (`wss://wss-primary.slack.com/link`).
  - Use the app-level token (`xapp-...`) to request a WebSocket URL via `apps.connections.open`.
  - Handle incoming `events_api` envelope type, specifically `message` events.
  - Acknowledge each envelope with `{"envelope_id": "..."}` reply.
  - Apply existing `shouldHandle()` policy checks to incoming messages.
  - Route accepted messages through the channel's message callback.
  - Implement `vtableStop()`: close the WebSocket connection cleanly.
- Handle reconnection on disconnect with exponential backoff (reuse patterns from Discord channel).
- Add tests for envelope parsing, acknowledgment format, and policy filtering.

## Acceptance
- `vtableStart()` establishes WebSocket connection via Socket Mode
- Incoming messages are received, filtered by policy, and dispatched
- `vtableStop()` cleanly closes connection
- Reconnection on disconnect
- Tests cover envelope parsing and ack format
- All existing Slack tests still pass
