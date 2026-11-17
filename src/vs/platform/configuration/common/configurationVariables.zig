// Port of `src/vs/platform/configuration/common/configurationVariables.ts`.
const std = @import("std");

pub const ConfigurationVariable = struct {
    /// `${name:arg}` (borrowed).
    id: []const u8,
    /// The `name:arg` in `${name:arg}`.
    inner: []const u8,
    /// The `name` in `${name:arg}`.
    name: []const u8,
    /// The `arg` in `${name:arg}`, when a colon is present.
    arg: ?[]const u8 = null,
};

pub const ParsedVariable = struct {
    replacement: ConfigurationVariable,
    end: usize,
};

/// Parses a configuration variable at `start`, including nested braces.
pub fn parseConfigurationVariable(value: []const u8, start: usize) ?ParsedVariable {
    if (start + 1 >= value.len) return null;
    if (value[start] != '$' or value[start + 1] != '{') return null;

    var end = start + 2;
    var brace_count: usize = 1;
    while (end < value.len) {
        if (value[end] == '{') {
            brace_count += 1;
        } else if (value[end] == '}') {
            brace_count -= 1;
            if (brace_count == 0) break;
        }
        end += 1;
    }
    if (brace_count != 0) return null;

    const id = value[start .. end + 1];
    const inner = value[start + 2 .. end];
    if (std.mem.indexOfScalar(u8, inner, ':')) |colon| {
        return .{
            .replacement = .{
                .id = id,
                .inner = inner,
                .name = inner[0..colon],
                .arg = inner[colon + 1 ..],
            },
            .end = end,
        };
    }
    return .{ .replacement = .{ .id = id, .inner = inner, .name = inner }, .end = end };
}

/// Scans backwards for a variable with a matching closing brace in linear time
/// and constant space.
pub fn hasConfigurationVariable(value: []const u8) bool {
    var unmatched_closing_braces: usize = 0;
    var offset = value.len;
    while (offset > 0) {
        offset -= 1;
        if (value[offset] == '}') {
            unmatched_closing_braces += 1;
        } else if (value[offset] == '{' and unmatched_closing_braces > 0) {
            unmatched_closing_braces -= 1;
            if (offset > 0 and value[offset - 1] == '$') return true;
        }
    }
    return false;
}
