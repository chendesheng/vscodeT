// Terminal subset of
// `src/vs/workbench/services/untitled/common/untitledTextEditorInput.ts`.
// Untitled inputs keep their content in memory; save-as to a file is not
// ported yet.
const std = @import("std");
const Allocator = std.mem.Allocator;
const editor_input = @import("../../../common/editor/editorInput.zig");
const EditorInput = editor_input.EditorInput;

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
