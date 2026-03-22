//! search tool - Search files with grep pattern

const std = @import("std");

pub fn execute(allocator: std.mem.Allocator, args_json: []const u8, _: ?*anyopaque) ![]const u8 {
    const Args = struct {
        path: []const u8,
        regex: []const u8,
    };
    
    var args: Args = undefined;
    
    // Parse path (optional, default ".")
    args.path = ".";
    const path_prefix = "\"path\":\"";
    if (std.mem.indexOf(u8, args_json, path_prefix)) |start| {
        const value_start = start + path_prefix.len;
        if (std.mem.indexOfPos(u8, args_json, value_start, "\"")) |end| {
            args.path = args_json[value_start..end];
        }
    }
    
    // Parse regex pattern
    const regex_prefix = "\"regex\":\"";
    if (std.mem.indexOf(u8, args_json, regex_prefix)) |start| {
        const value_start = start + regex_prefix.len;
        if (std.mem.indexOfPos(u8, args_json, value_start, "\"")) |end| {
            args.regex = args_json[value_start..end];
        } else return error.InvalidArgs;
    } else return error.InvalidArgs;
    
    // Simple recursive search (simplified - no actual regex)
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    var dir = std.fs.cwd().openDir(args.path, .{ .iterate = true }) catch {
        return try std.fmt.allocPrint(allocator, "Error: cannot open directory {s}", .{args.path});
    };
    defer dir.close();
    
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        
        const file = dir.openFile(entry.path, .{}) catch continue;
        defer file.close();
        
        const content = file.readToEndAlloc(allocator, 1024 * 1024) catch continue;
        defer allocator.free(content);
        
        // Simple substring search (not regex)
        if (std.mem.indexOf(u8, content, args.regex)) |_| {
            try result.writer().print("{s}\n", .{entry.path});
        }
    }
    
    if (result.items.len == 0) {
        return try allocator.dupe(u8, "No matches found");
    }
    
    return try allocator.dupe(u8, result.items);
}
