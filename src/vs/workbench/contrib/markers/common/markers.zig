// Port of `src/vs/workbench/contrib/markers/common/markers.ts`.
//
// Terminal adaptation: the Problems view is a side-panel container because the
// terminal bottom panel is the integrated terminal. The upstream view ids and
// command ids are kept so actions and status entries match VS Code metadata.

pub const Markers = struct {
    pub const MARKERS_CONTAINER_ID = "workbench.panel.markers";
    pub const MARKERS_VIEW_ID = "workbench.panel.markers.view";
    pub const MARKERS_VIEW_STORAGE_ID = "workbench.panel.markers";
    pub const MARKER_OPEN_ACTION_ID = "problems.action.open";
    pub const MARKER_OPEN_SIDE_ACTION_ID = "problems.action.openToSide";
    pub const MARKER_SHOW_PANEL_ID = "workbench.action.showErrorsWarnings";
    pub const TOGGLE_MARKERS_VIEW_ACTION_ID = "workbench.actions.view.toggleProblems";
    pub const SHOW_MARKERS_VIEW_ACTION_ID = "workbench.actions.view.problems";
    pub const MARKERS_VIEW_FOCUS_COMMAND = "workbench.action.problems.focus";
};

/// Terminal activity/composite id for the Problems container.
pub const PROBLEMS_ACTIVITY_ID = "problems";
pub const PROBLEMS_TITLE = "Problems";

/// Severity mask used by the Problems view. Upstream reads
/// `Error | Warning | Info`; hints are omitted from the list.
pub const problems_severities: u32 =
    @import("../../../../platform/markers/common/markers.zig").MarkerSeverity.Error |
    @import("../../../../platform/markers/common/markers.zig").MarkerSeverity.Warning |
    @import("../../../../platform/markers/common/markers.zig").MarkerSeverity.Info;

test "markers: upstream ids and severity mask" {
    try @import("std").testing.expectEqualStrings("workbench.panel.markers.view", Markers.MARKERS_VIEW_ID);
    try @import("std").testing.expectEqualStrings("workbench.actions.view.toggleProblems", Markers.TOGGLE_MARKERS_VIEW_ACTION_ID);
    try @import("std").testing.expectEqual(@as(u32, 8 | 4 | 2), problems_severities);
}
