//! Tool System - 8 Core Tools (with Undo Support)
//! 
//! Tools: readfile, writefile, editfile, search, glob, fetch, web_search, shell
//! All file-modifying tools automatically support undo via snapshot system.

const std = @import("std");

pub const readfile = @import("readfile.zig");
pub const writefile = @import("writefile.zig");
pub const editfile = @import("editfile.zig");
pub const search = @import("search.zig");
pub const glob = @import("glob.zig");
pub const fetch = @import("fetch.zig");
pub const web_search = @import("web_search.zig");
pub const shell = @import("shell.zig");
pub const undoable = @import("undoable.zig");

/// Tool risk level
pub const RiskLevel = enum {
    safe,
    moderate,
    dangerous,
};

/// Tool definition
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    risk_level: RiskLevel,
    supports_undo: bool,
    execute: *const fn (allocator: std.mem.Allocator, args: []const u8, userdata: ?*anyopaque) anyerror![]const u8,
};

/// Tool context passed during execution
pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    undo_manager: ?*@import("../undo/root.zig").UndoManager,
    data_dir: []const u8,
};

/// Tool registry
pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMap(Tool),
    undo_manager: ?*@import("../undo/root.zig").UndoManager = null,
    
    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{
            .allocator = allocator,
            .tools = std.StringHashMap(Tool).init(allocator),
        };
    }
    
    pub fn deinit(self: *ToolRegistry) void {
        self.tools.deinit();
    }
    
    pub fn setUndoManager(self: *ToolRegistry, undo_manager: *@import("../undo/root.zig").UndoManager) void {
        self.undo_manager = undo_manager;
    }
    
    pub fn register(self: *ToolRegistry, tool: Tool) !void {
        try self.tools.put(tool.name, tool);
    }
    
    pub fn get(self: ToolRegistry, name: []const u8) ?Tool {
        return self.tools.get(name);
    }
    
    /// Execute tool with undo support
    pub fn execute(self: ToolRegistry, allocator: std.mem.Allocator, name: []const u8, args: []const u8) ![]const u8 {
        const tool = self.get(name) orelse return error.UnknownTool;
        
        // If tool supports undo and we have an undo manager
        if (tool.supports_undo and self.undo_manager != null) {
            const paths = try undoable.extractPathsFromArgs(allocator, name, args);
            defer {
                for (paths) |p| allocator.free(p);
                allocator.free(paths);
            }
            
            return undoable.executeWithUndo(
                allocator,
                self.undo_manager.?,
                name,
                args,
                paths,
                struct {
                    allocator: std.mem.Allocator,
                    tool: Tool,
                    args: []const u8,
                    fn exec(self_exec: @This()) ![]const u8 {
                        return self_exec.tool.execute(self_exec.allocator, self_exec.args, null);
                    }
                }{ .allocator = allocator, .tool = tool, .args = args },
            );
        }
        
        // Execute without undo
        return tool.execute(allocator, args, null);
    }
    
    /// Register all 8 core tools
    pub fn registerCoreTools(self: *ToolRegistry) !void {
        try self.register(.{
            .name = "readfile",
            .description = "Read file contents",
            .risk_level = .safe,
            .supports_undo = false,  // Read doesn't modify
            .execute = readfile.execute,
        });
        try self.register(.{
            .name = "writefile",
            .description = "Write content to file",
            .risk_level = .moderate,
            .supports_undo = true,
            .execute = writefile.execute,
        });
        try self.register(.{
            .name = "editfile",
            .description = "Edit file by find/replace",
            .risk_level = .moderate,
            .supports_undo = true,
            .execute = editfile.execute,
        });
        try self.register(.{
            .name = "search",
            .description = "Search files with grep pattern",
            .risk_level = .safe,
            .supports_undo = false,  // Read-only
            .execute = search.execute,
        });
        try self.register(.{
            .name = "glob",
            .description = "Find files by pattern",
            .risk_level = .safe,
            .supports_undo = false,  // Read-only
            .execute = glob.execute,
        });
        try self.register(.{
            .name = "fetch",
            .description = "HTTP fetch URL",
            .risk_level = .safe,
            .supports_undo = false,  // Network operation
            .execute = fetch.execute,
        });
        try self.register(.{
            .name = "web_search",
            .description = "Search web using DuckDuckGo",
            .risk_level = .safe,
            .supports_undo = false,  // Network operation
            .execute = web_search.execute,
        });
        try self.register(.{
            .name = "shell",
            .description = "Execute shell command",
            .risk_level = .dangerous,
            .supports_undo = false,  // External command - can't reliably undo
            .execute = shell.execute,
        });
    }
};

test {
    _ = readfile;
    _ = writefile;
    _ = editfile;
    _ = search;
    _ = glob;
    _ = fetch;
    _ = web_search;
    _ = shell;
    _ = undoable;
}
