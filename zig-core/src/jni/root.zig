//! JNI Bindings for Android with Undo/Redo Support
//!
//! Exposes C API that can be called from Kotlin via JNI

const std = @import("std");
const Agent = @import("../agent/root.zig").Agent;
const AgentConfig = @import("../agent/root.zig").AgentConfig;

// Global agent instance
var global_agent: ?Agent = null;
var global_allocator: std.mem.Allocator = std.heap.page_allocator;

/// C-exported API for JNI
export fn cclaude_init(data_dir: [*c]const u8, api_key: [*c]const u8) i32 {
    if (global_agent != null) return -1;
    
    const data_dir_slice = std.mem.span(data_dir);
    const api_key_slice = std.mem.span(api_key);
    
    const config = AgentConfig{
        .allocator = global_allocator,
        .data_dir = global_allocator.dupe(u8, data_dir_slice) catch return -1,
        .api_key = global_allocator.dupe(u8, api_key_slice) catch return -1,
    };
    
    global_agent = Agent.init(global_allocator, config) catch return -1;
    return 0;
}

export fn cclaude_free() void {
    if (global_agent) |*agent| {
        agent.deinit();
        global_agent = null;
    }
}

export fn cclaude_send(message: [*c]const u8, token_callback: ?*const fn ([*c]const u8) callconv(.C) void) [*c]const u8 {
    const agent = &global_agent.?;
    agent.token_callback = token_callback;
    
    const message_slice = std.mem.span(message);
    const response = agent.send(message_slice) catch |err| {
        const error_msg = std.fmt.allocPrint(global_allocator, "Error: {s}", .{@errorName(err)}) catch return null;
        return @ptrCast(error_msg.ptr);
    };
    
    const result = global_allocator.alloc(u8, response.len + 1) catch return null;
    @memcpy(result[0..response.len], response);
    result[response.len] = 0;
    global_allocator.free(response);
    
    return @ptrCast(result.ptr);
}

// Undo/Redo exports
export fn cclaude_undo() i32 {
    const agent = &global_agent.?;
    const success = agent.undo() catch return -1;
    return if (success) 1 else 0;
}

export fn cclaude_redo() i32 {
    const agent = &global_agent.?;
    const success = agent.redo() catch return -1;
    return if (success) 1 else 0;
}

export fn cclaude_can_undo() i32 {
    const agent = &global_agent.?;
    return if (agent.canUndo()) 1 else 0;
}

export fn cclaude_can_redo() i32 {
    const agent = &global_agent.?;
    return if (agent.canRedo()) 1 else 0;
}

export fn cclaude_get_undo_description() [*c]const u8 {
    const agent = &global_agent.?;
    if (agent.getUndoDescription()) |desc| {
        const result = global_allocator.alloc(u8, desc.len + 1) catch return null;
        @memcpy(result[0..desc.len], desc);
        result[desc.len] = 0;
        return @ptrCast(result.ptr);
    }
    return null;
}

export fn cclaude_get_redo_description() [*c]const u8 {
    const agent = &global_agent.?;
    if (agent.getRedoDescription()) |desc| {
        const result = global_allocator.alloc(u8, desc.len + 1) catch return null;
        @memcpy(result[0..desc.len], desc);
        result[desc.len] = 0;
        return @ptrCast(result.ptr);
    }
    return null;
}

export fn cclaude_rollback_conversation() i32 {
    const agent = &global_agent.?;
    agent.rollbackConversation() catch return -1;
    return 0;
}

export fn cclaude_set_http_callback(callback: ?*const fn ([*c]const u8, [*c]const u8, [*c]const u8, usize) callconv(.C) [*c]const u8) void {
    if (global_agent) |*agent| {
        agent.http_callback = callback;
    }
}

export fn cclaude_set_approval_callback(callback: ?*const fn ([*c]const u8, [*c]const u8) callconv(.C) bool) void {
    if (global_agent) |*agent| {
        agent.approval_callback = callback;
    }
}

export fn cclaude_free_string(s: [*c]const u8) void {
    if (s != null) {
        // Note: In real impl, track allocations properly
    }
}
