//! Agent Core - ReAct Loop with Full Undo Support

const std = @import("std");

pub const config_mod = @import("config.zig");
pub const AgentConfig = config_mod.AgentConfig;

pub const Agent = struct {
    allocator: std.mem.Allocator,
    agent_config: AgentConfig,
    messages: std.ArrayList(ChatMessage),
    tool_registry: @import("../tools/root.zig").ToolRegistry,
    memory_store: @import("../memory/root.zig").ContextStore,
    undo_manager: @import("../undo/root.zig").UndoManager,
    memory_vc: @import("../memory/root.zig").MemoryVersionControl,
    
    token_callback: ?*const fn ([*c]const u8) callconv(.C) void = null,
    approval_callback: ?*const fn ([*c]const u8, [*c]const u8) callconv(.C) bool = null,
    http_callback: ?*const fn ([*c]const u8, [*c]const u8, [*c]const u8, usize) callconv(.C) [*c]const u8 = null,
    
    pub fn init(allocator: std.mem.Allocator, agent_config: AgentConfig) !Agent {
        var tool_registry = @import("../tools/root.zig").ToolRegistry.init(allocator);
        
        const history_dir = try std.fs.path.join(allocator, &.{agent_config.data_dir, "undo_history"});
        defer allocator.free(history_dir);
        
        var undo_manager = try @import("../undo/root.zig").UndoManager.init(
            allocator,
            100,
            true,
            history_dir
        );
        
        tool_registry.setUndoManager(&undo_manager);
        try tool_registry.registerCoreTools();
        
        const memory_store = try @import("../memory/root.zig").ContextStore.init(allocator, agent_config.data_dir);
        const memory_vc = try @import("../memory/root.zig").MemoryVersionControl.init(allocator, agent_config.data_dir);
        
        return .{
            .allocator = allocator,
            .agent_config = agent_config,
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
    
    pub fn send(self: *Agent, user_message: []const u8) ![]const u8 {
        try self.undo_manager.beginBatch("Conversation turn");
        errdefer self.undo_manager.endBatch() catch {};
        
        try self.messages.append(.{
            .role = try self.allocator.dupe(u8, "user"),
            .content = try self.allocator.dupe(u8, user_message),
        });
        
        var iteration: u32 = 0;
        while (iteration < self.agent_config.max_tool_iterations) : (iteration += 1) {
            const system_prompt = try self.buildSystemPrompt();
            defer self.allocator.free(system_prompt);
            
            const response = try self.callLLM(system_prompt);
            defer self.allocator.free(response);
            
            if (try self.parseToolCalls(response)) |tool_call| {
                defer tool_call.deinit(self.allocator);
                
                if (self.approval_callback) |callback| {
                    const tool = self.tool_registry.get(tool_call.name) orelse continue;
                    if (tool.risk_level == .dangerous or 
                        (tool.risk_level == .moderate and self.agent_config.approval_mode == .cautious)) {
                        const approved = callback(
                            @ptrCast(tool_call.name.ptr),
                            @ptrCast(tool_call.args.ptr)
                        );
                        if (!approved) {
                            try self.messages.append(.{
                                .role = try self.allocator.dupe(u8, "tool"),
                                .content = try self.allocator.dupe(u8, "Tool execution denied"),
                            });
                            continue;
                        }
                    }
                }
                
                const result = try self.tool_registry.execute(self.allocator, tool_call.name, tool_call.args);
                defer self.allocator.free(result);
                
                try self.messages.append(.{
                    .role = try self.allocator.dupe(u8, "assistant"),
                    .content = try self.allocator.dupe(u8, response),
                });
                try self.messages.append(.{
                    .role = try self.allocator.dupe(u8, "tool"),
                    .content = try self.allocator.dupe(u8, result),
                });
            } else {
                try self.messages.append(.{
                    .role = try self.allocator.dupe(u8, "assistant"),
                    .content = try self.allocator.dupe(u8, response),
                });
                return try self.allocator.dupe(u8, response);
            }
        }
        
        return error.MaxIterationsReached;
    }
    
    pub fn undo(self: *Agent) !bool {
        const op = try self.undo_manager.undo();
        if (op) |*operation| {
            if (operation.operation_type == .memory_update) {
                try self.memory_vc.undo("MEMORY.md");
            }
            operation.deinit();
            return true;
        }
        return false;
    }
    
    pub fn redo(self: *Agent) !bool {
        const op = try self.undo_manager.redo();
        if (op) |*operation| {
            operation.deinit();
            return true;
        }
        return false;
    }
    
    pub fn canUndo(self: *const Agent) bool {
        return self.undo_manager.canUndo();
    }
    
    pub fn canRedo(self: *const Agent) bool {
        return self.undo_manager.canRedo();
    }
    
    pub fn getUndoDescription(self: *const Agent) ?[]const u8 {
        return self.undo_manager.getUndoDescription();
    }
    
    pub fn getRedoDescription(self: *const Agent) ?[]const u8 {
        return self.undo_manager.getRedoDescription();
    }
    
    pub fn rollbackConversation(self: *Agent) !void {
        var i: i32 = @intCast(self.messages.items.len - 1);
        while (i >= 0) : (i -= 1) {
            const idx: usize = @intCast(i);
            if (std.mem.eql(u8, self.messages.items[idx].role, "user")) {
                while (self.messages.items.len > idx + 1) {
                    var msg = self.messages.pop();
                    self.allocator.free(msg.role);
                    self.allocator.free(msg.content);
                }
                break;
            }
        }
        
        while (self.undo_manager.canUndo()) {
            const undone = try self.undo_manager.undo();
            if (undone) |*op| {
                const was_tool = op.operation_type == .tool_execution or op.tool_name != null;
                op.deinit();
                if (!was_tool) break;
            } else break;
        }
    }
    
    fn buildSystemPrompt(self: *const Agent) ![]const u8 {
        var parts = std.ArrayList(u8).init(self.allocator);
        defer parts.deinit();
        
        try parts.appendSlice("You are CClaude, a helpful AI coding assistant.\n\n");
        try parts.appendSlice("Note: All file operations are tracked and can be undone.\n\n");
        
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
        
        const context = try self.memory_store.buildPrompt(self.allocator);
        defer self.allocator.free(context);
        try parts.appendSlice(context);
        
        return try self.allocator.dupe(u8, parts.items);
    }
    
    fn callLLM(self: *const Agent, system_prompt: []const u8) ![]const u8 {
        _ = system_prompt;
        if (self.http_callback) |callback| {
            const response = callback(
                @ptrCast(self.agent_config.api_url.ptr),
                @ptrCast(self.agent_config.api_key.ptr),
                @ptrCast("{}"),
                2
            );
            return try self.allocator.dupe(u8, std.mem.span(response));
        }
        return error.NoHttpCallback;
    }
    
    fn parseToolCalls(self: *const Agent, response: []const u8) !?ToolCall {
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
