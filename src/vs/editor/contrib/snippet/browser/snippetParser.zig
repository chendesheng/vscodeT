// Port of `src/vs/editor/contrib/snippet/browser/snippetParser.ts`.
//
// The parser builds the upstream marker tree: Text, Placeholder, Choice,
// Variable, Transform, FormatString and TextmateSnippet. Markers are allocated
// in the snippet arena; the snippet owns the arena and every compiled transform
// regexp. `SnippetParser.parse` is the terminal-side entry point used by the
// snippet session and by the suggest acceptance path.
//
// Unicode case mapping for the case transforms is ASCII-only, matching the
// documented limitation in `src/vs/base/common/search.zig`. Word boundaries and
// the transform regexp itself are evaluated by Oniguruma (`\p{L}` etc.).

const std = @import("std");
const Allocator = std.mem.Allocator;
const regexp = @import("../../../../../support/regexp.zig");

pub const SnippetError = Allocator.Error || regexp.Error;

pub const TokenType = enum {
    dollar,
    colon,
    comma,
    curly_open,
    curly_close,
    backslash,
    forwardslash,
    pipe,
    int,
    variable_name,
    format,
    plus,
    dash,
    question,
    eof,
};

pub const Token = struct {
    type: TokenType,
    pos: usize,
    len: usize,
};

pub const Scanner = struct {
    value: []const u8 = "",
    pos: usize = 0,

    pub fn text(self: *Scanner, value: []const u8) void {
        self.value = value;
        self.pos = 0;
    }

    pub fn tokenText(self: *const Scanner, token: Token) []const u8 {
        return self.value[token.pos .. token.pos + token.len];
    }

    pub fn isDigitCharacter(ch: u8) bool {
        return ch >= '0' and ch <= '9';
    }

    pub fn isVariableCharacter(ch: u8) bool {
        return ch == '_' or (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
    }

    pub fn next(self: *Scanner) Token {
        if (self.pos >= self.value.len) {
            return .{ .type = .eof, .pos = self.pos, .len = 0 };
        }

        const pos = self.pos;
        const ch = self.value[pos];
        const static_type: ?TokenType = switch (ch) {
            '$' => .dollar,
            ':' => .colon,
            ',' => .comma,
            '{' => .curly_open,
            '}' => .curly_close,
            '\\' => .backslash,
            '/' => .forwardslash,
            '|' => .pipe,
            '+' => .plus,
            '-' => .dash,
            '?' => .question,
            else => null,
        };
        if (static_type) |t| {
            self.pos += 1;
            return .{ .type = t, .pos = pos, .len = 1 };
        }

        if (isDigitCharacter(ch)) {
            var len: usize = 1;
            while (pos + len < self.value.len and isDigitCharacter(self.value[pos + len])) len += 1;
            self.pos += len;
            return .{ .type = .int, .pos = pos, .len = len };
        }

        if (isVariableCharacter(ch)) {
            var len: usize = 1;
            while (pos + len < self.value.len and
                (isVariableCharacter(self.value[pos + len]) or isDigitCharacter(self.value[pos + len])))
            {
                len += 1;
            }
            self.pos += len;
            return .{ .type = .variable_name, .pos = pos, .len = len };
        }

        var len: usize = 1;
        while (pos + len < self.value.len) {
            const next_ch = self.value[pos + len];
            if (isStatic(next_ch) or isDigitCharacter(next_ch) or isVariableCharacter(next_ch)) break;
            len += 1;
        }
        self.pos += len;
        return .{ .type = .format, .pos = pos, .len = len };
    }

    fn isStatic(ch: u8) bool {
        return switch (ch) {
            '$', ':', ',', '{', '}', '\\', '/', '|', '+', '-', '?' => true,
            else => false,
        };
    }
};

pub const MarkerKind = enum {
    text,
    placeholder,
    choice,
    variable,
    transform,
    format_string,
    snippet,
};

pub const TextmateSnippet = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    root: Marker,
    regexps: std.ArrayListUnmanaged(*regexp.RegExp) = .empty,
    placeholder_cache: ?PlaceholderInfo = null,

    pub const PlaceholderInfo = struct {
        all: []*Marker,
        last: ?*Marker,
    };

    pub fn init(allocator: Allocator) !*TextmateSnippet {
        const self = try allocator.create(TextmateSnippet);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .root = undefined,
        };
        const arena = self.arena.allocator();
        self.root = .{
            .kind = .snippet,
            .allocator = arena,
            .snippet = self,
        };
        return self;
    }

    pub fn deinit(self: *TextmateSnippet) void {
        for (self.regexps.items) |re| {
            re.deinit();
            self.allocator.destroy(re);
        }
        self.regexps.deinit(self.allocator);
        const allocator = self.allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }

    pub fn arenaAllocator(self: *TextmateSnippet) Allocator {
        return self.arena.allocator();
    }

    pub fn create(self: *TextmateSnippet, kind: MarkerKind) !*Marker {
        const marker = try self.arenaAllocator().create(Marker);
        marker.* = .{
            .kind = kind,
            .allocator = self.arenaAllocator(),
            .snippet = self,
        };
        return marker;
    }

    pub fn newText(self: *TextmateSnippet, value: []const u8) !*Marker {
        const marker = try self.create(.text);
        marker.value = try self.arenaAllocator().dupe(u8, value);
        return marker;
    }

    pub fn newPlaceholder(self: *TextmateSnippet, index: f64) !*Marker {
        const marker = try self.create(.placeholder);
        marker.index = index;
        return marker;
    }

    pub fn newVariable(self: *TextmateSnippet, name: []const u8) !*Marker {
        const marker = try self.create(.variable);
        marker.name = try self.arenaAllocator().dupe(u8, name);
        return marker;
    }

    pub fn newFormatString(
        self: *TextmateSnippet,
        index: usize,
        shorthand_name: ?[]const u8,
        if_value: ?[]const u8,
        else_value: ?[]const u8,
    ) !*Marker {
        const marker = try self.create(.format_string);
        marker.index = @floatFromInt(index);
        marker.shorthand_name = if (shorthand_name) |value| try self.arenaAllocator().dupe(u8, value) else null;
        marker.if_value = if (if_value) |value| try self.arenaAllocator().dupe(u8, value) else null;
        marker.else_value = if (else_value) |value| try self.arenaAllocator().dupe(u8, value) else null;
        return marker;
    }

    pub fn compileRegex(self: *TextmateSnippet, source: []const u8, options: []const u8) SnippetError!*regexp.RegExp {
        const re = try self.allocator.create(regexp.RegExp);
        errdefer self.allocator.destroy(re);
        re.* = try regexp.RegExp.init(source, regexOptions(options));
        errdefer re.deinit();
        try self.regexps.append(self.allocator, re);
        return re;
    }

    pub fn appendChild(self: *TextmateSnippet, child: *Marker) !void {
        self.placeholder_cache = null;
        try self.root.appendChild(child);
    }

    pub fn replace(self: *TextmateSnippet, child: *Marker, others: []const *Marker) !void {
        self.placeholder_cache = null;
        try self.root.replace(child, others);
    }

    pub fn children(self: *const TextmateSnippet) []*Marker {
        return self.root.children.items;
    }

    pub fn placeholderInfo(self: *TextmateSnippet) !PlaceholderInfo {
        if (self.placeholder_cache) |info| return info;
        var all = std.ArrayListUnmanaged(*Marker).empty;
        var last: ?*Marker = null;
        for (try self.walkArena()) |marker| {
            if (marker.kind == .placeholder) {
                try all.append(self.arenaAllocator(), marker);
                if (last == null or last.?.index < marker.index) last = marker;
            }
        }
        self.placeholder_cache = .{ .all = all.items, .last = last };
        return self.placeholder_cache.?;
    }

    /// Pre-order traversal, matching upstream `TextmateSnippet.walk`. The
    /// returned list is arena-owned and lives as long as the snippet.
    pub fn walkArena(self: *TextmateSnippet) ![]*Marker {
        var stack = std.ArrayListUnmanaged(*Marker).empty;
        var result = std.ArrayListUnmanaged(*Marker).empty;
        for (self.children()) |child| try stack.append(self.arenaAllocator(), child);
        while (stack.items.len > 0) {
            const marker = stack.orderedRemove(0);
            try result.append(self.arenaAllocator(), marker);
            var index = marker.children.items.len;
            while (index > 0) {
                index -= 1;
                try stack.insert(self.arenaAllocator(), 0, marker.children.items[index]);
            }
        }
        return result.items;
    }

    pub fn placeholders(self: *TextmateSnippet) ![]*Marker {
        return (try self.placeholderInfo()).all;
    }

    pub fn offset(self: *TextmateSnippet, marker: *Marker) isize {
        var pos: usize = 0;
        var found = false;
        var stack = std.ArrayListUnmanaged(*Marker).empty;
        defer stack.deinit(self.arenaAllocator());
        for (self.children()) |child| stack.append(self.arenaAllocator(), child) catch return -1;
        while (stack.items.len > 0) {
            const candidate = stack.orderedRemove(0);
            if (candidate == marker) {
                found = true;
                break;
            }
            pos += candidate.len();
            var index = candidate.children.items.len;
            while (index > 0) {
                index -= 1;
                stack.insert(self.arenaAllocator(), 0, candidate.children.items[index]) catch return -1;
            }
        }
        return if (found) @intCast(pos) else -1;
    }

    pub fn fullLen(self: *TextmateSnippet, marker: *Marker) usize {
        _ = self;
        var ret: usize = 0;
        var stack = std.ArrayListUnmanaged(*Marker).empty;
        defer stack.deinit(marker.allocator);
        stack.append(marker.allocator, marker) catch return ret;
        while (stack.items.len > 0) {
            const candidate = stack.pop().?;
            ret += candidate.len();
            for (candidate.children.items) |child| stack.append(marker.allocator, child) catch return ret;
        }
        return ret;
    }

    pub fn enclosingPlaceholders(self: *TextmateSnippet, placeholder: *Marker) ![]*Marker {
        var ret = std.ArrayListUnmanaged(*Marker).empty;
        var parent = placeholder.parent;
        while (parent) |marker| {
            if (marker.kind == .placeholder) try ret.append(self.arenaAllocator(), marker);
            parent = marker.parent;
        }
        return self.arenaAllocator().dupe(*Marker, ret.items);
    }

    pub fn resolveVariables(self: *TextmateSnippet, resolver: VariableResolver) !void {
        var resolved = false;
        for (try self.walkArena()) |marker| {
            if (marker.kind == .variable) {
                if (try marker.resolveVariable(resolver)) resolved = true;
            }
        }
        if (resolved) self.placeholder_cache = null;
    }

    pub fn toTextmateString(self: *TextmateSnippet, allocator: Allocator) Allocator.Error![]u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(allocator);
        for (self.children()) |child| {
            const value = try child.toTextmateString(allocator);
            defer allocator.free(value);
            try out.appendSlice(allocator, value);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn clone(self: *TextmateSnippet) SnippetError!*TextmateSnippet {
        const result = try TextmateSnippet.init(self.allocator);
        errdefer result.deinit();
        for (self.children()) |child| {
            try result.appendChild(try child.cloneInto(result));
        }
        return result;
    }

    pub fn toString(self: *TextmateSnippet, allocator: Allocator) Allocator.Error![]u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(allocator);
        for (self.children()) |child| {
            const value = try child.toString(allocator);
            defer allocator.free(value);
            try out.appendSlice(allocator, value);
        }
        return out.toOwnedSlice(allocator);
    }
};

