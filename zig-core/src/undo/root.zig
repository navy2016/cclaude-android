//! Undo/Redo System - Core Design Principle
//!
//! All operations must be undoable with minimal or no data loss.
//! This includes:
//! - Tool calls (file operations, edits)
//! - Memory updates
//! - Configuration changes

const std = @import("std");

pub const snapshot = @import("snapshot.zig");
pub const operation = @import("operation.zig");
pub const history = @import("history.zig");

pub const Snapshot = snapshot.Snapshot;
pub const SnapshotType = snapshot.SnapshotType;
pub const Operation = operation.Operation;
pub const OperationType = operation.OperationType;
pub const UndoManager = history.UndoManager;

test {
    _ = snapshot;
    _ = operation;
    _ = history;
}
