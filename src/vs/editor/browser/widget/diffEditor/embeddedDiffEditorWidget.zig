// Port of `src/vs/editor/browser/widget/diffEditor/embeddedDiffEditorWidget.ts`.
// The terminal host supplies retained editor views and a containing node; the
// embedded editor follows the parent's settings, with its own diff overrides.
const std = @import("std");
const ui = @import("ui");
const view_mod = @import("../codeEditor/terminalEditorView.zig");
const EditorDocument = @import("../codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
const diff = @import("diffEditorWidget.zig");
const ConfigurationChangedEvent = @import("../../../common/config/editorOptions.zig").ConfigurationChangedEvent;
const Worker = @import("../../services/editorWorkerService.zig").EditorWorkerService;
const Queue = @import("../../../../base/common/windowDispatch.zig").Queue;

pub const EmbeddedDiffEditorWidget = struct {
    allocator: std.mem.Allocator,
    parent: *view_mod.IEditorView,
    widget: *Widget,
    const Widget = diff.DiffEditorWidget(view_mod.IEditorView);

    pub fn create(allocator: std.mem.Allocator, parent: *view_mod.IEditorView, factory: view_mod.EditorViewFactory, original: *EditorDocument, label: []const u8, options: diff.Options, computed: ?diff.IDocumentDiff, worker: *Worker, queue: *Queue) !*EmbeddedDiffEditorWidget {
        const self = try allocator.create(EmbeddedDiffEditorWidget);
        errdefer allocator.destroy(self);
        var opts = options;
        opts.is_in_embedded_editor = true;
        const editor = parent.editor;
        const widget = try Widget.createWithModelSources(factory, allocator, editor.io, editor.path, editor.path, "", "", label, "Working Tree", editor.screen_width, 1, opts, .{ .original = original, .modified = editor.document }, computed);
        errdefer widget.destroy();
        self.* = .{ .allocator = allocator, .parent = parent, .widget = widget };
        for ([_]*@import("../codeEditor/codeEditorWidgetTerminal.zig").Editor{ widget.original_editor, widget.modified_editor }) |child| {
            child.attachWindow(queue);
            child.attachLanguageServices(editor.language_features, editor.marker_service, editor.marker_decorations);
        }
        widget.view_model.attachWorker(worker, null, queue);
        self.applyParentOptions();
        try parent.addConfigurationListener(self.configurationListener());
        return self;
    }

    pub fn destroy(self: *EmbeddedDiffEditorWidget) void {
        self.parent.removeConfigurationListener(self.configurationListener());
        self.unmount();
        self.widget.destroy();
        self.allocator.destroy(self);
    }

    pub fn getParentEditor(self: *EmbeddedDiffEditorWidget) *@import("../codeEditor/codeEditorWidgetTerminal.zig").Editor {
        return self.parent.editor;
    }

    fn configurationListener(self: *EmbeddedDiffEditorWidget) view_mod.ConfigurationListener {
        return .{ .context = self, .notify = onParentConfigurationChanged };
    }

    fn onParentConfigurationChanged(context: *anyopaque, _: ConfigurationChangedEvent) void {
        const self: *EmbeddedDiffEditorWidget = @ptrCast(@alignCast(context));
        self.applyParentOptions();
    }

    fn applyParentOptions(self: *EmbeddedDiffEditorWidget) void {
        self.widget.original_view.inheritEmbeddedOptions(self.parent.terminal_view_host);
        self.widget.modified_view.inheritEmbeddedOptions(self.parent.terminal_view_host);
        self.widget.layout(self.widget.width, self.widget.height);
    }

    pub fn mount(self: *EmbeddedDiffEditorWidget, node: *ui.Node, x: usize, y: usize, width: usize, height: usize) !void {
        const surface = self.parent.surfaceContext().surface;
        if (!self.widget.modified_view.isMounted()) self.widget.setThemeColors(self.parent.themeColors());
        if (self.widget.width != width or self.widget.height != height) self.widget.layout(width, height);
        try self.widget.mount(surface, node, x, y);
        if (self.widget.original_view.isMounted()) try self.widget.original_view.paint();
        try self.widget.modified_view.paint();
    }

    pub fn unmount(self: *EmbeddedDiffEditorWidget) void {
        self.widget.original_view.unmountSurface();
        self.widget.modified_view.unmountSurface();
    }
};
