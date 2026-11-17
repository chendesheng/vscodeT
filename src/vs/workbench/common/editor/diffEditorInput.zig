// Port of the identity/label subset of
// `src/vs/workbench/common/editor/diffEditorInput.ts`. Diff models, saving and
// serialization are handled by the terminal editor services later.
const std = @import("std");
const Allocator = std.mem.Allocator;
const editor_input = @import("editorInput.zig");
const editor = @import("../editor.zig");
const EditorInput = editor_input.EditorInput;

pub const ID = "workbench.editors.diffEditorInput";

pub const DiffEditorInput = struct {
    allocator: Allocator,
    base: EditorInput,
    original: *EditorInput,
    modified: *EditorInput,
    force_description: bool,
    owned_name: ?[]u8 = null,

    pub fn init(
        allocator: Allocator,
        preferred_name: ?[]const u8,
        preferred_description: ?[]const u8,
        original: *EditorInput,
        modified: *EditorInput,
    ) !*DiffEditorInput {
        const self = try allocator.create(DiffEditorInput);
        errdefer allocator.destroy(self);
        const original_name = original.getName();
        const modified_name = modified.getName();
        var base = EditorInput.init(allocator, ID);
        base.impl = self;
        base.matches_fn = matches;
        base.capabilities = modified.capabilities | editor.EditorInputCapabilities.MultipleEditors;
        base.description = preferred_description;
        self.* = .{
            .allocator = allocator,
            .base = base,
            .original = original,
            .modified = modified,
            .force_description = std.mem.eql(u8, original_name, modified_name),
        };
        if (self.force_description) self.base.capabilities |= editor.EditorInputCapabilities.ForceDescription;
        if (preferred_name) |name| {
            self.owned_name = try allocator.dupe(u8, name);
            self.base.name = self.owned_name.?;
        } else {
            self.owned_name = try std.fmt.allocPrint(allocator, "{s} ↔ {s}", .{ original_name, modified_name });
            self.base.name = self.owned_name.?;
        }
        if (preferred_description == null and self.force_description) {
            self.base.description = modified.getDescription(.LONG);
        }
        return self;
    }

    pub fn destroy(self: *DiffEditorInput) void {
        if (self.owned_name) |name| self.allocator.free(name);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    fn matches(base: *EditorInput, other: *EditorInput) bool {
        const self: *DiffEditorInput = @ptrCast(@alignCast(base.impl.?));
        const other_diff = is(other) orelse return false;
        return self.modified.matches(.{ .input = other_diff.modified }) and
            self.original.matches(.{ .input = other_diff.original }) and
            self.force_description == other_diff.force_description;
    }
};

pub fn is(input: *EditorInput) ?*DiffEditorInput {
    if (!std.mem.eql(u8, input.type_id, ID) or input.impl == null) return null;
    return @ptrCast(@alignCast(input.impl.?));
}
