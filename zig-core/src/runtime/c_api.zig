const std = @import("std");

const TokenCallback = *const fn ([*c]const u8) callconv(.C) void;
const HttpCallback = *const fn ([*c]const u8, [*c]const u8, [*c]const u8, usize) callconv(.C) [*c]const u8;
const ApprovalCallback = *const fn ([*c]const u8, [*c]const u8) callconv(.C) bool;

const MAX_CSTR = 1024 * 1024;
var g_cstr_buf: [MAX_CSTR]u8 = [_]u8{0} ** MAX_CSTR;
var g_token_buf: [8192]u8 = [_]u8{0} ** 8192;

const OpKind = enum { write_file, memory_file_replace, research_state_replace, search_cache_replace, paper_draft_replace, none };
const UndoOp = struct { kind: OpKind, target: []u8, previous: []u8 };
const ToolAction = enum { none, search_context, read_imported, do_research, memory_show, final_answer };
const ReActTurn = struct {
    goal: []const u8,
    tool: ToolAction = .none,
    tool_input: []const u8 = "",
    observation: []const u8 = "",
};

const RuntimeState = struct {
    allocator: std.mem.Allocator,
    data_dir: []u8,
    api_key: []u8,
    http_callback: ?HttpCallback = null,
    approval_callback: ?ApprovalCallback = null,
    can_undo: bool = false,
    can_redo: bool = false,
    last_user_message: ?[]u8 = null,
    last_response: ?[]u8 = null,
    undo_desc: ?[]u8 = null,
    redo_desc: ?[]u8 = null,
    undo_stack: std.ArrayList(UndoOp),
    redo_stack: std.ArrayList(UndoOp),

    fn init(alloc: std.mem.Allocator, data_dir: []const u8, api_key: []const u8) !*RuntimeState {
        const state = try alloc.create(RuntimeState);
        state.* = .{
            .allocator = alloc,
            .data_dir = try alloc.dupe(u8, data_dir),
            .api_key = try alloc.dupe(u8, api_key),
            .undo_stack = std.ArrayList(UndoOp).init(alloc),
            .redo_stack = std.ArrayList(UndoOp).init(alloc),
        };
        return state;
    }

    fn deinit(self: *RuntimeState) void {
        self.allocator.free(self.data_dir);
        self.allocator.free(self.api_key);
        if (self.last_user_message) |msg| self.allocator.free(msg);
        if (self.last_response) |msg| self.allocator.free(msg);
        if (self.undo_desc) |msg| self.allocator.free(msg);
        if (self.redo_desc) |msg| self.allocator.free(msg);
        for (self.undo_stack.items) |op| {
            self.allocator.free(op.target);
            self.allocator.free(op.previous);
        }
        for (self.redo_stack.items) |op| {
            self.allocator.free(op.target);
            self.allocator.free(op.previous);
        }
        self.undo_stack.deinit();
        self.redo_stack.deinit();
        self.allocator.destroy(self);
    }
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var global_state: ?*RuntimeState = null;
fn allocator() std.mem.Allocator { return gpa.allocator(); }

fn toStableCString(bytes: []const u8) [*c]const u8 {
    const n = @min(bytes.len, MAX_CSTR - 1);
    @memcpy(g_cstr_buf[0..n], bytes[0..n]);
    g_cstr_buf[n] = 0;
    return @ptrCast(&g_cstr_buf[0]);
}

fn setOwnedString(slot: *?[]u8, value: []const u8, a: std.mem.Allocator) !void {
    if (slot.*) |old| a.free(old);
    slot.* = try a.dupe(u8, value);
}

fn pathExists(path: []const u8) bool { std.fs.cwd().access(path, .{}) catch return false; return true; }
fn isExternalAndroidPath(path: []const u8) bool { return std.mem.startsWith(u8, path, "/storage/") or std.mem.startsWith(u8, path, "/sdcard/"); }

fn pushUndoOp(state: *RuntimeState, target: []const u8, previous: []const u8, kind: OpKind) !void {
    try state.undo_stack.append(.{ .kind = kind, .target = try state.allocator.dupe(u8, target), .previous = try state.allocator.dupe(u8, previous) });
    state.can_undo = true;
    state.can_redo = false;
    for (state.redo_stack.items) |op| { state.allocator.free(op.target); state.allocator.free(op.previous); }
    state.redo_stack.clearRetainingCapacity();
}

fn filePath(state: *RuntimeState, subdir: []const u8, file_name: []const u8) ![]u8 {
    return try std.fs.path.join(state.allocator, &.{ state.data_dir, subdir, file_name });
}

fn ensureBaseFiles(state: *RuntimeState) !void {
    const context_dir = try std.fs.path.join(state.allocator, &.{ state.data_dir, "context" }); defer state.allocator.free(context_dir);
    const cache_dir = try std.fs.path.join(state.allocator, &.{ state.data_dir, "cache" }); defer state.allocator.free(cache_dir);
    const research_dir = try std.fs.path.join(state.allocator, &.{ state.data_dir, "research" }); defer state.allocator.free(research_dir);
    try std.fs.cwd().makePath(context_dir); try std.fs.cwd().makePath(cache_dir); try std.fs.cwd().makePath(research_dir);
    const defaults = [_][3][]const u8{
        .{ "context", "SOUL.md", "# Soul\n\n**Name:** CClaude\n\n**Tone:** Precise, practical, rollback-first\n" },
        .{ "context", "USER.md", "# User Profile\n\n- Prefers Android-native local agent workflows\n" },
        .{ "context", "MEMORY.md", "# Long-term Memory\n\n- Native Zig runtime initialized\n" },
        .{ "context", "RESEARCH_STATE.md", "# Research State\n\n- Idle\n" },
        .{ "research", "PAPER_DRAFT.md", "# Paper Draft\n\n" },
        .{ "cache", "SEARCH_CACHE.md", "# Search Cache\n\n" },
    };
    for (defaults) |entry| {
        const fp = try filePath(state, entry[0], entry[1]); defer state.allocator.free(fp);
        if (!pathExists(fp)) { const f = try std.fs.cwd().createFile(fp, .{}); defer f.close(); try f.writeAll(entry[2]); }
    }
}

fn replaceTrackedFile(state: *RuntimeState, subdir: []const u8, file_name: []const u8, content: []const u8, kind: OpKind) !void {
    const fp = try filePath(state, subdir, file_name); defer state.allocator.free(fp);
    const current = std.fs.cwd().readFileAlloc(state.allocator, fp, 2 * 1024 * 1024) catch try state.allocator.dupe(u8, "");
    defer state.allocator.free(current);
    const old_content = try state.allocator.dupe(u8, current); errdefer state.allocator.free(old_content);
    const f = try std.fs.cwd().createFile(fp, .{}); defer f.close(); try f.writeAll(content);
    try pushUndoOp(state, fp, old_content, kind);
}

fn appendTrackedFile(state: *RuntimeState, subdir: []const u8, file_name: []const u8, line: []const u8, kind: OpKind) !void {
    const fp = try filePath(state, subdir, file_name); defer state.allocator.free(fp);
    const current = std.fs.cwd().readFileAlloc(state.allocator, fp, 2 * 1024 * 1024) catch try state.allocator.dupe(u8, "");
    defer state.allocator.free(current);
    const merged = try std.fmt.allocPrint(state.allocator, "{s}\n{s}\n", .{ current, line }); defer state.allocator.free(merged);
    try replaceTrackedFile(state, subdir, file_name, merged, kind);
}

fn nativeReadFile(state: *RuntimeState, path: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, path, " \t\r\n");
    if (isExternalAndroidPath(trimmed)) return try std.fmt.allocPrint(state.allocator, "Read blocked by Android scoped storage: {s}", .{trimmed});
    const file = std.fs.cwd().openFile(trimmed, .{}) catch |err| return try std.fmt.allocPrint(state.allocator, "Read failed: {s} -> {s}", .{ trimmed, @errorName(err) });
    defer file.close();
    return try file.readToEndAlloc(state.allocator, 2 * 1024 * 1024);
}

