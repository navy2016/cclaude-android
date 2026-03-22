//! AutoResearchClaw - 23-Stage Research Pipeline
//!
//! Research flow:
//! 1. Idea → 2. Literature Discovery → 3. Hypothesis Generation
//! 4. Experiment Design → 5. Code Generation → 6. Experiment Execution
//! 7. Result Analysis → 8. Paper Writing
//!
//! With feedback loop: if results don't validate hypothesis, go back to step 3

const std = @import("std");

pub const pipeline = @import("pipeline.zig");
pub const stages = @import("stages.zig");
pub const literature = @import("literature.zig");

pub const ResearchPipeline = pipeline.ResearchPipeline;
pub const Stage = stages.Stage;
pub const StageResult = stages.StageResult;
pub const LiteratureFinder = literature.LiteratureFinder;

test {
    _ = pipeline;
    _ = stages;
    _ = literature;
}
