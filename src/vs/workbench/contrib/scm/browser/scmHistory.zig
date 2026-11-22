// Port of `src/vs/workbench/contrib/scm/browser/scmHistory.ts`.
//
// The view-model generation, reference ordering, color assignment and
// incoming/outgoing insertion are literal ports. The renderer is the terminal
// adaptation: upstream emits SVG paths in 11 px × 22 px swimlanes; here one
// swimlane is one cell and one row is one cell. The canvas accumulates the
// four cell edges (up/down/left/right) and maps them to box-drawing glyphs,
// following lazygit's cell model: lanes are `│`, merge edges `─`, closed
// corners are `╮`/`╭`/`╯`/`╰`, and a crossing is `┼`. No `╱`/`╲` diagonals are
// emitted, because their rasterization reads as one continuous slope across
// rows. Draw order still follows the SVG: lane connections first, merge edges
// next, the commit circle last.
//
// Documented deviations:
// - `renderSCMHistoryItemGraph` returns `GraphGlyph` cells instead of an
//   `SVGElement`; circle strokes/curve radii collapse into single glyphs.
// - A base-commit diagonal becomes a horizontal connector, and a
//   horizontal-over-vertical crossing occupies one `┼` cell instead of
//   lazygit's two-character `│─` cell.
// - Lane and edge colors are keyed to the swimlane column, not to the moving
//   branch node. Upstream carries a node's color to the lane's new column when
//   duplicate swimlanes collapse; with one cell per lane that makes a screen
//   column change color on almost every merge. Every graph glyph, including
//   the commit circles, uses the `scmGraph.foreground1..5` palette by column
//   index, so a lane and its nodes always match and each column keeps one color
//   down the graph. The view model's node/reference colors still drive the ref
//   badges and the hover, but not the graph cells.
// - Hover content is plain text; markdown, avatars and command links are not
//   ported.
const std = @import("std");
const Allocator = std.mem.Allocator;

const history = @import("../common/history.zig");
const freeGraphNodes = history.freeGraphNodes;

pub const SWIMLANE_HEIGHT: usize = 1;
pub const SWIMLANE_WIDTH: usize = 1;
const SWIMLANE_CURVE_RADIUS: usize = 1;
const CIRCLE_STROKE_WIDTH: usize = 2;

/// History item reference colors (local, remote, base).
pub const history_item_ref_color = "scmGraph.historyItemRefColor";
pub const history_item_remote_ref_color = "scmGraph.historyItemRemoteRefColor";
pub const history_item_base_ref_color = "scmGraph.historyItemBaseRefColor";

/// Graph lane colors, in upstream `colorRegistry` order.
pub const color_registry = [_][]const u8{
    "scmGraph.foreground1",
    "scmGraph.foreground2",
    "scmGraph.foreground3",
    "scmGraph.foreground4",
    "scmGraph.foreground5",
};

pub const ColorMap = std.StringHashMap(?[]const u8);

pub fn rot(index: isize, modulo: usize) isize {
    const mod: isize = @intCast(modulo);
    return @mod(mod + @mod(index, mod), mod);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn getLabelColorIdentifier(
    history_item: history.ISCMHistoryItem,
    color_map: *const ColorMap,
) ?[]const u8 {
    if (eql(history_item.id, history.SCMIncomingHistoryItemId)) {
        return history_item_remote_ref_color;
    } else if (eql(history_item.id, history.SCMOutgoingHistoryItemId)) {
        return history_item_ref_color;
    }
    for (history_item.references) |ref| {
        if (color_map.contains(ref.id)) {
            if (color_map.get(ref.id).?) |color| return color;
        }
    }
    return null;
}

fn makeGraphNode(allocator: Allocator, id: []const u8, color: []const u8) !history.ISCMHistoryItemGraphNode {
    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);
    const owned_color = try allocator.dupe(u8, color);
    return .{ .id = owned_id, .color = owned_color };
}

fn cloneGraphNode(
    allocator: Allocator,
    node: history.ISCMHistoryItemGraphNode,
) !history.ISCMHistoryItemGraphNode {
    return makeGraphNode(allocator, node.id, node.color);
}

pub fn cloneGraphNodes(
    allocator: Allocator,
    nodes: []const history.ISCMHistoryItemGraphNode,
) ![]history.ISCMHistoryItemGraphNode {
    if (nodes.len == 0) return allocator.alloc(history.ISCMHistoryItemGraphNode, 0);
    const result = try allocator.alloc(history.ISCMHistoryItemGraphNode, nodes.len);
    var owned: usize = 0;
    errdefer {
        for (result[0..owned]) |node| {
            allocator.free(node.id);
            allocator.free(node.color);
        }
        allocator.free(result);
    }
    for (nodes, 0..) |node, index| {
        result[index] = try cloneGraphNode(allocator, node);
        owned = index + 1;
    }
    return result;
}