fn nativeWriteFile(state: *RuntimeState, path: []const u8, content: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, path, " \t\r\n");
    if (isExternalAndroidPath(trimmed)) return try std.fmt.allocPrint(state.allocator, "Write blocked by Android scoped storage: {s}", .{trimmed});
    const previous = std.fs.cwd().readFileAlloc(state.allocator, trimmed, 2 * 1024 * 1024) catch try state.allocator.dupe(u8, ""); errdefer state.allocator.free(previous);
    if (std.mem.lastIndexOf(u8, trimmed, "/")) |last_slash| std.fs.cwd().makePath(trimmed[0..last_slash]) catch {};
    const file = try std.fs.cwd().createFile(trimmed, .{}); defer file.close(); try file.writeAll(content);
    try pushUndoOp(state, trimmed, previous, .write_file);
    return try std.fmt.allocPrint(state.allocator, "Wrote file: {s}", .{trimmed});
}

fn searchDir(state: *RuntimeState, base_path: []const u8, needle: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(state.allocator); defer result.deinit();
    var dir = std.fs.cwd().openDir(base_path, .{ .iterate = true }) catch |err| return try std.fmt.allocPrint(state.allocator, "Search open dir failed: {s} -> {s}", .{ base_path, @errorName(err) });
    defer dir.close();
    var walker = try dir.walk(state.allocator); defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const file = dir.openFile(entry.path, .{}) catch continue; defer file.close();
        const content = file.readToEndAlloc(state.allocator, 512 * 1024) catch continue; defer state.allocator.free(content);
        if (std.mem.indexOf(u8, content, needle) != null) try result.writer().print("{s}/{s}\n", .{ base_path, entry.path });
    }
    if (result.items.len == 0) return try state.allocator.dupe(u8, "No matches found");
    return try state.allocator.dupe(u8, result.items);
}

