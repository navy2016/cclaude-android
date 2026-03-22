const std = @import("std");

const TokenCallback = *const fn ([*c]const u8) callconv(.C) void;
const HttpCallback = *const fn ([*c]const u8, [*c]const u8, [*c]const u8, usize) callconv(.C) [*c]const u8;
const ApprovalCallback = *const fn ([*c]const u8, [*c]const u8) callconv(.C) bool;

const MAX_CSTR = 1024 * 1024;
var g_cstr_buf: [MAX_CSTR]u8 = [_]u8{0} ** MAX_CSTR;
var g_token_buf: [8192]u8 = [_]u8{0} ** 8192;

const OpKind = enum { write_file, memory_file_replace, none };
const UndoOp = struct {
    kind: OpKind,
    target: []u8,
    previous: []u8,
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

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn isExternalAndroidPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/storage/") or std.mem.startsWith(u8, path, "/sdcard/");
}

fn pushUndoOp(state: *RuntimeState, target: []const u8, previous: []const u8, kind: OpKind) !void {
    try state.undo_stack.append(.{
        .kind = kind,
        .target = try state.allocator.dupe(u8, target),
        .previous = try state.allocator.dupe(u8, previous),
    });
    state.can_undo = true;
    state.can_redo = false;
    for (state.redo_stack.items) |op| {
        state.allocator.free(op.target);
        state.allocator.free(op.previous);
    }
    state.redo_stack.clearRetainingCapacity();
}

fn nativeReadFile(state: *RuntimeState, path: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, path, " \t\r\n");
    if (isExternalAndroidPath(trimmed)) {
        return try std.fmt.allocPrint(state.allocator,
            "Read blocked by Android scoped storage: {s}\nPlease use SAF import first, then read the imported copy.", .{trimmed});
    }
    const file = std.fs.cwd().openFile(trimmed, .{}) catch |err| {
        return try std.fmt.allocPrint(state.allocator, "Read failed: {s} -> {s}", .{ trimmed, @errorName(err) });
    };
    defer file.close();
    return try file.readToEndAlloc(state.allocator, 2 * 1024 * 1024);
}

fn nativeWriteFile(state: *RuntimeState, path: []const u8, content: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, path, " \t\r\n");
    if (isExternalAndroidPath(trimmed)) {
        return try std.fmt.allocPrint(state.allocator,
            "Write blocked by Android scoped storage: {s}\nPlease write under app-accessible directories.", .{trimmed});
    }
    const previous = std.fs.cwd().readFileAlloc(state.allocator, trimmed, 2 * 1024 * 1024) catch try state.allocator.dupe(u8, "");
    errdefer state.allocator.free(previous);
    if (std.mem.lastIndexOf(u8, trimmed, "/")) |last_slash| {
        const dir_path = trimmed[0..last_slash];
        std.fs.cwd().makePath(dir_path) catch {};
    }
    const file = try std.fs.cwd().createFile(trimmed, .{});
    defer file.close();
    try file.writeAll(content);
    try pushUndoOp(state, trimmed, previous, .write_file);
    return try std.fmt.allocPrint(state.allocator, "Wrote file: {s}", .{trimmed});
}

fn searchDir(state: *RuntimeState, base_path: []const u8, needle: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(state.allocator);
    defer result.deinit();
    var dir = std.fs.cwd().openDir(base_path, .{ .iterate = true }) catch |err| {
        return try std.fmt.allocPrint(state.allocator, "Search open dir failed: {s} -> {s}", .{ base_path, @errorName(err) });
    };
    defer dir.close();
    var walker = dir.walk(state.allocator) catch |err| {
        return try std.fmt.allocPrint(state.allocator, "Search walk failed: {s} -> {s}", .{ base_path, @errorName(err) });
    };
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const file = dir.openFile(entry.path, .{}) catch continue;
        defer file.close();
        const content = file.readToEndAlloc(state.allocator, 512 * 1024) catch continue;
        defer state.allocator.free(content);
        if (std.mem.indexOf(u8, content, needle) != null) {
            try result.writer().print("{s}/{s}\n", .{ base_path, entry.path });
        }
    }
    if (result.items.len == 0) return try state.allocator.dupe(u8, "No matches found");
    return try state.allocator.dupe(u8, result.items);
}

fn memoryFilePath(state: *RuntimeState, file_name: []const u8) ![]u8 {
    return try std.fs.path.join(state.allocator, &.{ state.data_dir, "context", file_name });
}