pub const Marker = struct {
    kind: MarkerKind,
    parent: ?*Marker = null,
    children: std.ArrayListUnmanaged(*Marker) = .empty,
    options: std.ArrayListUnmanaged(*Marker) = .empty,
    value: []const u8 = "",
    index: f64 = 0,
    name: []const u8 = "",
    transform: ?*Transform = null,
    shorthand_name: ?[]const u8 = null,
    if_value: ?[]const u8 = null,
    else_value: ?[]const u8 = null,
    allocator: Allocator,
    snippet: ?*TextmateSnippet = null,

    pub fn isFinalTabstop(self: *const Marker) bool {
        return self.index == 0;
    }

    pub fn choice(self: *const Marker) ?*Marker {
        if (self.children.items.len == 1 and self.children.items[0].kind == .choice) {
            return self.children.items[0];
        }
        return null;
    }

    pub fn appendChild(self: *Marker, child: *Marker) !void {
        if (self.kind == .choice) {
            if (child.kind == .text) {
                child.parent = self;
                try self.options.append(self.allocator, child);
            }
            return;
        }
        if (child.kind == .text and self.children.items.len > 0) {
            const last = self.children.items[self.children.items.len - 1];
            if (last.kind == .text) {
                last.value = try std.mem.concat(self.allocator, u8, &.{ last.value, child.value });
                return;
            }
        }
        child.parent = self;
        try self.children.append(self.allocator, child);
    }

    pub fn replace(self: *Marker, child: *Marker, others: []const *Marker) !void {
        _ = self;
        const parent = child.parent orelse return;
        var index: usize = 0;
        while (index < parent.children.items.len and parent.children.items[index] != child) index += 1;
        if (index == parent.children.items.len) return;

        var new_children = std.ArrayListUnmanaged(*Marker).empty;
        errdefer new_children.deinit(parent.allocator);
        try new_children.appendSlice(parent.allocator, parent.children.items[0..index]);
        try new_children.appendSlice(parent.allocator, others);
        try new_children.appendSlice(parent.allocator, parent.children.items[index + 1 ..]);

        parent.children.deinit(parent.allocator);
        parent.children = new_children;
        for (others) |other| try parent.fixParent(other);
    }

    fn fixParent(self: *Marker, child: *Marker) !void {
        child.parent = self;
        for (child.children.items) |nested| try child.fixParent(nested);
    }

    pub fn rightMostDescendant(self: *Marker) *Marker {
        var marker = self;
        while (marker.children.items.len > 0) {
            marker = marker.children.items[marker.children.items.len - 1];
        }
        return marker;
    }

    pub fn len(self: *const Marker) usize {
        return switch (self.kind) {
            .text => self.value.len,
            .choice => if (self.options.items.len > 0) self.options.items[0].len() else 0,
            else => 0,
        };
    }

    pub fn toString(self: *const Marker, allocator: Allocator) Allocator.Error![]u8 {
        switch (self.kind) {
            .text => return allocator.dupe(u8, self.value),
            .choice => {
                if (self.options.items.len == 0) return allocator.dupe(u8, "");
                return self.options.items[0].toString(allocator);
            },
            .transform, .format_string => return allocator.dupe(u8, ""),
            else => {},
        }
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(allocator);
        for (self.children.items) |child| {
            const value = try child.toString(allocator);
            defer allocator.free(value);
            try out.appendSlice(allocator, value);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn toTextmateString(self: *const Marker, allocator: Allocator) Allocator.Error![]u8 {
        switch (self.kind) {
            .text => {
                var out = std.ArrayListUnmanaged(u8).empty;
                errdefer out.deinit(allocator);
                for (self.value) |ch| {
                    if (ch == '$' or ch == '}' or ch == '\\') try out.append(allocator, '\\');
                    try out.append(allocator, ch);
                }
                return out.toOwnedSlice(allocator);
            },
            .placeholder => {
                var out = std.ArrayListUnmanaged(u8).empty;
                errdefer out.deinit(allocator);
                if (self.children.items.len == 0 and self.transform == null) {
                    try appendIndex(&out, allocator, self.index, "$");
                    return out.toOwnedSlice(allocator);
                }
                try out.appendSlice(allocator, "${");
                try appendIndex(&out, allocator, self.index, "");
                if (self.children.items.len == 0) {
                    if (self.transform) |transform| {
                        const value = try transform.toTextmateString(allocator);
                        defer allocator.free(value);
                        try out.appendSlice(allocator, value);
                    }
                    try out.append(allocator, '}');
                    return out.toOwnedSlice(allocator);
                }
                if (self.choice()) |choice_marker| {
                    try out.append(allocator, '|');
                    const value = try choice_marker.toTextmateString(allocator);
                    defer allocator.free(value);
                    try out.appendSlice(allocator, value);
                    try out.append(allocator, '|');
                    if (self.transform) |transform| {
                        const transform_value = try transform.toTextmateString(allocator);
                        defer allocator.free(transform_value);
                        try out.appendSlice(allocator, transform_value);
                    }
                    try out.append(allocator, '}');
                    return out.toOwnedSlice(allocator);
                }
                try out.append(allocator, ':');
                for (self.children.items) |child| {
                    const value = try child.toTextmateString(allocator);
                    defer allocator.free(value);
                    try out.appendSlice(allocator, value);
                }
                if (self.transform) |transform| {
                    const value = try transform.toTextmateString(allocator);
                    defer allocator.free(value);
                    try out.appendSlice(allocator, value);
                }
                try out.append(allocator, '}');
                return out.toOwnedSlice(allocator);
            },
            .choice => {
                var out = std.ArrayListUnmanaged(u8).empty;
                errdefer out.deinit(allocator);
                for (self.options.items, 0..) |option, index| {
                    if (index > 0) try out.append(allocator, ',');
                    for (option.value) |ch| {
                        if (ch == '|' or ch == ',' or ch == '\\') try out.append(allocator, '\\');
                        try out.append(allocator, ch);
                    }
                }
                return out.toOwnedSlice(allocator);
            },
            .variable => {
                var out = std.ArrayListUnmanaged(u8).empty;
                errdefer out.deinit(allocator);
                try out.appendSlice(allocator, "${");
                try out.appendSlice(allocator, self.name);
                if (self.children.items.len == 0) {
                    if (self.transform) |transform| {
                        const value = try transform.toTextmateString(allocator);
                        defer allocator.free(value);
                        try out.appendSlice(allocator, value);
                    }
                } else {
                    try out.append(allocator, ':');
                    for (self.children.items) |child| {
                        const value = try child.toTextmateString(allocator);
                        defer allocator.free(value);
                        try out.appendSlice(allocator, value);
                    }
                    if (self.transform) |transform| {
                        const value = try transform.toTextmateString(allocator);
                        defer allocator.free(value);
                        try out.appendSlice(allocator, value);
                    }
                }
                try out.append(allocator, '}');
                return out.toOwnedSlice(allocator);
            },
            .format_string => {
                var out = std.ArrayListUnmanaged(u8).empty;
                errdefer out.deinit(allocator);
                try out.appendSlice(allocator, "${");
                try appendIndex(&out, allocator, self.index, "");
                if (self.shorthand_name) |shorthand| {
                    try out.appendSlice(allocator, ":/");
                    try out.appendSlice(allocator, shorthand);
                } else if (self.if_value != null and self.else_value != null) {
                    try out.appendSlice(allocator, ":?");
                    try out.appendSlice(allocator, self.if_value.?);
                    try out.append(allocator, ':');
                    try out.appendSlice(allocator, self.else_value.?);
                } else if (self.if_value) |value| {
                    try out.appendSlice(allocator, ":+");
                    try out.appendSlice(allocator, value);
                } else if (self.else_value) |value| {
                    try out.appendSlice(allocator, ":-");
                    try out.appendSlice(allocator, value);
                }
                try out.append(allocator, '}');
                return out.toOwnedSlice(allocator);
            },
            .snippet => {
                var out = std.ArrayListUnmanaged(u8).empty;
                errdefer out.deinit(allocator);
                for (self.children.items) |child| {
                    const value = try child.toTextmateString(allocator);
                    defer allocator.free(value);
                    try out.appendSlice(allocator, value);
                }
                return out.toOwnedSlice(allocator);
            },
            .transform => return allocator.dupe(u8, ""),
        }
    }

    pub fn clone(self: *const Marker) SnippetError!*Marker {
        const snippet = self.snippet orelse unreachable;
        return self.cloneInto(snippet);
    }

    /// Clones this marker (and its subtree) into another snippet. Used when a
    /// nested snippet is merged into its parent snippet.
    pub fn cloneInto(self: *const Marker, destination: *TextmateSnippet) SnippetError!*Marker {
        const allocator = destination.arenaAllocator();
        const result = try allocator.create(Marker);
        result.* = .{
            .kind = self.kind,
            .allocator = allocator,
            .snippet = destination,
        };
        switch (self.kind) {
            .text => result.value = try allocator.dupe(u8, self.value),
            .placeholder, .variable => {
                result.index = self.index;
                result.name = try allocator.dupe(u8, self.name);
                if (self.transform) |transform| result.transform = try transform.cloneFor(destination);
            },
            .choice => {
                for (self.options.items) |option| try result.appendChild(try option.cloneInto(destination));
            },
            .format_string => {
                result.index = self.index;
                result.shorthand_name = if (self.shorthand_name) |value| try allocator.dupe(u8, value) else null;
                result.if_value = if (self.if_value) |value| try allocator.dupe(u8, value) else null;
                result.else_value = if (self.else_value) |value| try allocator.dupe(u8, value) else null;
            },
            .snippet, .transform => {},
        }
        for (self.children.items) |child| try result.appendChild(try child.cloneInto(destination));
        return result;
    }

    pub fn resolveVariable(self: *Marker, resolver: VariableResolver) !bool {
        const value = try resolver.resolve(resolver.context, self.snippet.?.arenaAllocator(), self);
        if (value) |resolved| {
            var transformed = resolved;
            if (self.transform) |transform| {
                transformed = try transform.resolve(self.snippet.?.arenaAllocator(), resolved);
            }
            self.children.deinit(self.allocator);
            self.children = .empty;
            const text = try self.snippet.?.newText(transformed);
            try self.appendChild(text);
            return true;
        }
        return false;
    }

    pub fn resolveFormatString(self: *const Marker, allocator: Allocator, value: ?[]const u8) Allocator.Error![]u8 {
        const input = value orelse "";
        if (self.shorthand_name) |shorthand| {
            if (input.len == 0) return allocator.dupe(u8, "");
            if (std.mem.eql(u8, shorthand, "upcase")) return mapCase(allocator, input, .upper);
            if (std.mem.eql(u8, shorthand, "downcase")) return mapCase(allocator, input, .lower);
            if (std.mem.eql(u8, shorthand, "capitalize")) {
                var out = try allocator.dupe(u8, input);
                if (out.len > 0) out[0] = std.ascii.toUpper(out[0]);
                return out;
            }
            if (std.mem.eql(u8, shorthand, "pascalcase")) return toPascalCase(allocator, input);
            if (std.mem.eql(u8, shorthand, "camelcase")) return toCamelCase(allocator, input);
            if (std.mem.eql(u8, shorthand, "kebabcase")) return toKebabCase(allocator, input);
            if (std.mem.eql(u8, shorthand, "snakecase")) return toSnakeCase(allocator, input);
            return allocator.dupe(u8, input);
        }
        if (input.len > 0 and self.if_value != null) return allocator.dupe(u8, self.if_value.?);
        if (input.len == 0 and self.else_value != null) return allocator.dupe(u8, self.else_value.?);
        return allocator.dupe(u8, input);
    }
};

pub const Transform = struct {
    regexp: *regexp.RegExp,
    regex_source: []const u8,
    options: []const u8,
    global: bool,
    ignore_case: bool,
    children: std.ArrayListUnmanaged(*Marker) = .empty,
    allocator: Allocator,

    pub fn appendChild(self: *Transform, child: *Marker) !void {
        child.parent = null;
        try self.children.append(self.allocator, child);
    }

    pub fn cloneFor(self: *const Transform, snippet: ?*TextmateSnippet) SnippetError!*Transform {
        const owner = snippet orelse unreachable;
        const result = try owner.arenaAllocator().create(Transform);
        result.* = .{
            .regexp = try owner.compileRegex(self.regex_source, self.options),
            .regex_source = try owner.arenaAllocator().dupe(u8, self.regex_source),
            .options = try owner.arenaAllocator().dupe(u8, self.options),
            .global = self.global,
            .ignore_case = self.ignore_case,
            .allocator = owner.arenaAllocator(),
        };
        for (self.children.items) |child| try result.appendChild(try child.clone());
        return result;
    }

    pub fn resolve(self: *const Transform, allocator: Allocator, value: []const u8) ![]u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(allocator);

        var did_match = false;
        var last: usize = 0;
        var search_start: usize = 0;
        while (search_start <= value.len) {
            const result = self.regexp.searchFrom(value, search_start) orelse break;
            defer result.deinit();
            did_match = true;
            try out.appendSlice(allocator, value[last..result.index()]);
            try self.replace(allocator, &out, &result);
            last = @min(value.len, result.index() + result.length());
            if (result.length() == 0) {
                if (last < value.len) {
                    const len = std.unicode.utf8ByteSequenceLength(value[last]) catch 1;
                    const end = @min(value.len, last + len);
                    try out.appendSlice(allocator, value[last..end]);
                    last = end;
                }
                search_start = last;
            } else {
                search_start = last;
            }
            if (!self.global) break;
            if (last >= value.len) break;
        }

        if (!did_match) {
            var has_else = false;
            for (self.children.items) |child| {
                if (child.kind == .format_string) {
                    if (child.else_value) |else_value| {
                        if (else_value.len > 0) has_else = true;
                    }
                }
            }
            if (!has_else) return allocator.dupe(u8, value);
            try self.replace(allocator, &out, null);
            return out.toOwnedSlice(allocator);
        }

        try out.appendSlice(allocator, value[last..]);
        return out.toOwnedSlice(allocator);
    }

    fn replace(self: *const Transform, allocator: Allocator, out: *std.ArrayListUnmanaged(u8), result: ?*const regexp.SearchResult) !void {
        for (self.children.items) |child| {
            if (child.kind == .format_string) {
                if (result) |match| {
                    const index: usize = @intFromFloat(child.index);
                    const group = if (index < match.numberOfGroups()) (match.groupNOrNull(index) orelse "") else "";
                    const value = try child.resolveFormatString(allocator, group);
                    defer allocator.free(value);
                    try out.appendSlice(allocator, value);
                } else {
                    const value = try child.resolveFormatString(allocator, "");
                    defer allocator.free(value);
                    try out.appendSlice(allocator, value);
                }
            } else {
                const value = try child.toString(allocator);
                defer allocator.free(value);
                try out.appendSlice(allocator, value);
            }
        }
    }

    pub fn toString(self: *const Transform, allocator: Allocator) ![]u8 {
        _ = self;
        return allocator.dupe(u8, "");
    }

    pub fn toTextmateString(self: *const Transform, allocator: Allocator) Allocator.Error![]u8 {
        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(allocator);
        try out.append(allocator, '/');
        try out.appendSlice(allocator, self.regex_source);
        try out.append(allocator, '/');
        for (self.children.items) |child| {
            const value = try child.toTextmateString(allocator);
            defer allocator.free(value);
            try out.appendSlice(allocator, value);
        }
        try out.append(allocator, '/');
        if (self.ignore_case) try out.append(allocator, 'i');
        if (self.global) try out.append(allocator, 'g');
        return out.toOwnedSlice(allocator);
    }
};

pub const VariableResolver = struct {
    context: *anyopaque,
    resolve: *const fn (context: *anyopaque, allocator: Allocator, variable: *const Marker) anyerror!?[]u8,
};

pub const SnippetParser = struct {
    scanner: Scanner = .{},
    token: Token = .{ .type = .eof, .pos = 0, .len = 0 },
    snippet: ?*TextmateSnippet = null,

    pub fn parse(
        self: *SnippetParser,
        snippet: *TextmateSnippet,
        value: []const u8,
        insert_final_tabstop: bool,
        enforce_final_tabstop: bool,
    ) !void {
        _ = try self.parseFragment(snippet, value);
        try self.ensureFinalTabstop(snippet, enforce_final_tabstop, insert_final_tabstop);
    }

    pub fn parseFragment(self: *SnippetParser, snippet: *TextmateSnippet, value: []const u8) ![]const *Marker {
        const offset = snippet.children().len;
        self.snippet = snippet;
        self.scanner.text(value);
        self.token = self.scanner.next();
        while (try self.parseOne(&snippet.root)) {}

        var placeholder_default_values = std.AutoHashMap(u64, []const *Marker).init(snippet.arenaAllocator());
        defer placeholder_default_values.deinit();
        var incomplete = std.ArrayListUnmanaged(*Marker).empty;
        defer incomplete.deinit(snippet.arenaAllocator());

        for (try snippet.walkArena()) |marker| {
            if (marker.kind != .placeholder) continue;
            if (marker.isFinalTabstop()) {
                // Defined final tabstop; no default value.
            } else if (!placeholder_default_values.contains(indexKey(marker.index)) and marker.children.items.len > 0) {
                try placeholder_default_values.put(indexKey(marker.index), try snippet.arenaAllocator().dupe(*Marker, marker.children.items));
            } else {
                try incomplete.append(snippet.arenaAllocator(), marker);
            }
        }

        var stack = std.AutoHashMap(u64, void).init(snippet.arenaAllocator());
        defer stack.deinit();
        for (incomplete.items) |placeholder| {
            try fillIncompletePlaceholder(snippet, placeholder, &placeholder_default_values, &stack);
        }

        return snippet.children()[offset..];
    }

    pub fn ensureFinalTabstop(self: *SnippetParser, snippet: *TextmateSnippet, enforce_final_tabstop: bool, insert_final_tabstop: bool) !void {
        _ = self;
        if (enforce_final_tabstop or (insert_final_tabstop and (try snippet.placeholders()).len > 0)) {
            var has_final = false;
            for (try snippet.placeholders()) |placeholder| {
                if (placeholder.index == 0) {
                    has_final = true;
                    break;
                }
            }
            if (!has_final) {
                try snippet.appendChild(try snippet.newPlaceholder(0));
            }
        }
    }

    fn allocator(self: *SnippetParser) Allocator {
        return self.snippet.?.arenaAllocator();
    }

    fn accept(self: *SnippetParser, token_type: TokenType) bool {
        if (self.token.type != token_type) return false;
        self.token = self.scanner.next();
        return true;
    }

    fn acceptText(self: *SnippetParser, token_type: TokenType) ?[]const u8 {
        if (self.token.type != token_type) return null;
        const value = self.scanner.tokenText(self.token);
        self.token = self.scanner.next();
        return value;
    }

    fn acceptAnyText(self: *SnippetParser) ?[]const u8 {
        if (self.token.type == .eof) return null;
        const value = self.scanner.tokenText(self.token);
        self.token = self.scanner.next();
        return value;
    }

    fn backTo(self: *SnippetParser, token: Token) bool {
        self.scanner.pos = token.pos + token.len;
        self.token = token;
        return false;
    }

    fn until(self: *SnippetParser, token_type: TokenType) ?[]const u8 {
        const start = self.token;
        while (self.token.type != token_type) {
            if (self.token.type == .eof) return null;
            if (self.token.type == .backslash) {
                const next_token = self.scanner.next();
                if (next_token.type != .dollar and next_token.type != .curly_close and next_token.type != .backslash) {
                    return null;
                }
            }
            self.token = self.scanner.next();
        }
        const raw = self.scanner.value[start.pos..self.token.pos];
        self.token = self.scanner.next();
        return unescape(raw, self.allocator()) catch null;
    }

    fn parseOne(self: *SnippetParser, parent: *Marker) Allocator.Error!bool {
        if (try self.parseEscaped(parent)) return true;
        if (try self.parseTabstopOrVariableName(parent)) return true;
        if (try self.parseComplexPlaceholder(parent)) return true;
        if (try self.parseComplexVariable(parent)) return true;
        return self.parseAnything(parent);
    }

    fn parseEscaped(self: *SnippetParser, parent: *Marker) Allocator.Error!bool {
        const value = self.acceptText(.backslash) orelse return false;
        var result: []const u8 = value;
        if (self.acceptText(.dollar)) |v| {
            result = v;
        } else if (self.acceptText(.curly_close)) |v| {
            result = v;
        } else if (self.acceptText(.backslash)) |v| {
            result = v;
        }
        try parent.appendChild(try self.snippet.?.newText(result));
        return true;
    }

    fn parseTabstopOrVariableName(self: *SnippetParser, parent: *Marker) Allocator.Error!bool {
        const token = self.token;
        if (!self.accept(.dollar)) return self.backTo(token);
        const value = self.acceptText(.variable_name) orelse self.acceptText(.int) orelse return self.backTo(token);
        if (isAllDigits(value)) {
            try parent.appendChild(try self.snippet.?.newPlaceholder(@floatFromInt(std.fmt.parseInt(usize, value, 10) catch 0)));
        } else {
            try parent.appendChild(try self.snippet.?.newVariable(value));
        }
        return true;
    }

    fn parseComplexPlaceholder(self: *SnippetParser, parent: *Marker) Allocator.Error!bool {
        const token = self.token;
        if (!self.accept(.dollar)) return self.backTo(token);
        if (!self.accept(.curly_open)) return self.backTo(token);
        const index_text = self.acceptText(.int) orelse return self.backTo(token);
        const placeholder = try self.snippet.?.newPlaceholder(@floatFromInt(std.fmt.parseInt(usize, index_text, 10) catch 0));

        if (self.accept(.colon)) {
            while (true) {
                if (self.accept(.curly_close)) {
                    try parent.appendChild(placeholder);
                    return true;
                }
                if (try self.parseOne(placeholder)) continue;
                try parent.appendChild(try self.snippet.?.newText(try std.mem.concat(self.allocator(), u8, &.{ "${", index_text, ":" })));
                for (placeholder.children.items) |child| try parent.appendChild(child);
                return true;
            }
        } else if (placeholder.index > 0 and self.accept(.pipe)) {
            const choice = try self.snippet.?.create(.choice);
            while (true) {
                if (try self.parseChoiceElement(choice)) {
                    if (self.accept(.comma)) continue;
                    if (self.accept(.pipe)) {
                        try placeholder.appendChild(choice);
                        if (self.accept(.curly_close)) {
                            try parent.appendChild(placeholder);
                            return true;
                        }
                    }
                }
                return self.backTo(token);
            }
        } else if (self.accept(.forwardslash)) {
            if (try self.parseTransform(placeholder)) {
                try parent.appendChild(placeholder);
                return true;
            }
            return self.backTo(token);
        } else if (self.accept(.curly_close)) {
            try parent.appendChild(placeholder);
            return true;
        }
        return self.backTo(token);
    }

    fn parseChoiceElement(self: *SnippetParser, parent: *Marker) Allocator.Error!bool {
        const token = self.token;
        var values = std.ArrayListUnmanaged(u8).empty;
        defer values.deinit(self.allocator());
        while (true) {
            if (self.token.type == .comma or self.token.type == .pipe) break;
            var value: []const u8 = undefined;
            if (self.acceptText(.backslash)) |escaped| {
                value = escaped;
                if (self.acceptText(.comma)) |v| {
                    value = v;
                } else if (self.acceptText(.pipe)) |v| {
                    value = v;
                } else if (self.acceptText(.backslash)) |v| {
                    value = v;
                }
            } else {
                value = self.acceptAnyText() orelse {
                    _ = self.backTo(token);
                    return false;
                };
            }
            try values.appendSlice(self.allocator(), value);
        }
        if (values.items.len == 0) {
            _ = self.backTo(token);
            return false;
        }
        try parent.appendChild(try self.snippet.?.newText(values.items));
        return true;
    }

    fn parseComplexVariable(self: *SnippetParser, parent: *Marker) Allocator.Error!bool {
        const token = self.token;
        if (!self.accept(.dollar)) return self.backTo(token);
        if (!self.accept(.curly_open)) return self.backTo(token);
        const name = self.acceptText(.variable_name) orelse return self.backTo(token);
        const variable = try self.snippet.?.newVariable(name);

        if (self.accept(.colon)) {
            while (true) {
                if (self.accept(.curly_close)) {
                    try parent.appendChild(variable);
                    return true;
                }
                if (try self.parseOne(variable)) continue;
                try parent.appendChild(try self.snippet.?.newText(try std.mem.concat(self.allocator(), u8, &.{ "${", name, ":" })));
                for (variable.children.items) |child| try parent.appendChild(child);
                return true;
            }
        } else if (self.accept(.forwardslash)) {
            if (try self.parseTransform(variable)) {
                try parent.appendChild(variable);
                return true;
            }
            return self.backTo(token);
        } else if (self.accept(.curly_close)) {
            try parent.appendChild(variable);
            return true;
        }
        return self.backTo(token);
    }

    fn parseTransform(self: *SnippetParser, parent: *Marker) Allocator.Error!bool {
        var regex_value = std.ArrayListUnmanaged(u8).empty;
        defer regex_value.deinit(self.allocator());
        var regex_options = std.ArrayListUnmanaged(u8).empty;
        defer regex_options.deinit(self.allocator());

        while (true) {
            if (self.accept(.forwardslash)) break;
            if (self.acceptText(.backslash)) |escaped_value| {
                var escaped: []const u8 = escaped_value;
                if (self.acceptText(.forwardslash)) |v| escaped = v;
                try regex_value.appendSlice(self.allocator(), escaped);
                continue;
            }
            if (self.token.type != .eof) {
                try regex_value.appendSlice(self.allocator(), self.acceptAnyText().?);
                continue;
            }
            return false;
        }

        const transform = try self.snippet.?.arenaAllocator().create(Transform);
        transform.* = .{
            .regexp = undefined,
            .regex_source = "",
            .options = "",
            .global = false,
            .ignore_case = false,
            .allocator = self.allocator(),
        };

        while (true) {
            if (self.accept(.forwardslash)) break;
            if (self.acceptText(.backslash)) |escaped_value| {
                var escaped: []const u8 = escaped_value;
                if (self.acceptText(.backslash)) |v| {
                    escaped = v;
                } else if (self.acceptText(.forwardslash)) |v| {
                    escaped = v;
                }
                try transform.appendChild(try self.snippet.?.newText(escaped));
                continue;
            }
            if (try self.parseFormatString(transform)) continue;
            if (try self.parseAnything(transform)) continue;
            return false;
        }

        while (true) {
            if (self.accept(.curly_close)) break;
            if (self.token.type != .eof) {
                try regex_options.appendSlice(self.allocator(), self.acceptAnyText().?);
                continue;
            }
            return false;
        }

        for (regex_options.items) |ch| {
            if (std.mem.indexOfScalar(u8, "gimsuy", ch) == null) return false;
        }
        const source = try self.allocator().dupe(u8, regex_value.items);
        const options = try self.allocator().dupe(u8, regex_options.items);
        transform.regexp = self.snippet.?.compileRegex(source, options) catch return false;
        transform.regex_source = source;
        transform.options = options;
        transform.global = std.mem.indexOfScalar(u8, options, 'g') != null;
        transform.ignore_case = std.mem.indexOfScalar(u8, options, 'i') != null;
        parent.transform = transform;
        return true;
    }

    fn parseFormatString(self: *SnippetParser, parent: *Transform) Allocator.Error!bool {
        const token = self.token;
        if (!self.accept(.dollar)) return false;
        const complex = self.accept(.curly_open);
        const index_text = self.acceptText(.int) orelse return self.backTo(token);
        const index = std.fmt.parseInt(usize, index_text, 10) catch 0;

        if (!complex) {
            try parent.appendChild(try self.snippet.?.newFormatString(index, null, null, null));
            return true;
        }
        if (self.accept(.curly_close)) {
            try parent.appendChild(try self.snippet.?.newFormatString(index, null, null, null));
            return true;
        }
        if (!self.accept(.colon)) return self.backTo(token);

        if (self.accept(.forwardslash)) {
            const shorthand = self.acceptText(.variable_name);
            if (shorthand == null or !self.accept(.curly_close)) return self.backTo(token);
            try parent.appendChild(try self.snippet.?.newFormatString(index, shorthand, null, null));
            return true;
        }
        if (self.accept(.plus)) {
            if (self.until(.curly_close)) |if_value| {
                if (if_value.len > 0) {
                    try parent.appendChild(try self.snippet.?.newFormatString(index, null, if_value, null));
                    return true;
                }
            }
        } else if (self.accept(.dash)) {
            if (self.until(.curly_close)) |else_value| {
                if (else_value.len > 0) {
                    try parent.appendChild(try self.snippet.?.newFormatString(index, null, null, else_value));
                    return true;
                }
            }
        } else if (self.accept(.question)) {
            if (self.until(.colon)) |if_value| {
                if (if_value.len > 0) {
                    if (self.until(.curly_close)) |else_value| {
                        if (else_value.len > 0) {
                            try parent.appendChild(try self.snippet.?.newFormatString(index, null, if_value, else_value));
                            return true;
                        }
                    }
                }
            }
        } else {
            if (self.until(.curly_close)) |else_value| {
                if (else_value.len > 0) {
                    try parent.appendChild(try self.snippet.?.newFormatString(index, null, null, else_value));
                    return true;
                }
            }
        }
        return self.backTo(token);
    }

    fn parseAnything(self: *SnippetParser, parent: anytype) Allocator.Error!bool {
        if (self.token.type == .eof) return false;
        const value = self.scanner.tokenText(self.token);
        self.token = self.scanner.next();
        try parent.appendChild(try self.snippet.?.newText(value));
        return true;
    }
};

fn fillIncompletePlaceholder(
    snippet: *TextmateSnippet,
    placeholder: *Marker,
    defaults: *std.AutoHashMap(u64, []const *Marker),
    stack: *std.AutoHashMap(u64, void),
) !void {
    const default_values = defaults.get(indexKey(placeholder.index)) orelse return;
    const clone = try snippet.newPlaceholder(placeholder.index);
    clone.transform = placeholder.transform;
    for (default_values) |child| {
        const new_child = try child.clone();
        try clone.appendChild(new_child);
        if (new_child.kind == .placeholder and defaults.contains(indexKey(new_child.index)) and !stack.contains(indexKey(new_child.index))) {
            try stack.put(indexKey(new_child.index), {});
            try fillIncompletePlaceholder(snippet, new_child, defaults, stack);
            _ = stack.remove(indexKey(new_child.index));
        }
    }
    try snippet.replace(placeholder, &.{clone});
}

fn indexKey(index: f64) u64 {
    return @bitCast(index);
}

fn isAllDigits(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

fn unescape(value: []const u8, allocator: Allocator) ![]const u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < value.len) : (index += 1) {
        if (value[index] == '\\' and index + 1 < value.len and
            (value[index + 1] == '$' or value[index + 1] == '}' or value[index + 1] == '\\'))
        {
            index += 1;
        }
        try out.append(allocator, value[index]);
    }
    return out.toOwnedSlice(allocator);
}

