// Port of the single-file channel descriptor and update contract in
// `src/vs/workbench/services/output/common/output.ts`.
const std = @import("std");

pub const OUTPUT_VIEW_ID = "workbench.panel.output";
pub const OutputChannelUpdateMode = enum(u8) { Append = 1, Replace = 2, Clear = 3 };

pub const IOutputChannelDescriptor = struct {
    id: []const u8,
    label: []const u8,
    source: std.Uri,
    log: bool = false,
    language_id: ?[]const u8 = null,
    extension_id: ?[]const u8 = null,
};
