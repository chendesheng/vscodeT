// Terminal subset of
// `src/vs/workbench/services/untitled/common/untitledTextEditorInput.ts`.
// Untitled inputs keep their content in memory; save-as to a file is not
// ported yet.
const std = @import("std");
const Allocator = std.mem.Allocator;
const editor_input = @import("../../../common/editor/editorInput.zig");
const EditorInput = editor_input.EditorInput;
const factory_mod = @import("../../../common/editor/editorFactory.zig");

pub const ID = "workbench.editors.untitledEditor";

pub const UntitledTextEditorInput = struct {
    allocator: Allocator,
    base: EditorInput,
    path: []u8,
    content: ?[]u8 = null,

    pub fn init(allocator: Allocator, name: []const u8) !*UntitledTextEditorInput {
        const self = try allocator.create(UntitledTextEditorInput);
        errdefer allocator.destroy(self);
        const path = try std.fmt.allocPrint(allocator, "untitled:/{s}", .{name});
        errdefer allocator.free(path);
        var base = EditorInput.init(allocator, ID);
        base.impl = self;
        base.resource = path;
        base.name = std.fs.path.basename(path);
        base.capabilities = editor_input.EditorInputCapabilities.None;
        base.matches_fn = matches;
        self.* = .{
            .allocator = allocator,
            .base = base,
            .path = path,
        };
        return self;
    }

    pub fn destroy(self: *UntitledTextEditorInput) void {
        if (self.content) |content| self.allocator.free(content);
        self.base.deinit();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    fn matches(base: *EditorInput, other: *EditorInput) bool {
        const self: *UntitledTextEditorInput = @ptrCast(@alignCast(base.impl.?));
        const other_input: *UntitledTextEditorInput = @ptrCast(@alignCast(other.impl.?));
        return std.mem.eql(u8, self.path, other_input.path);
    }

    pub fn getText(self: *const UntitledTextEditorInput) []const u8 {
        return self.content orelse "";
    }

    pub fn setText(self: *UntitledTextEditorInput, text: []const u8) !void {
        const copy = try self.allocator.dupe(u8, text);
        if (self.content) |content| self.allocator.free(content);
        self.content = copy;
        try self.base.setDirty(true);
    }

    pub fn revert(self: *UntitledTextEditorInput) !void {
        if (self.content) |content| self.allocator.free(content);
        self.content = null;
        try self.base.setDirty(false);
    }
};

test "UntitledTextEditorInput tracks content and dirty state" {
    const allocator = std.testing.allocator;
    var input = try UntitledTextEditorInput.init(allocator, "Untitled-1");
    defer input.destroy();
    try std.testing.expectEqualStrings("untitled:/Untitled-1", input.base.resource.?);
    try std.testing.expectEqualStrings("Untitled-1", input.base.getName());
    try std.testing.expectEqualStrings("", input.getText());
    try std.testing.expect(!input.base.isDirty());

    try input.setText("hello");
    try std.testing.expectEqualStrings("hello", input.getText());
    try std.testing.expect(input.base.isDirty());
    try input.revert();
    try std.testing.expectEqualStrings("", input.getText());
    try std.testing.expect(!input.base.isDirty());

    var same = try UntitledTextEditorInput.init(allocator, "Untitled-1");
    defer same.destroy();
    const candidate = editor_input.Candidate{ .input = &same.base };
    try std.testing.expect(input.base.matches(candidate));
}

pub const UntitledTextEditorSerializer = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) UntitledTextEditorSerializer {
        return .{ .allocator = allocator };
    }

    pub fn interface(self: *UntitledTextEditorSerializer) factory_mod.IEditorSerializer {
        return .{
            .context = self,
            .canSerialize = canSerialize,
            .serialize = serialize,
            .deserialize = deserialize,
        };
    }

    fn canSerialize(_: *anyopaque, input: *EditorInput) bool {
        return std.mem.eql(u8, input.type_id, ID) and input.impl != null;
    }

    fn serialize(context: *anyopaque, input: *EditorInput, allocator: Allocator) anyerror!?[]const u8 {
        const self: *UntitledTextEditorSerializer = @ptrCast(@alignCast(context));
        _ = self;
        const untitled: *UntitledTextEditorInput = @ptrCast(@alignCast(input.impl orelse return null));
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        var root = std.json.ObjectMap{};
        const arena = scratch.allocator();
        try root.put(arena, "name", .{ .string = untitled.base.getName() });
        try root.put(arena, "content", .{ .string = untitled.getText() });
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try std.json.Stringify.value(std.json.Value{ .object = root }, .{}, &out.writer);
        return try out.toOwnedSlice();
    }

    fn deserialize(context: *anyopaque, data: []const u8) anyerror!?*EditorInput {
        const self: *UntitledTextEditorSerializer = @ptrCast(@alignCast(context));
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return null;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |object| object,
            else => return null,
        };
        const name = switch (object.get("name") orelse return null) {
            .string => |value| value,
            else => return null,
        };
        const content = switch (object.get("content") orelse return null) {
            .string => |value| value,
            else => return null,
        };
        const input = try UntitledTextEditorInput.init(self.allocator, name);
        errdefer input.destroy();
        if (content.len > 0) try input.setText(content);
        return &input.base;
    }
};

test "UntitledTextEditorSerializer round-trips content" {
    const allocator = std.testing.allocator;
    var input = try UntitledTextEditorInput.init(allocator, "Untitled-2");
    defer input.destroy();
    try input.setText("body");
    var serializer = UntitledTextEditorSerializer.init(allocator);
    const interface = serializer.interface();
    const data = (try interface.serialize(interface.context, &input.base, allocator)).?;
    defer allocator.free(data);
    const restored = (try interface.deserialize(interface.context, data)).?;
    const restored_input: *UntitledTextEditorInput = @ptrCast(@alignCast(restored.impl.?));
    defer restored_input.destroy();
    try std.testing.expectEqualStrings("Untitled-2", restored_input.base.getName());
    try std.testing.expectEqualStrings("body", restored_input.getText());
}