fn appendIndex(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, index: f64, prefix: []const u8) !void {
    try out.appendSlice(allocator, prefix);
    const integer: i64 = @intFromFloat(index);
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{integer}) catch unreachable;
    try out.appendSlice(allocator, text);
}

fn regexOptions(options: []const u8) regexp.Options {
    var result: regexp.Options = regexp.DefaultOption;
    for (options) |ch| {
        switch (ch) {
            'i' => result.ignore_case = true,
            'm' => result.multiline = true,
            's' => result.singleline = true,
            else => {},
        }
    }
    return result;
}

const Case = enum { upper, lower };

fn mapCase(allocator: Allocator, value: []const u8, case: Case) ![]u8 {
    const out = try allocator.dupe(u8, value);
    for (out) |*ch| {
        ch.* = switch (case) {
            .upper => std.ascii.toUpper(ch.*),
            .lower => std.ascii.toLower(ch.*),
        };
    }
    return out;
}

fn collectWords(allocator: Allocator, value: []const u8, pattern: []const u8) !?std.ArrayListUnmanaged([]const u8) {
    var re = regexp.RegExp.init(pattern, regexp.DefaultOption) catch return null;
    defer re.deinit();
    var words = std.ArrayListUnmanaged([]const u8).empty;
    errdefer words.deinit(allocator);
    var offset: usize = 0;
    while (re.searchFrom(value, offset)) |result| {
        defer result.deinit();
        try words.append(allocator, result.groupN(0));
        const next = result.index() + result.length();
        if (next <= offset) {
            if (offset >= value.len) break;
            const len = std.unicode.utf8ByteSequenceLength(value[offset]) catch 1;
            offset = @min(value.len, offset + len);
        } else {
            offset = next;
        }
    }
    return words;
}

