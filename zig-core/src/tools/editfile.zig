//! editfile tool - Edit file by find/replace

const std = @import("std");

pub fn execute(allocator: std.mem.Allocator, args_json: []const u8, _: ?*anyopaque) ![]const u8 {
    const Args = struct {
        path: []const u8,
        old_string: []const u8,
        new_string: []const u8,
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
    
    // Parse old_string
    const old_prefix = "\"old_string\":\"";
    if (std.mem.indexOf(u8, args_json, old_prefix)) |start| {
        const value_start = start + old_prefix.len;
        var end = value_start;
        while (end < args_json.len) : (end += 1) {
            if (args_json[end] == '"' and args_json[end - 1] != '\\') break;
        }
        args.old_string = args_json[value_start..end];
    } else return error.InvalidArgs;
    
    // Parse new_string
    const new_prefix = "\"new_string\":\"";
    if (std.mem.indexOf(u8, args_json, new_prefix)) |start| {
        const value_start = start + new_prefix.len;
        var end = value_start;
        while (end < args_json.len) : (end += 1) {
            if (args_json[end] == '"' and args_json[end - 1] != '\\') break;
        }
        args.new_string = args_json[value_start..end];
    } else return error.InvalidArgs;
    
    // Read file
    const file = try std.fs.cwd().openFile(args.path, .{});
    defer file.close();
    
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);
    
    // Find and replace
    if (std.mem.indexOf(u8, content, args.old_string)) |pos| {
        const new_content = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
            content[0..pos],
            args.new_string,
            content[pos + args.old_string.len..],
        });
        defer allocator.free(new_content);
        
        // Write back
        const out_file = try std.fs.cwd().createFile(args.path, .{});
        defer out_file.close();
        try out_file.writeAll(new_content);
        
        return try std.fmt.allocPrint(allocator, "File edited successfully: {s}", .{args.path});
    } else {
        return try std.fmt.allocPrint(allocator, "Error: old_string not found in file", .{});
    }
}
