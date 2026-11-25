// Port of the navigation filters and scopes in
// `src/vs/workbench/services/history/common/history.ts`.

pub const GoFilter = enum { NONE, EDITS, NAVIGATION };
pub const GoScope = enum { DEFAULT, EDITOR_GROUP, EDITOR };