/// Returns a new slice with deep-cloned `nodes` plus `node`. The input slice
/// stays owned by the caller; `node` transfers into the result on success.
fn appendGraphNode(
    allocator: Allocator,
    nodes: []const history.ISCMHistoryItemGraphNode,
    node: history.ISCMHistoryItemGraphNode,
) ![]history.ISCMHistoryItemGraphNode {
    const result = try allocator.alloc(history.ISCMHistoryItemGraphNode, nodes.len + 1);
    var owned: usize = 0;
    errdefer {
        for (result[0..owned]) |cloned| {
            allocator.free(cloned.id);
            allocator.free(cloned.color);
        }
        allocator.free(result);
    }
    for (nodes, 0..) |existing, index| {
        result[index] = try cloneGraphNode(allocator, existing);
        owned = index + 1;
    }
    result[nodes.len] = node;
    return result;
}

fn findLastIndex(
    nodes: []const history.ISCMHistoryItemGraphNode,
    id: []const u8,
) ?usize {
    var index = nodes.len;
    while (index > 0) {
        index -= 1;
        if (eql(nodes[index].id, id)) return index;
    }
    return null;
}

fn findIndex(nodes: []const history.ISCMHistoryItemGraphNode, id: []const u8) ?usize {
    for (nodes, 0..) |node, index| {
        if (eql(node.id, id)) return index;
    }
    return null;
}

fn findHistoryItem(items: []const history.ISCMHistoryItem, id: []const u8) ?*const history.ISCMHistoryItem {
    for (items) |*item| {
        if (eql(item.id, id)) return item;
    }
    return null;
}

pub fn getHistoryItemIndex(view_model: *const history.ISCMHistoryItemViewModel) usize {
    if (findIndex(view_model.input_swimlanes, view_model.history_item.id)) |index| return index;
    return view_model.input_swimlanes.len;
}

const RefSortContext = struct {
    current: ?history.ISCMHistoryItemRef,
    remote: ?history.ISCMHistoryItemRef,
    base: ?history.ISCMHistoryItemRef,
};

fn refOrder(ref: history.ISCMHistoryItemRef, context: RefSortContext) i32 {
    if (context.current) |current| {
        if (eql(ref.id, current.id)) return 1;
    }
    if (context.remote) |remote| {
        if (eql(ref.id, remote.id)) return 2;
    }
    if (context.base) |base| {
        if (eql(ref.id, base.id)) return 3;
    }
    if (ref.color != null) return 4;
    return 99;
}

fn refLessThan(context: RefSortContext, a: history.ISCMHistoryItemRef, b: history.ISCMHistoryItemRef) bool {
    return refOrder(a, context) < refOrder(b, context);
}

pub fn compareHistoryItemRefs(
    ref1: history.ISCMHistoryItemRef,
    ref2: history.ISCMHistoryItemRef,
    current_ref: ?history.ISCMHistoryItemRef,
    remote_ref: ?history.ISCMHistoryItemRef,
    base_ref: ?history.ISCMHistoryItemRef,
) i32 {
    const context = RefSortContext{ .current = current_ref, .remote = remote_ref, .base = base_ref };
    return refOrder(ref1, context) - refOrder(ref2, context);
}

fn makeZeros(allocator: Allocator, length: usize) ![]u8 {
    const result = try allocator.alloc(u8, length);
    @memset(result, '0');
    return result;
}

fn displayIdLength(view_models: []const history.ISCMHistoryItemViewModel) usize {
    if (view_models.len == 0) return 0;
    const display_id = view_models[0].history_item.display_id orelse return 0;
    return display_id.len;
}

fn makeSyntheticItem(
    allocator: Allocator,
    id: []const u8,
    display_id: ?[]const u8,
    parent_id: []const u8,
    author: ?[]const u8,
    subject: []const u8,
) !history.ISCMHistoryItem {
    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);
    const owned_subject = try allocator.dupe(u8, subject);
    errdefer allocator.free(owned_subject);
    const owned_message = try allocator.alloc(u8, 0);
    errdefer allocator.free(owned_message);

    const parents = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(parents);
    const owned_parent = try allocator.dupe(u8, parent_id);
    errdefer allocator.free(owned_parent);
    parents[0] = owned_parent;

    const references = try allocator.alloc(history.ISCMHistoryItemRef, 0);
    errdefer allocator.free(references);

    const owned_display = if (display_id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_display) |value| allocator.free(value);
    const owned_author = if (author) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_author) |value| allocator.free(value);

    return .{
        .id = owned_id,
        .parent_ids = parents,
        .subject = owned_subject,
        .message = owned_message,
        .display_id = owned_display,
        .author = owned_author,
        .references = references,
    };
}