fn containsAny(hay: []const u8, needles: []const []const u8) bool { for (needles) |n| if (std.mem.indexOf(u8, hay, n) != null) return true; return false; }
fn importedDirPath(state: *RuntimeState) ![]u8 { return try std.fs.path.join(state.allocator, &.{ state.data_dir, "..", "imports" }); }

fn latestImportedFile(state: *RuntimeState) !?[]u8 {
    const dir_path = try importedDirPath(state); defer state.allocator.free(dir_path);
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return null; defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| if (entry.kind == .file) return try std.fs.path.join(state.allocator, &.{ dir_path, entry.name });
    return null;
}

fn memoryShow(state: *RuntimeState) ![]u8 {
    const soul_path = try filePath(state, "context", "SOUL.md"); defer state.allocator.free(soul_path);
    const user_path = try filePath(state, "context", "USER.md"); defer state.allocator.free(user_path);
    const mem_path = try filePath(state, "context", "MEMORY.md"); defer state.allocator.free(mem_path);
    const soul = std.fs.cwd().readFileAlloc(state.allocator, soul_path, 1024 * 1024) catch try state.allocator.dupe(u8, "# Soul\n"); defer state.allocator.free(soul);
    const user = std.fs.cwd().readFileAlloc(state.allocator, user_path, 1024 * 1024) catch try state.allocator.dupe(u8, "# User Profile\n"); defer state.allocator.free(user);
    const mem = std.fs.cwd().readFileAlloc(state.allocator, mem_path, 1024 * 1024) catch try state.allocator.dupe(u8, "# Long-term Memory\n"); defer state.allocator.free(mem);
    return try std.fmt.allocPrint(state.allocator, "## Soul\n{s}\n\n## User\n{s}\n\n## Memory\n{s}", .{ soul, user, mem });
}

fn classifyAndRemember(state: *RuntimeState, msg: []const u8) !void {
    const line = try std.fmt.allocPrint(state.allocator, "- {s}", .{msg}); defer state.allocator.free(line);
    if (containsAny(msg, &.{ "喜欢", "prefer", "偏好", "习惯" })) try appendTrackedFile(state, "context", "USER.md", line, .memory_file_replace)
    else try appendTrackedFile(state, "context", "MEMORY.md", line, .memory_file_replace);
}

