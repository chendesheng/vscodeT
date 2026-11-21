// Port of the wire subset of
// `src/vs/workbench/api/browser/mainThreadTextEditors.ts`.
//
// Terminal adaptation: there is one mirrored text editor (id `"1"`). The
// adapter applies selections and edits after converting UTF-16 columns to the
// editor's UTF-8 columns; decorations, options and editor visibility are
// accepted but not rendered.
const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const protocol = @import("../common/extHost.protocol.zig");
const Selection = @import("../../../editor/common/core/selection.zig").Selection;

pub const EditSpec = struct {
    start_line: usize,
    start_column: usize,
    end_line: usize,
    end_column: usize,
    text: []const u8,
};

pub const RevealSpec = struct {
    start_line: usize,
    end_line: usize,
};

/// Port of `TextEditorRevealType` from `extHost.protocol.ts`.
pub const TextEditorRevealType = enum(u8) {
    default = 0,
    in_center = 1,
    in_center_if_outside_viewport = 2,
    at_top = 3,

    pub fn fromValue(value: i64) TextEditorRevealType {
        return switch (value) {
            1 => .in_center,
            2 => .in_center_if_outside_viewport,
            3 => .at_top,
            else => .default,
        };
    }
};

pub const Host = struct {
    context: *anyopaque,
    set_selections: *const fn (context: *anyopaque, selections: []Selection) anyerror!void,
    apply_edits: *const fn (context: *anyopaque, version: u32, edits: []const EditSpec) anyerror!void,
    show_document: *const fn (context: *anyopaque, uri: std.json.Value, options: std.json.Value) anyerror!?[]const u8,
    reveal: *const fn (context: *anyopaque, range: RevealSpec, reveal_type: TextEditorRevealType) anyerror!void,
};

pub const MainThreadTextEditors = struct {
    allocator: Allocator,
    host: Host,
    decoration_count: usize = 0,

    pub fn init(allocator: Allocator, host: Host) MainThreadTextEditors {
        return .{ .allocator = allocator, .host = host };
    }

    pub fn invoke(self: *MainThreadTextEditors, method: []const u8, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        if (std.mem.eql(u8, method, "$registerTextEditorDecorationType")) {
            self.decoration_count += 1;
            var buffer: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&buffer, "decoration-{d}", .{self.decoration_count});
            return .{ .json = .{ .string = try arena.dupe(u8, key) } };
        }
        if (std.mem.eql(u8, method, "$trySetSelections")) {
            const list = valueArg(args, 1) orelse return .empty;
            if (list != .array) return .empty;
            var selections = try self.allocator.alloc(Selection, list.array.items.len);
            defer self.allocator.free(selections);
            for (list.array.items, 0..) |value, index| {
                selections[index] = selectionFromJson(value) orelse Selection.init(1, 1, 1, 1);
            }
            try self.host.set_selections(self.host.context, selections);
            return .empty;
        }
        if (std.mem.eql(u8, method, "$tryApplyEdits")) {
            const version: u32 = if (args.len > 1 and args[1] == .json and args[1].json == .integer) @intCast(args[1].json.integer) else 0;
            const list = valueArg(args, 2) orelse return .{ .json = .{ .bool = true } };
            if (list != .array) return .{ .json = .{ .bool = true } };
            var edits = std.array_list.Managed(EditSpec).init(arena);
            for (list.array.items) |value| {
                const edit = editSpecFromJson(value) orelse continue;
                try edits.append(edit);
            }
            try self.host.apply_edits(self.host.context, version, edits.items);
            return .{ .json = .{ .bool = true } };
        }
        if (std.mem.eql(u8, method, "$tryShowTextDocument")) {
            const uri = valueArg(args, 0) orelse return .empty;
            const options = valueArg(args, 1) orelse std.json.Value.null;
            if (try self.host.show_document(self.host.context, uri, options)) |id| {
                return .{ .json = .{ .string = try arena.dupe(u8, id) } };
            }
            return .empty;
        }
        if (std.mem.eql(u8, method, "$tryRevealRange")) {
            const range = valueArg(args, 1) orelse return .empty;
            const spec = revealSpecFromJson(range) orelse return .empty;
            const reveal_type: TextEditorRevealType = if (args.len > 2 and args[2] == .json and args[2].json == .integer)
                TextEditorRevealType.fromValue(args[2].json.integer)
            else
                .default;
            try self.host.reveal(self.host.context, spec, reveal_type);
            return .empty;
        }
        if (std.mem.eql(u8, method, "$trySetOptions") or
            std.mem.eql(u8, method, "$trySetDecorations") or
            std.mem.eql(u8, method, "$trySetDecorationsFast") or
            std.mem.eql(u8, method, "$tryShowEditor") or
            std.mem.eql(u8, method, "$tryHideEditor") or
            std.mem.eql(u8, method, "$removeTextEditorDecorationType"))
        {
            return .empty;
        }
        if (methodKind(method) == .request) {
            return .{ .err = .{ .name = "Unsupported", .message = method } };
        }
        return .empty;
    }
};