pub fn toISCMHistoryItemViewModelArray(
    allocator: Allocator,
    history_items: []const history.ISCMHistoryItem,
    color_map: ?*const ColorMap,
    current_history_item_ref: ?history.ISCMHistoryItemRef,
    current_history_item_remote_ref: ?history.ISCMHistoryItemRef,
    current_history_item_base_ref: ?history.ISCMHistoryItemRef,
    add_incoming_changes: bool,
    add_outgoing_changes: bool,
    merge_base: ?[]const u8,
) ![]history.ISCMHistoryItemViewModel {
    var fallback_map = ColorMap.init(allocator);
    defer fallback_map.deinit();
    const map = color_map orelse &fallback_map;

    var color_index: isize = -1;
    var view_models = std.array_list.Managed(history.ISCMHistoryItemViewModel).init(allocator);
    errdefer freeViewModels(allocator, view_models.items);

    for (history_items) |history_item| {
        const kind: history.HistoryItemKind = blk: {
            if (current_history_item_ref) |current| {
                if (current.revision) |revision| {
                    if (eql(history_item.id, revision)) break :blk .head;
                }
            }
            break :blk .node;
        };

        const previous_output: []const history.ISCMHistoryItemGraphNode = if (view_models.items.len > 0)
            view_models.items[view_models.items.len - 1].output_swimlanes
        else
            &.{};

        const input_swimlanes = try cloneGraphNodes(allocator, previous_output);
        var input_transferred = false;
        errdefer if (!input_transferred) freeGraphNodes(allocator, input_swimlanes);

        var output_swimlanes = std.array_list.Managed(history.ISCMHistoryItemGraphNode).init(allocator);
        errdefer {
            for (output_swimlanes.items) |node| {
                allocator.free(node.id);
                allocator.free(node.color);
            }
            output_swimlanes.deinit();
        }

        var first_parent_added = false;

        // Add first parent to the output.
        if (history_item.parent_ids.len > 0) {
            for (input_swimlanes) |node| {
                if (eql(node.id, history_item.id)) {
                    if (!first_parent_added) {
                        const color = getLabelColorIdentifier(history_item, map) orelse node.color;
                        try output_swimlanes.append(try makeGraphNode(allocator, history_item.parent_ids[0], color));
                        first_parent_added = true;
                    }
                    continue;
                }
                try output_swimlanes.append(try cloneGraphNode(allocator, node));
            }
        }

        // Add unprocessed parent(s) to the output.
        var parent_index: usize = if (first_parent_added) 1 else 0;
        while (parent_index < history_item.parent_ids.len) : (parent_index += 1) {
            var color_identifier: ?[]const u8 = null;
            if (parent_index == 0) {
                color_identifier = getLabelColorIdentifier(history_item, map);
            } else if (findHistoryItem(history_items, history_item.parent_ids[parent_index])) |parent_item| {
                color_identifier = getLabelColorIdentifier(parent_item.*, map);
            }

            if (color_identifier == null) {
                color_index = rot(color_index + 1, color_registry.len);
                color_identifier = color_registry[@intCast(color_index)];
            }

            try output_swimlanes.append(try makeGraphNode(
                allocator,
                history_item.parent_ids[parent_index],
                color_identifier.?,
            ));
        }

        // Add colors to references.
        var references = try allocator.alloc(history.ISCMHistoryItemRef, history_item.references.len);
        var references_owned: usize = 0;
        var references_transferred = false;
        errdefer if (!references_transferred) {
            for (references[0..references_owned]) |*reference| reference.deinit(allocator);
            allocator.free(references);
        };
        for (history_item.references, 0..) |reference, reference_index| {
            var color: ?[]const u8 = null;
            if (map.contains(reference.id)) {
                if (map.get(reference.id).?) |value| {
                    color = value;
                } else {
                    const input_index = findIndex(input_swimlanes, history_item.id);
                    const circle_index = input_index orelse input_swimlanes.len;
                    color = if (circle_index < output_swimlanes.items.len)
                        output_swimlanes.items[circle_index].color
                    else if (circle_index < input_swimlanes.len)
                        input_swimlanes[circle_index].color
                    else
                        history_item_ref_color;
                }
            }
            references[reference_index] = try reference.cloneWithColor(allocator, color);
            references_owned = reference_index + 1;
        }

        // Sort references (stable, like the upstream JS sort for equal keys).
        std.sort.insertion(history.ISCMHistoryItemRef, references, RefSortContext{
            .current = current_history_item_ref,
            .remote = current_history_item_remote_ref,
            .base = current_history_item_base_ref,
        }, refLessThan);

        var cloned_item = try history_item.clone(allocator);
        errdefer cloned_item.deinit(allocator);

        // Replace the cloned references with the colored/sorted ones.
        for (cloned_item.references) |*reference| reference.deinit(allocator);
        allocator.free(cloned_item.references);
        cloned_item.references = references;
        references_transferred = true;

        const output_slice = try output_swimlanes.toOwnedSlice();
        var output_transferred = false;
        errdefer if (!output_transferred) freeGraphNodes(allocator, output_slice);

        try view_models.append(.{
            .history_item = cloned_item,
            .input_swimlanes = input_swimlanes,
            .output_swimlanes = output_slice,
            .kind = kind,
        });
        output_transferred = true;
        input_transferred = true;
    }

    errdefer freeViewModels(allocator, view_models.items);
    try addIncomingOutgoingChangesHistoryItems(
        allocator,
        &view_models,
        current_history_item_ref,
        current_history_item_remote_ref,
        add_incoming_changes,
        add_outgoing_changes,
        merge_base,
    );

    return try view_models.toOwnedSlice();
}

