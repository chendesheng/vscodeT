// Terminal subset of `src/vs/workbench/services/workingCopy/common/workingCopyBackup.ts`.
const std = @import("std");

pub const WorkingCopyBackupIdentifier = struct {
    resource: []const u8,
    type_id: []const u8,
};

pub const WorkingCopyBackup = struct {
    /// Encoded backup content; owned by the service until discarded.
    content: []const u8,
    /// Optional metadata string (upstream stores a serialized meta object).
    meta: ?[]const u8 = null,
};
