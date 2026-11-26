// Port of the terminal workbench diff pane in
// `src/vs/workbench/browser/parts/editor/textDiffEditor.ts`.
//
// Terminal adaptation: resolved virtual text resources own native document
// references. The widget mounts independent editor views over those documents,
// with model-anchored alignment and deleted-code zones.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ui = @import("ui");
const widget_mod = @import("../../../../editor/browser/widget/diffEditor/diffEditorWidget.zig");
const diff_editor_input = @import("../../../common/editor/diffEditorInput.zig");
const editor_input = @import("../../../common/editor/editorInput.zig");
const text_files = @import("../../../services/textfile/common/textFileService.zig");
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;

pub const Options = widget_mod.Options;
pub const IDocumentDiff = widget_mod.IDocumentDiff;

// Snapshot inputs are immutable regardless of the diff widget defaults.
fn snapshotOptions(options: Options) Options {
    var result = options;
    result.read_only = true;
    result.original_editable = false;
    return result;
}

// Project the diffEditor configuration merged by upstream TextDiffEditor.
pub fn computeConfiguration(configuration_service: ?@import("../../../../platform/configuration/common/configuration.zig").IConfigurationService) Options {
    var options = snapshotOptions(.{});
    if (configuration_service) |configuration| {
        options.show_empty_decorations = configuration.getBool("diffEditor.experimental.showEmptyDecorations", true);
        options.use_true_inline_view = configuration.getBool("diffEditor.experimental.useTrueInlineView", false);
        options.ignore_trim_whitespace = configuration.getBool("diffEditor.ignoreTrimWhitespace", true);
        options.render_side_by_side = configuration.getBool("diffEditor.renderSideBySide", true);
        options.use_inline_view_when_space_is_limited = configuration.getBool("diffEditor.useInlineViewWhenSpaceIsLimited", true);
        if (configuration.getValue("diffEditor.renderSideBySideInlineBreakpoint")) |value| {
            switch (value.*) {
                .integer => |number| if (number >= 0) {
                    options.minimum_side_by_side_width = @import("../../../services/layout/browser/layoutService.zig").widthInCells(@intCast(number));
                },
                else => {},
            }
        }
        if (configuration.getValue("diffEditor.wordWrap")) |value| {
            if (value.* == .string) options.diff_word_wrap = std.meta.stringToEnum(@TypeOf(options.diff_word_wrap), value.string) orelse .inherit;
        }
        options.render_indicators = configuration.getBool("diffEditor.renderIndicators", true);
        options.render_gutter_menu = configuration.getBool("diffEditor.renderGutterMenu", true);
        options.render_margin_revert_icon = configuration.getBool("diffEditor.renderMarginRevertIcon", true);
        options.render_overview_ruler = configuration.getBool("diffEditor.renderOverviewRuler", true);
        options.enable_split_view_resizing = configuration.getBool("diffEditor.enableSplitViewResizing", true);
        options.hide_unchanged_regions = configuration.getBool("diffEditor.hideUnchangedRegions.enabled", false);
        options.compact_mode = configuration.getBool("diffEditor.compactMode", false);
        options.hide_original_line_numbers = configuration.getBool("diffEditor.hideOriginalLineNumbers", false);
        if (configuration.getValue("diffEditor.hideUnchangedRegions.revealLineCount")) |value| {
            switch (value.*) {
                .integer => |number| if (number >= 0) {
                    options.hide_unchanged_regions_reveal_line_count = @intCast(number);
                },
                else => {},
            }
        }
        if (configuration.getValue("diffEditor.hideUnchangedRegions.contextLineCount")) |value| {
            switch (value.*) {
                .integer => |number| if (number >= 0) {
                    options.hide_unchanged_regions_context_line_count = @intCast(number);
                },
                else => {},
            }
        }
        if (configuration.getValue("diffEditor.hideUnchangedRegions.minimumLineCount")) |value| {
            switch (value.*) {
                .integer => |number| if (number >= 0) {
                    options.hide_unchanged_regions_minimum_line_count = @intCast(number);
                },
                else => {},
            }
        }
        if (configuration.getValue("diffEditor.maxComputationTime")) |value| {
            switch (value.*) {
                .integer => |number| options.max_computation_time_ms = number,
                else => {},
            }
        }
        if (configuration.getValue("diffEditor.splitViewDefaultRatio")) |value| {
            switch (value.*) {
                .float => |number| options.split_view_default_ratio = number,
                .integer => |number| options.split_view_default_ratio = @floatFromInt(number),
                else => {},
            }
        }
        if (configuration.getValue("diffEditor.experimental.showMoves")) |value| {
            switch (value.*) {
                .bool => |enabled| options.show_moves = enabled,
                else => {},
            }
        }
        if (configuration.getValue("diffEditor.diffAlgorithm")) |value| {
            switch (value.*) {
                .string => |name| options.diff_algorithm = widget_mod.DiffAlgorithmName.fromName(name) orelse .advanced,
                else => {},
            }
        }
    }
    return options;
}