fn addIncomingOutgoingChangesHistoryItems(
    allocator: Allocator,
    view_models: *std.array_list.Managed(history.ISCMHistoryItemViewModel),
    current_history_item_ref: ?history.ISCMHistoryItemRef,
    current_history_item_remote_ref: ?history.ISCMHistoryItemRef,
    add_incoming_changes: bool,
    add_outgoing_changes: bool,
    merge_base: ?[]const u8,
) !void {
    const current = current_history_item_ref orelse return;
    const current_revision = current.revision orelse return;
    const remote = current_history_item_remote_ref orelse return;
    const remote_revision = remote.revision orelse return;
    const merge = merge_base orelse return;
    if (eql(current_revision, remote_revision)) return;

    // Incoming changes node.
    if (add_incoming_changes and !eql(remote_revision, merge)) {
        const before_index = lastIndexOfOutputLane(view_models.items, merge);
        const after_index = firstIndexOfHistoryItem(view_models.items, merge);

        if (before_index != null and after_index != null) {
            const before = before_index.?;
            const after = after_index.?;
            const before_item = &view_models.items[before].history_item;
            const incoming_change_merged = before_item.parent_ids.len == 2 and
                containsId(before_item.parent_ids, merge);

            if (!incoming_change_merged) {
                // Point the incoming/outgoing swimlanes at the pseudo node.
                for (view_models.items[before].input_swimlanes) |*node| {
                    if (!eql(node.id, merge) or !eql(node.color, history_item_remote_ref_color)) continue;
                    const replacement = try allocator.dupe(u8, history.SCMIncomingHistoryItemId);
                    allocator.free(node.id);
                    node.id = replacement;
                }
                for (view_models.items[before].output_swimlanes) |*node| {
                    if (!eql(node.id, merge) or !eql(node.color, history_item_remote_ref_color)) continue;
                    const replacement = try allocator.dupe(u8, history.SCMIncomingHistoryItemId);
                    allocator.free(node.id);
                    node.id = replacement;
                }

                const input_swimlanes = try cloneGraphNodes(
                    allocator,
                    view_models.items[before].output_swimlanes,
                );
                var input_owned = true;
                errdefer if (input_owned) freeGraphNodes(allocator, input_swimlanes);
                const output_swimlanes = try cloneGraphNodes(
                    allocator,
                    view_models.items[after].input_swimlanes,
                );
                var output_owned = true;
                errdefer if (output_owned) freeGraphNodes(allocator, output_swimlanes);

                const display_length = displayIdLength(view_models.items);
                const display_id = try makeZeros(allocator, display_length);
                defer allocator.free(display_id);

                var incoming_item = try makeSyntheticItem(
                    allocator,
                    history.SCMIncomingHistoryItemId,
                    display_id,
                    merge,
                    remote.name,
                    "Incoming Changes",
                );
                var item_owned = true;
                errdefer if (item_owned) incoming_item.deinit(allocator);

                try view_models.insert(after, .{
                    .history_item = incoming_item,
                    .input_swimlanes = input_swimlanes,
                    .output_swimlanes = output_swimlanes,
                    .kind = .incoming_changes,
                });
                item_owned = false;
                input_owned = false;
                output_owned = false;
            }
        }
    }

    // Outgoing changes node.
    if (add_outgoing_changes and !eql(current_revision, merge)) {
        const current_index = firstIndexOfHeadRevision(view_models.items, current_revision);
        if (current_index != null) {
            const index = current_index.?;
            const input_swimlanes = try cloneGraphNodes(
                allocator,
                view_models.items[index].input_swimlanes,
            );
            var input_owned = true;
            errdefer if (input_owned) freeGraphNodes(allocator, input_swimlanes);

            const outgoing_lane = try makeGraphNode(allocator, current_revision, history_item_ref_color);
            var lane_owned = true;
            errdefer if (lane_owned) {
                allocator.free(outgoing_lane.id);
                allocator.free(outgoing_lane.color);
            };
            const output_swimlanes = try appendGraphNode(allocator, input_swimlanes, outgoing_lane);
            input_owned = false;
            lane_owned = false;
            var output_owned = true;
            errdefer if (output_owned) freeGraphNodes(allocator, output_swimlanes);

            const display_id: ?[]const u8 = if (view_models.items[0].history_item.display_id != null)
                try makeZeros(allocator, displayIdLength(view_models.items))
            else
                null;
            defer if (display_id) |value| allocator.free(value);

            var outgoing_item = try makeSyntheticItem(
                allocator,
                history.SCMOutgoingHistoryItemId,
                display_id,
                current_revision,
                current.name,
                "Outgoing Changes",
            );
            var item_owned = true;
            errdefer if (item_owned) outgoing_item.deinit(allocator);

            try view_models.insert(index, .{
                .history_item = outgoing_item,
                .input_swimlanes = input_swimlanes,
                .output_swimlanes = output_swimlanes,
                .kind = .outgoing_changes,
            });
            item_owned = false;
            output_owned = false;

            // Update the input swimlane of the current history item ref so it
            // connects with the outgoing changes node.
            const target = &view_models.items[index + 1];
            const node = try makeGraphNode(allocator, current_revision, history_item_ref_color);
            var node_owned = true;
            errdefer if (node_owned) {
                allocator.free(node.id);
                allocator.free(node.color);
            };
            const target_input = try appendGraphNode(allocator, target.input_swimlanes, node);
            node_owned = false;
            freeGraphNodes(allocator, target.input_swimlanes);
            target.input_swimlanes = target_input;
        }
    }
}

