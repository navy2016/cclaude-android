//! Simple JSON utilities (minimal implementation)
//! For complex JSON, consider using a full library

const std = @import("std");

/// Parse a simple string value from JSON (handles escaped quotes)
pub fn parseStringValue(allocator: std.mem.Allocator, json_str: []const u8, key: []const u8) !?[]const u8 {
    const pattern = try std.fmt.allocPrint(allocator, "\"{s}\":\s*\"", .{key});
    defer allocator.free(pattern);
    
    if (std.mem.indexOf(u8, json_str, pattern)) |start| {
        const value_start = start + pattern.len;
        var end = value_start;
        while (end < json_str.len) : (end += 1) {
            if (json_str[end] == '"' and json_str[end - 1] != '\\') break;
        }
        return try allocator.dupe(u8, json_str[value_start..end]);
    }
    return null;
}

/// Parse a JSON array of objects (simplified)
pub fn parseArrayObjects(allocator: std.mem.Allocator, json_str: []const u8, array_key: []const u8) !std.ArrayList([]const u8) {
    var results = std.ArrayList([]const u8).init(allocator);
    errdefer results.deinit();
    
    const pattern = try std.fmt.allocPrint(allocator, "\"{s}\":\s*\[", .{array_key});
    defer allocator.free(pattern);
    
    if (std.mem.indexOf(u8, json_str, pattern)) |start| {
        var depth: i32 = 1;
        var obj_start: ?usize = null;
        var i = start + pattern.len;
        
        while (i < json_str.len and depth > 0) : (i += 1) {
            switch (json_str[i]) {
                '{' => {
                    if (depth == 1) obj_start = i;
                    depth += 1;
                },
                '}' => {
                    depth -= 1;
                    if (depth == 1 and obj_start != null) {
                        const obj = try allocator.dupe(u8, json_str[obj_start.?..i+1]);
                        try results.append(obj);
                        obj_start = null;
                    }
                },
                ']' => if (depth == 1) depth -= 1,
                else => {},
            }
        }
    }
    
    return results;
}
