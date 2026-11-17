// Port of the composite identity/label subset of
// `src/vs/workbench/common/editor/sideBySideEditorInput.ts`. Rendering,
// save/revert forwarding and serialization are handled by the terminal editor
// services and are not part of this identity model.
const std = @import("std");
const Allocator = std.mem.Allocator;
const editor_input = @import("editorInput.zig");
const editor = @import("../editor.zig");
const EditorInput = editor_input.EditorInput;

pub const ID = "workbench.editorinputs.sidebysideEditorInput";

pub const SideBySideEditorInput = struct {
    allocator: Allocator,
    base: EditorInput,
    primary: *EditorInput,
    secondary: *EditorInput,
    has_identical_sides: bool,
    owned_name: ?[]u8 = null,
    owned_description: ?[]u8 = null,

    pub fn init(
        allocator: Allocator,
        preferred_name: ?[]const u8,
        preferred_description: ?[]const u8,
        secondary: *EditorInput,
        primary: *EditorInput,
    ) !*SideBySideEditorInput {
        const self = try allocator.create(SideBySideEditorInput);
        errdefer allocator.destroy(self);
        var base = EditorInput.init(allocator, ID);
        base.impl = self;
        base.matches_fn = matches;
        base.capabilities = primary.capabilities | editor.EditorInputCapabilities.MultipleEditors;
        self.* = .{
            .allocator = allocator,
            .base = base,
            .primary = primary,
            .secondary = secondary,
            .has_identical_sides = primary.matches(.{ .input = secondary }),
        };
        self.base.resource = if (self.has_identical_sides) primary.resource else null;
        if (preferred_name) |name| {
            self.owned_name = try allocator.dupe(u8, name);
            self.base.name = self.owned_name.?;
        } else if (self.has_identical_sides) {
            self.base.name = primary.getName();
        } else {
            self.owned_name = try std.fmt.allocPrint(allocator, "{s} - {s}", .{ secondary.getName(), primary.getName() });
            self.base.name = self.owned_name.?;
        }
        if (preferred_description) |description| {
            self.owned_description = try allocator.dupe(u8, description);
            self.base.description = self.owned_description.?;
        } else if (self.has_identical_sides) {
            self.base.description = primary.getDescription(.LONG);
        }
        return self;
    }

    pub fn destroy(self: *SideBySideEditorInput) void {
        if (self.owned_name) |name| self.allocator.free(name);
        if (self.owned_description) |description| self.allocator.free(description);
        self.base.deinit();
        self.allocator.destroy(self);
    }

    pub fn getPreferredName(self: *const SideBySideEditorInput) ?[]const u8 {
        if (self.owned_name) |name| return name;
        return null;
    }

    pub fn getPreferredDescription(self: *const SideBySideEditorInput) ?[]const u8 {
        return self.owned_description;
    }

    fn matches(base: *EditorInput, other: *EditorInput) bool {
        const self: *SideBySideEditorInput = @ptrCast(@alignCast(base.impl.?));
        const other_side_by_side = is(other) orelse return false;
        return self.primary.matches(.{ .input = other_side_by_side.primary }) and
            self.secondary.matches(.{ .input = other_side_by_side.secondary });
    }
};

pub fn is(input: *EditorInput) ?*SideBySideEditorInput {
    if (!std.mem.eql(u8, input.type_id, ID) or input.impl == null) return null;
    return @ptrCast(@alignCast(input.impl.?));
}