fn toPascalCase(allocator: Allocator, value: []const u8) ![]u8 {
    var words = (try collectWords(allocator, value, "[\\p{L}0-9]+")) orelse return allocator.dupe(u8, value);
    defer words.deinit(allocator);
    if (words.items.len == 0) return allocator.dupe(u8, value);
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);
    for (words.items) |word| {
        if (word.len == 0) continue;
        try out.append(allocator, std.ascii.toUpper(word[0]));
        try out.appendSlice(allocator, word[1..]);
    }
    return out.toOwnedSlice(allocator);
}

fn toCamelCase(allocator: Allocator, value: []const u8) ![]u8 {
    var words = (try collectWords(allocator, value, "[\\p{L}0-9]+")) orelse return allocator.dupe(u8, value);
    defer words.deinit(allocator);
    if (words.items.len == 0) return allocator.dupe(u8, value);
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);
    for (words.items, 0..) |word, index| {
        if (word.len == 0) continue;
        try out.append(allocator, if (index == 0) std.ascii.toLower(word[0]) else std.ascii.toUpper(word[0]));
        try out.appendSlice(allocator, word[1..]);
    }
    return out.toOwnedSlice(allocator);
}

fn toKebabCase(allocator: Allocator, value: []const u8) ![]u8 {
    var matches = (try collectWords(allocator, value, "[\\p{L}0-9]+")) orelse return allocator.dupe(u8, value);
    defer matches.deinit(allocator);
    if (matches.items.len == 0) return allocator.dupe(u8, value);

    const cleaned = std.mem.trim(u8, value, " \t\r\n");
    var start: usize = 0;
    var end: usize = cleaned.len;
    while (start < end and cleaned[start] == '_') start += 1;
    while (end > start and cleaned[end - 1] == '_') end -= 1;
    const trimmed = cleaned[start..end];

    const pattern = "\\p{Lu}{2,}(?=\\p{Lu}\\p{Ll}+[0-9]*|[\\s_-]|$)|\\p{Lu}?\\p{Ll}+[0-9]*|\\p{Lu}(?=\\p{Lu}\\p{Ll})|\\p{Lu}(?=[\\s_-]|$)|[0-9]+";
    var words = (try collectWords(allocator, trimmed, pattern)) orelse {
        return joinCaseWords(allocator, trimmed, '-', false);
    };
    defer words.deinit(allocator);
    if (words.items.len == 0) {
        return joinCaseWords(allocator, trimmed, '-', false);
    }
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);
    for (words.items, 0..) |word, index| {
        if (index > 0) try out.append(allocator, '-');
        const lowered = try mapCase(allocator, word, .lower);
        defer allocator.free(lowered);
        try out.appendSlice(allocator, lowered);
    }
    return out.toOwnedSlice(allocator);
}

