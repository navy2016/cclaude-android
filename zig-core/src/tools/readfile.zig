//! readfile tool - Read file contents

const std = @import("std");

pub fn execute(allocator: std.mem.Allocator, args_json: []const u8, _: ?*anyopaque) ![]const u8 {
    // Parse path from JSON args
    const path = try extractPath(allocator, args_json);
    defer allocator.free(path);
    
    // Security: check path is within allowed directory
    // (simplified - real impl would check against data_dir)
    
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return std.fmt.allocPrint(allocator, "Error opening file: {s}", .{@errorName(err)});
    };
    defer file.close();
    
    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        return std.fmt.allocPrint(allocator, "Error reading file: {s}", .{@errorName(err)});
    };
    
    return content;
}

fn extractPath(allocator: std.mem.Allocator, json: []const u8) ![]const u8 {
    // Simple JSON extraction: "path":"..."
    const prefix = "\"path\":\"";
    if (std.mem.indexOf(u8, json, prefix)) |start| {
        const value_start = start + prefix.len;
        if (std.mem.indexOfPos(u8, json, value_start, "\"")) |end| {
            return try allocator.dupe(u8, json[value_start..end]);
        }
    }
    return error.InvalidArgs;
}
