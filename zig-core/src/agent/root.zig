//! Agent Core - ReAct Loop (Reasoning + Acting) with Full Undo Support
//!
//! ReAct Pattern:
//! 1. User Message → 2. LLM Thinks → 3. Tool Call Decision
//! 4. Execute Tool → 5. Observe Result → 6. Back to 2
//! 7. No tool call → Return final response
//!
//! Undo Support:
//! - Every file modification is recorded
//! - Tool calls can be undone via snapshot system
//! - Memory updates are version controlled
//! - Agent can roll back entire conversation turns

const std = @import("std");

pub const config = @import("config.zig");

pub const AgentConfig = config.AgentConfig;

/// Main Agent struct with undo support
pub const Agent = struct {
    allocator: std.mem.Allocator,
    config: AgentConfig,
    
    // State
    messages: std.ArrayList(ChatMessage),
    tool_registry: @import("../tools/root.zig").ToolRegistry,
    memory_store: @import("../memory/root.zig").ContextStore,
    undo_manager: @import("../undo/root.zig").UndoManager,
    memory_vc: @import("../memory/root.zig").MemoryVersionControl,
    
    // Callbacks (set via JNI for Android)
    token_callback: ?*const fn ([*c]const u8) callconv(.C) void = null,
    approval_callback: ?*const fn ([*c]const u8, [*c]const u8) callconv(.C) bool = null,
    
    // HTTP callback for LLM API calls
    http_callback: ?*const fn ([*c]const u8, [*c]const u8, [*c]const u8, usize) callconv(.C) [*c]const u8 = null,
    
    pub fn init(allocator: std.mem.Allocator, config: AgentConfig) !Agent {
        var tool_registry = @import("../tools/root.zig").ToolRegistry.init(allocator);
        
        // Setup undo manager
        const history_dir = try std.fs.path.join(allocator, &.{config.data_dir, "undo_history"});
        defer allocator.free(history_dir);
        
        var undo_manager = try @import("../undo/root.zig").UndoManager.init(
            allocator,
            100,  // max history
            true, // persist
            history_dir
        );
        
        // Connect undo manager to tool registry
        try tool_registry.registerCoreTools();
        tool_registry.setUndoManager(&undo_manager);
        
        const memory_store = try @import("../memory/root.zig").ContextStore.init(allocator, config.data_dir);
        
        // Initialize memory version control
        const memory_vc = try @import("../memory/root.zig").MemoryVersionControl.init(allocator, config.data_dir);
        
        return .{
            .allocator = allocator,
            .config = config,
            .messages = std.ArrayList(ChatMessage).init(allocator),
            .tool_registry = tool_registry,
            .memory_store = memory_store,
            .undo_manager = undo_manager,
            .memory_vc = memory_vc,
        };
    }
    
    pub fn deinit(self: *Agent) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.role);
            self.allocator.free(msg.content);
        }
        self.messages.deinit();
        self.tool_registry.deinit();
        self.memory_store.deinit();
        self.undo_manager.deinit();
        self.memory_vc.deinit();
    }
    
    /// Send message and run ReAct loop
    pub fn send(self: *Agent, user_message: []const u8) ![]const u8 {
        // Begin batch for this conversation turn
        try self.undo_manager.beginBatch("Conversation turn");
        defer self.undo_manager.endBatch() catch {};
        
        // Add user message
        try self.messages.append(.{
            .role = try self.allocator.dupe(u8, "user"),
            .content = try self.allocator.dupe(u8, user_message),
        });
        
        var iteration: u32 = 0;
        const max_iterations = self.config.max_tool_iterations;
        
        while (iteration < max_iterations) : (iteration += 1) {
            // Build system prompt with context
            const system_prompt = try self.buildSystemPrompt();
            defer self.allocator.free(system_prompt);
            
            // Call LLM
            const response = try self.callLLM(system_prompt);
            defer self.allocator.free(response);
            
            // Parse response for tool calls
            if (try self.parseToolCalls(response)) |tool_call| {
                defer tool_call.deinit(self.allocator);
                
                // Check approval for dangerous tools
                if (self.approval_callback) |callback| {
                    const tool = self.tool_registry.get(tool_call.name) orelse continue;
                    if (tool.risk_level == .dangerous or 
                        (tool.risk_level == .moderate and self.config.approval_mode == .cautious)) {
                        const approved = callback(
                            @ptrCast(tool_call.name.ptr),
                            @ptrCast(tool_call.args.ptr)
                        );
                        if (!approved) {
                            try self.messages.append(.{
                                .role = try self.allocator.dupe(u8, "tool"),
                                .content = try self.allocator.dupe(u8, "Tool execution denied by user"),
                            });
                            continue;
                        }
                    }
                }
                
                // Execute tool (with automatic undo support)
                const result = try self.tool_registry.execute(
                    self.allocator,
                    tool_call.name,
                    tool_call.args
                );
                defer self.allocator.free(result);
                
                // Add tool result to messages
                try self.messages.append(.{
                    .role = try self.allocator.dupe(u8, "assistant"),
                    .content = try self.allocator.dupe(u8, response),
                });
                try self.messages.append(.{
                    .role = try self.allocator.dupe(u8, "tool"),
                    .content = try self.allocator.dupe(u8, result),
                });
                
                // Trigger auto-learn if enabled
                if (self.config.auto_learn) {
                    try self.autoLearn(user_message, tool_call.name, result);
                }
            } else {
                // No tool call - final response
                try self.messages.append(.{
                    .role = try self.allocator.dupe(u8, "assistant"),
                    .content = try self.allocator.dupe(u8, response),
                });
                return try self.allocator.dupe(u8, response);
            }
        }
        
        return error.MaxIterationsReached;
    }
    
    /// Undo last operation
    pub fn undo(self: *Agent) !bool {
        const op = try self.undo_manager.undo();
        if (op) |*operation| {
            // If we undid a tool that modified memory, also undo memory change
            if (operation.operation_type == .memory_update) {
                try self.memory_vc.undo("MEMORY.md");
            }
            operation.deinit();
            return true;
        }
        return false;
    }
    
    /// Redo last undone operation
    pub fn redo(self: *Agent) !bool {
        const op = try self.undo_manager.redo();
        if (op) |*operation| {
            operation.deinit();
            return true;
        }
        return false;
    }
    
    /// Check if can undo
    pub fn canUndo(self: Agent) bool {
        return self.undo_manager.canUndo();
    }
    
    /// Check if can redo
    pub fn canRedo(self: Agent) bool {
        return self.undo_manager.canRedo();
    }
    
    /// Get undo description for UI
    pub fn getUndoDescription(self: Agent) ?[]const u8 {
        return self.undo_manager.getUndoDescription();
    }
    
    /// Get redo description for UI
    pub fn getRedoDescription(self: Agent) ?[]const u8 {
        return self.undo_manager.getRedoDescription();
    }
    
    /// Rollback entire conversation to before last user message
    pub fn rollbackConversation(self: *Agent) !void {
        // Find the last user message and remove everything after it
        var i: i32 = @intCast(self.messages.items.len - 1);
        while (i >= 0) : (i -= 1) {
            const idx: usize = @intCast(i);
            if (std.mem.eql(u8, self.messages.items[idx].role, "user")) {
                // Remove all messages from this point
                while (self.messages.items.len > idx + 1) {
                    var msg = self.messages.pop();
                    self.allocator.free(msg.role);
                    self.allocator.free(msg.content);
                }
                break;
            }
        }
        
        // Also undo any tool operations from this turn
        while (self.undo_manager.canUndo()) {
            const undone = try self.undo_manager.undo();
            if (undone) |*op| {
                const was_tool = op.operation_type == .tool_execution or
                                op.tool_name != null;
                op.deinit();
                if (!was_tool) break;  // Stop when we hit non-tool operations
            } else break;
        }
    }
    
    fn buildSystemPrompt(self: Agent) ![]const u8 {
        var parts = std.ArrayList(u8).init(self.allocator);
        defer parts.deinit();
        
        // Base system prompt
        try parts.appendSlice("You are CClaude, a helpful AI coding assistant running on Android.\n\n");
        
        // Add undo capability notice
        try parts.appendSlice("Note: All file operations are tracked and can be undone if needed.\n\n");
        
        // Add available tools
        try parts.appendSlice("Available tools:\n");
        var tools_it = self.tool_registry.tools.iterator();
        while (tools_it.next()) |entry| {
            const undo_marker = if (entry.value_ptr.supports_undo) " (undoable)" else "";
            try parts.writer().print("- {s}: {s}{s}\n", .{
                entry.key_ptr.*, 
                entry.value_ptr.description,
                undo_marker
            });
        }
        
        // Add memory context
        const context = try self.memory_store.buildPrompt(self.allocator);
        defer self.allocator.free(context);
        try parts.appendSlice(context);
        
        return try self.allocator.dupe(u8, parts.items);
    }
    
    fn callLLM(self: Agent, system_prompt: []const u8) ![]const u8 {
        _ = system_prompt;
        if (self.http_callback) |callback| {
            const response = callback(
                @ptrCast(self.config.api_url.ptr),
                @ptrCast(self.config.api_key.ptr),
                @ptrCast("{}"),
                2
            );
            return try self.allocator.dupe(u8, std.mem.span(response));
        }
        return error.NoHttpCallback;
    }
    
    fn parseToolCalls(self: Agent, response: []const u8) !?ToolCall {
        if (std.mem.indexOf(u8, response, "\"tool_calls\"")) |_| {
            if (std.mem.indexOf(u8, response, "\"name\":\"")) |name_start| {
                const name_value_start = name_start + 8;
                if (std.mem.indexOfPos(u8, response, name_value_start, "\"")) |name_end| {
                    const name = try self.allocator.dupe(u8, response[name_value_start..name_end]);
                    
                    if (std.mem.indexOf(u8, response, "\"arguments\":\"")) |args_start| {
                        const args_value_start = args_start + 13;
                        if (std.mem.indexOfPos(u8, response, args_value_start, "\"")) |args_end| {
                            const args = try self.allocator.dupe(u8, response[args_value_start..args_end]);
                            return ToolCall{ .name = name, .args = args };
                        }
                    }
                    self.allocator.free(name);
                }
            }
        }
        return null;
    }
    
    fn autoLearn(self: *Agent, user_input: []const u8, tool_name: []const u8, tool_result: []const u8) !void {
        const auto_learn = @import("../memory/root.zig").AutoLearn.init(self.allocator);
        
        const summary = try std.fmt.allocPrint(self.allocator, "Tool: {s}, Result: {s}", .{
            tool_name, 
            tool_result[0..@min(tool_result.len, 100)]
        });
        defer self.allocator.free(summary);
        
        const prompt = try auto_learn.buildExtractionPrompt(user_input, summary);
        defer self.allocator.free(prompt);
        
        _ = prompt;
    }
};

const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

const ToolCall = struct {
    name: []const u8,
    args: []const u8,
    
    fn deinit(self: ToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.args);
    }
};
