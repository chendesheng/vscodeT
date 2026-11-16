// Port of `../vscode-textmate/src/onigLib.ts` (microsoft/vscode-textmate
// v9.3.2), plus the libonig-backed implementation used by this standalone
// package.
//
// Adaptation notes:
//  * `vscode-textmate` receives an `IOnigLib` from the host (normally
//    `vscode-oniguruma`). This package has no host to inject one into, so
//    `OnigLib` is a concrete libonig binding and `IOnigLib` remains available
//    for callers that provide their own scanner.
//  * vscode-oniguruma converts between the JS UTF-16 string and the UTF-8
//    bytes Oniguruma matches. `OnigString` performs the same conversion and
//    returns UTF-16 capture offsets, keeping all tokenizer indices identical
//    to the TypeScript implementation. `textmate.zig`, by contrast, exposes
//    UTF-8 byte offsets.
//  * `findNextMatchSync` returns owned capture slices; callers release them
//    with `Match.deinit`.
const std = @import("std");
const c = @import("c_onig");
const Allocator = std.mem.Allocator;

pub const FindOption = struct {
    pub const none: u32 = 0;
    /// `ONIG_OPTION_NOT_BEGIN_STRING`: the start is not the beginning of the
    /// string (`\A` fails).
    pub const not_begin_string: u32 = 1;
    /// `ONIG_OPTION_NOT_END_STRING`: the end is not the end of the string
    /// (`\z`/`\Z` fail).
    pub const not_end_string: u32 = 2;
    /// `ONIG_OPTION_NOT_BEGIN_POSITION`: the start position is not the
    /// beginning (`\G` fails).
    pub const not_begin_position: u32 = 4;
    pub const debug_call: u32 = 8;
};

pub const CaptureIndex = struct {
    start: usize,
    end: usize,
    length: usize,
};

pub const Match = struct {
    index: usize,
    capture_indices: []CaptureIndex,

    pub fn deinit(self: *const Match, allocator: Allocator) void {
        allocator.free(self.capture_indices);
    }
};

/// A UTF-8 string prepared for Oniguruma, with the same UTF-16/UTF-8 offset
/// maps used by `vscode-oniguruma`.
///
/// `content` is the original UTF-8 text (including the trailing `\n` the
/// tokenizer adds). All public offsets in this package are UTF-16 code units.
pub const OnigString = struct {
    allocator: Allocator,
    content: []u8,
    utf16_len: usize,
    utf16_to_utf8: ?[]u32,
    utf8_to_utf16: ?[]u32,

    pub fn init(allocator: Allocator, text: []const u8) !*OnigString {
        const content = try allocator.dupe(u8, text);
        errdefer allocator.free(content);

        var utf16_len: usize = 0;
        var index: usize = 0;
        while (index < content.len) {
            const sequence_length = std.unicode.utf8ByteSequenceLength(content[index]) catch
                return error.InvalidUtf8;
            if (index + sequence_length > content.len) return error.InvalidUtf8;
            const codepoint = std.unicode.utf8Decode(content[index .. index + sequence_length]) catch
                return error.InvalidUtf8;
            utf16_len += if (codepoint > 0xFFFF) 2 else 1;
            index += sequence_length;
        }

        if (utf16_len == content.len) {
            // ASCII fast path: the identity mapping is valid.
            const result = try allocator.create(OnigString);
            errdefer allocator.destroy(result);
            result.* = .{
                .allocator = allocator,
                .content = content,
                .utf16_len = utf16_len,
                .utf16_to_utf8 = null,
                .utf8_to_utf16 = null,
            };
            return result;
        }

        const utf16_to_utf8 = try allocator.alloc(u32, utf16_len + 1);
        errdefer allocator.free(utf16_to_utf8);
        const utf8_to_utf16 = try allocator.alloc(u32, content.len + 1);
        errdefer allocator.free(utf8_to_utf16);

        var utf16_index: usize = 0;
        index = 0;
        while (index < content.len) {
            const sequence_length = std.unicode.utf8ByteSequenceLength(content[index]) catch
                return error.InvalidUtf8;
            const codepoint = std.unicode.utf8Decode(content[index .. index + sequence_length]) catch
                return error.InvalidUtf8;
            const width: usize = if (codepoint > 0xFFFF) 2 else 1;

            if (width == 2) {
                utf16_to_utf8[utf16_index] = @intCast(index);
                utf16_to_utf8[utf16_index + 1] = @intCast(index);
            } else {
                utf16_to_utf8[utf16_index] = @intCast(index);
            }

            var byte_index: usize = 0;
            while (byte_index < sequence_length) : (byte_index += 1) {
                utf8_to_utf16[index + byte_index] = @intCast(utf16_index);
            }
            utf16_index += width;
            index += sequence_length;
        }
        utf16_to_utf8[utf16_len] = @intCast(content.len);
        utf8_to_utf16[content.len] = @intCast(utf16_len);

        const result = try allocator.create(OnigString);
        errdefer allocator.destroy(result);
        result.* = .{
            .allocator = allocator,
            .content = content,
            .utf16_len = utf16_len,
            .utf16_to_utf8 = utf16_to_utf8,
            .utf8_to_utf16 = utf8_to_utf16,
        };
        return result;
    }

    pub fn deinit(self: *OnigString) void {
        if (self.utf16_to_utf8) |map| self.allocator.free(map);
        if (self.utf8_to_utf16) |map| self.allocator.free(map);
        self.allocator.free(self.content);
        self.allocator.destroy(self);
    }

    pub fn utf16ToUtf8(self: *const OnigString, index: usize) usize {
        if (self.utf16_to_utf8) |map| {
            if (index >= self.utf16_len) return self.content.len;
            return map[index];
        }
        return @min(index, self.content.len);
    }

    pub fn utf8ToUtf16(self: *const OnigString, index: usize) usize {
        if (self.utf8_to_utf16) |map| {
            if (index >= self.content.len) return self.utf16_len;
            return map[index];
        }
        return @min(index, self.utf16_len);
    }

    /// `String.prototype.substring(start, end)` in UTF-16 coordinates.
    pub fn sliceUtf16(self: *const OnigString, start: usize, end: usize) []const u8 {
        const utf8_start = self.utf16ToUtf8(start);
        const utf8_end = self.utf16ToUtf8(end);
        if (utf8_end <= utf8_start) return self.content[utf8_start..utf8_start];
        return self.content[utf8_start..utf8_end];
    }
};

