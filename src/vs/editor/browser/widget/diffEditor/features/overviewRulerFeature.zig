// Port of the per-side marker projection of
// `src/vs/editor/browser/widget/diffEditor/features/overviewRulerFeature.ts`.
//
// Terminal adaptation: upstream renders a combined two-lane overview ruler
// (deleted/original on the left, inserted/modified on the right) into one
// graphics strip. A terminal has one cell column per pane, so each snapshot
// pane receives its own markers through its model decorations and the existing
// terminal scrollbar; the combined two-lane ruler is not representable and is
// documented in `docs/terminal-ui.md`.
const std = @import("std");
const Allocator = std.mem.Allocator;

const view_model = @import("../diffEditorViewModel.zig");
const view_zones = @import("../components/diffEditorViewZones.zig");
const gutter = @import("./gutterFeature.zig");

pub const Side = enum { original, modified };

/// Terminal defaults for `diffEditorOverview.{inserted,removed}Foreground`
/// composited over the dark editor background.
pub const inserted_foreground = [3]u8{ 55, 88, 13 };
pub const removed_foreground = [3]u8{ 158, 93, 80 };

pub const Marker = struct {
    side: Side,
    line_number: usize,
    kind: gutter.ChangeKind,
    color: [3]u8,
};

/// Builds the per-side marker list for the aligned display rows. Original-side
/// markers cover deletions and modifications; modified-side markers cover
/// insertions and modifications.
pub fn collect(allocator: Allocator, aligned: *const view_zones.AlignedRows) ![]Marker {
    var markers = std.array_list.Managed(Marker).init(allocator);
    errdefer markers.deinit();
    for (aligned.mappings) |mapping| {
        const kind = gutter.changeKind(mapping.source);
        switch (kind) {
            .delete, .modify => try markers.append(.{
                .side = .original,
                .line_number = mapping.original.startLineNumber,
                .kind = kind,
                .color = removed_foreground,
            }),
            else => {},
        }
        switch (kind) {
            .add, .modify => try markers.append(.{
                .side = .modified,
                .line_number = mapping.modified.startLineNumber,
                .kind = kind,
                .color = inserted_foreground,
            }),
            else => {},
        }
    }
    return markers.toOwnedSlice();
}

test "overviewRulerFeature: per-side markers for each change kind" {
    const allocator = std.testing.allocator;
    const diff_provider = @import("../../../../common/diff/documentDiffProvider.zig");
    const lines_original = [_][]const u8{ "a", "b", "c" };
    const lines_modified = [_][]const u8{ "a", "B", "c", "d" };
    var provider = diff_provider.LineDiffProvider.init(.advanced);
    var diff = try provider.computeDiffFromLines(allocator, &lines_original, &lines_modified, .{
        .ignoreTrimWhitespace = false,
        .maxComputationTimeMs = 0,
        .computeMoves = false,
    });
    defer diff_provider.deinitDiff(allocator, &diff);
    var rows = try view_zones.computeAlignedRows(allocator, lines_original.len, lines_modified.len, diff.changes);
    defer rows.deinit();

    const markers = try collect(allocator, &rows);
    defer allocator.free(markers);
    try std.testing.expect(markers.len >= 2);
    var has_original = false;
    var has_modified = false;
    for (markers) |marker| {
        if (marker.side == .original) has_original = true;
        if (marker.side == .modified) has_modified = true;
    }
    try std.testing.expect(has_original);
    try std.testing.expect(has_modified);
}
