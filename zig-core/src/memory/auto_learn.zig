//! Auto-Learn - LLM-driven automatic memory extraction
//!
//! After each tool execution, analyze the interaction and extract
//! useful facts to store in USER.md or MEMORY.md

const std = @import("std");

pub const AutoLearn = struct {
    allocator: std.mem.Allocator,
    enabled: bool = true,
    max_facts_per_interaction: u32 = 3,
    min_length: usize = 5,
    max_length: usize = 200,
    
    pub fn init(allocator: std.mem.Allocator) AutoLearn {
        return .{
            .allocator = allocator,
        };
    }
    
    /// Build extraction prompt for auto-learning
    pub fn buildExtractionPrompt(self: AutoLearn, user_input: []const u8, tool_summary: []const u8) ![]const u8 {
        _ = self;
        
        return try std.fmt.allocPrint(self.allocator,
            \\Analyze this agent interaction and extract ONLY genuinely useful long-term facts.
            \\Focus on:
            \\- User preferences (coding style, tool choices, language preferences)
            \\- Project-specific facts (tech stack, file structure patterns)
            \\- Workflow patterns (how user likes to work, review preferences)
            \\
            \\User input: {s}
            \\Tool execution: {s}
            \\
            \\Rules:
            \\- Return ONLY new, non-obvious facts worth remembering across sessions
            \\- Each fact on its own line, prefixed with target file:
            \\  [USER] for user preferences and habits
            \\  [MEMORY] for project facts and patterns
            \\- Maximum 3 facts per interaction. Return NONE if nothing worth learning.
            \\- Be concise: each fact should be one short sentence.
        , .{user_input, tool_summary});
    }
    
    /// Parse LLM response and extract facts
    pub fn parseFacts(self: AutoLearn, response: []const u8, allocator: std.mem.Allocator) !std.ArrayList(struct { target: []const u8, fact: []const u8 }) {
        var facts = std.ArrayList(struct { target: []const u8, fact: []const u8 }).init(allocator);
        errdefer {
            for (facts.items) |f| {
                allocator.free(f.target);
                allocator.free(f.fact);
            }
            facts.deinit();
        }
        
        var lines = std.mem.splitScalar(u8, response, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            
            // Skip empty lines and NONE
            if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "NONE")) continue;
            
            // Parse [TARGET] fact format
            if (std.mem.startsWith(u8, trimmed, "[")) {
                if (std.mem.indexOf(u8, trimmed, "]")) |close_bracket| {
                    const target = trimmed[1..close_bracket];
                    const fact = std.mem.trim(u8, trimmed[close_bracket + 1..], " -");
                    
                    // Validate length
                    if (fact.len < self.min_length or fact.len > self.max_length) continue;
                    
                    // Validate target
                    if (!std.mem.eql(u8, target, "USER") and !std.mem.eql(u8, target, "MEMORY")) continue;
                    
                    try facts.append(.{
                        .target = try allocator.dupe(u8, target),
                        .fact = try allocator.dupe(u8, fact),
                    });
                }
            }
        }
        
        return facts;
    }
    
    /// Format fact for storage in Markdown
    pub fn formatFact(self: AutoLearn, allocator: std.mem.Allocator, fact: []const u8) ![]const u8 {
        _ = self;
        return try std.fmt.allocPrint(allocator, "- {s}", .{fact});
    }
};
