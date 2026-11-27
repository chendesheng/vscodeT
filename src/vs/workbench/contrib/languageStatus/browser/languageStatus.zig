// Port of the single-window LanguageStatus contribution in
// `src/vs/workbench/contrib/languageStatus/browser/languageStatus.ts`.
// Terminal substitution: the combined status entry uses a plain-text tooltip
// rather than browser DOM and codicon animations. Dedicated pinning, clickable
// links/commands inside the tooltip and persistence are not yet ported.
const std = @import("std");
const service_mod = @import("../../../services/languageStatus/common/languageStatusService.zig");
const StatusbarService = @import("../../../browser/parts/statusbar/statusbarPart.zig").StatusbarService;
const EntryAccessor = @import("../../../browser/parts/statusbar/statusbarPart.zig").EntryAccessor;
const StatusbarEntry = @import("../../../services/statusbar/browser/statusbar.zig").StatusbarEntry;
const statusbar = @import("../../../services/statusbar/browser/statusbar.zig");
const EditorService = @import("../../../services/editor/browser/editorService.zig").EditorService;
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const TextModel = @import("../../../../editor/common/model/textModel.zig").TextModel;
const ModelLanguageChangedEvent = @import("../../../../editor/common/textModelEvents.zig").ModelLanguageChangedEvent;
const ModelChange = @import("../../../../editor/common/editorCommon.zig").IModelChangedEvent;
const Allocator = std.mem.Allocator;

pub const LanguageStatusContribution = struct {
    pub const ID = "status.languageStatus";
    allocator: Allocator,
    service: service_mod.ILanguageStatusService,
    statusbar: *StatusbarService,
    editors: EditorService,
    service_listener: ?usize = null,
    active_listener: ?usize = null,
    visible_listener: ?usize = null,
    editor: ?*Editor = null,
    editor_dispose_listener: ?usize = null,
    editor_model_listener: ?usize = null,
    model: ?*TextModel = null,
    language_listener: ?usize = null,
    accessor: ?EntryAccessor = null,
    tooltip: ?[]u8 = null,

    pub fn create(allocator: Allocator, service: service_mod.ILanguageStatusService, status: *StatusbarService, editors: EditorService) !*LanguageStatusContribution {
        const self = try allocator.create(LanguageStatusContribution);
        self.* = .{ .allocator = allocator, .service = service, .statusbar = status, .editors = editors };
        errdefer self.deinit();
        self.service_listener = try service.on_did_change.listen(self, onStatusChanged);
        self.active_listener = try editors.onDidActiveEditorChange().listen(self, onActiveChanged);
        self.visible_listener = try editors.onDidVisibleEditorsChange().listen(self, onVisibleChanged);
        try self.updateActiveEditor();
        return self;
    }

    pub fn deinit(self: *LanguageStatusContribution) void {
        if (self.service_listener) |listener| self.service.on_did_change.unlisten(listener);
        if (self.active_listener) |listener| self.editors.onDidActiveEditorChange().unlisten(listener);
        if (self.visible_listener) |listener| self.editors.onDidVisibleEditorsChange().unlisten(listener);
        self.detachEditor();
        self.clearEntry();
        self.allocator.destroy(self);
    }

    fn onStatusChanged(_: usize, self: *LanguageStatusContribution) !void {
        try self.update();
    }
    fn onActiveChanged(_: ?*EditorInput, self: *LanguageStatusContribution) !void {
        try self.updateActiveEditor();
    }
    fn onVisibleChanged(_: void, self: *LanguageStatusContribution) !void {
        try self.updateActiveEditor();
    }
    fn onLanguageChanged(_: ModelLanguageChangedEvent, self: *LanguageStatusContribution) !void {
        try self.update();
    }
    fn onModelChanged(_: ModelChange, self: *LanguageStatusContribution) !void {
        try self.bindModel(if (self.editor) |editor| (if (editor.hasModel()) editor.model else null) else null);
        try self.update();
    }
    fn onEditorDisposed(_: void, self: *LanguageStatusContribution) !void {
        self.detachEditor();
        self.clearEntry();
    }

    fn detachEditor(self: *LanguageStatusContribution) void {
        self.bindModel(null) catch {};
        if (self.editor) |editor| {
            if (self.editor_dispose_listener) |listener| editor.on_will_dispose.unlisten(listener);
            if (self.editor_model_listener) |listener| editor.on_did_change_model.unlisten(listener);
        }
        self.editor = null;
        self.editor_dispose_listener = null;
        self.editor_model_listener = null;
    }

    fn bindModel(self: *LanguageStatusContribution, model: ?*TextModel) !void {
        if (self.model == model) return;
        if (self.model) |old| if (self.language_listener) |listener| old.removeDidChangeLanguageListener(listener);
        self.model = model;
        self.language_listener = null;
        if (model) |value| self.language_listener = try value.listenDidChangeLanguage(self, onLanguageChanged);
    }

    fn updateActiveEditor(self: *LanguageStatusContribution) !void {
        const editor = if (self.editors.activeEditorPane()) |pane| pane.codeEditorControl() else null;
        if (editor != self.editor) {
            self.detachEditor();
            if (editor) |active| {
                self.editor = active;
                self.editor_dispose_listener = try active.on_will_dispose.listen(self, onEditorDisposed);
                self.editor_model_listener = try active.on_did_change_model.listen(self, onModelChanged);
                try self.bindModel(if (active.hasModel()) active.model else null);
            }
        }
        try self.update();
    }

    fn clearEntry(self: *LanguageStatusContribution) void {
        if (self.accessor) |entry| entry.dispose();
        self.accessor = null;
        if (self.tooltip) |tooltip| self.allocator.free(tooltip);
        self.tooltip = null;
    }

    fn update(self: *LanguageStatusContribution) !void {
        const model = self.model orelse {
            self.clearEntry();
            return;
        };
        const statuses = try self.service.getLanguageStatus(self.allocator, model);
        defer self.allocator.free(statuses);
        if (statuses.len == 0) {
            self.clearEntry();
            return;
        }
        var tooltip_writer = std.Io.Writer.Allocating.init(self.allocator);
        defer tooltip_writer.deinit();
        var busy = false;
        for (statuses, 0..) |status, index| {
            if (index > 0) try tooltip_writer.writer.writeByte('\n');
            const detail = try status.detail.toString(self.allocator);
            defer self.allocator.free(detail);
            try tooltip_writer.writer.print("{s}: {s}", .{ status.name, status.label });
            if (detail.len > 0) try tooltip_writer.writer.print(" — {s}", .{detail});
            if (status.source.len > 0) try tooltip_writer.writer.print(" ({s})", .{status.source});
            busy = busy or status.busy;
        }
        const tooltip = try tooltip_writer.toOwnedSlice();
        errdefer self.allocator.free(tooltip);
        const props: StatusbarEntry = .{
            .name = "Editor Language Status",
            .text = switch (statuses[0].severity) {
                .Error => "[!]",
                .Warning => "[•]",
                else => "[]",
            },
            .aria_label = tooltip,
            .tooltip = tooltip,
            .command = .{ .id = statusbar.show_tooltip_command_id },
            .show_progress = if (busy) .loading else .off,
        };
        if (self.accessor) |entry| entry.update(props) else self.accessor = try self.statusbar.addEntry(props, ID, .right, .{ .location = .{ .location = .{ .id = "status.editor.mode", .priority = 100.1 }, .alignment = .left, .compact = true } });
        if (self.tooltip) |old| self.allocator.free(old);
        self.tooltip = tooltip;
    }
};