fn toSnakeCase(allocator: Allocator, value: []const u8) ![]u8 {
    var re = regexp.RegExp.init("(\\p{Ll})(\\p{Lu})", regexp.DefaultOption) catch return allocator.dupe(u8, value);
    defer re.deinit();
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);
    var last: usize = 0;
    var offset: usize = 0;
    while (re.searchFrom(value, offset)) |result| {
        defer result.deinit();
        try out.appendSlice(allocator, value[last..result.index()]);
        try out.appendSlice(allocator, result.groupN(1));
        try out.append(allocator, '_');
        try out.appendSlice(allocator, result.groupN(2));
        last = result.index() + result.length();
        offset = last;
        if (result.length() == 0) {
            if (offset >= value.len) break;
            const len = std.unicode.utf8ByteSequenceLength(value[offset]) catch 1;
            offset = @min(value.len, offset + len);
        }
    }
    try out.appendSlice(allocator, value[last..]);

    var final = std.ArrayListUnmanaged(u8).empty;
    errdefer final.deinit(allocator);
    var index: usize = 0;
    while (index < out.items.len) : (index += 1) {
        const ch = out.items[index];
        if (ch == ' ' or ch == '\t' or ch == '-' or ch == '\r' or ch == '\n') {
            if (final.items.len == 0 or final.items[final.items.len - 1] != '_') try final.append(allocator, '_');
        } else {
            try final.append(allocator, std.ascii.toLower(ch));
        }
    }
    return final.toOwnedSlice(allocator);
}

