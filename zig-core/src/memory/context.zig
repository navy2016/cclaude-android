//! Context file system - Markdown-based memory storage

const std = @import("std");

pub const TriggerType = enum {
    session_start,
    task_failed,
    task_completed,
};

pub const Trigger = struct {
    trigger_type: TriggerType,
    action: []const u8,
    cooldown_sec: i64,
    last_fired: i64 = 0,
};

pub const ContextFile = struct {
    allocator: std.mem.Allocator,
    filename: []const u8,
    frontmatter: std.StringHashMap([]const u8),
    body: []const u8,
    modified_time: i64,
    
    pub fn init(allocator: std.mem.Allocator, filename: []const u8) ContextFile {
        return .{
            .allocator = allocator,
            .filename = try allocator.dupe(u8, filename),
            .frontmatter = std.StringHashMap([]const u8).init(allocator),
            .body = "",
            .modified_time = 0,
        };
    }
    
    pub fn deinit(self: *ContextFile) void {
        self.allocator.free(self.filename);
        var it = self.frontmatter.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.frontmatter.deinit();
        self.allocator.free(self.body);
    }
    
    pub fn parse(self: *ContextFile, content: []const u8) !void {
        // Parse YAML frontmatter between --- markers
        if (std.mem.startsWith(u8, content, "---\n")) {
            if (std.mem.indexOf(u8, content[4..], "---\n")) |end_pos| {
                const fm_content = content[4..4+end_pos];
                try self.parseFrontmatter(fm_content);
                
                const body_start = 4 + end_pos + 4;
                if (body_start < content.len) {
                    self.body = try self.allocator.dupe(u8, std.mem.trim(u8, content[body_start..], " \n\r\t"));
                }
            }
        } else {
            self.body = try self.allocator.dupe(u8, content);
        }
    }
    
    fn parseFrontmatter(self: *ContextFile, content: []const u8) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, ":")) |colon_pos| {
                const key = std.mem.trim(u8, line[0..colon_pos], " ");
                const value = std.mem.trim(u8, line[colon_pos+1..], " \"");
                try self.frontmatter.put(try self.allocator.dupe(u8, key), try self.allocator.dupe(u8, value));
            }
        }
    }
    
    pub fn serialize(self: ContextFile, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();
        
        // Write frontmatter
        try result.appendSlice("---\n");
        var it = self.frontmatter.iterator();
        while (it.next()) |entry| {
            try result.writer().print("{s}: {s}\n", .{entry.key_ptr.*, entry.value_ptr.*});
        }
        try result.appendSlice("---\n\n");
        
        // Write body
        try result.appendSlice(self.body);
        
        return try allocator.dupe(u8, result.items);
    }
};

