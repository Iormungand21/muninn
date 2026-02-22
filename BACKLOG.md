# NullClaw Backlog

> Generated 2026-02-22. Covers issues with existing functionality and new feature proposals.

---

## Part 1: Issues with Existing Features

### CRITICAL — Broken or Non-Functional

| # | Area | Issue | Files | Notes |
|---|------|-------|-------|-------|
| B-001 | Channels | **Slack channel cannot receive messages** — `vtableStart()` and `vtableStop()` are empty stubs (`_ = ptr;`). Sending works, but there is no polling loop for `conversations.history` so Slack is a write-only channel. | `src/channels/slack.zig:130-135` | Discord is fully implemented with WebSocket gateway; Slack needs equivalent Socket Mode or RTM/polling implementation. |
| B-002 | Security | **Landlock sandbox has no syscall implementation** — `LandlockSandbox` struct exists but contains no actual `landlock_create_ruleset` / `landlock_add_rule` / `landlock_restrict_self` syscalls. `wrapCommand()` returns argv unchanged. Comments say "caller is responsible" but no caller does it. | `src/security/landlock.zig` | On Linux, auto-detect will select Landlock as highest priority, giving a false sense of sandboxing. |
| B-003 | Security | **Secret scope enforcement not wired** — `scope.zig` explicitly states it contains "skeleton primitives for later enforcement integration." The types, lookups, and resolvers are complete, but nothing in the system actually calls `isSecretAccessible()` or `findWorkspacePolicy()` to enforce scoping. | `src/security/scope.zig:7` | Secrets are effectively global regardless of scope configuration. |

### HIGH — Incomplete Features

| # | Area | Issue | Files | Notes |
|---|------|-------|-------|-------|
| B-004 | Autonomy | **Offline queue is schema-only** — `enqueue()` and `drain()` have 3 TODOs: no max_items check, no JSONL parsing, no batch writes. The drain loop is not implemented. | `src/offline.zig:214,229,255` | Tagged M3-OFF. |
| B-005 | Autonomy | **Delegation client is a stub** — `sendPlanRequest()`, `pollResult()`, and `healthCheck()` all have TODOs for HTTP transport. No actual HTTP calls are made. | `src/delegation.zig:224,237,250` | Tagged M4-DEL. |
| B-006 | Sync | **Federated sync is scaffolding only** — Handshake protocol, conflict resolution, and shared types are defined but contain no production message routing. ~2,200 lines of types with no runtime integration. | `src/sync/` (4 files, 2,205 lines) | Tagged X1/X2/X3-SYNC. |
| B-007 | Observability | **Replay/event sourcing is stubbed** — `processEvent()` is a no-op TODO, `loadEvents()` doesn't parse the JSONL file, `computeStats()` doesn't read actual events. | `src/replay.zig:61,192,196,234` | Tagged S3-OBS. |
| B-008 | Tools | **Reliability framework not adopted by any tool** — `reliableExecute()` with circuit breaker and exponential backoff exists but no tool uses it. All tools execute directly without retry or circuit-breaking. | `src/tools/root.zig:88-90`, `src/tools/reliability.zig` | Tagged S1-TOOL-001. |

### MEDIUM — Integration Gaps

| # | Area | Issue | Files | Notes |
|---|------|-------|-------|-------|
| B-009 | Memory | **Confidence decay not wired to backends** — `decayConfidence()` and `reinforceConfidence()` are fully implemented but never called during recall/search ranking. Search results ignore confidence decay. | `src/memory/decay.zig:7-10` | Tagged S2-MEM-001. |
| B-010 | Memory | **TypedRecord not persisted in SQLite** — `MemoryKind`, `RetentionTier`, `SourceMeta`, and `Confidence` fields exist in the struct but the SQLite schema has no columns for them. Requires migration. | `src/memory/types.zig:8-13` | Tagged S2-MEM-001. |
| B-011 | Memory | **Episodic→semantic consolidation not implemented** — The `EpisodicMeta.consolidated` flag and `SemanticMeta.derived_from_episodes` exist as types but nothing triggers the consolidation workflow. | `src/memory/decay.zig` | Listed as future integration TODO. |
| B-012 | Memory | **Embedding cache populated but vector search not wired end-to-end** — `hybridMerge()` exists, embeddings can be computed and cached, but no recall path actually performs vector similarity search combined with FTS5. | `src/memory/vector.zig`, `src/memory/embeddings.zig` | The SQLite backend has the tables but the query path doesn't use them for hybrid ranking. |
| B-013 | Tunnel | **Tunnel provider implementations incomplete** — Cloudflare tunnel has process spawning skeleton but URL extraction may be incomplete. Tailscale, ngrok, and custom tunnel backends need verification. | `src/tunnel.zig` | Only the `none` tunnel and partial Cloudflare visible. |
| B-014 | Gateway | **processIncomingMessage() subprocess fallback** — When session_mgr is unavailable, the gateway spawns a subprocess to handle messages instead of routing through the agent. This is a performance and reliability concern. | `src/gateway.zig:464-497` | Should be a graceful error, not a subprocess spawn. |