fn jsonEscape(allocator_: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator_); defer out.deinit();
    for (s) |c| switch (c) {
        '"' => try out.appendSlice("\\\""),
        '\\' => try out.appendSlice("\\\\"),
        '\n' => try out.appendSlice("\\n"),
        '\r' => try out.appendSlice("\\r"),
        '\t' => try out.appendSlice("\\t"),
        else => try out.append(c),
    };
    return try allocator_.dupe(u8, out.items);
}

fn extractJsonString(allocator_: std.mem.Allocator, json: []const u8, key: []const u8) !?[]u8 {
    const pattern = try std.fmt.allocPrint(allocator_, "\"{s}\":\"", .{key}); defer allocator_.free(pattern);
    const pos = std.mem.indexOf(u8, json, pattern) orelse return null;
    const start = pos + pattern.len;
    var i = start;
    while (i < json.len) : (i += 1) if (json[i] == '"' and json[i - 1] != '\\') return try allocator_.dupe(u8, json[start..i]);
    return null;
}

fn buildAnthropicBody(state: *RuntimeState, system_prompt: []const u8, user_prompt: []const u8) ![]u8 {
    const esc_system = try jsonEscape(state.allocator, system_prompt); defer state.allocator.free(esc_system);
    const esc_user = try jsonEscape(state.allocator, user_prompt); defer state.allocator.free(esc_user);
    return try std.fmt.allocPrint(state.allocator,
        "{{\"model\":\"claude-3-5-sonnet-20241022\",\"max_tokens\":900,\"system\":\"{s}\",\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}}]}}",
        .{ esc_system, esc_user },
    );
}

fn callLlm(state: *RuntimeState, system_prompt: []const u8, user_prompt: []const u8) ![]u8 {
    const cb = state.http_callback orelse return error.NoHttpCallback;
    const body = try buildAnthropicBody(state, system_prompt, user_prompt); defer state.allocator.free(body);
    const headers = try std.fmt.allocPrint(state.allocator,
        "METHOD: POST\nContent-Type: application/json\nx-api-key: {s}\nanthropic-version: 2023-06-01\n", .{state.api_key});
    defer state.allocator.free(headers);
    const raw = cb(@ptrCast("https://api.anthropic.com/v1/messages"), @ptrCast(headers.ptr), @ptrCast(body.ptr), body.len);
    const resp = std.mem.span(raw);
    if (std.mem.indexOf(u8, resp, ":")) |colon| {
        const body_part = resp[colon + 1 ..];
        if (try extractJsonString(state.allocator, body_part, "text")) |txt| return txt;
        return try state.allocator.dupe(u8, body_part);
    }
    return try state.allocator.dupe(u8, resp);
}

fn parseToolAction(text: []const u8) ToolAction {
    if (std.mem.indexOf(u8, text, "search_context") != null) return .search_context;
    if (std.mem.indexOf(u8, text, "read_imported") != null) return .read_imported;
    if (std.mem.indexOf(u8, text, "do_research") != null) return .do_research;
    if (std.mem.indexOf(u8, text, "memory_show") != null) return .memory_show;
    if (std.mem.indexOf(u8, text, "final_answer") != null) return .final_answer;
    return .none;
}

fn searchLiterature(state: *RuntimeState, idea: []const u8) ![]u8 {
    const url = try std.fmt.allocPrint(state.allocator, "https://api.crossref.org/works?rows=5&query.title={s}", .{idea}); defer state.allocator.free(url);
    const cb = state.http_callback orelse return try state.allocator.dupe(u8, "Crossref unavailable");
    const headers = "METHOD: GET\nAccept: application/json\n";
    const raw = cb(@ptrCast(url.ptr), @ptrCast(headers.ptr), @ptrCast(""), 0);
    return try state.allocator.dupe(u8, std.mem.span(raw));
}

