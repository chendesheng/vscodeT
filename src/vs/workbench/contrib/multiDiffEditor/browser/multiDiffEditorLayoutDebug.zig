// Port of `src/vs/workbench/contrib/multiDiffEditor/browser/multiDiffEditorLayoutDebug.ts`.
// Zig JSON objects omit undefined properties. Structural patches retain
// their operation order and JSON Pointer escaping from upstream.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const JsonPatchOperation = struct {
    op: enum { add, replace, remove },
    path: []const u8,
    value: ?Value = null,
};

pub const JsonPatch = union(enum) {
    operations: []const JsonPatchOperation,
    children: []const JsonPatch,
};

fn pointer(allocator: Allocator, prefix: []const u8, segment: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    try result.appendSlice(allocator, prefix);
    try result.append(allocator, '/');
    for (segment) |ch| {
        switch (ch) {
            '~' => try result.appendSlice(allocator, "~0"),
            '/' => try result.appendSlice(allocator, "~1"),
            else => try result.append(allocator, ch),
        }
    }
    return result.toOwnedSlice(allocator);
}

fn primitiveEqual(previous: Value, next: Value) bool {
    if (previous == .integer and next == .float) return @as(f64, @floatFromInt(previous.integer)) == next.float;
    if (previous == .float and next == .integer) return previous.float == @as(f64, @floatFromInt(next.integer));
    if (std.meta.activeTag(previous) != std.meta.activeTag(next)) return false;
    return switch (previous) {
        .null => true,
        .bool => |value| value == next.bool,
        .integer => |value| value == next.integer,
        .float => |value| value == next.float,
        .number_string => |value| std.mem.eql(u8, value, next.number_string),
        .string => |value| std.mem.eql(u8, value, next.string),
        .array, .object => false,
    };
}

/// The supplied allocator is an arena for operation paths and the operation
/// slice. Values are borrowed from the next JSON state until serialization.
pub fn createJsonPatch(allocator: Allocator, previous: Value, next: Value) !JsonPatch {
    var result: std.ArrayList(JsonPatchOperation) = .empty;
    try appendPatch(allocator, &result, previous, next, "");
    return .{ .operations = try result.toOwnedSlice(allocator) };
}

fn appendPatch(allocator: Allocator, result: *std.ArrayList(JsonPatchOperation), previous: Value, next: Value, path: []const u8) !void {
    if (primitiveEqual(previous, next)) return;
    if (previous == .array and next == .array) {
        if (previous.array.items.len != next.array.items.len) {
            try result.append(allocator, .{ .op = .replace, .path = path, .value = next });
            return;
        }
        for (previous.array.items, next.array.items, 0..) |old, new, index| {
            const name = try std.fmt.allocPrint(allocator, "{d}", .{index});
            try appendPatch(allocator, result, old, new, try pointer(allocator, path, name));
        }
        return;
    }
    if (previous == .object and next == .object) {
        for (previous.object.keys()) |name| {
            if (!next.object.contains(name)) try result.append(allocator, .{ .op = .remove, .path = try pointer(allocator, path, name) });
        }
        for (next.object.keys(), next.object.values()) |name, value| {
            const child_path = try pointer(allocator, path, name);
            if (previous.object.get(name)) |old| {
                try appendPatch(allocator, result, old, value, child_path);
            } else {
                try result.append(allocator, .{ .op = .add, .path = child_path, .value = value });
            }
        }
        return;
    }
    try result.append(allocator, .{ .op = .replace, .path = path, .value = next });
}

fn decodeSegment(allocator: Allocator, encoded: []const u8) ![]const u8 {
    var decoded: std.ArrayList(u8) = .empty;
    var offset: usize = 0;
    while (offset < encoded.len) : (offset += 1) {
        const ch = encoded[offset];
        if (ch != '~') {
            try decoded.append(allocator, ch);
            continue;
        }
        offset += 1;
        if (offset == encoded.len) return error.InvalidJsonPointer;
        try decoded.append(allocator, switch (encoded[offset]) {
            '0' => '~',
            '1' => '/',
            else => return error.InvalidJsonPointer,
        });
    }
    return decoded.toOwnedSlice(allocator);
}

