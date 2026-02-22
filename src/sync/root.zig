//! Sync protocol module for huginn <-> muninn bidirectional sync.
//!
//! Re-exports shared protocol types, schema versioning, and serialization
//! helpers used by both nodes.

pub const protocol = @import("protocol.zig");

// Re-export key types for convenience.
pub const SchemaVersion = protocol.SchemaVersion;
pub const NodeRole = protocol.NodeRole;
pub const DeltaKind = protocol.DeltaKind;
pub const DeltaOp = protocol.DeltaOp;
pub const SyncDirection = protocol.SyncDirection;
pub const AckStatus = protocol.AckStatus;
pub const EventDelta = protocol.EventDelta;
pub const TaskDelta = protocol.TaskDelta;
pub const MemoryDelta = protocol.MemoryDelta;
pub const SyncEnvelope = protocol.SyncEnvelope;
pub const SyncAck = protocol.SyncAck;

// Re-export constants.
pub const SCHEMA_VERSION_MAJOR = protocol.SCHEMA_VERSION_MAJOR;
pub const SCHEMA_VERSION_MINOR = protocol.SCHEMA_VERSION_MINOR;

// Re-export serialization helpers.
pub const serializeEnvelope = protocol.serializeEnvelope;
pub const serializeAck = protocol.serializeAck;
pub const currentSchemaVersion = protocol.currentSchemaVersion;

test {
    @import("std").testing.refAllDecls(@This());
}
