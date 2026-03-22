//! Research pipeline stages

const std = @import("std");

pub const StageType = enum {
    idea_input,              // User inputs research idea
    literature_discovery,    // Find relevant papers from arXiv, Semantic Scholar
    literature_validation,   // Cross-check DOI, validate citations
    hypothesis_generation,   // Multi-agent debate to form hypothesis
    experiment_design,       // Design experiments to test hypothesis
    code_generation,         // Generate experiment code
    experiment_execution,    // Run code in sandbox
    result_analysis,         // Analyze results
    hypothesis_validation,   // Check if results support hypothesis
    paper_writing,           // Generate LaTeX paper
    paper_formatting,        // Format to ICML/NeurIPS style
};

pub const StageResult = union(enum) {
    success: []const u8,      // Output to pass to next stage
    failure: []const u8,      // Error message
    retry_hypothesis: void,   // Go back to hypothesis generation
    complete: []const u8,     // Final output (paper)
};

pub const Stage = struct {
    stage_type: StageType,
    name: []const u8,
    description: []const u8,
    max_iterations: u32 = 1,
    
    pub fn execute(self: Stage, allocator: std.mem.Allocator, input: []const u8) !StageResult {
        _ = self;
        _ = allocator;
        // Stage execution would call LLM with specific prompts
        // This is a simplified placeholder
        return StageResult{ .success = input };
    }
};

/// Get all 23 stages (some are grouped for simplicity)
pub fn getAllStages(allocator: std.mem.Allocator) !std.ArrayList(Stage) {
    var stages = std.ArrayList(Stage).init(allocator);
    
    try stages.append(.{
        .stage_type = .idea_input,
        .name = "Idea Input",
        .description = "Capture user's research idea",
    });
    
    try stages.append(.{
        .stage_type = .literature_discovery,
        .name = "Literature Discovery",
        .description = "Search arXiv, Semantic Scholar, OpenAlex",
    });
    
    try stages.append(.{
        .stage_type = .literature_validation,
        .name = "Citation Validation",
        .description = "Cross-check DOI with DataCite, CrossRef",
    });
    
    try stages.append(.{
        .stage_type = .hypothesis_generation,
        .name = "Hypothesis Generation",
        .description = "Multi-agent debate to form hypothesis",
        .max_iterations = 5,
    });
    
    try stages.append(.{
        .stage_type = .experiment_design,
        .name = "Experiment Design",
        .description = "Design experiments to validate hypothesis",
    });
    
    try stages.append(.{
        .stage_type = .code_generation,
        .name = "Code Generation",
        .description = "Generate Python experiment code",
    });
    
    try stages.append(.{
        .stage_type = .experiment_execution,
        .name = "Experiment Execution",
        .description = "Run code in sandboxed environment",
    });
    
    try stages.append(.{
        .stage_type = .result_analysis,
        .name = "Result Analysis",
        .description = "Analyze experiment results",
    });
    
    try stages.append(.{
        .stage_type = .hypothesis_validation,
        .name = "Hypothesis Validation",
        .description = "Check if results support hypothesis",
    });
    
    try stages.append(.{
        .stage_type = .paper_writing,
        .name = "Paper Writing",
        .description = "Generate LaTeX paper content",
    });
    
    try stages.append(.{
        .stage_type = .paper_formatting,
        .name = "Paper Formatting",
        .description = "Format to ICML conference style",
    });
    
    return stages;
}
