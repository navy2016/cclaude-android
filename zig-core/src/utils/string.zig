//! String utilities

const std = @import("std");

/// Normalize string for deduplication (lowercase, trim whitespace)
pub fn normalize(buffer: []u8, input: []const u8) []const u8 {
    var i: usize = 0;
    var last_was_space = true;
    
    for (input) |c| {
        if (std.ascii.isWhitespace(c)) {
            if (!last_was_space and i < buffer.len - 1) {
                buffer[i] = ' ';
                i += 1;
                last_was_space = true;
            }
        } else {
            if (i < buffer.len) {
                buffer[i] = std.ascii.toLower(c);
                i += 1;
                last_was_space = false;
            }
        }
    }
    
    // Trim trailing space
    if (i > 0 and buffer[i - 1] == ' ') i -= 1;
    
    return buffer[0..i];
}

/// Calculate similarity ratio (0-100) between two strings
pub fn similarityRatio(a: []const u8, b: []const u8) u8 {
    if (a.len == 0 or b.len == 0) return 0;
    
    const shorter = @min(a.len, b.len);
    const longer = @max(a.len, b.len);
    
    // Simple substring check
    if (std.mem.indexOf(u8, a, b) != null or std.mem.indexOf(u8, b, a) != null) {
        return @intCast((shorter * 100) / longer);
    }
    
    return 0;
}