fn selectionFromJson(value: std.json.Value) ?Selection {
    if (value != .object) return null;
    const object = value.object;
    const start_line = intField(object, "selectionStartLineNumber") orelse return null;
    const start_column = intField(object, "selectionStartColumn") orelse return null;
    const end_line = intField(object, "positionLineNumber") orelse return null;
    const end_column = intField(object, "positionColumn") orelse return null;
    return Selection.init(start_line, start_column, end_line, end_column);
}

fn revealSpecFromJson(value: std.json.Value) ?RevealSpec {
    if (value != .object) return null;
    const start_line = intField(value.object, "startLineNumber") orelse return null;
    const end_line = intField(value.object, "endLineNumber") orelse return null;
    if (start_line < 1 or end_line < 1) return null;
    return .{ .start_line = start_line, .end_line = end_line };
}

fn editSpecFromJson(value: std.json.Value) ?EditSpec {
    if (value != .object) return null;
    const object = value.object;
    const range = object.get("range") orelse return null;
    if (range != .object) return null;
    const text = object.get("text") orelse return null;
    return .{
        .start_line = intField(range.object, "startLineNumber") orelse return null,
        .start_column = intField(range.object, "startColumn") orelse return null,
        .end_line = intField(range.object, "endLineNumber") orelse return null,
        .end_column = intField(range.object, "endColumn") orelse return null,
        .text = if (text == .string) text.string else "",
    };
}

fn intField(object: std.json.ObjectMap, name: []const u8) ?usize {
    const value = object.get(name) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

fn methodKind(method: []const u8) protocol.MethodKind {
    for (protocol.MainThreadTextEditors.methods) |candidate| {
        if (std.mem.eql(u8, candidate.name, method)) return candidate.kind;
    }
    return .notification;
}

fn valueArg(args: []const rpc.Arg, index: usize) ?std.json.Value {
    if (index >= args.len or args[index] != .json) return null;
    return args[index].json;
}

test "MainThreadTextEditors: reveal type and range parsing" {
    try std.testing.expectEqual(TextEditorRevealType.default, TextEditorRevealType.fromValue(0));
    try std.testing.expectEqual(TextEditorRevealType.in_center, TextEditorRevealType.fromValue(1));
    try std.testing.expectEqual(TextEditorRevealType.in_center_if_outside_viewport, TextEditorRevealType.fromValue(2));
    try std.testing.expectEqual(TextEditorRevealType.at_top, TextEditorRevealType.fromValue(3));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        "{\"startLineNumber\":2,\"startColumn\":1,\"endLineNumber\":4,\"endColumn\":3}",
        .{},
    );
    const spec = revealSpecFromJson(value).?;
    try std.testing.expectEqual(@as(usize, 2), spec.start_line);
    try std.testing.expectEqual(@as(usize, 4), spec.end_line);
}
