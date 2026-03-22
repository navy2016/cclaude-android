//! glob tool - Find files by pattern

const std = @import("std");

pub fn execute(allocator: std.mem.Allocator, args_json: []const u8, _: ?*anyopaque) ![]const u8 {
    const pattern_prefix = "\"pattern\":\"";
    var pattern: []const u8 = "*";
    
    if (std.mem.indexOf(u8, args_json, pattern_prefix)) |start| {
        const value_start = start + pattern_prefix.len;
        if (std.mem.indexOfPos(u8, args_json, value_start, "\"")) |end| {
            pattern = args_json[value_start..end];
        }
    }
    
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch {
        return try allocator.dupe(u8, "Error: cannot open directory");
    };
    defer dir.close();
    
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        
        // Simple glob matching (just checks suffix for now)
        if (std.mem.endsWith(u8, entry.name, pattern[1..])) {
            try result.writer().print("{s}\n", .{entry.name});
        }
    }
    
    if (result.items.len == 0) {
        return try allocator.dupe(u8, "No files found");
    }
    
    return try allocator.dupe(u8, result.items);
}
