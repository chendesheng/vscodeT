// Port of `src/vs/workbench/contrib/extensions/common/extensionQuery.ts`.
//
// Terminal adaptation: `Query.suggestions` needs the extension gallery
// manifest and the extension-feature registry, neither of which is ported, so
// the search box has no autocomplete. `isValid`/`containsMcpTerm`/`equals`
// keep the upstream behavior.
const std = @import("std");

pub const Query = struct {
    value: []u8,
    sort_by: []u8,

    pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Query {
        var sort_by: []const u8 = "";
        var cleaned: std.array_list.Managed(u8) = .init(allocator);
        errdefer cleaned.deinit();

        var index: usize = 0;
        while (index < input.len) {
            if (startsWithIgnoreCase(input[index..], "@sort:")) {
                const token_start = index + "@sort:".len;
                var end = token_start;
                while (end < input.len and isWordChar(input[end])) : (end += 1) {}
                if (end > token_start) {
                    sort_by = input[token_start..end];
                    index = end;
                    // `@sort:<name>-<order>` consumes the optional order part.
                    if (index < input.len and input[index] == '-') {
                        index += 1;
                        while (index < input.len and isWordChar(input[index])) : (index += 1) {}
                    }
                    continue;
                }
            }
            try cleaned.append(input[index]);
            index += 1;
        }

        const trimmed = std.mem.trim(u8, cleaned.items, " \t\r\n");
        const value = try allocator.dupe(u8, trimmed);
        errdefer allocator.free(value);
        const owned_sort = try allocator.dupe(u8, sort_by);
        cleaned.deinit();
        return .{ .value = value, .sort_by = owned_sort };
    }

    pub fn init(allocator: std.mem.Allocator, value: []const u8, sort_by: []const u8) !Query {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        const owned_value = try allocator.dupe(u8, trimmed);
        errdefer allocator.free(owned_value);
        return .{ .value = owned_value, .sort_by = try allocator.dupe(u8, sort_by) };
    }

    pub fn deinit(self: *Query, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
        allocator.free(self.sort_by);
    }

    pub fn toString(self: *const Query, allocator: std.mem.Allocator) ![]u8 {
        if (self.sort_by.len == 0) return allocator.dupe(u8, self.value);
        return std.fmt.allocPrint(allocator, "{s}{s}@sort:{s}", .{
            self.value,
            if (self.value.len > 0) " " else "",
            self.sort_by,
        });
    }

    pub fn isValid(self: *const Query) bool {
        return std.mem.indexOf(u8, self.value, "@outdated") == null;
    }

    /// `/(^|[^a-z0-9_])mcp($|[^a-z0-9_])/i`
    pub fn containsMcpTerm(self: *const Query) bool {
        var index: usize = 0;
        while (index + 3 <= self.value.len) : (index += 1) {
            if (!std.ascii.eqlIgnoreCase(self.value[index .. index + 3], "mcp")) continue;
            const before_ok = index == 0 or !isWordChar(self.value[index - 1]);
            const after = index + 3;
            const after_ok = after == self.value.len or !isWordChar(self.value[after]);
            if (before_ok and after_ok) return true;
        }
        return false;
    }

    pub fn equals(self: *const Query, other: *const Query) bool {
        return std.mem.eql(u8, self.value, other.value) and std.mem.eql(u8, self.sort_by, other.sort_by);
    }
};

fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}
