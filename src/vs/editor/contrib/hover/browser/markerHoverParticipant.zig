// Port of `src/vs/editor/contrib/hover/browser/markerHoverParticipant.ts`.
//
// Terminal adaptation: the browser participant builds a marker row (severity
// icon, message, source/code and related-information links) as DOM nodes. The
// terminal renders the same rows as cells: the severity glyph from the
// Problems view, the plain-text marker message with its embedded newlines, and
// a dim `source(code)` line and related-information rows. Navigation and
// status-bar actions are bound through the editor services.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const ui = @import("ui");

const Range = @import("../../../common/core/range.zig").Range;
const ModelDecoration = @import("../../../common/model.zig").ModelDecoration;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const MarkerDecorationsService = @import("../../../common/services/markerDecorationsService.zig").MarkerDecorationsService;
const markers = @import("../../../../platform/markers/common/markers.zig");
const MarkerSeverity = markers.MarkerSeverity;

const hoverTypes = @import("./hoverTypes.zig");
const HoverAnchor = hoverTypes.HoverAnchor;
const HoverStartSource = hoverTypes.HoverStartSource;
const IHoverPart = hoverTypes.IHoverPart;
const IRenderedHoverPart = hoverTypes.IRenderedHoverPart;
const IEditorHoverParticipant = hoverTypes.IEditorHoverParticipant;
const IEditorHoverRenderContext = hoverTypes.IEditorHoverRenderContext;

const markdown = @import("../../../common/markdown/markdownTerminalRenderer.zig");
const Position = @import("../../../common/core/position.zig").Position;
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const codeAction = @import("../../codeAction/browser/codeAction.zig");
const action_types = @import("../../codeAction/common/types.zig");
const CodeActionController = @import("../../codeAction/browser/codeActionController.zig").CodeActionController;
const goto_error = @import("../../gotoError/browser/gotoError.zig");
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const Disposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const menu_api = @import("../../../../platform/actions/common/menuService.zig");
const contextkey = @import("../../../../platform/contextkey/common/contextkey.zig");
const IAction = @import("../../../../base/common/actions.zig").IAction;
const markerCodeActionTrigger: action_types.CodeActionTrigger = .{ .type = .Invoke, .filter = .{ .include = action_types.CodeActionKind.QuickFix }, .trigger_action = .QuickFixHover };

pub const CodeActionServices = struct {
    editor: *Editor,
    registry: *@import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(@import("../../../common/languages.zig").CodeActionProvider),
    window: *dispatch.Queue,
};

pub const MenuServices = struct {
    menus: *menu_api.MenuService,
    parent_context: contextkey.IContext,
};

/// Narrow adapter for IOpenerService. Related positions retain UTF-16 columns
/// until the target resource resolves, just as in the diagnostic DTO.
pub const Opener = @import("../../../../platform/opener/common/opener.zig").IOpenerService;

/// Port of `MarkerHover`. The marker fields are copied into the participant's
/// arena so a later marker-service update cannot invalidate a rendered hover.
pub const MarkerHover = struct {
    range: Range,
    severity: u32,
    message: []const u8,
    source: ?[]const u8 = null,
    code: ?[]const u8 = null,
    code_target: ?markers.Resource = null,
    related_information: []const markers.RelatedInformation = &.{},
    /// The marker's full model range, distinct from its one-line hover anchor.
    marker_range: ?Range = null,
};