pub const TextResourceEditorInput = @import("../../../common/editor/textResourceEditorInput.zig").TextResourceEditorInput;
const FileEditorInput = @import("../../../contrib/files/browser/editors/fileEditorInputTerminal.zig").FileEditorInput;
const EditorDocument = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;

pub const SideInput = union(enum) {
    resource: *TextResourceEditorInput,
    file: *FileEditorInput,

    pub fn interface(self: SideInput) *editor_input.EditorInput {
        return switch (self) {
            .resource => |input| input.interface(),
            .file => |input| input.interface(),
        };
    }

    pub fn resolve(self: SideInput) *EditorDocument {
        return switch (self) {
            .resource => |input| input.resolve(),
            .file => |input| input.editor.document,
        };
    }

    pub fn destroy(self: SideInput) void {
        switch (self) {
            .resource => |input| input.destroy(),
            .file => |input| input.deinit(),
        }
    }

    pub fn fileInput(self: SideInput) ?*FileEditorInput {
        return switch (self) {
            .resource => null,
            .file => |input| input,
        };
    }
};

pub const SideSource = struct {
    resource: ?std.Uri = null,
    file: ?*FileEditorInput = null,

    fn resolve(self: SideSource, allocator: Allocator, io: Io, path: []const u8, label: []const u8, text: []const u8) !SideInput {
        if (self.file) |input| return .{ .file = input.retain() };
        const absolute = try text_files.absolutePath(allocator, io, path);
        defer allocator.free(absolute);
        return .{ .resource = try TextResourceEditorInput.init(allocator, io, path, label, text, self.resource orelse snapshotResource(absolute, label)) };
    }
};

pub const ResolvedSources = struct {
    original: SideSource = .{},
    modified: SideSource = .{},
};

fn inputOptions(options: Options, original: SideInput, modified: SideInput) Options {
    var result = options;
    result.original_editable = !original.interface().isReadonly();
    result.read_only = modified.interface().isReadonly();
    return result;
}

/// A generic snapshot comparison without an extension-provided resource
/// uses the label as a virtual URI query. SCM provides its actual ref URI.
fn snapshotResource(absolute_path: []const u8, label: []const u8) std.Uri {
    return .{ .scheme = "vscode-diff", .path = .{ .raw = absolute_path }, .query = .{ .raw = label } };
}

pub const DiffEditorModel = struct {
    original_path: []const u8,
    modified_path: []const u8,
    original_label: []const u8,
    modified_label: []const u8,
};