fn buildHypothesis(allocator_: std.mem.Allocator, literature: []const u8) ![]u8 {
    const score: u8 = if (std.mem.indexOf(u8, literature, "title") != null) 78 else 52;
    return try std.fmt.allocPrint(allocator_, "## Hypothesis\n- Hypothesis: A Zig-native Android local agent with rollback-first orchestration can deliver practical autonomy.\n- Novelty score: {d}/100", .{score});
}

fn buildExperimentPlan(allocator_: std.mem.Allocator, idea: []const u8) ![]u8 {
    return try std.fmt.allocPrint(allocator_, "## Experiment\n1. Validate LLM-driven ReAct turn loop\n2. Validate artifact-level rollback\n3. Validate import/read/write flow\n4. Evaluate runtime weight\n5. Tracked idea: {s}", .{idea});
}

fn buildPaperDraft(state: *RuntimeState, idea: []const u8, literature: []const u8, hypothesis: []const u8, experiment: []const u8) ![]u8 {
    const draft = try std.fmt.allocPrint(state.allocator,
        "# Paper Draft\n\n## Title\nRollback-First Native Zig Android Agent for Local ReAct Execution\n\n## Abstract\nThis draft investigates {s}.\n\n## Literature\n{s}\n\n{s}\n\n{s}\n\n## Next Steps\n- Expand literature retrieval\n- Refine scoring\n- Translate experiment into executable tasks\n",
        .{ idea, literature[0..@min(literature.len, 3000)], hypothesis, experiment },
    );
    try replaceTrackedFile(state, "research", "PAPER_DRAFT.md", draft, .paper_draft_replace);
    return draft;
}

fn runResearch(state: *RuntimeState, idea: []const u8) ![]u8 {
    const literature = try searchLiterature(state, idea); defer state.allocator.free(literature);
    const hypothesis = try buildHypothesis(state.allocator, literature); defer state.allocator.free(hypothesis);
    const experiment = try buildExperimentPlan(state.allocator, idea); defer state.allocator.free(experiment);
    const draft = try buildPaperDraft(state, idea, literature, hypothesis, experiment); defer state.allocator.free(draft);
    const state_md = try std.fmt.allocPrint(state.allocator,
        "# Research State\n\n## Idea\n{s}\n\n## Literature\n{s}\n\n{s}\n\n{s}\n\n## Artifact\nresearch/PAPER_DRAFT.md\n",
        .{ idea, literature[0..@min(literature.len, 1200)], hypothesis, experiment },
    );
    defer state.allocator.free(state_md);
    try replaceTrackedFile(state, "context", "RESEARCH_STATE.md", state_md, .research_state_replace);
    return try std.fmt.allocPrint(state.allocator,
        "[Research Execution]\nIdea: {s}\n\n## Literature\n{s}\n\n{s}\n\n{s}\n\n## Draft Artifact\nSaved: research/PAPER_DRAFT.md",
        .{ idea, literature[0..@min(literature.len, 1500)], hypothesis, experiment },
    );
}

fn cacheSearch(state: *RuntimeState, query: []const u8, result: []const u8) !void {
    const line = try std.fmt.allocPrint(state.allocator, "## Query\n{s}\n\n## Result\n{s}", .{ query, result[0..@min(result.len, 4000)] });
    defer state.allocator.free(line);
    try appendTrackedFile(state, "cache", "SEARCH_CACHE.md", line, .search_cache_replace);
}

fn executeToolAction(state: *RuntimeState, action: ToolAction, tool_input: []const u8) ![]u8 {
    return switch (action) {
        .search_context => blk: {
            const context_dir = try std.fs.path.join(state.allocator, &.{ state.data_dir, "context" }); defer state.allocator.free(context_dir);
            const res = try searchDir(state, context_dir, if (tool_input.len == 0) "CClaude" else tool_input);
            try cacheSearch(state, tool_input, res);
            break :blk res;
        },
        .read_imported => blk: {
            if (try latestImportedFile(state)) |fp| { defer state.allocator.free(fp); break :blk try nativeReadFile(state, fp); }
            break :blk try state.allocator.dupe(u8, "No imported file found. Use import first.");
        },
        .do_research => try runResearch(state, tool_input),
        .memory_show => try memoryShow(state),
        .final_answer, .none => try state.allocator.dupe(u8, tool_input),
    };
}