/// A set of Oniguruma regexes searched in parallel, mimicking
/// `vscode-oniguruma`'s `OnigScanner`.
pub const OnigScanner = struct {
    allocator: Allocator,
    regexes: []c.OnigRegex,
    regions: []*c.OnigRegion,

    pub fn init(allocator: Allocator, sources: []const []const u8) !*OnigScanner {
        const self = try allocator.create(OnigScanner);
        errdefer allocator.destroy(self);

        const regexes = try allocator.alloc(c.OnigRegex, sources.len);
        errdefer allocator.free(regexes);
        const regions = try allocator.alloc(*c.OnigRegion, sources.len);
        errdefer allocator.free(regions);

        var created: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < created) : (i += 1) {
                c.onig_free(regexes[i]);
                c.onig_region_free(regions[i], 1);
            }
        }

        for (sources, 0..) |source, i| {
            var regex: c.OnigRegex = null;
            var error_info: c.OnigErrorInfo = undefined;
            const status = c.onig_new(
                &regex,
                source.ptr,
                source.ptr + source.len,
                c.ONIG_OPTION_CAPTURE_GROUP,
                @ptrCast(@alignCast(c.ONIG_ENCODING_UTF8())),
                @ptrCast(@alignCast(c.ONIG_SYNTAX_RUBY())),
                &error_info,
            );
            if (status != c.ONIG_NORMAL) {
                // The system Oniguruma may be older than the one bundled by
                // vscode-oniguruma and reject a grammar pattern it cannot
                // parse. `textmate.zig` skipped such patterns; preserve that
                // resilience by installing a never-matching placeholder.
                const placeholder = "(?!)";
                var placeholder_regex: c.OnigRegex = null;
                var placeholder_error: c.OnigErrorInfo = undefined;
                const placeholder_status = c.onig_new(
                    &placeholder_regex,
                    placeholder.ptr,
                    placeholder.ptr + placeholder.len,
                    c.ONIG_OPTION_CAPTURE_GROUP,
                    @ptrCast(@alignCast(c.ONIG_ENCODING_UTF8())),
                    @ptrCast(@alignCast(c.ONIG_SYNTAX_RUBY())),
                    &placeholder_error,
                );
                if (placeholder_status != c.ONIG_NORMAL) return error.OnigCompileError;
                regexes[i] = placeholder_regex;
            } else {
                regexes[i] = regex;
            }
            regions[i] = c.onig_region_new();
            created += 1;
        }

        self.* = .{
            .allocator = allocator,
            .regexes = regexes,
            .regions = regions,
        };
        return self;
    }

    pub fn deinit(self: *OnigScanner) void {
        for (self.regexes, self.regions) |regex, region| {
            c.onig_free(regex);
            c.onig_region_free(region, 1);
        }
        self.allocator.free(self.regexes);
        self.allocator.free(self.regions);
        self.allocator.destroy(self);
    }

    /// Port of `OnigScanner.findNextMatchSync`. The returned captures are in
    /// UTF-16 code units and owned by the caller.
    pub fn findNextMatchSync(
        self: *OnigScanner,
        string: *const OnigString,
        start_position: usize,
        options: u32,
    ) !?Match {
        const utf8_start = string.utf16ToUtf8(start_position);
        const base = string.content.ptr;
        const end = base + string.content.len;

        var best: ?Match = null;
        var best_utf8_start: usize = 0;

        for (self.regexes, self.regions, 0..) |regex, region, regex_index| {
            const status = c.onig_search(
                regex,
                base,
                end,
                base + utf8_start,
                end,
                region,
                options,
            );
            if (status < 0) continue; // ONIG_MISMATCH or a search error

            const num_regs: usize = @intCast(region.num_regs);
            const captures = try self.allocator.alloc(CaptureIndex, num_regs);
            errdefer self.allocator.free(captures);

            var i: usize = 0;
            while (i < num_regs) : (i += 1) {
                const raw_start = region.beg[i];
                const raw_end = region.end[i];
                const capture_start = if (raw_start < 0) 0 else string.utf8ToUtf16(@intCast(raw_start));
                const capture_end = if (raw_end < 0) 0 else string.utf8ToUtf16(@intCast(raw_end));
                captures[i] = .{
                    .start = capture_start,
                    .end = capture_end,
                    .length = if (capture_end >= capture_start) capture_end - capture_start else 0,
                };
            }

            const location: usize = if (region.beg[0] < 0) 0 else @intCast(region.beg[0]);
            if (best == null or location < best_utf8_start) {
                if (best) |previous| previous.deinit(self.allocator);
                best = .{ .index = regex_index, .capture_indices = captures };
                best_utf8_start = location;
            } else {
                self.allocator.free(captures);
            }

            if (location == utf8_start) break;
        }

        return best;
    }
};