fn cloneValue(allocator: Allocator, value: Value) !Value {
    const bytes = try std.json.Stringify.valueAlloc(allocator, value, .{});
    return std.json.parseFromSliceLeaky(Value, allocator, bytes, .{ .allocate = .alloc_always });
}

fn applyOperation(allocator: Allocator, root: *Value, operation: JsonPatchOperation) !void {
    if (operation.path.len == 0) {
        root.* = if (operation.value) |value| try cloneValue(allocator, value) else .null;
        return;
    }
    if (operation.path[0] != '/') return error.InvalidJsonPointer;
    var segments = std.mem.splitScalar(u8, operation.path[1..], '/');
    var encoded = segments.next().?;
    var node = root;
    while (segments.next()) |next| {
        const segment = try decodeSegment(allocator, encoded);
        node = switch (node.*) {
            .object => node.object.getPtr(segment) orelse return error.InvalidJsonPointer,
            .array => blk: {
                const index = try std.fmt.parseInt(usize, segment, 10);
                if (index >= node.array.items.len) return error.InvalidJsonPointer;
                break :blk &node.array.items[index];
            },
            else => return error.InvalidJsonPointer,
        };
        encoded = next;
    }
    const segment = try decodeSegment(allocator, encoded);
    switch (node.*) {
        .object => {
            if (operation.op == .remove) {
                _ = node.object.orderedRemove(segment);
            } else {
                try node.object.put(allocator, segment, try cloneValue(allocator, operation.value orelse return error.MissingValue));
            }
        },
        .array => {
            const index = try std.fmt.parseInt(usize, segment, 10);
            if (operation.op == .add) {
                if (index > node.array.items.len) return error.InvalidJsonPointer;
                try node.array.insert(index, try cloneValue(allocator, operation.value orelse return error.MissingValue));
            } else {
                if (index >= node.array.items.len) return error.InvalidJsonPointer;
                if (operation.op == .remove) {
                    _ = node.array.orderedRemove(index);
                } else {
                    node.array.items[index] = try cloneValue(allocator, operation.value orelse return error.MissingValue);
                }
            }
        },
        else => return error.InvalidJsonPointer,
    }
}

fn applyPatch(allocator: Allocator, root: *Value, patch: JsonPatch) !void {
    switch (patch) {
        .operations => |operations| for (operations) |operation| try applyOperation(allocator, root, operation),
        .children => |children| for (children) |child| try applyPatch(allocator, root, child),
    }
}

/// The layout-debug viewer works with generated JSON, never user settings.
/// Re-serialize the structurally edited value with tab indentation.
pub fn applyJsonPatchToText(allocator: Allocator, text: []const u8, patch: JsonPatch) ![]u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var value = try std.json.parseFromSliceLeaky(Value, a, text, .{ .allocate = .alloc_always });
    try applyPatch(a, &value, patch);
    return std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_tab });
}

const resource_input = @import("../../../common/editor/textResourceEditorInput.zig");
const subscriptions = @import("../../../../base/common/event.zig");
const time = @import("../../../../base/common/timeCompat.zig");

/// One generated JSONL editor owns the source-layout subscription. Destroying
/// either the source pane or the log removes the subscription synchronously.
pub fn createMultiDiffEditorLayoutDebugModel(comptime Widget: type, source: *Widget) !*resource_input.TextResourceEditorInput {
    const Session = LayoutDebugSession(Widget);
    return Session.create(source);
}

