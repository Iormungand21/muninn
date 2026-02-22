# Sync Protocol — huginn <-> muninn

## Overview

The sync protocol enables bidirectional replication of events, tasks, and memory
records between **muninn** (edge) and **huginn** (cloud/server) nodes.  Each
message is wrapped in a `SyncEnvelope` that carries identity, ordering, and
schema versioning metadata.

## Schema Versioning

Every `SyncEnvelope` includes an explicit `schema_version` field using
**major.minor** semantics:

| Change type        | Bump  | Wire compatibility          |
|--------------------|-------|-----------------------------|
| Breaking change    | major | Receiver MUST reject        |
| Additive field     | minor | Receiver MAY ignore new fields |

Current version: **1.0**

Receivers check compatibility via `SchemaVersion.isCompatible()` — same major
and sender minor <= receiver minor.

## Envelope Structure

```
SyncEnvelope
├── id              — unique message ID
├── node_id         — sender node identifier
├── node_role       — muninn | huginn | unknown
├── sequence        — monotonic per-node counter (gap detection)
├── schema_version  — protocol version (major.minor)
├── timestamp       — ISO-8601 creation time
├── direction       — push | pull | bidirectional
├── delta_kind      — event | task | memory
├── workspace_id?   — optional workspace scope
└── <delta payload> — exactly one of:
    ├── event_delta
    ├── task_delta
    └── memory_delta
```

## Delta Payloads

### EventDelta

Syncs event timeline entries (observability / audit).

| Field            | Type     | Required | Notes                        |
|------------------|----------|----------|------------------------------|
| event_id         | string   | yes      | Unique event record ID       |
| op               | enum     | yes      | create / update / delete     |
| event_kind       | string   | no       | Maps to EventKind enum       |
| severity         | string   | no       | trace/debug/info/warn/err    |
| event_timestamp  | string   | no       | ISO-8601 of original event   |
| summary          | string   | no       | Short description            |

### TaskDelta

Syncs task lifecycle changes.

| Field         | Type     | Required | Notes                        |
|---------------|----------|----------|------------------------------|
| task_id       | string   | yes      | Unique task record ID        |
| op            | enum     | yes      | create / update / delete     |
| status        | string   | no       | Maps to TaskStatus enum      |
| priority      | string   | no       | low / normal / high          |
| goal          | string   | no       | Task description             |
| workspace_id  | string   | no       | Workspace scope              |

### MemoryDelta

Syncs memory record mutations.

| Field          | Type     | Required | Notes                        |
|----------------|----------|----------|------------------------------|
| memory_id      | string   | yes      | Unique memory record ID      |
| op             | enum     | yes      | create / update / delete     |
| memory_kind    | string   | no       | episodic / semantic / etc.   |
| retention_tier | string   | no       | pinned / long_term / etc.    |
| key            | string   | no       | Lookup key                   |
| content        | string   | no       | Body (omitted on delete)     |
| confidence     | string   | no       | Numeric string e.g. "0.85"   |

## Acknowledgement

Receivers respond with a `SyncAck`:

| Field        | Type     | Required | Notes                          |
|--------------|----------|----------|--------------------------------|
| envelope_id  | string   | yes      | The envelope being ack'd       |
| node_id      | string   | yes      | Acknowledger node ID           |
| status       | enum     | yes      | accepted/rejected/conflict/err |
| sequence     | u64      | yes      | Ack'd sequence number          |
| timestamp    | string   | yes      | ISO-8601 ack time              |
| reason       | string   | no       | Explanation for non-accepted   |

## Serialization

All payloads use JSONL (one JSON object per line) for wire transport and
persistent queue storage.  Serialization uses stack-allocated fixed buffers
(no heap allocation) via `serializeEnvelope()` and `serializeAck()`.

## Future Work

- **X2-SYNC-001**: Conflict resolution policy (last-writer-wins, merge, manual)
- **X3-SYNC-001**: Federated task routing handshake and heartbeat flow
- Batch envelope support (multiple deltas per message)
- Compression for large memory content payloads