fn containsId(ids: []const []const u8, id: []const u8) bool {
    for (ids) |candidate| {
        if (eql(candidate, id)) return true;
    }
    return false;
}

fn lastIndexOfOutputLane(
    view_models: []const history.ISCMHistoryItemViewModel,
    id: []const u8,
) ?usize {
    var index = view_models.len;
    while (index > 0) {
        index -= 1;
        for (view_models[index].output_swimlanes) |node| {
            if (eql(node.id, id)) return index;
        }
    }
    return null;
}

fn firstIndexOfHistoryItem(
    view_models: []const history.ISCMHistoryItemViewModel,
    id: []const u8,
) ?usize {
    for (view_models, 0..) |view_model, index| {
        if (eql(view_model.history_item.id, id)) return index;
    }
    return null;
}

fn firstIndexOfHeadRevision(
    view_models: []const history.ISCMHistoryItemViewModel,
    revision: []const u8,
) ?usize {
    for (view_models, 0..) |view_model, index| {
        if (view_model.kind == .head and eql(view_model.history_item.id, revision)) return index;
    }
    return null;
}

pub fn freeViewModels(allocator: Allocator, view_models: []history.ISCMHistoryItemViewModel) void {
    for (view_models) |*view_model| view_model.deinit(allocator);
    if (view_models.len > 0) allocator.free(view_models);
}

// ---------------------------------------------------------------------------
// Terminal graph renderer
// ---------------------------------------------------------------------------

pub const GraphGlyph = struct {
    cp: u21 = ' ',
    /// Color identifier borrowed from the view model or the static registry.
    color: ?[]const u8 = null,
};

