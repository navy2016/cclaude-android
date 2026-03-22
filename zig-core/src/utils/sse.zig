//! Server-Sent Events (SSE) parser for streaming LLM responses

const std = @import("std");

pub const SseEvent = struct {
    event: ?[]const u8,
    data: []const u8,
    
    pub fn deinit(self: SseEvent, allocator: std.mem.Allocator) void {
        if (self.event) |e| allocator.free(e);
        allocator.free(self.data);
    }
};

/// Parse SSE stream line by line
pub fn parseEvent(allocator: std.mem.Allocator, line: []const u8) !?SseEvent {
    if (line.len == 0) return null;
    if (!std.mem.startsWith(u8, line, "data:")) return null;
    
    const data = std.mem.trimLeft(u8, line[5..], " ");
    const owned_data = try allocator.dupe(u8, data);
    
    return SseEvent{
        .event = null,
        .data = owned_data,
    };
}

/// Extract delta content from Claude SSE event
pub fn extractDelta(allocator: std.mem.Allocator, event_data: []const u8) !?[]const u8 {
    // Look for "delta":{"type":"text_delta","text":"..."}
    if (std.mem.indexOf(u8, event_data, "\"type\":\"text_delta\"")) |_| {
        if (std.mem.indexOf(u8, event_data, "\"text\":\"")) |text_start| {
            const value_start = text_start + 8;
            var end = value_start;
            while (end < event_data.len) : (end += 1) {
                if (event_data[end] == '"' and event_data[end - 1] != '\\') break;
            }
            return try allocator.dupe(u8, event_data[value_start..end]);
        }
    }
    return null;
}
