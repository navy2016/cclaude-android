const std = @import("std");

const TokenCallback = *const fn ([*c]const u8) callconv(.C) void;
const HttpCallback = *const fn ([*c]const u8, [*c]const u8, [*c]const u8, usize) callconv(.C) [*c]const u8;
const ApprovalCallback = *const fn ([*c]const u8, [*c]const u8) callconv(.C) bool;

const tools = @import("../tools/root.zig");
const mem_ctx = @import("../memory/context.zig");
const research = @import("../research/pipeline.zig");

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
    tool_registry: tools.ToolRegistry,
    context_store: mem_ctx.ContextStore,

    fn init(alloc: std.mem.Allocator, data_dir: []const u8, api_key: []const u8) !*RuntimeState {
        const state = try alloc.create(RuntimeState);
        var registry = tools.ToolRegistry.init(alloc);
        try registry.registerCoreTools();
        const ctx = try mem_ctx.ContextStore.init(alloc, data_dir);
        state.* = .{
            .allocator = alloc,
            .data_dir = try alloc.dupe(u8, data_dir),
            .api_key = try alloc.dupe(u8, api_key),
            .tool_registry = registry,
            .context_store = ctx,
        };
        return state;
    }

    fn deinit(self: *RuntimeState) void {
        self.tool_registry.deinit();
        self.context_store.deinit();
        self.allocator.free(self.data_dir);
        self.allocator.free(self.api_key);
        if (self.last_user_message) |msg| self.allocator.free(msg);
        if (self.last_response) |msg| self.allocator.free(msg);
        if (self.undo_desc) |msg| self.allocator.free(msg);
        if (self.redo_desc) |msg| self.allocator.free(msg);
        self.allocator.destroy(self);
    }
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var global_state: ?*RuntimeState = null;

fn allocator() std.mem.Allocator {
    return gpa.allocator();
}

fn allocNullTerminated(bytes: []const u8) ?[*c]const u8 {
    const a = allocator();
    const buf = a.alloc(u8, bytes.len + 1) catch return null;
    @memcpy(buf[0..bytes.len], bytes);
    buf[bytes.len] = 0;
    return @ptrCast(buf.ptr);
}

fn setOwnedString(slot: *?[]u8, value: []const u8, a: std.mem.Allocator) !void {
    if (slot.*) |old| a.free(old);
    slot.* = try a.dupe(u8, value);
}

fn ensureContextFiles(state: *RuntimeState) !void {
    const base = try std.fs.path.join(state.allocator, &.{ state.data_dir, "context" });
    defer state.allocator.free(base);
    try std.fs.cwd().makePath(base);

    const defaults = [_][2][]const u8{
        .{ "SOUL.md", "# Soul\n\n**Name:** CClaude\n\n**Tone:** Precise, practical, rollback-first\n" },
        .{ "USER.md", "# User Profile\n\n- Prefers Android-native local agent workflows\n" },
        .{ "MEMORY.md", "# Long-term Memory\n\n- Native Zig runtime initialized\n" },
    };
    for (defaults) |entry| {
        const fp = try std.fs.path.join(state.allocator, &.{ base, entry[0] });
        defer state.allocator.free(fp);
        std.fs.cwd().access(fp, .{}) catch {
            const f = try std.fs.cwd().createFile(fp, .{});
            defer f.close();
            try f.writeAll(entry[1]);
        };
    }
}

fn appendMemory(state: *RuntimeState, file_name: []const u8, line: []const u8) !void {
    const fp = try std.fs.path.join(state.allocator, &.{ state.data_dir, "context", file_name });
    defer state.allocator.free(fp);
    const current = std.fs.cwd().readFileAlloc(state.allocator, fp, 1024 * 1024) catch try state.allocator.dupe(u8, "");
    defer state.allocator.free(current);
    const merged = try std.fmt.allocPrint(state.allocator, "{s}\n- {s}\n", .{ current, line });
    defer state.allocator.free(merged);
    const f = try std.fs.cwd().createFile(fp, .{});
    defer f.close();
    try f.writeAll(merged);
}

fn runResearch(state: *RuntimeState, idea: []const u8) ![]const u8 {
    var pipeline = try research.ResearchPipeline.init(state.allocator);
    defer pipeline.deinit();
    try pipeline.start(idea);
    const progress = pipeline.getProgress();
    return try std.fmt.allocPrint(state.allocator,
        "[Native Zig Research]\nIdea: {s}\nPipeline stages: {d}\nCurrent: {s}\nStatus: initialized rollback-first research orchestration",
        .{ idea, progress.total, progress.name },
    );
}

fn handleToolCommand(state: *RuntimeState, message: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, message, "/tool readfile ")) {
        const path = message[15..];
        const args = try std.fmt.allocPrint(state.allocator, "{{\"path\":\"{s}\"}}", .{path});
        defer state.allocator.free(args);
        return try state.tool_registry.execute(state.allocator, "readfile", args);
    }
    if (std.mem.startsWith(u8, message, "/tool search ")) {
        const rest = message[13..];
        const args = try std.fmt.allocPrint(state.allocator, "{{\"path\":\".\",\"regex\":\"{s}\"}}", .{rest});
        defer state.allocator.free(args);
        return try state.tool_registry.execute(state.allocator, "search", args);
    }
    if (std.mem.startsWith(u8, message, "/tool writefile ")) {
        const rest = message[16..];
        if (std.mem.indexOf(u8, rest, " :: ")) |sep| {
            const path = rest[0..sep];
            const content = rest[sep + 4 ..];
            const args = try std.fmt.allocPrint(state.allocator, "{{\"path\":\"{s}\",\"content\":\"{s}\"}}", .{path, content});
            defer state.allocator.free(args);
            return try state.tool_registry.execute(state.allocator, "writefile", args);
        }
        return try state.allocator.dupe(u8, "Usage: /tool writefile <path> :: <content>");
    }
    return try state.allocator.dupe(u8, "Unknown /tool command");
}

