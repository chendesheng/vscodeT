// Port of the terminal workbench diff pane in
// `src/vs/workbench/browser/parts/editor/textDiffEditor.ts`.
//
// Terminal adaptations:
// - `DiffEditorModel` owns the paths and labels of the snapshots. The diff
//   widget builds aligned display snapshots from the supplied text.
// - `SnapshotEditorInput` is a terminal workbench input with no upstream
//   counterpart. It gives `HEAD`/index/working variants distinct resource keys
//   so they do not collide in the editor group, and it can never save or
//   revert. Its read-only editor is the diff widget's snapshot editor, owned by
//   the widget (not duplicated in the input).
// - The diff input has no serializer, so session save skips diff tabs.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const ui = @import("ui");
const widget_mod = @import("../../../../editor/browser/widget/diffEditor/diffEditorWidget.zig");
const diff_editor_input = @import("../../../common/editor/diffEditorInput.zig");
const editor_input = @import("../../../common/editor/editorInput.zig");
const editor_mod = @import("../../../common/editor.zig");
const text_files = @import("../../../services/textfile/common/textFileService.zig");
const Editor = @import("../../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;

pub const Options = widget_mod.Options;

// Project the diffEditor configuration merged by upstream TextDiffEditor.
pub fn computeConfiguration(configuration_service: ?@import("../../../../platform/configuration/common/configuration.zig").IConfigurationService) Options {
    var options = Options{};
    if (configuration_service) |configuration| {
        options.ignore_trim_whitespace = configuration.getBool("diffEditor.ignoreTrimWhitespace", true);
        options.render_side_by_side = configuration.getBool("diffEditor.renderSideBySide", true);
        options.use_inline_view_when_space_is_limited = configuration.getBool("diffEditor.useInlineViewWhenSpaceIsLimited", true);
        if (configuration.getValue("diffEditor.renderSideBySideInlineBreakpoint")) |value| {
            switch (value.*) {
                // The TUI breakpoint is measured in cells, using the same
                // 900px -> 50 cells scale as the default terminal projection.
                .integer => |number| if (number >= 0) {
                    options.minimum_side_by_side_width = @intCast(@divTrunc(number, 18));
                },
                else => {},
            }
        }
        options.render_indicators = configuration.getBool("diffEditor.renderIndicators", true);
        options.render_overview_ruler = configuration.getBool("diffEditor.renderOverviewRuler", true);
        options.enable_split_view_resizing = configuration.getBool("diffEditor.enableSplitViewResizing", true);
        options.hide_unchanged_regions = configuration.getBool("diffEditor.hideUnchangedRegions.enabled", false);
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

pub const SnapshotEditorInput = struct {
    allocator: Allocator,
    base: editor_input.EditorInput,
    key: []u8,
    name: []u8,

    pub const TYPE_ID = "workbench.editors.textDiffSnapshot";

    pub fn init(allocator: Allocator, path: []const u8, label: []const u8, key: []const u8) !*SnapshotEditorInput {
        const self = try allocator.create(SnapshotEditorInput);
        errdefer allocator.destroy(self);
        const key_copy = try allocator.dupe(u8, key);
        errdefer allocator.free(key_copy);
        const name_copy = try allocator.dupe(u8, std.fs.path.basename(path));
        errdefer allocator.free(name_copy);

        self.* = .{
            .allocator = allocator,
            .base = editor_input.EditorInput.init(allocator, TYPE_ID),
            .key = key_copy,
            .name = name_copy,
        };
        self.base.impl = self;
        self.base.resource = self.key;
        self.base.name = self.name;
        self.base.description = label;
        self.base.capabilities = editor_mod.EditorInputCapabilities.Readonly;
        self.base.is_dirty_fn = alwaysClean;
        self.base.save_fn = saveNoop;
        self.base.revert_fn = revertNoop;
        self.base.matches_fn = matches;
        return self;
    }

    pub fn destroy(self: *SnapshotEditorInput) void {
        self.base.dispose();
        self.base.deinit();
        self.allocator.free(self.key);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    pub fn interface(self: *SnapshotEditorInput) *editor_input.EditorInput {
        return &self.base;
    }

    fn alwaysClean(_: *const editor_input.EditorInput) bool {
        return false;
    }

    fn saveNoop(base: *editor_input.EditorInput, _: editor_input.GroupIdentifier) anyerror!editor_input.SaveResult {
        return base;
    }

    fn revertNoop(_: *editor_input.EditorInput, _: editor_input.GroupIdentifier) anyerror!void {}

    fn matches(base: *editor_input.EditorInput, other: *editor_input.EditorInput) bool {
        if (base == other) return true;
        if (!std.mem.eql(u8, base.type_id, other.type_id)) return false;
        const left = base.resource orelse return false;
        const right = other.resource orelse return false;
        return std.mem.eql(u8, left, right);
    }
};

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
        original_input: *SnapshotEditorInput,
        modified_input: *SnapshotEditorInput,
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

            const widget = try DiffEditorWidget.create(
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
                options,
            );
            errdefer widget.destroy();

            const original_key = try std.fmt.allocPrint(
                allocator,
                "{s}::{s}::original",
                .{ model.original_path, model.original_label },
            );
            defer allocator.free(original_key);
            const modified_key = try std.fmt.allocPrint(
                allocator,
                "{s}::{s}::modified",
                .{ model.modified_path, model.modified_label },
            );
            defer allocator.free(modified_key);

            const original_input = try SnapshotEditorInput.init(allocator, original_path, original_label, original_key);
            errdefer original_input.destroy();
            const modified_input = try SnapshotEditorInput.init(allocator, modified_path, modified_label, modified_key);
            errdefer modified_input.destroy();

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
                &original_input.base,
                &modified_input.base,
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

        /// Replaces the snapshot texts in place, recreating the diff widget with
        /// the new content while keeping the input identity/tab.
        pub fn replace(self: *Self, original_text: []const u8, modified_text: []const u8, width: usize, height: usize, options: Options) !void {
            const widget = try DiffEditorWidget.create(
                self.factory,
                self.allocator,
                self.io,
                self.model.original_path,
                self.model.modified_path,
                original_text,
                modified_text,
                self.model.original_label,
                self.model.modified_label,
                width,
                height,
                options,
            );
            self.widget.destroy();
            self.widget = widget;
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
            self.widget.swapSides();
        }

        pub fn input(self: *Self) *editor_input.EditorInput {
            return &self.diff_input.base;
        }

        /// Whether this diff view shows the same path/ref pair. Used by the
        /// workbench to refresh an existing diff tab instead of opening a new one.
        pub fn matches(self: *const Self, path: []const u8, left_label: []const u8, right_label: []const u8) bool {
            return std.mem.eql(u8, self.model.original_label, left_label) and
                std.mem.eql(u8, self.model.modified_label, right_label) and
                text_files.samePath(self.allocator, self.io, self.model.original_path, path) and
                text_files.samePath(self.allocator, self.io, self.model.modified_path, path);
        }
    };
}
