//! Research pipeline orchestrator

const std = @import("std");
const stages = @import("stages.zig");

pub const ResearchPipeline = struct {
    allocator: std.mem.Allocator,
    stages: std.ArrayList(stages.Stage),
    current_stage: usize = 0,
    max_retries: u32 = 3,
    state: union(enum) {
        idle,
        running,
        waiting_for_hypothesis_retry,
        completed: []const u8,  // Final paper
        failed: []const u8,     // Error message
    } = .idle,
    
    /// 30-day time decay for learned lessons (MetaClaw)
    lesson_decay_days: i64 = 30,
    
    pub fn init(allocator: std.mem.Allocator) !ResearchPipeline {
        return .{
            .allocator = allocator,
            .stages = try stages.getAllStages(allocator),
            .state = .idle,
        };
    }
    
    pub fn deinit(self: *ResearchPipeline) void {
        self.stages.deinit();
        switch (self.state) {
            .completed => |paper| self.allocator.free(paper),
            .failed => |err| self.allocator.free(err),
            else => {},
        }
    }
    
    /// Start research with initial idea
    pub fn start(self: *ResearchPipeline, idea: []const u8) !void {
        self.state = .running;
        self.current_stage = 0;
        
        var current_input = try self.allocator.dupe(u8, idea);
        defer self.allocator.free(current_input);
        
        while (self.current_stage < self.stages.items.len) {
            const stage = self.stages.items[self.current_stage];
            
            // Execute stage
            const result = try stage.execute(self.allocator, current_input);
            
            switch (result) {
                .success => |output| {
                    self.allocator.free(current_input);
                    current_input = try self.allocator.dupe(u8, output);
                    self.current_stage += 1;
                },
                .failure => |err| {
                    self.state = .{ .failed = try self.allocator.dupe(u8, err) };
                    return;
                },
                .retry_hypothesis => {
                    // Go back to hypothesis generation
                    self.current_stage = 3; // hypothesis_generation index
                },
                .complete => |paper| {
                    self.state = .{ .completed = try self.allocator.dupe(u8, paper) };
                    return;
                },
            }
        }
        
        // If we finished all stages without completion, something went wrong
        self.state = .{ .failed = try self.allocator.dupe(u8, "Pipeline completed without final output") };
    }
    
    /// Get current stage info for UI display
    pub fn getProgress(self: ResearchPipeline) struct { current: usize, total: usize, name: []const u8 } {
        if (self.current_stage < self.stages.items.len) {
            return .{
                .current = self.current_stage + 1,
                .total = self.stages.items.len,
                .name = self.stages.items[self.current_stage].name,
            };
        }
        return .{ .current = self.stages.items.len, .total = self.stages.items.len, .name = "Complete" };
    }
    
    /// Apply learned lesson with time decay
    /// Lessons older than 30 days have reduced weight
    pub fn applyLesson(self: *ResearchPipeline, lesson: Lesson) void {
        _ = self;
        _ = lesson;
        // Store lesson to ~/.metaclaw/skills/
        // Format: arc-{category}.md
    }
};

pub const Lesson = struct {
    category: []const u8,
    content: []const u8,
    timestamp: i64,
    success_count: u32 = 0,
    failure_count: u32 = 0,
};