const GraphCell = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    glyph: ?u21 = null,
    glyph_color: ?[]const u8 = null,
    vertical_color: ?[]const u8 = null,
    horizontal_color: ?[]const u8 = null,

    fn addUp(self: *GraphCell, color: ?[]const u8) void {
        self.up = true;
        self.vertical_color = color;
    }

    fn addDown(self: *GraphCell, color: ?[]const u8) void {
        self.down = true;
        self.vertical_color = color;
    }

    fn addLeft(self: *GraphCell, color: ?[]const u8) void {
        self.left = true;
        self.horizontal_color = color;
    }

    fn addRight(self: *GraphCell, color: ?[]const u8) void {
        self.right = true;
        self.horizontal_color = color;
    }

    /// Box-drawing glyph for the edges that touch this cell. The mapping is
    /// lazygit's `getBoxDrawingChars`, collapsed from its two-character cell to
    /// a single terminal cell: a crossing becomes `┼` instead of `│─`.
    fn boxDrawingGlyph(self: *const GraphCell) u21 {
        if (self.up and self.down and self.left and self.right) return '\u{253C}'; // ┼
        if (self.up and self.down and self.left) return '\u{2524}'; // ┤
        if (self.up and self.down and self.right) return '\u{251C}'; // ├
        if (self.up and self.down) return '\u{2502}'; // │
        if (self.up and self.left) return '\u{256F}'; // ╯
        if (self.up and self.right) return '\u{2570}'; // ╰
        if (self.down and self.left) return '\u{256E}'; // ╮
        if (self.down and self.right) return '\u{256D}'; // ╭
        if (self.left and self.right) return '\u{2500}'; // ─
        if (self.up) return '\u{2575}'; // ╵
        if (self.down) return '\u{2577}'; // ╷
        if (self.left) return '\u{2574}'; // ╴
        if (self.right) return '\u{2576}'; // ╶
        return ' ';
    }

    fn colorIdentifier(self: *const GraphCell) ?[]const u8 {
        if (self.glyph != null) return self.glyph_color;
        // A cell that carries a lane keeps the lane's color even when a merge
        // edge crosses it. VS Code paints one color per column: the vertical
        // line owns the cell, and the horizontal edge only shows its own color
        // where it runs between lanes or turns down into a new lane.
        if (self.up or self.down) return self.vertical_color orelse self.horizontal_color;
        return self.horizontal_color orelse self.vertical_color;
    }

    fn toGlyph(self: *const GraphCell) GraphGlyph {
        return .{
            .cp = self.glyph orelse self.boxDrawingGlyph(),
            .color = self.colorIdentifier(),
        };
    }
};

/// Color of a swimlane column. Upstream ties the color to the branch node, so
/// a lane that shifts left/right carries its color to the new column. In a
/// one-cell terminal graph that makes the same screen column change color on
/// almost every merge (duplicate lanes and first-parent replacements shift the
/// lanes after them), which reads as a different color per row. The terminal
/// adaptation keys the lane and edge color to the column instead, while commit
/// circles keep the node/reference color.
fn laneColor(lane: usize) ?[]const u8 {
    return color_registry[lane % color_registry.len];
}

const GraphCanvas = struct {
    cells: []GraphCell,

    fn init(allocator: Allocator, width: usize) !GraphCanvas {
        const cells = try allocator.alloc(GraphCell, width);
        for (cells) |*cell| cell.* = .{};
        return .{ .cells = cells };
    }

    fn deinit(self: *GraphCanvas, allocator: Allocator) void {
        allocator.free(self.cells);
        self.* = undefined;
    }

    fn laneCell(self: *GraphCanvas, lane: usize) ?*GraphCell {
        const column = SWIMLANE_WIDTH * (lane + 1);
        if (column >= self.cells.len) return null;
        return &self.cells[column];
    }

    fn putGlyph(self: *GraphCanvas, lane: usize, cp: u21, color: ?[]const u8) void {
        const cell = self.laneCell(lane) orelse return;
        cell.glyph = cp;
        cell.glyph_color = color;
    }

    fn addUp(self: *GraphCanvas, lane: usize, color: ?[]const u8) void {
        if (self.laneCell(lane)) |cell| cell.addUp(color);
    }

    fn addDown(self: *GraphCanvas, lane: usize, color: ?[]const u8) void {
        if (self.laneCell(lane)) |cell| cell.addDown(color);
    }

    /// Adds a horizontal run between two lanes, including the side edges of
    /// the endpoint cells.
    fn addHorizontal(self: *GraphCanvas, from: usize, to: usize, color: ?[]const u8) void {
        if (from == to) return;
        const step: isize = if (to > from) 1 else -1;
        const from_cell = self.laneCell(from);
        if (step > 0) {
            if (from_cell) |cell| cell.addRight(color);
        } else {
            if (from_cell) |cell| cell.addLeft(color);
        }
        const to_cell = self.laneCell(to);
        if (step > 0) {
            if (to_cell) |cell| cell.addLeft(color);
        } else {
            if (to_cell) |cell| cell.addRight(color);
        }
        var lane: isize = @as(isize, @intCast(from)) + step;
        const target: isize = @intCast(to);
        while (lane != target) : (lane += step) {
            if (self.laneCell(@as(usize, @intCast(lane)))) |cell| {
                cell.addLeft(color);
                cell.addRight(color);
            }
        }
    }

    /// Connects a swimlane from its cell in the previous row to its cell in the
    /// next row: a straight `│` when the lane stays put, closed orthogonal
    /// corners when it moves left or right. Each endpoint uses its own
    /// column's color, so a shifted lane changes to the target column's color.
    fn connect(self: *GraphCanvas, from: usize, to: usize) void {
        self.addUp(from, laneColor(from));
        self.addDown(to, laneColor(to));
        self.addHorizontal(from, to, laneColor(to));
    }

    /// The extra-parent edge of a merge commit: a horizontal run away from the
    /// commit circle, then a corner and a vertical line down the parent lane.
    fn drawMergeEdge(self: *GraphCanvas, from: usize, to: usize) void {
        if (from == to) return;
        const color = laneColor(to);
        self.addDown(to, color);
        self.addHorizontal(from, to, color);
    }

    fn drawCircle(self: *GraphCanvas, lane: usize, kind: history.HistoryItemKind, parents: usize) void {
        const cp: u21 = switch (kind) {
            .head => '\u{25C9}', // ◉
            .incoming_changes, .outgoing_changes => '\u{25CC}', // ◌
            .node => if (parents > 1) '\u{25CE}' else '\u{25CF}', // ◎ / ●
        };
        self.putGlyph(lane, cp, laneColor(lane));
    }

    fn toGlyphs(self: *GraphCanvas, allocator: Allocator) ![]GraphGlyph {
        const result = try allocator.alloc(GraphGlyph, self.cells.len);
        for (self.cells, 0..) |cell, index| result[index] = cell.toGlyph();
        return result;
    }
};