### LOW — Minor Issues

| # | Area | Issue | Files | Notes |
|---|------|-------|-------|-------|
| B-015 | Config | **No live config reload** — Config is loaded at startup only. Any changes require a full restart. | `src/config.zig` | Acceptable for now; matters more for daemon mode. |
| B-016 | Embeddings | **No timeout on OpenAI embedding requests** — `OpenAiEmbedding.embed()` has no explicit timeout; relies on system/client defaults. Could hang on network issues. | `src/memory/embeddings.zig` | Should use `curlPostTimed()` or similar. |
| B-017 | Peripherals | **Serial-only peripheral backend** — GPIO, flash, and other hardware interfaces mentioned in README/config are not visible in the implementation. | `src/peripherals.zig` | May exist beyond line 200; needs verification. |
| B-018 | Hygiene | **pruneConversationRows may use non-existent API** — Calls `mem.search()` which may not be available on all memory backends. | `src/memory/hygiene.zig` | Needs integration test verification. |

---

## Part 2: New Features & Improvements

### Discord/Slack Enhancements

| # | Feature | Description | Priority | Complexity |
|---|---------|-------------|----------|------------|
| F-001 | **Slack Socket Mode** | Implement real-time message receiving via Slack Socket Mode (WebSocket), replacing the missing polling loop. This is the modern Slack approach and mirrors how Discord is implemented. | Critical | High |
| F-002 | **Discord slash commands** | Register and handle Discord Application Commands (`/ask`, `/remember`, `/forget`, `/status`). Currently Discord only responds to mentions/DMs. | High | Medium |
| F-003 | **Discord thread support** | Automatically create threads for long conversations to keep channels clean. Reply in existing threads when messages come from threads. | Medium | Medium |
| F-004 | **Discord embed responses** | Use rich embeds for structured responses (code blocks, memory results, status reports) instead of plain text. | Low | Low |
| F-005 | **Slack interactive components** | Support Slack Block Kit for buttons, dropdowns, and modal dialogs in responses. | Low | Medium |

### Memory System

| # | Feature | Description | Priority | Complexity |
|---|---------|-------------|----------|------------|
| F-006 | **Wire hybrid vector+keyword search** | Complete the end-to-end path: embed on store, vector similarity on recall, merge with FTS5 BM25 scores via `hybridMerge()`. The pieces exist but aren't connected. | High | Medium |
| F-007 | **Wire confidence decay into recall ranking** | Call `decayConfidence()` during search result ranking. Records with low confidence should rank lower or be excluded. | High | Low |
| F-008 | **SQLite schema migration for TypedRecord** | Add columns for `kind`, `tier`, `source_channel`, `source_author`, `confidence`, `decay_model` to the memories table. Backfill existing records as `raw`/`short_term`. | Medium | Medium |
| F-009 | **Episodic→semantic consolidation** | Implement the workflow: identify clusters of related episodic memories, distill into semantic facts, mark originals as consolidated. Triggered periodically or by hygiene sweep. | Medium | High |
| F-010 | **Memory importance scoring** | Auto-classify memory importance at write time (user preferences > casual mentions > ephemeral context) to inform retention tier assignment. | Low | Medium |

### Security & Policy

| # | Feature | Description | Priority | Complexity |
|---|---------|-------------|----------|------------|
| F-011 | **Implement Landlock syscalls** | Write actual Zig bindings for `landlock_create_ruleset`, `landlock_add_rule`, `landlock_restrict_self`. This is the highest-priority sandbox on Linux. | High | Medium |
| F-012 | **Enforce secret scoping** | Wire `isSecretAccessible()` checks into the secret retrieval path so workspace/channel restrictions are actually enforced. | High | Low |
| F-013 | **Enforce workspace approval policies** | Wire `findWorkspacePolicy()` and the resolve functions into the policy evaluation path so per-workspace autonomy overrides take effect. | Medium | Low |
| F-014 | **Audit log querying** | Add a CLI command (`nullclaw audit search --actor X --action Y --since 7d`) and tool to search audit logs. Currently write-only. | Low | Medium |