fn memoryShow(state: *RuntimeState) ![]u8 {
    const soul_path = try memoryFilePath(state, "SOUL.md");
    defer state.allocator.free(soul_path);
    const user_path = try memoryFilePath(state, "USER.md");
    defer state.allocator.free(user_path);
    const mem_path = try memoryFilePath(state, "MEMORY.md");
    defer state.allocator.free(mem_path);
    const soul = std.fs.cwd().readFileAlloc(state.allocator, soul_path, 1024 * 1024) catch try state.allocator.dupe(u8, "# Soul\n");
    defer state.allocator.free(soul);
    const user = std.fs.cwd().readFileAlloc(state.allocator, user_path, 1024 * 1024) catch try state.allocator.dupe(u8, "# User Profile\n");
    defer state.allocator.free(user);
    const mem = std.fs.cwd().readFileAlloc(state.allocator, mem_path, 1024 * 1024) catch try state.allocator.dupe(u8, "# Long-term Memory\n");
    defer state.allocator.free(mem);
    return try std.fmt.allocPrint(state.allocator, "## Soul\n{s}\n\n## User\n{s}\n\n## Memory\n{s}", .{ soul, user, mem });
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
        if (!pathExists(fp)) {
            const f = try std.fs.cwd().createFile(fp, .{});
            defer f.close();
            try f.writeAll(entry[1]);
        }
    }
}

fn appendMemory(state: *RuntimeState, file_name: []const u8, line: []const u8) !void {
    const fp = try memoryFilePath(state, file_name);
    defer state.allocator.free(fp);
    const current = std.fs.cwd().readFileAlloc(state.allocator, fp, 1024 * 1024) catch try state.allocator.dupe(u8, "");
    defer state.allocator.free(current);
    const merged = try std.fmt.allocPrint(state.allocator, "{s}\n- {s}\n", .{ current, line });
    defer state.allocator.free(merged);
    const old_content = try state.allocator.dupe(u8, current);
    errdefer state.allocator.free(old_content);
    const f = try std.fs.cwd().createFile(fp, .{});
    defer f.close();
    try f.writeAll(merged);
    try pushUndoOp(state, fp, old_content, .memory_file_replace);
}

fn containsAny(hay: []const u8, needles: []const []const u8) bool {
    for (needles) |n| if (std.mem.indexOf(u8, hay, n) != null) return true;
    return false;
}

fn importedDirPath(state: *RuntimeState) ![]u8 {
    return try std.fs.path.join(state.allocator, &.{ state.data_dir, "..", "imports" });
}

fn latestImportedFile(state: *RuntimeState) !?[]u8 {
    const dir_path = try importedDirPath(state);
    defer state.allocator.free(dir_path);
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .file) return try std.fs.path.join(state.allocator, &.{ dir_path, entry.name });
    }
    return null;
}

fn classifyAndRemember(state: *RuntimeState, msg: []const u8) !void {
    if (containsAny(msg, &.{ "喜欢", "prefer", "偏好", "习惯" })) {
        try appendMemory(state, "USER.md", msg);
    } else {
        try appendMemory(state, "MEMORY.md", msg);
    }
}

fn runResearch(state: *RuntimeState, idea: []const u8) ![]u8 {
    const literature = try std.fmt.allocPrint(state.allocator,
        "[Literature]\n- Search query: {s}\n- Seed sources: arXiv / Semantic Scholar / OpenAlex\n- Status: ready", .{idea});
    defer state.allocator.free(literature);
    const hypothesis = try std.fmt.allocPrint(state.allocator,
        "[Hypothesis]\n- Core hypothesis: local Zig-native Android agent can reduce runtime weight while preserving agent autonomy\n- Risk: Android scoped storage and JNI complexity", .{});
    defer state.allocator.free(hypothesis);
    const experiment = try std.fmt.allocPrint(state.allocator,
        "[Experiment]\n- Plan 1: native runtime + JNI bridge\n- Plan 2: SAF import + app-private file access\n- Plan 3: undo/redo consistency across UI and native state", .{});
    defer state.allocator.free(experiment);
    const paper = try std.fmt.allocPrint(state.allocator,
        "[Paper]\n- Draft title: Native Zig Android Agent with Rollback-First Tooling\n- Deliverable: literature -> hypothesis -> experiment -> paper pipeline initialized", .{});
    defer state.allocator.free(paper);
    return try std.fmt.allocPrint(state.allocator,
        "[Native Zig Research]\nIdea: {s}\n\n{s}\n\n{s}\n\n{s}\n\n{s}", .{ idea, literature, hypothesis, experiment, paper });
}