fn joinCaseWords(allocator: Allocator, value: []const u8, separator: u8, lower: bool) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);
    var start: ?usize = null;
    var index: usize = 0;
    while (index <= value.len) : (index += 1) {
        const boundary = index == value.len or value[index] == ' ' or value[index] == '\t' or
            value[index] == '\r' or value[index] == '\n' or value[index] == '-' or value[index] == '_';
        if (!boundary) {
            if (start == null) start = index;
        } else if (start) |begin| {
            if (out.items.len > 0) try out.append(allocator, separator);
            for (value[begin..index]) |ch| try out.append(allocator, if (lower) std.ascii.toLower(ch) else ch);
            start = null;
        }
    }
    return out.toOwnedSlice(allocator);
}

test "snippetParser: escaped text" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator, "foo\\$0", false, false);
    defer parsed.deinit();
    const text = try parsed.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("foo$0", text);
}

test "snippetParser: placeholders, choices and transforms" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator, "hi ${1:name} ${2|red,blue|} $0", false, false);
    defer parsed.deinit();
    const text = try parsed.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hi name red ", text);
    try std.testing.expect((try parsed.placeholders()).len == 3);
}

test "snippetParser: marker offsets and textmate strings" {
    const allocator = std.testing.allocator;
    const parsed = try parse(allocator, "this ${1:is ${2:nested with $var}}", false, false);
    defer parsed.deinit();
    const text = try parsed.toTextmateString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("this ${1:is ${2:nested with ${var}}}", text);
    try std.testing.expectEqual(@as(isize, 0), parsed.offset(parsed.children()[0]));
}