fn llmDrivenReAct(state: *RuntimeState, user_msg: []const u8) ![]u8 {
    const context_snapshot = try memoryShow(state); defer state.allocator.free(context_snapshot);
    const system_prompt =
        "You are a Zig-native Android coding and research agent. Return STRICT JSON with keys reasoning, action, input, final. " ++
        "Valid actions: search_context, read_imported, do_research, memory_show, final_answer. " ++
        "Use final_answer only when done. JSON only.";

    var turn = ReActTurn{ .goal = user_msg };
    var scratch = std.ArrayList(u8).init(state.allocator); defer scratch.deinit();
    var step: u8 = 0;
    while (step < 4) : (step += 1) {
        scratch.clearRetainingCapacity();
        try scratch.writer().print(
            "User goal:\n{s}\n\nContext:\n{s}\n\nCurrent observation:\n{s}\n\nReturn JSON only.",
            .{ turn.goal, context_snapshot, turn.observation },
        );
        const llm = callLlm(state, system_prompt, scratch.items) catch break;
        defer state.allocator.free(llm);
        const action = parseToolAction(llm);
        const input = (try extractJsonString(state.allocator, llm, "input")) orelse try state.allocator.dupe(u8, turn.goal);
        defer state.allocator.free(input);
        if (action == .final_answer) {
            if (try extractJsonString(state.allocator, llm, "final")) |fin| return fin;
            return try state.allocator.dupe(u8, llm);
        }
        turn.tool = action;
        turn.tool_input = input;
        const obs = try executeToolAction(state, action, input); defer state.allocator.free(obs);
        turn.observation = try state.allocator.dupe(u8, obs);
    }
    return try std.fmt.allocPrint(state.allocator, "[Fallback ReAct]\nGoal: {s}\nObservation: {s}", .{ turn.goal, turn.observation });
}

fn handleToolCommand(state: *RuntimeState, message: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, message, "/tool readfile ")) return try nativeReadFile(state, message[15..]);
    if (std.mem.startsWith(u8, message, "/tool search ")) {
        const rest = std.mem.trim(u8, message[13..], " \t\r\n");
        const context_dir = try std.fs.path.join(state.allocator, &.{ state.data_dir, "context" }); defer state.allocator.free(context_dir);
        const res = try searchDir(state, context_dir, rest); try cacheSearch(state, rest, res); return res;
    }
    if (std.mem.startsWith(u8, message, "/tool writefile ")) {
        const rest = message[16..];
        if (std.mem.indexOf(u8, rest, " :: ")) |sep| return try nativeWriteFile(state, rest[0..sep], rest[sep + 4 ..]);
        return try state.allocator.dupe(u8, "Usage: /tool writefile <path> :: <content>");
    }
    return try state.allocator.dupe(u8, "Unknown /tool command");
}

fn reactLoop(state: *RuntimeState, msg: []const u8) ![]u8 {
    try ensureBaseFiles(state);
    if (std.mem.startsWith(u8, msg, "/tool ")) return try handleToolCommand(state, msg);
    if (std.mem.eql(u8, msg, "/memory show")) return try memoryShow(state);
    if (std.mem.startsWith(u8, msg, "/research ")) return try runResearch(state, std.mem.trim(u8, msg[10..], " \t\r\n"));
    try classifyAndRemember(state, msg);
    if (state.http_callback != null and state.api_key.len > 0) return llmDrivenReAct(state, msg) catch {};
    return try std.fmt.allocPrint(state.allocator, "[Deterministic Fallback]\nReceived: {s}\nSet API key to unlock LLM-driven ReAct.", .{msg});
}