/// Port of `IOnigLib`.
pub const IOnigLib = struct {
    context: *anyopaque,
    vtable: *const VTable,
    allocator: Allocator,

    pub const VTable = struct {
        create_onig_scanner: *const fn (context: *anyopaque, sources: []const []const u8) anyerror!*OnigScanner,
        create_onig_string: *const fn (context: *anyopaque, content: []const u8) anyerror!*OnigString,
    };

    pub fn createOnigScanner(self: IOnigLib, sources: []const []const u8) anyerror!*OnigScanner {
        return self.vtable.create_onig_scanner(self.context, sources);
    }

    pub fn createOnigString(self: IOnigLib, content: []const u8) anyerror!*OnigString {
        return self.vtable.create_onig_string(self.context, content);
    }
};

/// libonig-backed `IOnigLib`.
pub const OnigLib = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) OnigLib {
        return .{ .allocator = allocator };
    }

    pub fn interface(self: *OnigLib) IOnigLib {
        return .{
            .context = self,
            .allocator = self.allocator,
            .vtable = &.{
                .create_onig_scanner = createOnigScanner,
                .create_onig_string = createOnigString,
            },
        };
    }

    fn createOnigScanner(context: *anyopaque, sources: []const []const u8) anyerror!*OnigScanner {
        const self: *OnigLib = @ptrCast(@alignCast(context));
        return OnigScanner.init(self.allocator, sources);
    }

    fn createOnigString(context: *anyopaque, content: []const u8) anyerror!*OnigString {
        const self: *OnigLib = @ptrCast(@alignCast(context));
        return OnigString.init(self.allocator, content);
    }
};

pub fn disposeOnigString(string: *OnigString) void {
    string.deinit();
}

test "onig string maps utf16 offsets" {
    var lib = OnigLib.init(std.testing.allocator);
    const onig = lib.interface();
    const text = "a😀b\u{00e9}c\n";
    const string = try onig.createOnigString(text);
    defer string.deinit();

    try std.testing.expectEqual(@as(usize, 7), string.utf16_len);
    try std.testing.expectEqualStrings("😀", string.sliceUtf16(1, 3));
    try std.testing.expectEqualStrings("bé", string.sliceUtf16(3, 5));
    try std.testing.expectEqual(@as(usize, 1), string.utf16ToUtf8(2));
    try std.testing.expectEqual(@as(usize, 3), string.utf8ToUtf16(5));
}

test "onig scanner returns utf16 captures" {
    var lib = OnigLib.init(std.testing.allocator);
    const onig = lib.interface();
    const scanner = try onig.createOnigScanner(&.{"a(b)"});
    defer scanner.deinit();
    const string = try onig.createOnigString("xxab😀");
    defer string.deinit();

    const found = (try scanner.findNextMatchSync(string, 0, FindOption.none)).?;
    defer found.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), found.index);
    try std.testing.expectEqual(@as(usize, 2), found.capture_indices[0].start);
    try std.testing.expectEqual(@as(usize, 4), found.capture_indices[0].end);
    try std.testing.expectEqual(@as(usize, 3), found.capture_indices[1].start);
    try std.testing.expectEqual(@as(usize, 4), found.capture_indices[1].end);
}