fn buildNativeReply(state: *RuntimeState, msg: []const u8) ![]const u8 {
    try ensureContextFiles(state);

    if (std.mem.startsWith(u8, msg, "/tool ")) {
        const tool_result = try handleToolCommand(state, msg);
        try appendMemory(state, "MEMORY.md", "Executed a native tool command");
        return tool_result;
    }

    if (std.mem.eql(u8, msg, "/memory show")) {
        const prompt = try state.context_store.buildPrompt(state.allocator);
        return prompt;
    }

    if (std.mem.startsWith(u8, msg, "/research ")) {
        const idea = msg[10..];
        try appendMemory(state, "MEMORY.md", "Triggered native research pipeline");
        return try runResearch(state, idea);
    }

    try appendMemory(state, "USER.md", "User sent a native message");
    const memory_prompt = try state.context_store.buildPrompt(state.allocator);
    defer state.allocator.free(memory_prompt);

    return try std.fmt.allocPrint(
        state.allocator,
        "[Native Zig] CClaude online. Received: {s}\n\n## Context Snapshot\n{s}\n\nTry commands:\n- /tool readfile <path>\n- /tool writefile <path> :: <content>\n- /tool search <text>\n- /memory show\n- /research <idea>",
        .{ msg, memory_prompt },
    );
}

export fn cclaude_init(data_dir: [*c]const u8, api_key: [*c]const u8) i32 {
    if (global_state != null) return 0;
    const dd = std.mem.span(data_dir);
    const key = std.mem.span(api_key);
    global_state = RuntimeState.init(allocator(), dd, key) catch return -1;
    ensureContextFiles(global_state.?) catch return -1;
    return 0;
}

export fn cclaude_free() void {
    if (global_state) |state| {
        state.deinit();
        global_state = null;
    }
}

export fn cclaude_set_http_callback(callback: ?HttpCallback) void {
    if (global_state) |state| state.http_callback = callback;
}

export fn cclaude_set_approval_callback(callback: ?ApprovalCallback) void {
    if (global_state) |state| state.approval_callback = callback;
}

export fn cclaude_send(message: [*c]const u8, token_callback: ?TokenCallback) [*c]const u8 {
    const state = global_state orelse return @ptrCast("Error: not initialized");
    const msg = std.mem.span(message);

    setOwnedString(&state.last_user_message, msg, state.allocator) catch return @ptrCast("Error: OOM");
    const response = buildNativeReply(state, msg) catch |err| {
        return @ptrCast(@errorName(err).ptr);
    };

    if (state.last_response) |old| state.allocator.free(old);
    state.last_response = response;
    setOwnedString(&state.undo_desc, "Undo last native operation", state.allocator) catch {};
    setOwnedString(&state.redo_desc, "Redo last native operation", state.allocator) catch {};
    state.can_undo = true;
    state.can_redo = false;

    if (token_callback) |cb| {
        var it = std.mem.splitScalar(u8, response, ' ');
        while (it.next()) |part| {
            const token = std.fmt.allocPrint(state.allocator, "{s} ", .{part}) catch continue;
            defer state.allocator.free(token);
            if (allocNullTerminated(token)) |cstr| {
                cb(cstr);
                cclaude_free_string(cstr);
            }
        }
    }

    return allocNullTerminated(response) orelse @ptrCast("Error: response alloc failed");
}

export fn cclaude_undo() i32 {
    const state = global_state orelse return -1;
    if (!state.can_undo) return 0;
    state.can_undo = false;
    state.can_redo = true;
    return 1;
}

export fn cclaude_redo() i32 {
    const state = global_state orelse return -1;
    if (!state.can_redo) return 0;
    state.can_redo = false;
    state.can_undo = true;
    return 1;
}

export fn cclaude_can_undo() i32 {
    const state = global_state orelse return 0;
    return if (state.can_undo) 1 else 0;
}

export fn cclaude_can_redo() i32 {
    const state = global_state orelse return 0;
    return if (state.can_redo) 1 else 0;
}

export fn cclaude_get_undo_description() [*c]const u8 {
    const state = global_state orelse return null;
    if (state.undo_desc) |d| return allocNullTerminated(d) orelse @ptrCast("Undo");
    return null;
}

export fn cclaude_get_redo_description() [*c]const u8 {
    const state = global_state orelse return null;
    if (state.redo_desc) |d| return allocNullTerminated(d) orelse @ptrCast("Redo");
    return null;
}

export fn cclaude_rollback_conversation() i32 {
    const state = global_state orelse return -1;
    state.can_undo = false;
    state.can_redo = false;
    return 0;
}

export fn cclaude_free_string(s: [*c]const u8) void {
    _ = s;
}
