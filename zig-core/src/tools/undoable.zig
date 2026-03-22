//! Undoable tool wrapper - Makes any tool undoable

const std = @import("std");
const UndoManager = @import("../undo/root.zig").UndoManager;
const Operation = @import("../undo/root.zig").Operation;
const Snapshot = @import("../undo/root.zig").Snapshot;

/// Wraps a tool execution with undo support
pub fn executeWithUndo(
    allocator: std.mem.Allocator,
    undo_manager: *UndoManager,
    tool_name: []const u8,
    args: []const u8,
    affected_paths: []const []const u8,
    execute_fn: *const fn () anyerror![]const u8,
) ![]const u8 {
    // Begin batch for this operation
    const desc = try std.fmt.allocPrint(allocator, "Execute {s}", .{tool_name});
    defer allocator.free(desc);
    
    try undo_manager.beginBatch(desc);
    defer undo_manager.endBatch() catch {};
    
    // Capture pre-snapshots
    for (affected_paths) |path| {
        var snapshot = try Snapshot.init(allocator, .file_content, path);
        try snapshot.captureFile();
        
        var sub_op = try Operation.init(allocator, .file_write, "Pre-operation snapshot");
        sub_op.setPreSnapshot(snapshot);
        
        if (undo_manager.current_batch) |*batch| {
            try batch.sub_operations.append(sub_op);
        } else {
            sub_op.deinit();
        }
    }
    
    // Execute the tool
    const result = try execute_fn();
    
    // Store result in operation for redo capability
    if (undo_manager.current_batch) |*batch| {
        batch.tool_name = try allocator.dupe(u8, tool_name);
        batch.tool_args = try allocator.dupe(u8, args);
        batch.tool_result = try allocator.dupe(u8, result);
        
        // Capture post-snapshots
        for (affected_paths) |path| {
            var snapshot = try Snapshot.init(allocator, .file_content, path);
            try snapshot.captureFile();
            
            var sub_op = try Operation.init(allocator, .file_write, "Post-operation snapshot");
            sub_op.setPostSnapshot(snapshot);
            try batch.sub_operations.append(sub_op);
        }
    }
    
    return result;
}

/// Get affected paths from tool arguments
pub fn extractPathsFromArgs(allocator: std.mem.Allocator, tool_name: []const u8, args: []const u8) ![][]const u8 {
    var paths = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit();
    }
    
    const path_tools = [_][]const u8{"readfile", "writefile", "editfile", "search"};
    
    for (path_tools) |tool| {
        if (std.mem.eql(u8, tool_name, tool)) {
            // Extract path from JSON args
            const path_prefix = "\"path\":\"";
            if (std.mem.indexOf(u8, args, path_prefix)) |start| {
                const value_start = start + path_prefix.len;
                if (std.mem.indexOfPos(u8, args, value_start, "\"")) |end| {
                    const path = try allocator.dupe(u8, args[value_start..end]);
                    try paths.append(path);
                }
            }
            break;
        }
    }
    
    return try paths.toOwnedSlice();
}