### Tools & Reliability

| # | Feature | Description | Priority | Complexity |
|---|---------|-------------|----------|------------|
| F-015 | **Adopt reliability framework** | Wrap shell, http_request, web_search, web_fetch tools with `reliableExecute()` for automatic retry with exponential backoff and circuit breaking. | High | Low |
| F-016 | **Tool timeout enforcement** | Add per-tool timeout configuration in config.json. Currently tools can run indefinitely if the underlying operation hangs. | Medium | Low |
| F-017 | **Tool usage analytics** | Track per-tool invocation count, success rate, average latency, and surface via `nullclaw status` or `nullclaw doctor`. | Low | Medium |

### Autonomy & Sync

| # | Feature | Description | Priority | Complexity |
|---|---------|-------------|----------|------------|
| F-018 | **Complete offline queue** | Implement the drain loop, JSONL persistence, max_items bounds checking, and deduplication for the offline queue. | Medium | Medium |
| F-019 | **Complete delegation HTTP transport** | Wire `sendPlanRequest()`, `pollResult()`, and `healthCheck()` to actual HTTP calls via curlPost/curlGet. | Medium | Medium |
| F-020 | **Complete event replay** | Implement JSONL parsing in `loadEvents()`, event processing in `processEvent()`, and stats computation for observability replay. | Low | Medium |

### Infrastructure

| # | Feature | Description | Priority | Complexity |
|---|---------|-------------|----------|------------|
| F-021 | **Config hot-reload** | Watch config.json for changes and apply non-disruptive updates (provider keys, temperature, rate limits) without restarting the daemon. | Medium | High |
| F-022 | **Structured logging** | Replace ad-hoc print/log statements with a unified structured logger (JSON output mode for production, human-readable for dev). | Medium | Medium |
| F-023 | **Prometheus/OpenTelemetry metrics** | Implement the Observer vtable beyond noop/log/file. Expose request latency, token usage, memory operations, tool calls as metrics. | Low | High |
| F-024 | **Webhook channel authentication** | Add HMAC signature verification for inbound webhook messages (currently relies only on bearer token from pairing). | Low | Low |
| F-025 | **Health check endpoint detail** | Expand `/health` to return component-level status (memory backend, provider connectivity, channel health) instead of just "ok". | Low | Low |

### Developer Experience

| # | Feature | Description | Priority | Complexity |
|---|---------|-------------|----------|------------|
| F-026 | **Integration test suite** | Add end-to-end tests that exercise full flows: config→agent→provider→tool→memory→response. Currently tests are unit-level per module. | High | High |
| F-027 | **`nullclaw check`** | A pre-flight command that validates config, tests provider connectivity (API key validity), verifies memory backend, and checks channel credentials — more thorough than `doctor`. | Medium | Medium |
| F-028 | **Plugin/extension system** | Allow loading external .so/.dylib plugins that implement the vtable interfaces, beyond the built-in set. Useful for custom channels or providers. | Low | High |

---

## Part 3: Suggested Priority Order

### Immediate (fix what's broken)
1. **B-001** — Slack channel receive (F-001 Slack Socket Mode)
2. **B-002** — Landlock sandbox (F-011 implement syscalls)
3. **B-003** — Secret scope enforcement (F-012)

### Next Sprint (complete half-done features)
4. **B-008 / F-015** — Adopt tool reliability framework
5. **B-009 / F-007** — Wire confidence decay into recall
6. **B-012 / F-006** — Wire hybrid vector+keyword search
7. **B-013** — Verify and complete tunnel implementations
8. **F-013** — Enforce workspace approval policies

### Medium Term (new capabilities)
9. **F-002** — Discord slash commands
10. **F-008** — SQLite schema migration for TypedRecord
11. **F-003** — Discord thread support
12. **F-021** — Config hot-reload
13. **F-018** — Complete offline queue
14. **F-019** — Complete delegation HTTP transport

### Long Term (polish and scale)
15. **F-009** — Episodic→semantic consolidation
16. **F-022** — Structured logging
17. **F-023** — Prometheus/OTel metrics
18. **F-026** — Integration test suite
19. **F-020** — Complete event replay
20. **F-028** — Plugin/extension system
