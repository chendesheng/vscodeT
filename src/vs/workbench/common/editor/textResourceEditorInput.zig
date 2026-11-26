// Port of the read-only TextResourceEditorInput in
// src/vs/workbench/common/editor/textResourceEditorInput.ts.
// The resolved native EditorDocument reference replaces ITextModelService's
// reference to a TextResourceEditorModel; mounted editors retain it separately.
const std = @import("std");
const EditorDocument = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
const EditorInput = @import("editorInput.zig").EditorInput;
const GroupIdentifier = @import("editorInput.zig").GroupIdentifier;
const SaveResult = @import("editorInput.zig").SaveResult;
const resource_key = @import("../../../base/common/stdUri.zig").resourceKey;

pub const TextResourceEditorInput = struct {
    allocator: std.mem.Allocator,
    base: EditorInput,
    document: *EditorDocument,
    key: []u8,
    description: []u8,
    refs: usize = 1,

    pub const ID = "workbench.editors.resourceEditorInput";

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8, description: []const u8, text: []const u8, resource: std.Uri) !*TextResourceEditorInput {
        const document = try EditorDocument.createFromText(allocator, io, path, text, resource);
        errdefer document.release();
        const key = try resource_key(allocator, document.model.uri());
        errdefer allocator.free(key);
        const label = try allocator.dupe(u8, description);
        errdefer allocator.free(label);
        const self = try allocator.create(TextResourceEditorInput);
        self.* = .{
            .allocator = allocator,
            .base = EditorInput.init(allocator, ID),
            .document = document,
            .key = key,
            .description = label,
        };
        self.base.impl = self;
        self.base.resource = key;
        self.base.name = std.fs.path.basename(document.path);
        self.base.description = label;
        self.base.capabilities = @import("../editor.zig").EditorInputCapabilities.Readonly;
        self.base.save_fn = saveNoop;
        return self;
    }

    pub fn retain(self: *TextResourceEditorInput) *TextResourceEditorInput {
        self.refs += 1;
        return self;
    }

    pub fn destroy(self: *TextResourceEditorInput) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        self.base.dispose();
        self.base.deinit();
        self.document.release();
        self.allocator.free(self.key);
        self.allocator.free(self.description);
        self.allocator.destroy(self);
    }

    pub fn interface(self: *TextResourceEditorInput) *EditorInput {
        return &self.base;
    }

    pub fn resolve(self: *TextResourceEditorInput) *EditorDocument {
        return self.document;
    }

    fn saveNoop(base: *EditorInput, _: GroupIdentifier) anyerror!SaveResult {
        return base;
    }
};