/// The terminal diff pane: the diff widget plus the snapshot/diff inputs.
/// The concrete cell view is injected by the editor pane composition root.
pub fn DiffView(comptime View: type) type {
    const DiffEditorWidget = widget_mod.DiffEditorWidget(View);
    return struct {
        const Self = @This();
        factory: *const fn (Allocator, *Editor) anyerror!*View,
        allocator: Allocator,
        io: Io,
        model: DiffEditorModel,
        widget: *DiffEditorWidget,
        theme_colors: ?*const @import("../../themeColors.zig").ThemeColors = null,
        on_control_changed: ?struct { context: *anyopaque, run: *const fn (*anyopaque) void } = null,
        original_input: SideInput,
        modified_input: SideInput,
        diff_input: *diff_editor_input.DiffEditorInput,

        pub fn create(
            factory: *const fn (Allocator, *Editor) anyerror!*View,
            allocator: Allocator,
            io: Io,
            model: DiffEditorModel,
            original_text: []const u8,
            modified_text: []const u8,
            width: usize,
            height: usize,
            options: Options,
        ) !*Self {
            return createWithDiff(factory, allocator, io, model, original_text, modified_text, width, height, options, null);
        }

        pub fn createWithDiff(
            factory: *const fn (Allocator, *Editor) anyerror!*View,
            allocator: Allocator,
            io: Io,
            model: DiffEditorModel,
            original_text: []const u8,
            modified_text: []const u8,
            width: usize,
            height: usize,
            options: Options,
            computed: ?IDocumentDiff,
        ) !*Self {
            return createWithSources(factory, allocator, io, model, original_text, modified_text, width, height, options, .{}, computed);
        }

        pub fn createWithSources(
            factory: *const fn (Allocator, *Editor) anyerror!*View,
            allocator: Allocator,
            io: Io,
            model: DiffEditorModel,
            original_text: []const u8,
            modified_text: []const u8,
            width: usize,
            height: usize,
            options: Options,
            sources: ResolvedSources,
            computed: ?IDocumentDiff,
        ) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            // SCM refreshes and history updates can discard the source strings
            // while the diff tab and its input are still open.
            const original_path = try allocator.dupe(u8, model.original_path);
            errdefer allocator.free(original_path);
            const modified_path = try allocator.dupe(u8, model.modified_path);
            errdefer allocator.free(modified_path);
            const original_label = try allocator.dupe(u8, model.original_label);
            errdefer allocator.free(original_label);
            const modified_label = try allocator.dupe(u8, model.modified_label);
            errdefer allocator.free(modified_label);

            const original_input = try sources.original.resolve(allocator, io, original_path, original_label, original_text);
            errdefer original_input.destroy();
            const modified_input = try sources.modified.resolve(allocator, io, modified_path, modified_label, modified_text);
            errdefer modified_input.destroy();
            const valid_computed = if (computed != null and
                snapshotLinesEqual(allocator, original_input.resolve().model, original_text) and
                snapshotLinesEqual(allocator, modified_input.resolve().model, modified_text)) computed else null;
            const widget = try DiffEditorWidget.createWithModelSources(
                factory,
                allocator,
                io,
                model.original_path,
                model.modified_path,
                original_text,
                modified_text,
                model.original_label,
                model.modified_label,
                width,
                height,
                inputOptions(options, original_input, modified_input),
                .{ .original = original_input.resolve(), .modified = modified_input.resolve() },
                valid_computed,
            );
            errdefer widget.destroy();

            const basename = std.fs.path.basename(model.modified_path);
            const title = try std.fmt.allocPrint(
                allocator,
                "{s} ({s} \u{2194} {s})",
                .{ basename, model.original_label, model.modified_label },
            );
            defer allocator.free(title);
            const diff_input = try diff_editor_input.DiffEditorInput.init(
                allocator,
                title,
                null,
                original_input.interface(),
                modified_input.interface(),
            );
            errdefer diff_input.destroy();

            self.* = .{
                .factory = factory,
                .allocator = allocator,
                .io = io,
                .model = .{
                    .original_path = original_path,
                    .modified_path = modified_path,
                    .original_label = original_label,
                    .modified_label = modified_label,
                },
                .widget = widget,
                .original_input = original_input,
                .modified_input = modified_input,
                .diff_input = diff_input,
            };
            return self;
        }

        pub fn destroy(self: *Self) void {
            const allocator = self.allocator;
            self.diff_input.destroy();
            self.original_input.destroy();
            self.modified_input.destroy();
            self.widget.destroy();
            allocator.free(self.model.original_path);
            allocator.free(self.model.modified_path);
            allocator.free(self.model.original_label);
            allocator.free(self.model.modified_label);
            allocator.destroy(self);
        }

        /// Refresh both immutable resources in place. Their inputs, models,
        /// mounted editors, selections and contributions retain identity.
        pub fn replace(self: *Self, original_text: []const u8, modified_text: []const u8, width: usize, height: usize, options: Options) !void {
            try self.replaceWithDiff(original_text, modified_text, width, height, options, null);
        }

        pub fn replaceWithDiff(self: *Self, original_text: []const u8, modified_text: []const u8, width: usize, height: usize, options: Options, computed: ?IDocumentDiff) !void {
            if (self.original_input == .resource and !snapshotLinesEqual(self.allocator, self.widget.originalModel(), original_text)) {
                try self.widget.original_editor.replaceGeneratedContents(original_text, false);
            }
            if (self.modified_input == .resource and !snapshotLinesEqual(self.allocator, self.widget.modifiedModel(), modified_text)) {
                try self.widget.modified_editor.replaceGeneratedContents(modified_text, false);
            }
            const result_matches = snapshotLinesEqual(self.allocator, self.widget.originalModel(), original_text) and snapshotLinesEqual(self.allocator, self.widget.modifiedModel(), modified_text);
            _ = try self.widget.updateOptionsWithDiff(inputOptions(options, self.original_input, self.modified_input), if (result_matches) computed else null);
            if (!result_matches) self.widget.view_model.requestRecompute(0);
            self.widget.layout(width, height);
        }

        pub fn matchesSnapshot(self: *Self, original: []const u8, modified: []const u8, options: Options) bool {
            return std.meta.eql(self.widget.options, inputOptions(options, self.original_input, self.modified_input).normalize()) and
                snapshotLinesEqual(self.allocator, self.widget.originalModel(), original) and
                snapshotLinesEqual(self.allocator, self.widget.modifiedModel(), modified);
        }

        fn snapshotLinesEqual(allocator: Allocator, model: *@import("../../../../editor/common/model/textModel.zig").TextModel, text: []const u8) bool {
            const strings = @import("../../../../base/common/strings.zig");
            const source = if (strings.startsWithUTF8BOM(text)) text[strings.UTF8_BOM_CHARACTER.len..] else text;
            var lines = strings.splitLines(allocator, source) catch return false;
            defer lines.deinit();
            if (lines.items.len != model.getLineCount()) return false;
            for (lines.items, 1..) |line, number| {
                const model_line = model.borrowLineContent(number) catch return false;
                if (!std.mem.eql(u8, line, model_line)) return false;
            }
            return true;
        }

        /// Configuration changes update the existing diff model and views.
        /// Presentation-only changes do not re-run the diff provider.
        pub fn updateOptions(self: *Self, options: Options) !bool {
            return self.widget.updateOptions(inputOptions(options, self.original_input, self.modified_input));
        }

        pub fn setThemeColors(self: *Self, palette: ?*const @import("../../themeColors.zig").ThemeColors) void {
            self.theme_colors = palette;
            self.widget.setThemeColors(palette);
        }

        pub fn paint(self: *Self, frame: *ui.Frame, x: usize, y: usize, w: usize, h: usize) !void {
            try self.widget.paint(frame, x, y, w, h);
        }

        pub fn layout(self: *Self, width: usize, height: usize) void {
            self.widget.layout(width, height);
        }

        pub fn cursorCell(self: *Self) ?struct { row: usize, col: usize } {
            const cell = self.widget.cursorCell() orelse return null;
            return .{ .row = cell.row, .col = cell.col };
        }

        pub fn focus(self: *Self) void {
            self.widget.setFocus(.modified);
        }

        pub fn handleKey(self: *Self, event: *ui.KeyEvent) bool {
            return self.widget.dispatchKey(event);
        }

        pub fn handleMouse(self: *Self, event: *ui.MouseEvent) !bool {
            return self.widget.dispatchMouse(event);
        }

        pub fn nextChange(self: *Self) bool {
            return self.widget.nextChange();
        }

        pub fn previousChange(self: *Self) bool {
            return self.widget.previousChange();
        }

        pub fn swapSides(self: *Self) void {
            const title = std.fmt.allocPrint(self.allocator, "{s} ({s} ↔ {s})", .{
                std.fs.path.basename(self.model.original_path),
                self.model.modified_label,
                self.model.original_label,
            }) catch return;
            self.widget.swapSides();
            std.mem.swap([]const u8, &self.model.original_path, &self.model.modified_path);
            std.mem.swap([]const u8, &self.model.original_label, &self.model.modified_label);
            std.mem.swap(SideInput, &self.original_input, &self.modified_input);
            self.diff_input.setSides(self.original_input.interface(), self.modified_input.interface()) catch {};
            _ = self.updateOptions(self.widget.options) catch false;

            self.diff_input.base.name = title;
            if (self.diff_input.owned_name) |old| self.allocator.free(old);
            self.diff_input.owned_name = title;
            self.diff_input.base.fireLabel() catch {};
        }

        pub fn input(self: *Self) *editor_input.EditorInput {
            return &self.diff_input.base;
        }

        /// Whether this diff view shows the same path/ref pair. Used by the
        /// workbench to refresh an existing diff tab instead of opening a new one.
        pub fn matches(self: *const Self, path: []const u8, left_label: []const u8, right_label: []const u8) bool {
            return std.mem.eql(u8, self.model.original_label, left_label) and
                std.mem.eql(u8, self.model.modified_label, right_label) and
                text_files.samePath(self.allocator, self.io, self.model.modified_path, path);
        }
    };
}
