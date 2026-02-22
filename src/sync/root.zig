//! Sync protocol module for huginn <-> muninn bidirectional sync.
//!
//! Re-exports shared protocol types, schema versioning, and serialization
//! helpers used by both nodes.

pub const protocol = @import("protocol.zig");
pub const conflict = @import("conflict.zig");
pub const handshake = @import("handshake.zig");

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

// Re-export conflict resolution types.
pub const ConflictSide = conflict.ConflictSide;
pub const ConflictOutcome = conflict.ConflictOutcome;
pub const ConflictRecord = conflict.ConflictRecord;
pub const resolveTask = conflict.resolveTask;
pub const resolveMemory = conflict.resolveMemory;
pub const resolve = conflict.resolve;

// Re-export handshake and heartbeat types.
pub const HandshakePhase = handshake.HandshakePhase;
pub const HandshakeIntent = handshake.HandshakeIntent;
pub const NodeHealth = handshake.NodeHealth;
pub const ConnectionState = handshake.ConnectionState;
pub const HandshakeInit = handshake.HandshakeInit;
pub const HandshakeResponse = handshake.HandshakeResponse;
pub const Heartbeat = handshake.Heartbeat;
pub const HeartbeatAck = handshake.HeartbeatAck;
pub const TransitionResult = handshake.TransitionResult;

// Re-export handshake state transition helpers.
pub const transitionSendInit = handshake.transitionSendInit;
pub const transitionReceiveInit = handshake.transitionReceiveInit;
pub const transitionSendAccept = handshake.transitionSendAccept;
pub const transitionSendReject = handshake.transitionSendReject;
pub const transitionReceiveAccept = handshake.transitionReceiveAccept;
pub const transitionReceiveReject = handshake.transitionReceiveReject;
pub const transitionConfirmEstablished = handshake.transitionConfirmEstablished;
pub const transitionFail = handshake.transitionFail;
pub const transitionReset = handshake.transitionReset;

// Re-export heartbeat processing helpers.
pub const processHeartbeatMiss = handshake.processHeartbeatMiss;
pub const processHeartbeatSuccess = handshake.processHeartbeatSuccess;

// Re-export handshake serialization helpers.
pub const serializeHandshakeInit = handshake.serializeHandshakeInit;
pub const serializeHeartbeat = handshake.serializeHeartbeat;

test {
    @import("std").testing.refAllDecls(@This());
}
