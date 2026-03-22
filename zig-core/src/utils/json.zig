//! Simple JSON utilities

const std = @import("std");

/// Parse a simple string value from JSON
pub fn parseStringValue(allocator: std.mem.Allocator, json_str: []const u8, key: []const u8) !?[]const u8 {
    const pattern = try std.fmt.allocPrint(allocator, "\"{s}\":", .{key});
    defer allocator.free(pattern);
    
    if (std.mem.indexOf(u8, json_str, pattern)) |start| {
        var pos = start + pattern.len;
        while (pos < json_str.len and json_str[pos] == ' ') pos += 1;
        if (pos < json_str.len and json_str[pos] == '"') {
            const str_start = pos + 1;
            var end_pos = str_start;
            while (end_pos < json_str.len) : (end_pos += 1) {
                if (json_str[end_pos] == '"' and json_str[end_pos - 1] != '\\') break;
            }
            return try allocator.dupe(u8, json_str[str_start..end_pos]);
        }
    }
    return null;
}

/// Parse a JSON array of objects
pub fn parseArrayObjects(allocator: std.mem.Allocator, json_str: []const u8, array_key: []const u8) !std.ArrayList([]const u8) {
    var results = std.ArrayList([]const u8).init(allocator);
    errdefer results.deinit();
    
    const pattern = try std.fmt.allocPrint(allocator, "\"{s}\": [", .{array_key});
    defer allocator.free(pattern);
    
    if (std.mem.indexOf(u8, json_str, pattern)) |start| {
        var depth: i32 = 1;
        var obj_start: ?usize = null;
        var pos = start + pattern.len;
        
        while (pos < json_str.len and depth > 0) {
            switch (json_str[pos]) {
                '{' => {
                    if (depth == 1) obj_start = pos;
                    depth += 1;
                },
                '}' => {
                    depth -= 1;
                    if (depth == 1 and obj_start != null) {
                        const obj = try allocator.dupe(u8, json_str[obj_start.?..pos+1]);
                        try results.append(obj);
                        obj_start = null;
                    }
                },
                ']' => {
                    if (depth == 1) depth -= 1;
                },
                else => {},
            }
            pos += 1;
        }
    }
    
    return results;
}
