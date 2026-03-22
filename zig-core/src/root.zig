//! CClaude Agent Core - Pure Zig Implementation
//! 
//! Features:
//! - ReAct Agent Loop (Reasoning + Acting)
//! - Tool System (8 core tools with Undo Support)
//! - Memory System (Markdown Context Files with Version Control)
//! - Auto-Learn (LLM-driven automatic memory)
//! - AutoResearchClaw (23-stage research pipeline)
//! - Undo/Redo System (All operations recoverable)

const std = @import("std");

// Core modules
pub const agent = @import("agent/root.zig");
pub const tools = @import("tools/root.zig");
pub const memory = @import("memory/root.zig");
pub const research = @import("research/root.zig");
pub const undo = @import("undo/root.zig");
pub const utils = @import("utils/root.zig");

// JNI bindings for Android
pub const jni = @import("jni/root.zig");

// Re-export main types
pub const Agent = agent.Agent;
pub const AgentConfig = agent.AgentConfig;
pub const Tool = tools.Tool;
pub const ToolRegistry = tools.ToolRegistry;
pub const MemoryStore = memory.MemoryStore;
pub const ContextFile = memory.ContextFile;
pub const ResearchPipeline = research.ResearchPipeline;
pub const UndoManager = undo.UndoManager;
pub const Operation = undo.Operation;
pub const Snapshot = undo.Snapshot;

test {
    _ = agent;
    _ = tools;
    _ = memory;
    _ = research;
    _ = undo;
    _ = utils;
    _ = jni;
}
