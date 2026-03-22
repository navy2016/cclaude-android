//! HTTP utilities (simplified, real impl would use libcurl or platform HTTP)

const std = @import("std");

pub const HttpResponse = struct {
    status: u16,
    body: []const u8,
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: HttpResponse) void {
        self.allocator.free(self.body);
    }
};

/// HTTP client interface (platform-specific impl via callbacks)
pub const HttpClient = struct {
    // Callback for actual HTTP request (set by JNI layer on Android)
    request_callback: ?*const fn ([*c]const u8, [*c]const u8, [*c]const u8, usize) callconv(.C) [*c]const u8,
    
    pub fn post(self: HttpClient, allocator: std.mem.Allocator, url: []const u8, headers: []const u8, body: []const u8) !HttpResponse {
        if (self.request_callback) |callback| {
            const response_ptr = callback(url.ptr, headers.ptr, body.ptr, body.len);
            const response = std.mem.span(response_ptr);
            
            // Parse status and body from response
            // Format: "STATUS:BODY"
            if (std.mem.indexOf(u8, response, ":")) |colon_pos| {
                const status = try std.fmt.parseInt(u16, response[0..colon_pos], 10);
                const response_body = try allocator.dupe(u8, response[colon_pos + 1..]);
                
                return HttpResponse{
                    .status = status,
                    .body = response_body,
                    .allocator = allocator,
                };
            }
        }
        return error.NoHttpImplementation;
    }
};
