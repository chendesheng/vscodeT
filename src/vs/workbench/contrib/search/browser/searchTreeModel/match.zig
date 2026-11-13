// Port of `src/vs/workbench/contrib/search/browser/searchTreeModel/match.ts`.
// The node implementation lives in `searchTreeCommon.zig`.

pub const Match = @import("searchTreeCommon.zig").Match;
pub const SEARCH_ELIDED_PREFIX = "⟪ ";
pub const SEARCH_ELIDED_SUFFIX = " characters skipped ⟫";
