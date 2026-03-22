//! Snapshot system - Capture state before operations

const std = @import("std");

pub const SnapshotType = enum {
    file_content,      // File before write/edit
    file_existence,    // Whether file existed (for create/delete)
    memory_section,    // Memory file section
    full_memory,       // Complete memory file
    directory_state,   // Directory contents
};

/// A snapshot captures state that can be restored
pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    snapshot_type: SnapshotType,
    target_path: []const u8,
    data: []const u8,           // Serialized state
    metadata: std.StringHashMap([]const u8),
    timestamp: i64,
    
    pub fn init(allocator: std.mem.Allocator, snapshot_type: SnapshotType, target_path: []const u8) !Snapshot {
        return .{
            .allocator = allocator,
            .snapshot_type = snapshot_type,
            .target_path = try allocator.dupe(u8, target_path),
            .data = &[_]u8{},
            .metadata = std.StringHashMap([]const u8).init(allocator),
            .timestamp = std.time.timestamp(),
        };
    }
    
    pub fn deinit(self: *Snapshot) void {
        self.allocator.free(self.target_path);
        self.allocator.free(self.data);
        var it = self.metadata.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }
    
    /// Create snapshot of file content
    pub fn captureFile(self: *Snapshot) !void {
        const file = std.fs.cwd().openFile(self.target_path, .{}) catch {
            // File doesn't exist - mark as non-existent
            try self.metadata.put(try self.allocator.dupe(u8, "exists"), try self.allocator.dupe(u8, "false"));
            return;
        };
        defer file.close();
        
        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024); // 10MB max
        self.allocator.free(self.data);
        self.data = content;
        
        try self.metadata.put(try self.allocator.dupe(u8, "exists"), try self.allocator.dupe(u8, "true"));
        try self.metadata.put(try self.allocator.dupe(u8, "size"), try std.fmt.allocPrint(self.allocator, "{d}", .{content.len}));
    }
    
    /// Restore file from snapshot
    pub fn restoreFile(self: Snapshot) !void {
        const exists = self.metadata.get("exists") orelse "false";
        
        if (std.mem.eql(u8, exists, "false")) {
            // File didn't exist before - delete it
            std.fs.cwd().deleteFile(self.target_path) catch {};
            return;
        }
        
        // Restore content
        const file = try std.fs.cwd().createFile(self.target_path, .{});
        defer file.close();
        try file.writeAll(self.data);
    }
    
    /// Create snapshot of memory section
    pub fn captureMemorySection(self: *Snapshot, section: []const u8) !void {
        self.allocator.free(self.data);
        self.data = try self.allocator.dupe(u8, section);
    }
    
    /// Serialize snapshot for storage
    pub fn serialize(self: Snapshot, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();
        
        // Write header
        try result.writer().print("SNAPSHOT\nTYPE:{s}\nPATH:{s}\nTIME:{d}\n", .{
            @tagName(self.snapshot_type),
            self.target_path,
            self.timestamp,
        });
        
        // Write metadata
        try result.appendSlice("META:\n");
        var it = self.metadata.iterator();
        while (it.next()) |entry| {
            try result.writer().print("{s}:{s}\n", .{entry.key_ptr.*, entry.value_ptr.*});
        }
        
        // Write data length and data
        try result.writer().print("DATA:{d}\n", .{self.data.len});
        try result.appendSlice(self.data);
        
        return try allocator.dupe(u8, result.items);
    }
};

/// Snapshot manager for bulk operations
pub const SnapshotManager = struct {
    allocator: std.mem.Allocator,
    snapshots: std.ArrayList(Snapshot),
    
    pub fn init(allocator: std.mem.Allocator) SnapshotManager {
        return .{
            .allocator = allocator,
            .snapshots = std.ArrayList(Snapshot).init(allocator),
        };
    }
    
    pub fn deinit(self: *SnapshotManager) void {
        for (self.snapshots.items) |*snapshot| {
            snapshot.deinit();
        }
        self.snapshots.deinit();
    }
    
    pub fn captureFile(self: *SnapshotManager, path: []const u8) !void {
        var snapshot = try Snapshot.init(self.allocator, .file_content, path);
        try snapshot.captureFile();
        try self.snapshots.append(snapshot);
    }
    
    pub fn restoreAll(self: SnapshotManager) !void {
        // Restore in reverse order
        var i: usize = self.snapshots.items.len;
        while (i > 0) : (i -= 1) {
            try self.snapshots.items[i - 1].restoreFile();
        }
    }
    
    pub fn clear(self: *SnapshotManager) void {
        for (self.snapshots.items) |*snapshot| {
            snapshot.deinit();
        }
        self.snapshots.clearRetainingCapacity();
    }
};
