//! writefile tool - Write content to file

const std = @import("std");

pub fn execute(allocator: std.mem.Allocator, args_json: []const u8, _: ?*anyopaque) ![]const u8 {
    const Args = struct {
        path: []const u8,
        content: []const u8,
    };
    
    var args: Args = undefined;
    
    // Parse path
    const path_prefix = "\"path\":\"";
    if (std.mem.indexOf(u8, args_json, path_prefix)) |start| {
        const value_start = start + path_prefix.len;
        if (std.mem.indexOfPos(u8, args_json, value_start, "\"")) |end| {
            args.path = args_json[value_start..end];
        } else return error.InvalidArgs;
    } else return error.InvalidArgs;
    
    // Parse content
    const content_prefix = "\"content\":\"";
    if (std.mem.indexOf(u8, args_json, content_prefix)) |start| {
        const value_start = start + content_prefix.len;
        // Find end of content (handle escaped quotes)
        var end = value_start;
        while (end < args_json.len) : (end += 1) {
            if (args_json[end] == '"' and args_json[end - 1] != '\\') break;
        }
        args.content = args_json[value_start..end];
    } else return error.InvalidArgs;
    
    // Create parent directories if needed
    if (std.mem.lastIndexOf(u8, args.path, "/")) |last_slash| {
        const dir_path = args.path[0..last_slash];
        std.fs.cwd().makePath(dir_path) catch {};
    }
    
    const file = try std.fs.cwd().createFile(args.path, .{});
    defer file.close();
    
    try file.writeAll(args.content);
    
    return try std.fmt.allocPrint(allocator, "File written successfully: {s}", .{args.path});
}