pub fn renderSCMHistoryItemGraph(
    allocator: Allocator,
    view_model: *const history.ISCMHistoryItemViewModel,
) ![]GraphGlyph {
    const history_item = view_model.history_item;
    const input_swimlanes = view_model.input_swimlanes;
    const output_swimlanes = view_model.output_swimlanes;

    const input_index = findIndex(input_swimlanes, history_item.id);
    const circle_index = input_index orelse input_swimlanes.len;

    const width = SWIMLANE_WIDTH * (@max(@max(input_swimlanes.len, output_swimlanes.len), 1) + 1);
    var canvas = try GraphCanvas.init(allocator, width);
    defer canvas.deinit(allocator);

    var output_swimlane_index: usize = 0;
    var first_parent_output: ?usize = null;
    for (input_swimlanes, 0..) |node, index| {
        if (eql(node.id, history_item.id)) {
            if (index == circle_index) {
                // The current commit ends here. Its first parent occupies the
                // next output lane, which is where the vertical line resumes
                // below the circle.
                if (history_item.parent_ids.len > 0 and output_swimlane_index < output_swimlanes.len) {
                    first_parent_output = output_swimlane_index;
                    output_swimlane_index += 1;
                }
            } else {
                // Duplicate expectation of the same commit (a feature branch
                // based on the commit it was merged into): fold that lane into
                // the circle lane instead of rasterizing upstream's diagonal
                // SVG arc.
                canvas.connect(index, circle_index);
            }
            continue;
        }
        if (output_swimlane_index < output_swimlanes.len and
            eql(node.id, output_swimlanes[output_swimlane_index].id))
        {
            canvas.connect(index, output_swimlane_index);
            output_swimlane_index += 1;
        }
    }

    // The circle continues into its first parent.
    if (history_item.parent_ids.len > 0 and circle_index < output_swimlanes.len) {
        const first_parent_lane = first_parent_output orelse circle_index;
        canvas.addDown(first_parent_lane, laneColor(first_parent_lane));
        if (first_parent_output) |parent_output| {
            if (parent_output != circle_index) {
                canvas.connect(circle_index, parent_output);
            }
        }
    }

    // Remaining parents are merge edges to the lanes that hold them.
    var parent_index: usize = 1;
    while (parent_index < history_item.parent_ids.len) : (parent_index += 1) {
        const parent_output_index = findLastIndex(output_swimlanes, history_item.parent_ids[parent_index]) orelse continue;
        canvas.drawMergeEdge(circle_index, parent_output_index);
    }

    canvas.drawCircle(circle_index, view_model.kind, history_item.parent_ids.len);

    return canvas.toGlyphs(allocator);
}

pub fn renderSCMHistoryGraphPlaceholder(
    allocator: Allocator,
    columns: []const history.ISCMHistoryItemGraphNode,
    highlight_index: ?usize,
) ![]GraphGlyph {
    const width = SWIMLANE_WIDTH * (columns.len + 1);
    var canvas = try GraphCanvas.init(allocator, width);
    defer canvas.deinit(allocator);
    for (columns, 0..) |_, index| {
        const cp: u21 = if (highlight_index != null and highlight_index.? == index)
            '\u{2503}' // ┃
        else
            '\u{2502}'; // │
        canvas.putGlyph(index, cp, laneColor(index));
    }
    return canvas.toGlyphs(allocator);
}

/// Rendered graph width in cells for a view model (exposed for the row layout).
pub fn graphWidth(view_model: *const history.ISCMHistoryItemViewModel) usize {
    return SWIMLANE_WIDTH * (@max(@max(view_model.input_swimlanes.len, view_model.output_swimlanes.len), 1) + 1);
}

