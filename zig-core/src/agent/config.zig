//! Agent configuration

const std = @import("std");

pub const ApprovalMode = enum {
    auto,      // Only intercept Dangerous
    cautious,  // Intercept Moderate + Dangerous
    strict,    // Intercept all
    yolo,      // Allow all (dangerous)
};

pub const AgentConfig = struct {
    allocator: std.mem.Allocator,
    
    // API settings
    api_url: []const u8 = "https://api.anthropic.com/v1/messages",
    api_key: []const u8 = "",
    model: []const u8 = "claude-sonnet-4-20250514",
    
    // Paths
    data_dir: []const u8 = "/data/data/com.cclaude/files/agent",
    
    // Behavior
    max_tool_iterations: u32 = 25,
    max_history: u32 = 50,
    approval_mode: ApprovalMode = .auto,
    auto_learn: bool = true,
    
    pub fn deinit(self: AgentConfig) void {
        self.allocator.free(self.api_url);
        self.allocator.free(self.api_key);
        self.allocator.free(self.model);
        self.allocator.free(self.data_dir);
    }
};