fn handleToolCommand(state: *RuntimeState, message: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, message, "/tool readfile ")) {
        return try nativeReadFile(state, message[15..]);
    }
    if (std.mem.startsWith(u8, message, "/tool search ")) {
        const rest = std.mem.trim(u8, message[13..], " \t\r\n");
        const context_dir = try std.fs.path.join(state.allocator, &.{ state.data_dir, "context" });
        defer state.allocator.free(context_dir);
        return try searchDir(state, context_dir, rest);
    }
    if (std.mem.startsWith(u8, message, "/tool writefile ")) {
        const rest = message[16..];
        if (std.mem.indexOf(u8, rest, " :: ")) |sep| {
            return try nativeWriteFile(state, rest[0..sep], rest[sep + 4 ..]);
        }
        return try state.allocator.dupe(u8, "Usage: /tool writefile <path> :: <content>");
    }
    return try state.allocator.dupe(u8, "Unknown /tool command");
}

fn reactLoop(state: *RuntimeState, msg: []const u8) ![]u8 {
    try ensureContextFiles(state);

    if (std.mem.startsWith(u8, msg, "/tool ")) return try handleToolCommand(state, msg);
    if (std.mem.eql(u8, msg, "/memory show")) return try memoryShow(state);
    if (std.mem.startsWith(u8, msg, "/research ")) return try runResearch(state, std.mem.trim(u8, msg[10..], " \t\r\n"));

    try classifyAndRemember(state, msg);

    if (containsAny(msg, &.{ "search", "find", "查找", "搜索" })) {
        const context_dir = try std.fs.path.join(state.allocator, &.{ state.data_dir, "context" });
        defer state.allocator.free(context_dir);
        return try searchDir(state, context_dir, "CClaude");
    }
    if (containsAny(msg, &.{ "research", "论文", "研究", "paper" })) {
        return try runResearch(state, msg);
    }
    if (containsAny(msg, &.{ "read", "打开文件", "读取", "readfile" })) {
        if (try latestImportedFile(state)) |fp| {
            defer state.allocator.free(fp);
            return try nativeReadFile(state, fp);
        }
    }

    const memory_prompt = try memoryShow(state);
    defer state.allocator.free(memory_prompt);
    return try std.fmt.allocPrint(state.allocator,
        "[Native Zig] CClaude online.\nReceived: {s}\n\n## Context Snapshot\n{s}\n\nTry commands:\n- /tool readfile <path>\n- /tool writefile <path> :: <content>\n- /tool search <text>\n- /memory show\n- /research <idea>", .{ msg, memory_prompt });
}

export fn cclaude_init(data_dir: [*c]const u8, api_key: [*c]const u8) i32 {
    if (global_state != null) return 0;
    global_state = RuntimeState.init(allocator(), std.mem.span(data_dir), std.mem.span(api_key)) catch return -1;
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
    const response_const = reactLoop(state, msg) catch return @ptrCast("Error: native runtime failure");
    const response = state.allocator.dupe(u8, response_const) catch return @ptrCast("Error: OOM");
    state.allocator.free(response_const);

    if (state.last_response) |old| state.allocator.free(old);
    state.last_response = response;
    setOwnedString(&state.undo_desc, "Undo last native operation", state.allocator) catch {};
    setOwnedString(&state.redo_desc, "Redo last native operation", state.allocator) catch {};
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

fn restoreOp(_state: *RuntimeState, op: UndoOp) !void {
    const f = try std.fs.cwd().createFile(op.target, .{});
    defer f.close();
    try f.writeAll(op.previous);
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
    const f = std.fs.cwd().createFile(op.target, .{}) catch return -1;
    f.close();
    state.undo_stack.append(op) catch return -1;
    state.can_undo = state.undo_stack.items.len > 0;
    state.can_redo = state.redo_stack.items.len > 0;
    return 1;
}

export fn cclaude_can_undo() i32 {
    const state = global_state orelse return 0;
    return if (state.can_undo or state.undo_stack.items.len > 0) 1 else 0;
}

export fn cclaude_can_redo() i32 {
    const state = global_state orelse return 0;
    return if (state.can_redo or state.redo_stack.items.len > 0) 1 else 0;
}

export fn cclaude_get_undo_description() [*c]const u8 {
    const state = global_state orelse return null;
    if (state.undo_desc) |d| return toStableCString(d);
    return null;
}

export fn cclaude_get_redo_description() [*c]const u8 {
    const state = global_state orelse return null;
    if (state.redo_desc) |d| return toStableCString(d);
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