pub const ContextStore = struct {
    allocator: std.mem.Allocator,
    data_dir: []const u8,
    files: std.StringHashMap(ContextFile),
    triggers: std.ArrayList(Trigger),
    bootstrapping: bool = false,
    
    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8) !ContextStore {
        var store = ContextStore{
            .allocator = allocator,
            .data_dir = try allocator.dupe(u8, data_dir),
            .files = std.StringHashMap(ContextFile).init(allocator),
            .triggers = std.ArrayList(Trigger).init(allocator),
        };
        
        // Load all context files
        try store.loadAll();
        
        return store;
    }
    
    pub fn deinit(self: *ContextStore) void {
        self.allocator.free(self.data_dir);
        var it = self.files.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.files.deinit();
        self.triggers.deinit();
    }
    
    fn loadAll(self: *ContextStore) !void {
        const filenames = [_][]const u8{"SOUL.md", "USER.md", "MEMORY.md", "BOOTSTRAP.md"};
        
        for (filenames) |filename| {
            const filepath = try std.fs.path.join(self.allocator, &.{self.data_dir, "context", filename});
            defer self.allocator.free(filepath);
            
            const content = std.fs.cwd().readFileAlloc(self.allocator, filepath, 1024 * 1024) catch {
                // File doesn't exist, will be created on demand
                if (std.mem.eql(u8, filename, "BOOTSTRAP.md")) {
                    self.bootstrapping = true;
                }
                continue;
            };
            defer self.allocator.free(content);
            
            var file = ContextFile.init(self.allocator, filename);
            try file.parse(content);
            try self.files.put(try self.allocator.dupe(u8, filename), file);
        }
    }
    
    pub fn getFile(self: ContextStore, filename: []const u8) ?*ContextFile {
        return self.files.getPtr(filename);
    }
    
    pub fn buildPrompt(self: ContextStore, allocator: std.mem.Allocator) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();
        
        // SOUL.md - Agent identity
        if (self.files.get("SOUL.md")) |soul| {
            try result.appendSlice("\n\n## Soul\n");
            try result.appendSlice(soul.body);
        }
        
        // USER.md - User profile
        if (self.files.get("USER.md")) |user| {
            try result.appendSlice("\n\n## User Profile\n");
            try result.appendSlice(user.body);
        }
        
        // MEMORY.md - Project context
        if (self.files.get("MEMORY.md")) |mem| {
            try result.appendSlice("\n\n## Long-term Memory\n");
            try result.appendSlice(mem.body);
        }
        
        return try allocator.dupe(u8, result.items);
    }
    
    pub fn updateFile(self: *ContextStore, filename: []const u8, action: []const u8, content: []const u8, section: ?[]const u8) !void {
        // Validate filename
        const valid_files = [_][]const u8{"SOUL.md", "USER.md", "MEMORY.md"};
        var is_valid = false;
        for (valid_files) |valid| {
            if (std.mem.eql(u8, filename, valid)) {
                is_valid = true;
                break;
            }
        }
        if (!is_valid) return error.InvalidFilename;
        
        var file = self.files.getPtr(filename) orelse {
            // Create new file
            var new_file = ContextFile.init(self.allocator, filename);
            new_file.body = try self.allocator.dupe(u8, content);
            try self.files.put(try self.allocator.dupe(u8, filename), new_file);
            return;
        };
        
        if (std.mem.eql(u8, action, "append")) {
            const new_body = try std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{file.body, content});
            self.allocator.free(file.body);
            file.body = new_body;
        } else if (std.mem.eql(u8, action, "replace_all")) {
            self.allocator.free(file.body);
            file.body = try self.allocator.dupe(u8, content);
        } else if (std.mem.eql(u8, action, "replace_section")) {
            if (section) |sec| {
                try self.replaceSection(file, sec, content);
            }
        }
        
        // Save to disk
        try self.saveFile(filename, file);
    }
    
    fn replaceSection(self: ContextStore, file: *ContextFile, section: []const u8, content: []const u8) !void {
        const section_marker = try std.fmt.allocPrint(self.allocator, "## {s}", .{section});
        defer self.allocator.free(section_marker);
        
        if (std.mem.indexOf(u8, file.body, section_marker)) |start| {
            // Find next section or end of file
            const next_section = std.mem.indexOfPos(u8, file.body, start + section_marker.len, "## ");
            const end = next_section orelse file.body.len;
            
            const new_body = try std.fmt.allocPrint(self.allocator, "{s}{s}\n{s}{s}", .{
                file.body[0..start],
                section_marker,
                content,
                file.body[end..],
            });
            self.allocator.free(file.body);
            file.body = new_body;
        }
    }
    
    fn saveFile(self: ContextStore, filename: []const u8, file: *ContextFile) !void {
        const dir_path = try std.fs.path.join(self.allocator, &.{self.data_dir, "context"});
        defer self.allocator.free(dir_path);
        
        try std.fs.cwd().makePath(dir_path);
        
        const filepath = try std.fs.path.join(self.allocator, &.{dir_path, filename});
        defer self.allocator.free(filepath);
        
        const serialized = try file.serialize(self.allocator);
        defer self.allocator.free(serialized);
        
        const f = try std.fs.cwd().createFile(filepath, .{});
        defer f.close();
        try f.writeAll(serialized);
    }
    
    pub fn checkTriggers(self: *ContextStore, trigger_type: TriggerType) ?[]const u8 {
        const now = std.time.timestamp();
        
        for (self.triggers.items) |*trigger| {
            if (trigger.trigger_type != trigger_type) continue;
            
            if (trigger.cooldown_sec > 0 and trigger.last_fired > 0) {
                if (now - trigger.last_fired < trigger.cooldown_sec) continue;
            }
            
            trigger.last_fired = now;
            return trigger.action;
        }
        
        return null;
    }
    
    /// Check if content is similar to existing memory
    pub fn hasSimilar(self: ContextStore, target_file: []const u8, content: []const u8) bool {
        const file = self.files.get(target_file) orelse return false;
        
        var norm_buf1: [512]u8 = undefined;
        const norm1 = @import("../utils/string.zig").normalize(&norm_buf1, content);
        
        var norm_buf2: [512]u8 = undefined;
        const norm2 = @import("../utils/string.zig").normalize(&norm_buf2, file.body);
        
        // Check for exact match or substring
        if (std.mem.indexOf(u8, norm2, norm1) != null) return true;
        
        // Check similarity ratio
        const similarity = @import("../utils/string.zig").similarityRatio(norm1, norm2);
        return similarity > 60;
    }
};
