// Port of `src/vs/base/common/severity.ts`.
const std = @import("std");

pub const Severity = enum(u8) {
    Ignore = 0,
    Info = 1,
    Warning = 2,
    Error = 3,

    /// Parses `error`, `warning`/`warn`, `info` case-insensitively and falls
    /// back to `Ignore`.
    pub fn fromValue(value: []const u8) Severity {
        if (std.ascii.eqlIgnoreCase("error", value)) return .Error;
        if (std.ascii.eqlIgnoreCase("warning", value) or std.ascii.eqlIgnoreCase("warn", value)) return .Warning;
        if (std.ascii.eqlIgnoreCase("info", value)) return .Info;
        return .Ignore;
    }

    pub fn toString(self: Severity) []const u8 {
        return switch (self) {
            .Error => "error",
            .Warning => "warning",
            .Info => "info",
            .Ignore => "ignore",
        };
    }
};

test "severity parses values case-insensitively" {
    try std.testing.expectEqual(Severity.Error, Severity.fromValue("Error"));
    try std.testing.expectEqual(Severity.Warning, Severity.fromValue("WARN"));
    try std.testing.expectEqual(Severity.Warning, Severity.fromValue("warning"));
    try std.testing.expectEqual(Severity.Info, Severity.fromValue("info"));
    try std.testing.expectEqual(Severity.Ignore, Severity.fromValue(""));
    try std.testing.expectEqual(Severity.Ignore, Severity.fromValue("unknown"));
    try std.testing.expectEqualStrings("error", Severity.Error.toString());
    try std.testing.expectEqualStrings("ignore", Severity.Ignore.toString());
}
