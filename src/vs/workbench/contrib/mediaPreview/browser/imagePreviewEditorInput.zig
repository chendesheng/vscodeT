// Port of
// `src/vs/workbench/contrib/mediaPreview/browser/imagePreviewEditorInput.ts`.
//
// Upstream extends `AbstractResourceEditorInput` and is a read-only custom
// editor input. The terminal port embeds the shared `EditorInput` value, owns
// the local path string (resources are canonical paths here, not `URI`s) and
// exposes the same identity: the image input type, the image preview editor id
// and path-only matching. Rename/save-as and preferred-resource bookkeeping have
// no terminal file-dialog counterpart and are omitted; the serializer keeps the
// path only.

const std = @import("std");
const Allocator = std.mem.Allocator;

const editor_mod = @import("../../../common/editor.zig");
const editor_input = @import("../../../common/editor/editorInput.zig");
const editor_factory = @import("../../../common/editor/editorFactory.zig");
const media_preview = @import("../common/mediaPreview.zig");

const EditorInput = editor_input.EditorInput;
const GroupIdentifier = editor_input.GroupIdentifier;
const SaveResult = editor_input.SaveResult;
const IEditorSerializer = editor_factory.IEditorSerializer;

pub const ImagePreviewEditorInput = struct {
    allocator: Allocator,
    base: EditorInput,
    path: []u8,

    /// Upstream `ImagePreviewEditorInput.ID`.
    pub const ID = "workbench.input.imagePreview";

    pub fn init(allocator: Allocator, path: []const u8) !*ImagePreviewEditorInput {
        const self = try allocator.create(ImagePreviewEditorInput);
        errdefer allocator.destroy(self);
        const owned = try allocator.dupe(u8, path);
        errdefer allocator.free(owned);

        self.* = .{
            .allocator = allocator,
            .base = EditorInput.init(allocator, ID),
            .path = owned,
        };
        self.base.impl = self;
        self.base.editor_id = media_preview.IMAGE_PREVIEW_EDITOR_ID;
        self.base.resource = owned;
        self.base.name = std.fs.path.basename(owned);
        self.base.capabilities = editor_mod.EditorInputCapabilities.Readonly;
        self.base.is_dirty_fn = isDirty;
        self.base.save_fn = save;
        self.base.matches_fn = matches;
        return self;
    }

    pub fn deinit(self: *ImagePreviewEditorInput) void {
        self.base.dispose();
        self.base.deinit();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    pub fn interface(self: *ImagePreviewEditorInput) *EditorInput {
        return &self.base;
    }

    fn isDirty(_: *const EditorInput) bool {
        return false;
    }

    fn save(base: *EditorInput, _: GroupIdentifier) anyerror!SaveResult {
        _ = base;
        return null;
    }

    fn matches(base: *EditorInput, other: *EditorInput) bool {
        if (base == other) return true;
        if (!std.mem.eql(u8, base.type_id, other.type_id)) return false;
        const left = base.resource orelse return false;
        const right = other.resource orelse return false;
        return std.mem.eql(u8, left, right);
    }
};

/// Serializer for image preview inputs. Only the path needs to survive: the
/// pane and image data are rebuilt when the tab is restored.
pub const ImagePreviewEditorInputSerializer = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) ImagePreviewEditorInputSerializer {
        return .{ .allocator = allocator };
    }

    pub fn interface(self: *ImagePreviewEditorInputSerializer) IEditorSerializer {
        return .{
            .context = self,
            .canSerialize = canSerialize,
            .serialize = serialize,
            .deserialize = deserialize,
            .discard_deserialized = discardDeserialized,
        };
    }

    fn discardDeserialized(_: *anyopaque, input: *EditorInput) void {
        const image: *ImagePreviewEditorInput = @ptrCast(@alignCast(input.impl.?));
        image.deinit();
    }

    fn canSerialize(_: *anyopaque, input: *EditorInput) bool {
        return std.mem.eql(u8, input.type_id, ImagePreviewEditorInput.ID);
    }

    fn serialize(_: *anyopaque, input: *EditorInput, allocator: Allocator) anyerror!?[]const u8 {
        const resource = input.resource orelse return null;
        return try allocator.dupe(u8, resource);
    }

    fn deserialize(context: *anyopaque, data: []const u8) anyerror!?*EditorInput {
        const self: *ImagePreviewEditorInputSerializer = @ptrCast(@alignCast(context));
        const input = try ImagePreviewEditorInput.init(self.allocator, data);
        return &input.base;
    }
};
