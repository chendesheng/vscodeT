// Port of `src/vs/editor/common/services/markerDecorations.ts`.

const std = @import("std");
const Marker = @import("../../../platform/markers/common/markers.zig").Marker;
const Range = @import("../core/range.zig").Range;

pub const IMarkerLimit = struct {
    is_markers_source_truncated: bool = false,
    is_markers_truncated: ?usize = null,
};

pub const LiveMarker = struct {
    range: Range,
    marker: *Marker,
};