pub const MarkerHoverParticipant = struct {
    allocator: Allocator,
    model: *TextModel,
    marker_decorations: ?*MarkerDecorationsService,
    opener: ?Opener = null,
    code_actions: ?CodeActionServices = null,
    menus: ?MenuServices = null,
    recent_marker_code_actions_info: ?struct { key: []u8, has_code_actions: bool } = null,
    /// Payloads of the current hover computation.
    parts_arena: std.heap.ArenaAllocator,
    /// Parsed rows of the currently rendered hover.
    rendered_arena: std.heap.ArenaAllocator,
    rendered: []const IRenderedHoverPart = &.{},

    pub fn init(
        allocator: Allocator,
        model: *TextModel,
        marker_decorations: ?*MarkerDecorationsService,
    ) MarkerHoverParticipant {
        return .{
            .allocator = allocator,
            .model = model,
            .marker_decorations = marker_decorations,
            .parts_arena = std.heap.ArenaAllocator.init(allocator),
            .rendered_arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *MarkerHoverParticipant) void {
        if (self.recent_marker_code_actions_info) |recent| self.allocator.free(recent.key);
        self.parts_arena.deinit();
        self.rendered_arena.deinit();
    }

    pub fn interface(self: *MarkerHoverParticipant) IEditorHoverParticipant {
        return .{
            .context = self,
            .hover_ordinal = 1,
            .compute_sync = computeSync,
            .render_hover_parts = renderHoverParts,
            .get_accessible_content = getAccessibleContent,
            .handle_hide = handleHide,
        };
    }

    fn computeSync(
        context: *anyopaque,
        anchor: *const HoverAnchor,
        line_decorations: []const ModelDecoration,
        source: HoverStartSource,
    ) []const IHoverPart {
        _ = source;
        const self: *MarkerHoverParticipant = @ptrCast(@alignCast(context));
        return self.computeSyncParts(anchor, line_decorations) catch &.{};
    }

    fn computeSyncParts(
        self: *MarkerHoverParticipant,
        anchor: *const HoverAnchor,
        line_decorations: []const ModelDecoration,
    ) ![]const IHoverPart {
        const supports_marker_hover = switch (anchor.*) {
            .range => true,
            .foreign_element => |foreign| foreign.supports_marker_hover orelse false,
        };
        if (!supports_marker_hover) return &.{};
        const service = self.marker_decorations orelse return &.{};

        const anchor_range = anchor.getRange();
        const line_number = anchor_range.startLineNumber;
        if (line_number == 0 or line_number > self.model.getLineCount()) return &.{};
        const max_column = self.model.getLineMaxColumn(line_number);

        const allocator = self.parts_arena.allocator();
        var result = ArrayList(IHoverPart).init(allocator);
        for (line_decorations) |decoration| {
            const start_column = if (decoration.range.startLineNumber == line_number) decoration.range.startColumn else 1;
            const end_column = if (decoration.range.endLineNumber == line_number) decoration.range.endColumn else max_column;
            const marker = service.getMarker(self.model, decoration.id) orelse continue;

            const hover = try allocator.create(MarkerHover);
            hover.* = .{
                .range = Range.init(line_number, start_column, line_number, end_column),
                .severity = marker.severity,
                .message = try allocator.dupe(u8, marker.message),
                .source = if (marker.source) |value| try allocator.dupe(u8, value) else null,
                .code = if (marker.code) |value| try allocator.dupe(u8, value) else null,
                .code_target = if (marker.code_target) |target| try target.clone(allocator) else null,
                .related_information = try markers.RelatedInformation.cloneAll(allocator, marker.related_information),
                .marker_range = Range.init(marker.start_line_number, marker.start_column, marker.end_line_number, marker.end_column),
            };
            try result.append(.{
                .owner = self,
                .range = hover.range,
                .data = hover,
                .is_valid_for_hover_anchor = isValidForHoverAnchor,
            });
        }
        return try result.toOwnedSlice();
    }

    fn isValidForHoverAnchor(part: *const IHoverPart, anchor: *const HoverAnchor) bool {
        if (anchor.getType() != .range) return false;
        const anchor_range = anchor.getRange();
        return part.range.startColumn <= anchor_range.startColumn and
            part.range.endColumn >= anchor_range.endColumn;
    }

    fn renderHoverParts(
        context: *anyopaque,
        render_context: *const IEditorHoverRenderContext,
        hover_parts: []const IHoverPart,
    ) ![]const IRenderedHoverPart {
        const self: *MarkerHoverParticipant = @ptrCast(@alignCast(context));
        _ = self.rendered_arena.reset(.retain_capacity);
        const allocator = self.rendered_arena.allocator();

        const sorted = try allocator.dupe(IHoverPart, hover_parts);
        sortBySeverity(sorted);

        var rendered = ArrayList(IRenderedHoverPart).init(allocator);
        for (sorted) |part| {
            const hover: *const MarkerHover = @ptrCast(@alignCast(part.data orelse continue));
            const state = try allocator.create(RenderedMarkerHover);
            state.* = .{
                .hover_part = part,
                .allocator = self.allocator,
                .lines = try buildLines(allocator, hover),
                .accessible = try accessibleText(allocator, hover),
                .hover = hover,
                .opener = self.opener,
            };
            try rendered.append(.{
                .hover_part = part,
                .context = state,
                .measure = measureRenderedMarker,
                .height = heightRenderedMarker,
                .build = buildRenderedMarker,
                .accessible_content = state.accessible,
            });
        }
        self.rendered = try rendered.toOwnedSlice();
        if (sorted.len > 0) {
            const hover: *const MarkerHover = @ptrCast(@alignCast(sorted[0].data orelse return self.rendered));
            if (self.code_actions) |services| try MarkerStatus.start(self, services, render_context.*, hover);
        }
        return self.rendered;
    }

    fn getAccessibleContent(context: *anyopaque, hover_part: *const IHoverPart) []const u8 {
        const self: *MarkerHoverParticipant = @ptrCast(@alignCast(context));
        for (self.rendered) |rendered| {
            // Marker parts can share a range; match the computed payload by
            // identity instead of collapsing them by range.
            if (rendered.hover_part.data == hover_part.data) {
                return rendered.accessible_content;
            }
        }
        return "";
    }

    fn handleHide(context: *anyopaque) void {
        const self: *MarkerHoverParticipant = @ptrCast(@alignCast(context));
        _ = self.parts_arena.reset(.retain_capacity);
        _ = self.rendered_arena.reset(.retain_capacity);
        self.rendered = &.{};
    }
};

/// The rendered result owns the status query and its result set. Re-render,
/// hiding or swapping a model cancels pending work and drops provider state.
const MarkerStatus = struct {
    participant: *MarkerHoverParticipant,
    services: CodeActionServices,
    context: IEditorHoverRenderContext,
    key: []u8,
    timer: dispatch.Task = .{},
    pending: ?Disposable = null,
    actions: ?*codeAction.ManagedCodeActionSet = null,
    ai_index: ?usize = null,
    menu_actions: ?menu_api.MenuActions = null,
    menu_action_count: usize = 0,
    hover_range: Range,
    marker_range: Range,

    fn start(participant: *MarkerHoverParticipant, services: CodeActionServices, context: IEditorHoverRenderContext, hover: *const MarkerHover) !void {
        const register = context.add_disposable orelse return;
        if (context.status_bar.set_message == null) return;
        const has_navigation = (hover.severity == MarkerSeverity.Error or hover.severity == MarkerSeverity.Warning or hover.severity == MarkerSeverity.Info) and services.editor.getContribution(goto_error.MarkerController) != null;
        if (services.editor.isReadOnly() and participant.menus == null and !has_navigation) return;
        const a = participant.allocator;
        const self = try a.create(MarkerStatus);
        errdefer a.destroy(self);
        const r = hover.marker_range orelse hover.range;
        const source = hover.source orelse "";
        const code = hover.code orelse "";
        const key = try std.fmt.allocPrint(a, "{d}:{s}{d}:{s}{d}:{s}:{d}:{d}:{d}:{d}:{d}", .{ source.len, source, code.len, code, hover.message.len, hover.message, hover.severity, r.startLineNumber, r.startColumn, r.endLineNumber, r.endColumn });
        errdefer a.free(key);
        self.* = .{ .participant = participant, .services = services, .context = context, .key = key, .hover_range = hover.range, .marker_range = r };
        self.timer = .{ .queue = services.window, .context = self, .run = showChecking };
        if (participant.menus) |menus| {
            var scoped = @import("../../../browser/editorExtensions.zig").EditorScopedContext{ .editor = services.editor, .parent = menus.parent_context };
            self.menu_actions = try menus.menus.getMenuActions(a, @import("../../../../platform/actions/common/actions.zig").menu_ids.MarkerHoverStatusBar, scoped.interface());
            for (self.menu_actions.?.groups) |group| for (group.actions) |action| {
                if (menu_api.MenuItemAction.from(action) != null and action.enabled()) self.menu_action_count += 1;
            };
        }
        errdefer if (self.menu_actions) |*actions| actions.deinit();
        try register(context.context, Disposable.from(MarkerStatus, self, dispose));
        // Once registered, the rendered owner is responsible for cleanup.
        if (has_navigation) {
            _ = context.status_bar.add_action(context.status_bar.context, .{ .label = "View Problem", .command_id = goto_error.next_marker_id, .run_context = self, .run = showProblem });
        }
        if (services.editor.isReadOnly()) {
            self.renderMenuActions();
            return;
        }
        var recent_no_actions = false;
        if (participant.recent_marker_code_actions_info) |recent| {
            if (std.mem.eql(u8, recent.key, key)) {
                recent_no_actions = !recent.has_code_actions;
            } else {
                a.free(recent.key);
                participant.recent_marker_code_actions_info = null;
            }
        }
        self.setMessage(if (recent_no_actions and self.menu_action_count == 0) "No quick fixes available" else " ");
        if (!recent_no_actions) self.timer.schedule(@import("../../../../base/common/timeCompat.zig").milliTimestamp(services.window.io) + 200);
        self.pending = codeAction.getCodeActions(a, services.registry, participant.model, r, markerCodeActionTrigger, .None, .{ .context = self, .complete = completed }) catch |err| blk: {
            completed(self, err);
            break :blk null;
        };
    }

    fn setMessage(self: *MarkerStatus, message: ?[]const u8) void {
        self.context.status_bar.set_message.?(self.context.status_bar.context, message);
    }

    fn showChecking(context: *anyopaque, _: i64, _: bool) bool {
        const self: *MarkerStatus = @ptrCast(@alignCast(context));
        self.setMessage("Checking for quick fixes...");
        self.context.callOnContentsChanged();
        return true;
    }

    fn completed(context: *anyopaque, reply: anyerror!*codeAction.ManagedCodeActionSet) void {
        const self: *MarkerStatus = @ptrCast(@alignCast(context));
        self.pending = null;
        self.timer.schedule(null);
        const set = reply catch {
            self.setMessage(null);
            self.renderMenuActions();
            self.context.callOnContentsChanged();
            return;
        };
        const has_actions = set.valid_actions.len > 0;
        const participant = self.participant;
        if (participant.allocator.dupe(u8, self.key)) |owned| {
            if (participant.recent_marker_code_actions_info) |old| participant.allocator.free(old.key);
            participant.recent_marker_code_actions_info = .{ .key = owned, .has_code_actions = has_actions };
        } else |_| {}
        if (!has_actions) {
            set.dispose();
            self.setMessage(if (self.menu_action_count == 0) "No quick fixes available" else null);
            self.renderMenuActions();
        } else {
            self.actions = set;
            self.setMessage(null);
            const status_bar = self.context.status_bar;
            _ = status_bar.add_action(status_bar.context, .{ .label = "Quick Fix...", .command_id = codeAction.quickFixCommandId, .run_context = self, .run_at = showQuickFixes });
            for (set.valid_actions, 0..) |item, index| if (item.action.is_ai) {
                self.ai_index = index;
                _ = status_bar.add_action(status_bar.context, .{ .label = item.action.title, .command_id = if (item.action.command) |cmd| cmd.id else "", .run_context = self, .run = applyAI });
                break;
            };
            if (self.ai_index == null) self.renderMenuActions();
        }
        self.context.callOnContentsChanged();
    }

    fn renderMenuActions(self: *MarkerStatus) void {
        const actions = if (self.menu_actions) |*snapshot| snapshot else return;
        const status = self.context.status_bar;
        for (actions.groups) |group| for (group.actions) |action| {
            if (menu_api.MenuItemAction.from(action) == null or !action.enabled()) continue;
            const item = actions.arena.allocator().create(MenuAction) catch continue;
            item.* = .{ .owner = self, .action = action };
            _ = status.add_action(status.context, .{ .label = action.label(), .command_id = action.id(), .run_context = item, .run = MenuAction.run });
        };
    }

    const MenuAction = struct {
        owner: *MarkerStatus,
        action: IAction,
        fn run(context: ?*anyopaque) void {
            const self: *MenuAction = @ptrCast(@alignCast(context orelse return));
            const owner = self.owner;
            const editor = owner.services.editor;
            const range = owner.hover_range;
            const action = self.action;
            var snapshot = owner.menu_actions orelse return;
            owner.menu_actions = null;
            defer snapshot.deinit();
            // Hiding the hover disposes the rendered status owner; retain the
            // selected menu snapshot until its registered command returns.
            owner.context.callHide();
            editor.setSelection(range) catch return;
            if (editor.getContribution(CodeActionController)) |controller| if (controller.view) |view| view.focusEditor();
            action.execute(null) catch {};
        }
    };

    fn showQuickFixes(context: ?*anyopaque, node: *ui.Node) void {
        const self: *MarkerStatus = @ptrCast(@alignCast(context orelse return));
        const controller = self.services.editor.getContribution(CodeActionController) orelse return;
        const actions = self.actions orelse return;
        self.actions = null;
        controller.showCodeActions(markerCodeActionTrigger, actions, controller.anchorForHoverTarget(node));
    }

    fn showProblem(context: ?*anyopaque) void {
        const self: *MarkerStatus = @ptrCast(@alignCast(context orelse return));
        const controller = self.services.editor.getContribution(goto_error.MarkerController) orelse return;
        const range = self.marker_range;
        self.context.callHide();
        controller.showAtMarker(range) catch {};
    }

    fn applyAI(context: ?*anyopaque) void {
        const self: *MarkerStatus = @ptrCast(@alignCast(context orelse return));
        const controller = self.services.editor.getContribution(CodeActionController) orelse return;
        const actions = self.actions orelse return;
        self.actions = null;
        controller.applyHoverCodeAction(actions, self.ai_index orelse return);
    }

    fn dispose(self: *MarkerStatus) void {
        self.timer.schedule(null);
        if (self.pending) |pending| pending.dispose();
        if (self.actions) |set| set.dispose();
        if (self.menu_actions) |*actions| actions.deinit();
        const a = self.participant.allocator;
        a.free(self.key);
        a.destroy(self);
    }
};

/// Stable severity sort: errors first, equal severities in input order, matching
/// upstream's `MarkerSeverity.compare` sort over a copied array.
fn sortBySeverity(items: []IHoverPart) void {
    var index: usize = 1;
    while (index < items.len) : (index += 1) {
        var current = index;
        while (current > 0) : (current -= 1) {
            const left = severityOf(items[current - 1]);
            const right = severityOf(items[current]);
            if (left >= right) break;
            std.mem.swap(IHoverPart, &items[current - 1], &items[current]);
        }
    }
}

fn severityOf(part: IHoverPart) u32 {
    const hover: *const MarkerHover = @ptrCast(@alignCast(part.data orelse return 0));
    return hover.severity;
}

const RenderedMarkerHover = struct {
    hover_part: IHoverPart,
    allocator: Allocator,
    lines: []const markdown.Line,
    accessible: []const u8,
    hover: *const MarkerHover,
    opener: ?Opener,
};

fn buildLines(allocator: Allocator, hover: *const MarkerHover) ![]const markdown.Line {
    var lines = ArrayList(markdown.Line).init(allocator);
    var first_line = true;
    const icon = severityGlyph(hover.severity);
    const color = severityColor(hover.severity);

    var message_lines = std.mem.splitScalar(u8, hover.message, '\n');
    while (message_lines.next()) |message| {
        var spans = ArrayList(markdown.Span).init(allocator);
        if (first_line) {
            try spans.append(.{ .text = icon, .style = .{ .color = color } });
            try spans.append(.{ .text = " " });
            first_line = false;
        }
        if (message.len > 0) {
            try spans.append(.{ .text = try allocator.dupe(u8, message) });
        }
        try lines.append(.{ .spans = try spans.toOwnedSlice() });
    }

    if (hover.code_target != null and hover.code != null) {
        var spans = ArrayList(markdown.Span).init(allocator);
        if (hover.source) |source| try spans.append(.{ .text = source, .style = .{ .dim = true } });
        try spans.append(.{ .text = hover.code.?, .style = .{ .dim = true, .underline = true }, .link = "code" });
        try lines.append(.{ .spans = try spans.toOwnedSlice() });
    } else if (hover.source != null or hover.code != null) {
        const details = if (hover.source != null and hover.code != null)
            try std.fmt.allocPrint(allocator, "{s}({s})", .{ hover.source.?, hover.code.? })
        else if (hover.source) |source|
            try allocator.dupe(u8, source)
        else
            try std.fmt.allocPrint(allocator, "({s})", .{hover.code.?});
        try lines.append(.{ .spans = try allocator.dupe(markdown.Span, &.{
            .{ .text = details, .style = .{ .dim = true } },
        }) });
    }
    for (hover.related_information, 0..) |info, index| {
        const location = try relatedLocationLabel(allocator, info);
        var related_lines = std.mem.splitScalar(u8, info.message, '\n');
        try lines.append(.{ .spans = try allocator.dupe(markdown.Span, &.{
            .{ .text = location, .style = .{ .underline = true }, .link = try std.fmt.allocPrint(allocator, "{d}", .{index}) },
            .{ .text = related_lines.next() orelse "" },
        }) });
        while (related_lines.next()) |message| try lines.append(.{ .spans = try allocator.dupe(markdown.Span, &.{.{ .text = message }}) });
    }
    return try lines.toOwnedSlice();
}

fn relatedLocationLabel(allocator: Allocator, info: markers.RelatedInformation) ![]const u8 {
    // The resource path is URI syntax at this boundary (not a native path).
    const basename = if (std.mem.lastIndexOfScalar(u8, info.resource.path, '/')) |index| info.resource.path[index + 1 ..] else info.resource.path;
    return try std.fmt.allocPrint(allocator, "{s}({d}, {d}): ", .{ basename, info.start_line_number, info.start_column });
}

fn accessibleText(allocator: Allocator, hover: *const MarkerHover) ![]const u8 {
    var text = ArrayList(u8).init(allocator);
    try text.appendSlice(try std.fmt.allocPrint(allocator, "{s}: {s}", .{ severityLabel(hover.severity), hover.message }));
    for (hover.related_information) |info| {
        try text.append('\n');
        try text.appendSlice(try relatedLocationLabel(allocator, info));
        try text.appendSlice(info.message);
    }
    return try text.toOwnedSlice();
}

fn severityLabel(severity: u32) []const u8 {
    if (severity == MarkerSeverity.Hint) return "Hint";
    return MarkerSeverity.toString(severity);
}

fn severityGlyph(severity: u32) []const u8 {
    return switch (severity) {
        MarkerSeverity.Error => "\u{2716}",
        MarkerSeverity.Warning => "\u{26A0}",
        MarkerSeverity.Info => "\u{2139}",
        else => "\u{00B7}",
    };
}

fn severityColor(severity: u32) ui.Color {
    return switch (severity) {
        MarkerSeverity.Error => .{ .r = 241, .g = 76, .b = 76 },
        MarkerSeverity.Warning => .{ .r = 204, .g = 167, .b = 0 },
        MarkerSeverity.Info => .{ .r = 55, .g = 148, .b = 255 },
        else => .{ .r = 138, .g = 138, .b = 138 },
    };
}

fn measureRenderedMarker(context: *const anyopaque, max_width: usize) usize {
    const state: *const RenderedMarkerHover = @ptrCast(@alignCast(context));
    var width: usize = 1;
    for (state.lines) |line| width = @max(width, @min(line.width(), max_width));
    return width;
}

fn heightRenderedMarker(context: *const anyopaque, width: usize) usize {
    const state: *const RenderedMarkerHover = @ptrCast(@alignCast(context));
    var rows: usize = 0;
    for (state.lines) |line| {
        var scratch = std.heap.ArenaAllocator.init(state.allocator);
        defer scratch.deinit();
        const wrapped = markdown.wrapLine(scratch.allocator(), line, width) catch {
            rows += 1;
            continue;
        };
        rows += wrapped.len;
    }
    return @max(rows, 1);
}

fn buildRenderedMarker(
    context: *const anyopaque,
    doc: *ui.Document,
    parent: *ui.Node,
    width: usize,
    top: usize,
) !usize {
    const state: *const RenderedMarkerHover = @ptrCast(@alignCast(context));
    var scratch = std.heap.ArenaAllocator.init(doc.allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();

    var row = top;
    var previous_link: ?[]const u8 = null;
    for (state.lines) |line| {
        const rows = try markdown.wrapLine(allocator, line, width);
        for (rows) |wrapped| {
            const line_row = try appendRow(doc, parent, row);
            row += 1;
            var link_node: ?*ui.Node = null;
            for (wrapped) |span| {
                if (span.text.len == 0) continue;
                const text = try doc.createText(span.text);
                text.setStyle(span.style);
                if (span.link != null and state.opener != null) {
                    const target = span.link.?;
                    const same_link = if (previous_link) |last| std.mem.eql(u8, last, target) else false;
                    if (!same_link or link_node == null) {
                        const link = try doc.createElement(.span);
                        try link.setAttribute("data-marker-hover-link", target);
                        // A wrapped link has one keyboard stop, while every
                        // visible segment remains clickable.
                        link.asElement().focusable = !same_link;
                        link.setStyle(.{ .pointer = .pointer });
                        const node_arena = doc.arena.allocator();
                        const action = try node_arena.create(OpenLink);
                        if (std.mem.eql(u8, target, "code")) {
                            action.* = .{ .opener = state.opener.?, .resource = try state.hover.code_target.?.clone(node_arena) };
                        } else {
                            const index = try std.fmt.parseInt(usize, target, 10);
                            const info = state.hover.related_information[index];
                            action.* = .{ .opener = state.opener.?, .resource = try info.resource.clone(node_arena), .position = Position.init(info.start_line_number, info.start_column) };
                        }
                        try link.addEventListener(.{ .context = action, .click = OpenLink.click, .key_down = OpenLink.key });
                        _ = try line_row.appendChild(link);
                        link_node = link;
                    }
                    _ = try link_node.?.appendChild(text);
                    previous_link = target;
                } else {
                    _ = try line_row.appendChild(text);
                    previous_link = null;
                    link_node = null;
                }
            }
        }
    }
    return row - top;
}

const OpenLink = struct {
    opener: Opener,
    resource: markers.Resource,
    position: ?Position = null,

    fn click(context: ?*anyopaque, event: *ui.MouseEvent) void {
        const self: *OpenLink = @ptrCast(@alignCast(context orelse return));
        event.preventDefault();
        event.stopPropagation();
        self.open();
    }

    fn key(context: ?*anyopaque, event: *ui.KeyEvent) void {
        if (event.key != .enter and !(event.key == .char and event.key.char == ' ')) return;
        const self: *OpenLink = @ptrCast(@alignCast(context orelse return));
        event.preventDefault();
        event.stopPropagation();
        self.open();
    }

    fn open(self: *const OpenLink) void {
        self.opener.open(.{ .scheme = self.resource.scheme, .authority = self.resource.authority, .path = self.resource.path, .query = self.resource.query, .fragment = self.resource.fragment }, self.position);
    }
};

fn appendRow(doc: *ui.Document, parent: *ui.Node, row: usize) !*ui.Node {
    const node = try doc.createElement(.div);
    node.setStyle(.{
        .position = .absolute,
        .left = .{ .cells = 0 },
        .top = .{ .cells = @floatFromInt(row) },
        .width = .{ .percent = 100 },
        .height = .{ .cells = 1 },
        .white_space = .pre,
    });
    _ = try parent.appendChild(node);
    return node;
}