fn LayoutDebugSession(comptime Widget: type) type {
    return struct {
        const Self = @This();
        allocator: Allocator,
        source: ?*Widget,
        input: *resource_input.TextResourceEditorInput,
        previous_arena: std.heap.ArenaAllocator,
        previous: Value,
        layout_listener: ?subscriptions.SignalSubscription = null,
        source_dispose: ?subscriptions.SignalSubscription = null,
        input_dispose: ?subscriptions.SignalSubscription = null,
        updating: bool = false,

        fn readState(a: Allocator, source: *Widget) !Value {
            const state = try source.getLayoutDebugState(a);
            const serialized = try std.json.Stringify.valueAlloc(a, state, .{});
            var result = try std.json.parseFromSliceLeaky(Value, a, serialized, .{ .allocate = .alloc_always });
            // Upstream's optional geometryEdit is omitted rather than null.
            if (state.geometryEdit == null) _ = result.object.orderedRemove("geometryEdit");
            return result;
        }

        fn create(source: *Widget) !*resource_input.TextResourceEditorInput {
            const allocator = source.allocator;
            const io = source.impl.io;
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const a = arena.allocator();
            const state = try readState(a, source);
            const first = try std.json.Stringify.valueAlloc(a, .{ .timestamp = time.milliTimestamp(), .set = state }, .{});
            const contents = try std.fmt.allocPrint(a, "{s}\n", .{first});
            var random: [16]u8 = undefined;
            io.random(&random);
            const hex = std.fmt.bytesToHex(random, .lower);
            const path = try std.fmt.allocPrint(a, "/multi-diff-editor-layout-{s}.jsonl", .{&hex});
            const uri = try std.Uri.parse(try std.fmt.allocPrint(a, "inmemory:{s}", .{path}));
            const input = try resource_input.TextResourceEditorInput.init(allocator, io, path, "Multi Diff Editor Layout Debug State", contents, uri);
            errdefer input.destroy();
            input.document.model.setLanguage("jsonl");
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{ .allocator = allocator, .source = source, .input = input, .previous_arena = arena, .previous = state };
            self.layout_listener = try source.on_did_change_layout.listenDisposable(self, onLayout);
            errdefer self.detachSource();
            self.source_dispose = try source.on_will_dispose.listenDisposable(self, onSourceDispose);
            self.input_dispose = try input.base.on_will_dispose.listenDisposable(self, onInputDispose);
            return input;
        }

        fn detachSource(self: *Self) void {
            if (self.layout_listener) |listener| listener.dispose();
            if (self.source_dispose) |listener| listener.dispose();
            self.layout_listener = null;
            self.source_dispose = null;
            self.source = null;
        }

        fn onSourceDispose(_: void, self: *Self) !void {
            self.detachSource();
        }

        fn onInputDispose(_: void, self: *Self) !void {
            self.detachSource();
            if (self.input_dispose) |listener| listener.dispose();
            self.previous_arena.deinit();
            self.allocator.destroy(self);
        }

        fn onLayout(_: void, self: *Self) !void {
            if (self.updating) return;
            self.updating = true;
            defer self.updating = false;
            self.appendChange() catch |err| {
                if (err != error.LayoutNotReady) std.log.scoped(.multi_diff).warn("Layout debug update failed: {s}", .{@errorName(err)});
            };
        }

        fn appendChange(self: *Self) !void {
            const source = self.source orelse return;
            var next_arena = std.heap.ArenaAllocator.init(self.allocator);
            errdefer next_arena.deinit();
            const next = try readState(next_arena.allocator(), source);
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            const a = scratch.allocator();
            const patch = try createJsonPatch(a, self.previous, next);
            if (patch.operations.len != 0) {
                const line = try std.json.Stringify.valueAlloc(a, .{ .timestamp = time.milliTimestamp(), .patch = patch.operations }, .{ .emit_null_optional_fields = false });
                try self.input.document.appendGeneratedContents(try std.fmt.allocPrint(a, "{s}\n", .{line}));
            }
            self.previous_arena.deinit();
            self.previous_arena = next_arena;
            self.previous = next;
        }
    };
}
