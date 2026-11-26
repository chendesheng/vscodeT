// Port of the read-only TextResourceEditorInput in
// src/vs/workbench/common/editor/textResourceEditorInput.ts.
// Resolved inputs retain the ITextModelService reference; mounted code
// editors retain the same document independently.
const std = @import("std");
const EditorDocument = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
const EditorInput = @import("editorInput.zig").EditorInput;
const ModelReference = @import("../../../editor/common/services/resolverService.zig").ModelReference;
const GroupIdentifier = @import("editorInput.zig").GroupIdentifier;
const SaveResult = @import("editorInput.zig").SaveResult;
const resource_key = @import("../../../base/common/stdUri.zig").resourceKey;

pub const TextResourceEditorInput = struct {
    allocator: std.mem.Allocator,
    base: EditorInput,
    document: *EditorDocument,
    model_reference: ?ModelReference = null,
    key: []u8,
    description: []u8,
    preferred_name: ?[]u8 = null,
    refs: usize = 1,

    pub const ID = "workbench.editors.resourceEditorInput";

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8, description: []const u8, text: []const u8, resource: std.Uri) !*TextResourceEditorInput {
        const document = try EditorDocument.createFromText(allocator, io, path, text, resource);
        errdefer document.release();
        return initResolved(allocator, document, description, null);
    }

    /// Adopts the acquired reference on every outcome.
    pub fn initFromReference(allocator: std.mem.Allocator, reference: ModelReference, description: []const u8) !*TextResourceEditorInput {
        var owned = reference;
        errdefer owned.dispose();
        const document: *EditorDocument = @ptrCast(@alignCast(reference.object.context));
        return initResolved(allocator, document, description, owned);
    }

    fn initResolved(allocator: std.mem.Allocator, document: *EditorDocument, description: []const u8, reference: ?ModelReference) !*TextResourceEditorInput {
        const key = try resource_key(allocator, document.model.uri());
        errdefer allocator.free(key);
        const label = try allocator.dupe(u8, description);
        errdefer allocator.free(label);
        const self = try allocator.create(TextResourceEditorInput);
        self.* = .{
            .allocator = allocator,
            .base = EditorInput.init(allocator, ID),
            .document = document,
            .model_reference = reference,
            .key = key,
            .description = label,
        };
        self.base.impl = self;
        self.base.editor_id = "default";
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
        if (self.model_reference) |*reference| reference.dispose() else self.document.release();
        self.allocator.free(self.key);
        self.allocator.free(self.description);
        if (self.preferred_name) |name| self.allocator.free(name);
        self.allocator.destroy(self);
    }

    pub fn interface(self: *TextResourceEditorInput) *EditorInput {
        return &self.base;
    }

    pub fn setPreferredName(self: *TextResourceEditorInput, name: []const u8) !void {
        if (std.mem.eql(u8, self.base.getName(), name)) return;
        const owned = try self.allocator.dupe(u8, name);
        const previous = self.preferred_name;
        self.preferred_name = owned;
        self.base.name = owned;
        defer if (previous) |old| self.allocator.free(old);
        try self.base.fireLabel();
    }

    /// A virtual file provider may change the contents at the same URI
    /// (for example Git's index or HEAD). Keep the shared model reference
    /// and emit the normal content change instead of replacing the input.
    pub fn updateContents(self: *TextResourceEditorInput, text: []const u8) !void {
        _ = try self.document.replaceGeneratedContents(text);
    }

    pub fn resolve(self: *TextResourceEditorInput) *EditorDocument {
        return self.document;
    }

    fn saveNoop(base: *EditorInput, _: GroupIdentifier) anyerror!SaveResult {
        return base;
    }
};