export fn cclaude_init(data_dir: [*c]const u8, api_key: [*c]const u8) i32 {
    if (global_state != null) return 0;
    global_state = RuntimeState.init(allocator(), std.mem.span(data_dir), std.mem.span(api_key)) catch return -1;
    ensureBaseFiles(global_state.?) catch return -1;
    return 0;
}

export fn cclaude_free() void { if (global_state) |state| { state.deinit(); global_state = null; } }
export fn cclaude_set_http_callback(callback: ?HttpCallback) void { if (global_state) |state| state.http_callback = callback; }
export fn cclaude_set_approval_callback(callback: ?ApprovalCallback) void { if (global_state) |state| state.approval_callback = callback; }

export fn cclaude_send(message: [*c]const u8, token_callback: ?TokenCallback) [*c]const u8 {
    const state = global_state orelse return @ptrCast("Error: not initialized");
    const msg = std.mem.span(message);
    setOwnedString(&state.last_user_message, msg, state.allocator) catch return @ptrCast("Error: OOM");
    const response_const = reactLoop(state, msg) catch return @ptrCast("Error: native runtime failure");
    const response = state.allocator.dupe(u8, response_const) catch return @ptrCast("Error: OOM");
    state.allocator.free(response_const);
    if (state.last_response) |old| state.allocator.free(old);
    state.last_response = response;
    setOwnedString(&state.undo_desc, "Undo last artifact/tool mutation", state.allocator) catch {};
    setOwnedString(&state.redo_desc, "Redo last artifact/tool mutation", state.allocator) catch {};
    state.can_undo = state.undo_stack.items.len > 0;
    state.can_redo = state.redo_stack.items.len > 0;
    if (token_callback) |cb| {
        var it = std.mem.splitScalar(u8, response, ' ');
        while (it.next()) |part| {
            const token_len = @min(part.len + 1, g_token_buf.len - 2);
            @memcpy(g_token_buf[0 .. token_len - 1], part[0 .. token_len - 1]);
            g_token_buf[token_len - 1] = ' ';
            g_token_buf[token_len] = 0;
            cb(@ptrCast(&g_token_buf[0]));
        }
    }
    return toStableCString(response);
}

fn restoreOp(_: *RuntimeState, op: UndoOp) !void {
    const f = try std.fs.cwd().createFile(op.target, .{}); defer f.close(); try f.writeAll(op.previous);
}

export fn cclaude_undo() i32 {
    const state = global_state orelse return -1;
    if (state.undo_stack.items.len == 0) return 0;
    const op = state.undo_stack.pop();
    restoreOp(state, op) catch return -1;
    state.redo_stack.append(op) catch return -1;
    state.can_undo = state.undo_stack.items.len > 0;
    state.can_redo = state.redo_stack.items.len > 0;
    return 1;
}

export fn cclaude_redo() i32 {
    const state = global_state orelse return -1;
    if (state.redo_stack.items.len == 0) return 0;
    const op = state.redo_stack.pop();
    const f = std.fs.cwd().createFile(op.target, .{}) catch return -1; defer f.close();
    try f.writeAll(op.previous) catch return -1;
    state.undo_stack.append(op) catch return -1;
    state.can_undo = state.undo_stack.items.len > 0;
    state.can_redo = state.redo_stack.items.len > 0;
    return 1;
}

export fn cclaude_can_undo() i32 { const state = global_state orelse return 0; return if (state.can_undo or state.undo_stack.items.len > 0) 1 else 0; }
export fn cclaude_can_redo() i32 { const state = global_state orelse return 0; return if (state.can_redo or state.redo_stack.items.len > 0) 1 else 0; }
export fn cclaude_get_undo_description() [*c]const u8 { const state = global_state orelse return null; if (state.undo_desc) |d| return toStableCString(d); return null; }
export fn cclaude_get_redo_description() [*c]const u8 { const state = global_state orelse return null; if (state.redo_desc) |d| return toStableCString(d); return null; }
export fn cclaude_rollback_conversation() i32 { const state = global_state orelse return -1; state.can_undo = false; state.can_redo = false; return 0; }
export fn cclaude_free_string(s: [*c]const u8) void { _ = s; }
