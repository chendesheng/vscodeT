// Port of `src/vs/workbench/contrib/extensions/common/extensionQuery.ts`.
//
// Terminal adaptation: suggestions expose the query capabilities implemented
// by the terminal gallery and local views. Unsupported specialized views and
// the unported feature registry are not advertised in the search picker.
const std = @import("std");

pub const Query = struct {
    value: []u8,
    sort_by: []u8,

    /// Query.suggestions keeps duplicate commands and a second completed
    /// category/sort modifier out of the suggestion model. The caller owns
    /// the strings (a picker-owned arena is convenient).
    pub fn suggestions(allocator: std.mem.Allocator, query: []const u8, has_gallery: bool) ![][]const u8 {
        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |item| allocator.free(item);
            result.deinit(allocator);
        }
        for ([_][]const u8{ "installed", "updates", "enabled", "disabled", "builtin", "popular", "recommended", "recentlyUpdated", "restartRequired" }) |command| {
            if (!has_gallery and (std.mem.eql(u8, command, "popular") or std.mem.eql(u8, command, "recommended") or std.mem.eql(u8, command, "updates"))) continue;
            var buffer: [64]u8 = undefined;
            const token = try std.fmt.bufPrint(&buffer, "@{s}", .{command});
            if (std.mem.indexOf(u8, query, token) != null) continue;
            try result.ensureUnusedCapacity(allocator, 1);
            result.appendAssumeCapacity(try std.fmt.allocPrint(allocator, "{s} ", .{token}));
        }
        const sort = [_][]const u8{ "installs", "rating", "name", "publishedDate", "updateDate" };
        var has_sort = false;
        for (sort) |name| {
            var buffer: [64]u8 = undefined;
            const token = try std.fmt.bufPrint(&buffer, "@sort:{s}", .{name});
            if (std.mem.indexOf(u8, query, token) != null) has_sort = true;
        }
        if (!has_sort) for (sort) |name| {
            if (!has_gallery and (std.mem.eql(u8, name, "installs") or std.mem.eql(u8, name, "rating") or std.mem.eql(u8, name, "publishedDate"))) continue;
            try result.ensureUnusedCapacity(allocator, 1);
            result.appendAssumeCapacity(try std.fmt.allocPrint(allocator, "@sort:{s} ", .{name}));
        };
        if (std.mem.indexOf(u8, query, "@category:") == null and std.mem.indexOf(u8, query, "category:") == null) {
            for ([_][]const u8{ "ai", "azure", "chat", "data science", "debuggers", "extension packs", "education", "formatters", "keymaps", "language packs", "linters", "machine learning", "notebooks", "programming languages", "scm providers", "snippets", "testing", "themes", "visualization", "other" }) |category| {
                try result.ensureUnusedCapacity(allocator, 1);
                result.appendAssumeCapacity(try std.fmt.allocPrint(allocator, "@category:\"{s}\" ", .{category}));
            }
        }
        try result.ensureUnusedCapacity(allocator, 1);
        result.appendAssumeCapacity(try allocator.dupe(u8, "@id:"));
        return result.toOwnedSlice(allocator);
    }

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
