//! Memory Version Control - Track changes to context files
//!
//! Each memory file (SOUL.md, USER.md, MEMORY.md) has a git-like
//! history with commits that can be checked out, compared, and restored.

const std = @import("std");
const ContextFile = @import("context.zig").ContextFile;
const Snapshot = @import("../undo/snapshot.zig").Snapshot;

pub const MemoryVersion = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    timestamp: i64,
    message: []const u8,       // Commit message
    author: []const u8,        // "user" or "agent"
    snapshot: Snapshot,        // Full file snapshot
    parent_id: ?[]const u8,    // Previous version
    
    pub fn init(allocator: std.mem.Allocator, filename: []const u8, message: []const u8, author: []const u8) !MemoryVersion {
        const id = try std.fmt.allocPrint(allocator, "{x:0>16}", .{std.crypto.random.int(u64)});
        
        var snapshot = try Snapshot.init(allocator, .full_memory, filename);
        try snapshot.captureFile();
        
        return .{
            .allocator = allocator,
            .id = id,
            .timestamp = std.time.timestamp(),
            .message = try allocator.dupe(u8, message),
            .author = try allocator.dupe(u8, author),
            .snapshot = snapshot,
            .parent_id = null,
        };
    }
    
    pub fn deinit(self: *MemoryVersion) void {
        self.allocator.free(self.id);
        self.allocator.free(self.message);
        self.allocator.free(self.author);
        self.snapshot.deinit();
        if (self.parent_id) |pid| self.allocator.free(pid);
    }
};

pub const MemoryVersionControl = struct {
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    versions: std.StringHashMap(std.ArrayList(MemoryVersion)),  // filename -> versions
    current_version: std.StringHashMap([]const u8),              // filename -> current version id
    
    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8) !MemoryVersionControl {
        var vc = MemoryVersionControl{
            .allocator = allocator,
            .data_dir = try allocator.dupe(u8, data_dir),
            .versions = std.StringHashMap(std.ArrayList(MemoryVersion)).init(allocator),
            .current_version = std.StringHashMap([]const u8).init(allocator),
        };
        
        try vc.loadHistory();
        
        return vc;
    }
    
    pub fn deinit(self: *MemoryVersionControl) void {
        var it = self.versions.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |*v| v.deinit();
            entry.value_ptr.deinit();
        }
        self.versions.deinit();
        
        var cv_it = self.current_version.iterator();
        while (cv_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.current_version.deinit();
        
        self.allocator.free(self.data_dir);
    }
    
    /// Commit a new version of a memory file
    pub fn commit(self: *MemoryVersionControl, filename: []const u8, message: []const u8, author: []const u8) ![]const u8 {
        var version = try MemoryVersion.init(self.allocator, filename, message, author);
        
        // Set parent to current version
        if (self.current_version.get(filename)) |current| {
            version.parent_id = try self.allocator.dupe(u8, current);
        }
        
        // Store version
        const gop = try self.versions.getOrPut(filename);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(MemoryVersion).init(self.allocator);
        }
        try gop.value_ptr.append(version);
        
        // Update current version
        const owned_filename = try self.allocator.dupe(u8, filename);
        if (self.current_version.fetchPut(owned_filename, try self.allocator.dupe(u8, version.id))) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        
        // Persist
        try self.persistVersion(filename, version);
        
        return version.id;
    }
    
    /// Get version history for a file
    pub fn getHistory(self: MemoryVersionControl, filename: []const u8) ?[]const MemoryVersion {
        if (self.versions.get(filename)) |versions| {
            return versions.items;
        }
        return null;
    }
    
    /// Checkout a specific version
    pub fn checkout(self: *MemoryVersionControl, filename: []const u8, version_id: []const u8) !void {
        if (self.versions.get(filename)) |versions| {
            for (versions.items) |version| {
                if (std.mem.eql(u8, version.id, version_id)) {
                    // Restore snapshot
                    try version.snapshot.restoreFile();
                    
                    // Update current version
                    const owned_filename = try self.allocator.dupe(u8, filename);
                    if (self.current_version.fetchPut(owned_filename, try self.allocator.dupe(u8, version_id))) |old| {
                        self.allocator.free(old.key);
                        self.allocator.free(old.value);
                    }
                    
                    return;
                }
            }
        }
        return error.VersionNotFound;
    }
    
    /// Restore to previous version (undo last change)
    pub fn undo(self: *MemoryVersionControl, filename: []const u8) !void {
        const current_id = self.current_version.get(filename) orelse return error.NoCurrentVersion;
        
        if (self.versions.get(filename)) |versions| {
            for (versions.items) |version| {
                if (std.mem.eql(u8, version.id, current_id)) {
                    if (version.parent_id) |parent_id| {
                        try self.checkout(filename, parent_id);
                        return;
                    }
                    return error.NoParentVersion;
                }
            }
        }
        return error.VersionNotFound;
    }
    
    /// Compare two versions
    pub fn diff(self: MemoryVersionControl, version1_id: []const u8, version2_id: []const u8) ![]const u8 {
        _ = self;
        _ = version1_id;
        _ = version2_id;
        // Would implement diff algorithm
        return "Diff not implemented in this version";
    }
    
    /// Load version history from disk
    fn loadHistory(self: *MemoryVersionControl) !void {
        const history_dir = try std.fs.path.join(self.allocator, &.{self.data_dir, "history"});
        defer self.allocator.free(history_dir);
        
        var dir = std.fs.cwd().openDir(history_dir, .{ .iterate = true }) catch return;
        defer dir.close();
        
        // Load saved versions
        // (simplified - would load from serialized files)
    }
    
    /// Persist version to disk
    fn persistVersion(self: MemoryVersionControl, filename: []const u8, version: MemoryVersion) !void {
        const history_dir = try std.fs.path.join(self.allocator, &.{self.data_dir, "history"});
        defer self.allocator.free(history_dir);
        
        try std.fs.cwd().makePath(history_dir);
        
        const filepath = try std.fs.path.join(self.allocator, &.{
            history_dir,
            try std.fmt.allocPrint(self.allocator, "{s}_{s}.snap", .{filename, version.id}),
        });
        defer self.allocator.free(filepath);
        
        const serialized = try version.snapshot.serialize(self.allocator);
        defer self.allocator.free(serialized);
        
        const file = try std.fs.cwd().createFile(filepath, .{});
        defer file.close();
        try file.writeAll(serialized);
    }
};