pub fn placeholderWidth(columns: []const history.ISCMHistoryItemGraphNode) usize {
    return SWIMLANE_WIDTH * (columns.len + 1);
}

// ---------------------------------------------------------------------------
// Hover content
// ---------------------------------------------------------------------------

fn appendTimestamp(list: *std.array_list.Managed(u8), timestamp_ms: i64) !void {
    const seconds = @divFloor(timestamp_ms, 1000);
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const text = try std.fmt.allocPrint(list.allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
    });
    defer list.allocator.free(text);
    try list.appendSlice(text);
}

/// Builds the compact terminal hover: identity line, author/date, message,
/// statistics and references. The view wraps the result to its overlay width.
pub fn buildHistoryItemHover(allocator: Allocator, item: history.ISCMHistoryItem) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    try result.appendSlice(item.display_id orelse item.id);
    try result.append(' ');
    try result.appendSlice(item.subject);
    try result.append('\n');

    var has_author_line = false;
    if (item.author) |author| {
        try result.appendSlice(author);
        has_author_line = true;
    }
    if (item.author_email) |email| {
        if (has_author_line) try result.appendSlice(" <");
        try result.appendSlice(email);
        if (has_author_line) try result.append('>');
        has_author_line = true;
    }
    if (item.timestamp) |timestamp| {
        if (has_author_line) try result.appendSlice(", ");
        try appendTimestamp(&result, timestamp);
        has_author_line = true;
    }
    if (has_author_line) try result.append('\n');

    if (item.message.len > 0) {
        try result.appendSlice(item.message);
        if (item.message[item.message.len - 1] != '\n') try result.append('\n');
    }

    const stats = item.statistics;
    if (stats.files > 0) {
        const stats_line = try std.fmt.allocPrint(
            allocator,
            "{d} file{s} changed, +{d} \u{2212}{d}\n",
            .{ stats.files, if (stats.files == 1) "" else "s", stats.insertions, stats.deletions },
        );
        defer allocator.free(stats_line);
        try result.appendSlice(stats_line);
    }

    if (item.references.len > 0) {
        try result.appendSlice("refs: ");
        for (item.references, 0..) |reference, index| {
            if (index > 0) try result.appendSlice(", ");
            try result.appendSlice(reference.name);
        }
        try result.append('\n');
    }

    return result.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "scmHistory: label color and ref ordering" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var map = ColorMap.init(allocator);
    defer map.deinit();
    try map.put("refs/heads/main", "scmGraph.foreground1");
    try map.put("refs/heads/other", null);

    const references = [_]history.ISCMHistoryItemRef{
        .{ .id = "refs/heads/other", .name = "other" },
        .{ .id = "refs/heads/main", .name = "main" },
    };
    const item = history.ISCMHistoryItem{
        .id = "abc",
        .parent_ids = &.{},
        .subject = "subject",
        .message = "subject",
        .references = @constCast(&references),
    };
    try testing.expectEqualStrings("scmGraph.foreground1", getLabelColorIdentifier(item, &map).?);

    const current = history.ISCMHistoryItemRef{ .id = "refs/heads/main", .name = "main" };
    try testing.expectEqual(@as(i32, 98), compareHistoryItemRefs(references[0], references[1], current, null, null));
    try testing.expectEqual(@as(i32, -98), compareHistoryItemRefs(references[1], references[0], current, null, null));
    try testing.expectEqual(@as(isize, 0), rot(0, 5));
    try testing.expectEqual(@as(isize, 0), rot(5, 5));
    try testing.expectEqual(@as(isize, 4), rot(-1, 5));
}

test "scmHistory: linear graph cells" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const items = [_]history.ISCMHistoryItem{
        .{ .id = "a", .parent_ids = @constCast(&[_][]const u8{"b"}), .subject = "", .message = "" },
        .{ .id = "b", .parent_ids = &.{}, .subject = "", .message = "" },
    };
    const view_models = try toISCMHistoryItemViewModelArray(allocator, &items, null, null, null, null, false, false, null);
    defer freeViewModels(allocator, view_models);
    try testing.expectEqual(@as(usize, 2), view_models.len);

    const first = try renderSCMHistoryItemGraph(allocator, &view_models[0]);
    defer allocator.free(first);
    try testing.expectEqual(@as(usize, 2), first.len);
    try testing.expectEqual(@as(u21, '\u{25CF}'), first[1].cp);

    const second = try renderSCMHistoryItemGraph(allocator, &view_models[1]);
    defer allocator.free(second);
    try testing.expectEqual(@as(u21, '\u{25CF}'), second[1].cp);
}
