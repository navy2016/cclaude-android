const std = @import("std");

const TokenCallback = *const fn ([*c]const u8) callconv(.C) void;
const HttpCallback = *const fn ([*c]const u8, [*c]const u8, [*c]const u8, usize) callconv(.C) [*c]const u8;
const ApprovalCallback = *const fn ([*c]const u8, [*c]const u8) callconv(.C) bool;

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

    fn init(alloc: std.mem.Allocator, data_dir: []const u8, api_key: []const u8) !*RuntimeState {
        const state = try alloc.create(RuntimeState);
        state.* = .{
            .allocator = alloc,
            .data_dir = try alloc.dupe(u8, data_dir),
            .api_key = try alloc.dupe(u8, api_key),
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

export fn cclaude_init(data_dir: [*c]const u8, api_key: [*c]const u8) i32 {
    if (global_state != null) return 0;
    const dd = std.mem.span(data_dir);
    const key = std.mem.span(api_key);
    global_state = RuntimeState.init(allocator(), dd, key) catch return -1;
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

    const response = std.fmt.allocPrint(
        state.allocator,
        "[Native Zig] CClaude online. Received: {s}\nUndo-ready: true\nDataDir: {s}",
        .{ msg, state.data_dir },
    ) catch return @ptrCast("Error: OOM");

    if (state.last_response) |old| state.allocator.free(old);
    state.last_response = response;

    setOwnedString(&state.undo_desc, "Undo last native reply", state.allocator) catch {};
    setOwnedString(&state.redo_desc, "Redo last native reply", state.allocator) catch {};
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
    // Intentionally a no-op for now to avoid cross-boundary free issues.
}
