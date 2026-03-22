//! shell tool - Execute shell command (Android safe)

const std = @import("std");

pub fn execute(allocator: std.mem.Allocator, args_json: []const u8, _: ?*anyopaque) ![]const u8 {
    const command_prefix = "\"command\":\"";
    var command: []const u8 = undefined;
    
    if (std.mem.indexOf(u8, args_json, command_prefix)) |start| {
        const value_start = start + command_prefix.len;
        var end = value_start;
        while (end < args_json.len) : (end += 1) {
            if (args_json[end] == '"' and args_json[end - 1] != '\\') break;
        }
        command = args_json[value_start..end];
    } else return error.InvalidArgs;
    
    // Security: whitelist safe commands for Android
    const safe_commands = [_][]const u8{ "ls", "cat", "cp", "mv", "rm", "mkdir", "find", "chmod", "touch", "grep", "sed", "sort", "uniq", "wc", "head", "tail", "tr", "tar", "gzip", "gunzip", "uname", "df", "du", "env", "id", "date", "stat", "pwd", "echo" };
    
    var is_safe = false;
    for (safe_commands) |safe| {
        if (std.mem.startsWith(u8, command, safe)) {
            is_safe = true;
            break;
        }
    }
    
    if (!is_safe) {
        return try std.fmt.allocPrint(allocator, "Error: Command not in safe list: {s}", .{command});
    }
    
    // Execute via popen (Android bionic supports this)
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"/system/bin/sh", "-c", command},
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    if (result.term.Exited == 0) {
        return try allocator.dupe(u8, result.stdout);
    } else {
        return try std.fmt.allocPrint(allocator, "Error: {s}", .{result.stderr});
    }
}
