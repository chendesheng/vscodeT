// Terminal subset of `src/vs/workbench/services/workingCopy/common/workingCopyHistory.ts`.
const std = @import("std");

pub const WorkingCopyHistoryEntry = struct {
    resource: []const u8,
    type_id: []const u8,
    /// Milliseconds since the Unix epoch.
    timestamp: i64,
    content: []const u8,
};

pub const WorkingCopyHistoryEntryView = struct {
    resource: []const u8,
    type_id: []const u8,
    timestamp: i64,
    content: []const u8,
};
