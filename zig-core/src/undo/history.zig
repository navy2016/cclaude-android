//! Undo/Redo history manager

const std = @import("std");
const Operation = @import("operation.zig").Operation;

pub const UndoManager = struct {
    allocator: std.mem.Allocator,
    
    // Stacks
    undo_stack: std.ArrayList(Operation),
    redo_stack: std.ArrayList(Operation),
    
    // Configuration
    max_history: usize,       // Maximum operations to keep
    persist_history: bool,    // Save history to disk
    history_dir: []const u8,
    
    // State
    is_undoing: bool = false,
    is_redoing: bool = false,
    
    // Batching
    batch_depth: u32 = 0,
    current_batch: ?Operation = null,
    
    // Callbacks
    on_change: ?*const fn () void = null,
    
    pub fn init(allocator: std.mem.Allocator, max_history: usize, persist_history: bool, history_dir: []const u8) !UndoManager {
        // Create history directory if needed
        if (persist_history) {
            try std.fs.cwd().makePath(history_dir);
        }
        
        return .{
            .allocator = allocator,
            .undo_stack = std.ArrayList(Operation).init(allocator),
            .redo_stack = std.ArrayList(Operation).init(allocator),
            .max_history = max_history,
            .persist_history = persist_history,
            .history_dir = try allocator.dupe(u8, history_dir),
        };
    }
    
    pub fn deinit(self: *UndoManager) void {
        for (self.undo_stack.items) |*op| op.deinit();
        for (self.redo_stack.items) |*op| op.deinit();
        
        self.undo_stack.deinit();
        self.redo_stack.deinit();
        
        if (self.current_batch) |*batch| batch.deinit();
        
        self.allocator.free(self.history_dir);
    }
    
    /// Record an operation
    pub fn record(self: *UndoManager, operation: Operation) !void {
        // If we're in a batch, add to batch
        if (self.batch_depth > 0) {
            if (self.current_batch) |*batch| {
                try batch.sub_operations.append(operation);
            }
            return;
        }
        
        // Clear redo stack on new operation
        for (self.redo_stack.items) |*op| op.deinit();
        self.redo_stack.clearRetainingCapacity();
        
        // Add to undo stack
        try self.undo_stack.append(operation);
        
        // Trim if exceeding max
        if (self.undo_stack.items.len > self.max_history) {
            var old_op = self.undo_stack.orderedRemove(0);
            old_op.deinit();
        }
        
        // Persist if enabled
        if (self.persist_history) {
            try self.persistOperation(operation);
        }
        
        // Notify
        if (self.on_change) |callback| callback();
    }
    
    /// Begin a batch operation
    pub fn beginBatch(self: *UndoManager, description: []const u8) !void {
        if (self.batch_depth == 0) {
            self.current_batch = try Operation.init(
                self.allocator,
                .batch_operation,
                description
            );
        }
        self.batch_depth += 1;
    }
    
    /// End a batch operation
    pub fn endBatch(self: *UndoManager) !void {
        if (self.batch_depth == 0) return;
        
        self.batch_depth -= 1;
        
        if (self.batch_depth == 0) {
            if (self.current_batch) |batch| {
                // Only add if there are sub-operations
                if (batch.sub_operations.items.len > 0) {
                    try self.record(batch);
                    self.current_batch = null;
                } else {
                    var b = batch;
                    b.deinit();
                    self.current_batch = null;
                }
            }
        }
    }
    
    /// Cancel current batch
    pub fn cancelBatch(self: *UndoManager) void {
        if (self.current_batch) |*batch| {
            // Undo all sub-operations
            var i: usize = batch.sub_operations.items.len;
            while (i > 0) : (i -= 1) {
                batch.sub_operations.items[i - 1].undo() catch {};
            }
            batch.deinit();
            self.current_batch = null;
        }
        self.batch_depth = 0;
    }
    
    /// Undo last operation
    pub fn undo(self: *UndoManager) !?Operation {
        if (self.undo_stack.items.len == 0) return null;
        
        self.is_undoing = true;
        defer self.is_undoing = false;
        
        // Get last operation
        var operation = self.undo_stack.pop();
        
        // Perform undo
        try operation.undo();
        
        // Move to redo stack
        try self.redo_stack.append(operation);
        
        if (self.on_change) |callback| callback();
        
        return operation;
    }
    
    /// Redo last undone operation
    pub fn redo(self: *UndoManager) !?Operation {
        if (self.redo_stack.items.len == 0) return null;
        
        self.is_redoing = true;
        defer self.is_redoing = false;
        
        // Get last redo operation
        var operation = self.redo_stack.pop();
        
        // Perform redo
        try operation.redo();
        
        // Move back to undo stack
        try self.undo_stack.append(operation);
        
        if (self.on_change) |callback| callback();
        
        return operation;
    }
    
    /// Check if can undo
    pub fn canUndo(self: UndoManager) bool {
        return self.undo_stack.items.len > 0;
    }
    
    /// Check if can redo
    pub fn canRedo(self: UndoManager) bool {
        return self.redo_stack.items.len > 0;
    }
    
    /// Get undo description (for UI)
    pub fn getUndoDescription(self: UndoManager) ?[]const u8 {
        if (self.undo_stack.items.len == 0) return null;
        return self.undo_stack.items[self.undo_stack.items.len - 1].description;
    }
    
    /// Get redo description (for UI)
    pub fn getRedoDescription(self: UndoManager) ?[]const u8 {
        if (self.redo_stack.items.len == 0) return null;
        return self.redo_stack.items[self.redo_stack.items.len - 1].description;
    }
    
    /// Clear all history
    pub fn clear(self: *UndoManager) void {
        for (self.undo_stack.items) |*op| op.deinit();
        for (self.redo_stack.items) |*op| op.deinit();
        
        self.undo_stack.clearRetainingCapacity();
        self.redo_stack.clearRetainingCapacity();
        
        if (self.on_change) |callback| callback();
    }
    
    /// Get operation count
    pub fn getHistorySize(self: UndoManager) usize {
        return self.undo_stack.items.len;
    }
    
    /// Get all operations (for history view)
    pub fn getOperations(self: UndoManager) []const Operation {
        return self.undo_stack.items;
    }
    
    /// Persist operation to disk
    fn persistOperation(self: UndoManager, operation: Operation) !void {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json", .{
            self.history_dir,
            operation.id,
        });
        defer self.allocator.free(filename);
        
        const data = try operation.serialize(self.allocator);
        defer self.allocator.free(data);
        
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        try file.writeAll(data);
    }
    
    /// Load history from disk
    pub fn loadHistory(self: *UndoManager) !void {
        if (!self.persist_history) return;
        
        var dir = std.fs.cwd().openDir(self.history_dir, .{ .iterate = true }) catch return;
        defer dir.close();
        
        var entries = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (entries.items) |entry| self.allocator.free(entry);
            entries.deinit();
        }
        
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            try entries.append(try self.allocator.dupe(u8, entry.name));
        }
        
        // Sort by timestamp and load
        // (simplified - would need to parse JSON to get timestamps)
    }
};