test "snippetParser: variable transform" {
    const allocator = std.testing.allocator;
    const Resolver = struct {
        fn resolve(_: *anyopaque, a: Allocator, _: *const Marker) anyerror!?[]u8 {
            return try a.dupe(u8, "sample.zig");
        }
    };
    var marker: u8 = 0;
    const parsed = try parse(allocator, "${TM_FILENAME/(.*)/${1:/upcase}/}", false, false);
    defer parsed.deinit();
    try parsed.resolveVariables(.{ .context = &marker, .resolve = Resolver.resolve });
    const text = try parsed.toString(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("SAMPLE.ZIG", text);
}

pub fn parse(allocator: Allocator, value: []const u8, insert_final_tabstop: bool, enforce_final_tabstop: bool) !*TextmateSnippet {
    const snippet = try TextmateSnippet.init(allocator);
    errdefer snippet.deinit();
    var parser = SnippetParser{};
    try parser.parse(snippet, value, insert_final_tabstop, enforce_final_tabstop);
    return snippet;
}

pub fn escape(allocator: Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);
    for (value) |ch| {
        if (ch == '$' or ch == '}' or ch == '\\') try out.append(allocator, '\\');
        try out.append(allocator, ch);
    }
    return out.toOwnedSlice(allocator);
}

pub fn guessNeedsClipboard(template: []const u8) bool {
    var re = regexp.RegExp.init("\\$\\{?CLIPBOARD", regexp.DefaultOption) catch return false;
    defer re.deinit();
    return re.isMatch(template);
}

pub fn asInsertText(allocator: Allocator, value: []const u8) ![]u8 {
    const snippet = try parse(allocator, value, false, false);
    defer snippet.deinit();
    return snippet.toString(allocator);
}
