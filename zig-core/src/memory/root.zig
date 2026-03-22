//! Memory System - Markdown Context Files with Version Control
//!
//! Context files:
//! - SOUL.md: Agent personality (name, tone, expertise, goals)
//! - USER.md: User profile (preferences, habits, tech background)
//! - MEMORY.md: Project knowledge (tech stack, architecture, patterns)
//! - BOOTSTRAP.md: First launch guide (temporary)
//!
//! Features:
//! - Version control for all memory files
//! - Auto-learn from interactions
//! - Undo/redo support

const std = @import("std");

pub const context = @import("context.zig");
pub const auto_learn = @import("auto_learn.zig");
pub const versioning = @import("versioning.zig");

pub const ContextFile = context.ContextFile;
pub const ContextStore = context.ContextStore;
pub const Trigger = context.Trigger;
pub const AutoLearn = auto_learn.AutoLearn;
pub const MemoryVersionControl = versioning.MemoryVersionControl;
pub const MemoryVersion = versioning.MemoryVersion;

test {
    _ = context;
    _ = auto_learn;
    _ = versioning;
}
