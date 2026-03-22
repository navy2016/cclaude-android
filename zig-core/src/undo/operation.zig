//! Operation log - Records all undoable actions

const std = @import("std");
const Snapshot = @import("snapshot.zig").Snapshot;

pub const OperationType = enum {
    file_write,
    file_edit,
    file_delete,
    file_move,
    shell_command,
    memory_update,
    memory_append,
    memory_replace_section,
    tool_execution,
    batch_operation,   // Group of operations
};

/// An operation that can be undone/redone
pub const Operation = struct {
    allocator: std.mem.Allocator,
    operation_type: OperationType,
    id: []const u8,           // Unique operation ID
    description: []const u8,  // Human-readable description
    timestamp: i64,
    
    // State for undo/redo
    pre_snapshot: ?Snapshot,  // State before operation
    post_snapshot: ?Snapshot, // State after operation (for redo)
    
    // Operation-specific data
    tool_name: ?[]const u8,
    tool_args: ?[]const u8,
    tool_result: ?[]const u8,
    
    // For compound operations
    sub_operations: std.ArrayList(Operation),
    
    // Redo info - how to re-apply the operation
    redo_data: ?[]const u8,
    
    pub fn init(allocator: std.mem.Allocator, operation_type: OperationType, description: []const u8) !Operation {
        const id = try std.fmt.allocPrint(allocator, "op_{d}_{d}", .{
            std.time.timestamp(),
            std.crypto.random.int(u32),
        });
        
        return .{
            .allocator = allocator,
            .operation_type = operation_type,
            .id = id,
            .description = try allocator.dupe(u8, description),
            .timestamp = std.time.timestamp(),
            .pre_snapshot = null,
            .post_snapshot = null,
            .tool_name = null,
            .tool_args = null,
            .tool_result = null,
            .sub_operations = std.ArrayList(Operation).init(allocator),
            .redo_data = null,
        };
    }
    
    pub fn deinit(self: *Operation) void {
        self.allocator.free(self.id);
        self.allocator.free(self.description);
        
        if (self.pre_snapshot) |*snapshot| snapshot.deinit();
        if (self.post_snapshot) |*snapshot| snapshot.deinit();
        
        if (self.tool_name) |name| self.allocator.free(name);
        if (self.tool_args) |args| self.allocator.free(args);
        if (self.tool_result) |result| self.allocator.free(result);
        if (self.redo_data) |data| self.allocator.free(data);
        
        for (self.sub_operations.items) |*op| {
            op.deinit();
        }
        self.sub_operations.deinit();
    }
    
    /// Set pre-operation snapshot
    pub fn setPreSnapshot(self: *Operation, snapshot: Snapshot) void {
        if (self.pre_snapshot) |*s| s.deinit();
        self.pre_snapshot = snapshot;
    }
    
    /// Set post-operation snapshot
    pub fn setPostSnapshot(self: *Operation, snapshot: Snapshot) void {
        if (self.post_snapshot) |*s| s.deinit();
        self.post_snapshot = snapshot;
    }
    
    /// Set tool info
    pub fn setToolInfo(self: *Operation, name: []const u8, args: []const u8, result: []const u8) !void {
        self.tool_name = try self.allocator.dupe(u8, name);
        self.tool_args = try self.allocator.dupe(u8, args);
        self.tool_result = try self.allocator.dupe(u8, result);
    }
    
    /// Undo this operation
    pub fn undo(self: Operation) !void {
        if (self.pre_snapshot) |snapshot| {
            try snapshot.restoreFile();
        }
    }
    
    /// Redo this operation
    pub fn redo(self: Operation) !void {
        if (self.post_snapshot) |snapshot| {
            try snapshot.restoreFile();
        } else if (self.redo_data) |data| {
            // Re-execute based on redo data
            _ = data;
            // Implementation depends on operation type
        }
    }
    
    /// Check if operation can be undone
    pub fn canUndo(self: Operation) bool {
        return self.pre_snapshot != null;
    }
    
    /// Serialize operation for persistence
    pub fn serialize(self: Operation, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();
        
        try result.writer().print(
            \\{{
            \\  "id": "{s}",
            \\  "type": "{s}",
            \\  "description": "{s}",
            \\  "timestamp": {d},
            \\  "undoable": {}
            \\}}
        , .{
            self.id,
            @tagName(self.operation_type),
            self.description,
            self.timestamp,
            self.canUndo(),
        });
        
        return try allocator.dupe(u8, result.items);
    }
};

/// Operation builder for complex operations
pub const OperationBuilder = struct {
    allocator: std.mem.Allocator,
    operation: ?Operation,
    
    pub fn init(allocator: std.mem.Allocator, operation_type: OperationType, description: []const u8) !OperationBuilder {
        return .{
            .allocator = allocator,
            .operation = try Operation.init(allocator, operation_type, description),
        };
    }
    
    pub fn withPreSnapshot(self: *OperationBuilder, snapshot: Snapshot) !*OperationBuilder {
        if (self.operation) |*op| {
            op.setPreSnapshot(snapshot);
        }
        return self;
    }
    
    pub fn withToolInfo(self: *OperationBuilder, name: []const u8, args: []const u8, result: []const u8) !*OperationBuilder {
        if (self.operation) |*op| {
            try op.setToolInfo(name, args, result);
        }
        return self;
    }
    
    pub fn build(self: *OperationBuilder) ?Operation {
        const result = self.operation;
        self.operation = null;
        return result;
    }
    
    pub fn deinit(self: *OperationBuilder) void {
        if (self.operation) |*op| {
            op.deinit();
        }
    }
};
