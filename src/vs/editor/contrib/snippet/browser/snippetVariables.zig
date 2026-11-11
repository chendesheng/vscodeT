// Port of `src/vs/editor/contrib/snippet/browser/snippetVariables.ts`.
//
// Host services that VS Code gets from the workbench are adapted to the
// terminal editor:
// - the model path and its parent directory replace the label/workspace
//   services;
// - clipboard text is supplied by the caller through the snippet options;
// - time variables use UTC because the terminal has no local-time zone
//   database; `CURRENT_TIMEZONE_NAME` is `UTC` and the offset is `+00:00`.
//
// Selection, model, comment, time, workspace and random resolvers are ported;
// composite resolution follows upstream order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Range = @import("../../../common/core/range.zig").Range;
const Selection = @import("../../../common/core/selection.zig").Selection;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const LanguageService = @import("../../../common/services/languageService.zig").LanguageService;
const strings = @import("../../../../base/common/strings.zig");
const time_compat = @import("../../../../base/common/timeCompat.zig");
const parser = @import("./snippetParser.zig");

pub const KnownSnippetVariableNames = [_][]const u8{
    "CURRENT_YEAR",
    "CURRENT_YEAR_SHORT",
    "CURRENT_MONTH",
    "CURRENT_DATE",
    "CURRENT_HOUR",
    "CURRENT_MINUTE",
    "CURRENT_SECOND",
    "CURRENT_MILLISECOND",
    "CURRENT_DAY_NAME",
    "CURRENT_DAY_NAME_SHORT",
    "CURRENT_MONTH_NAME",
    "CURRENT_MONTH_NAME_SHORT",
    "CURRENT_SECONDS_UNIX",
    "CURRENT_MILLISECONDS_UNIX",
    "CURRENT_TIMEZONE_OFFSET",
    "CURRENT_TIMEZONE_NAME",
    "SELECTION",
    "CLIPBOARD",
    "TM_SELECTED_TEXT",
    "TM_CURRENT_LINE",
    "TM_CURRENT_WORD",
    "TM_LINE_INDEX",
    "TM_LINE_NUMBER",
    "TM_FILENAME",
    "TM_FILENAME_BASE",
    "TM_DIRECTORY",
    "TM_DIRECTORY_BASE",
    "TM_FILEPATH",
    "CURSOR_INDEX",
    "CURSOR_NUMBER",
    "RELATIVE_FILEPATH",
    "BLOCK_COMMENT_START",
    "BLOCK_COMMENT_END",
    "LINE_COMMENT",
    "WORKSPACE_NAME",
    "WORKSPACE_FOLDER",
    "RANDOM",
    "RANDOM_HEX",
    "UUID",
};

pub fn isKnownVariableName(name: []const u8) bool {
    for (KnownSnippetVariableNames) |known| {
        if (std.mem.eql(u8, known, name)) return true;
    }
    return false;
}

pub const OvertypingInfo = struct {
    value: []const u8,
    multiline: bool,
};

pub const OvertypingCapturer = struct {
    context: *anyopaque,
    get_last: *const fn (context: *anyopaque, idx: usize) ?OvertypingInfo,
};

pub const CompositeSnippetVariableResolver = struct {
    resolvers: []const parser.VariableResolver,

    pub fn resolve(self: CompositeSnippetVariableResolver, allocator: Allocator, variable: *const parser.Marker) !?[]u8 {
        for (self.resolvers) |resolver| {
            if (try resolver.resolve(resolver.context, allocator, variable)) |value| return value;
        }
        return null;
    }

    pub fn interface(self: *CompositeSnippetVariableResolver) parser.VariableResolver {
        return .{ .context = self, .resolve = resolveOpaque };
    }

    fn resolveOpaque(context: *anyopaque, allocator: Allocator, variable: *const parser.Marker) anyerror!?[]u8 {
        const self: *CompositeSnippetVariableResolver = @ptrCast(@alignCast(context));
        return self.resolve(allocator, variable);
    }
};

pub const SelectionBasedVariableResolver = struct {
    model: *TextModel,
    selection: Selection,
    selection_idx: usize,
    overtyping_capturer: ?OvertypingCapturer = null,

    pub fn resolve(self: *const SelectionBasedVariableResolver, allocator: Allocator, variable: *const parser.Marker) !?[]u8 {
        const name = variable.name;

        if (std.mem.eql(u8, name, "SELECTION") or std.mem.eql(u8, name, "TM_SELECTED_TEXT")) {
            var value: ?[]u8 = null;
            defer if (value) |owned| allocator.free(owned);
            var multiline = self.selection.selectionStartLineNumber != self.selection.positionLineNumber;
            const range = Range.init(
                self.selection.selectionStartLineNumber,
                self.selection.selectionStartColumn,
                self.selection.positionLineNumber,
                self.selection.positionColumn,
            );
            var text = try self.model.getValueInRange(range, .TextDefined);
            defer text.deinit();
            if (text.items.len > 0) {
                value = try allocator.dupe(u8, text.items);
            } else if (self.overtyping_capturer) |capturer| {
                if (capturer.get_last(capturer.context, self.selection_idx)) |info| {
                    value = try allocator.dupe(u8, info.value);
                    multiline = info.multiline;
                }
            }
            if (value) |selected| {
                if (multiline and variable.snippet != null) {
                    return try adjustMultilineSelection(allocator, self.model, self.selection, variable, selected);
                }
                return try allocator.dupe(u8, selected);
            }
            return null;
        } else if (std.mem.eql(u8, name, "TM_CURRENT_LINE")) {
            var line = try self.model.getLineContent(self.selection.positionLineNumber);
            defer line.deinit();
            return try allocator.dupe(u8, line.items);
        } else if (std.mem.eql(u8, name, "TM_CURRENT_WORD")) {
            if (self.model.getWordAtPosition(.{
                .lineNumber = self.selection.positionLineNumber,
                .column = self.selection.positionColumn,
            })) |info| {
                var word = info;
                defer word.deinit();
                return try allocator.dupe(u8, word.word.items);
            }
            return null;
        } else if (std.mem.eql(u8, name, "TM_LINE_INDEX")) {
            return try std.fmt.allocPrint(allocator, "{d}", .{self.selection.positionLineNumber - 1});
        } else if (std.mem.eql(u8, name, "TM_LINE_NUMBER")) {
            return try std.fmt.allocPrint(allocator, "{d}", .{self.selection.positionLineNumber});
        } else if (std.mem.eql(u8, name, "CURSOR_INDEX")) {
            return try std.fmt.allocPrint(allocator, "{d}", .{self.selection_idx});
        } else if (std.mem.eql(u8, name, "CURSOR_NUMBER")) {
            return try std.fmt.allocPrint(allocator, "{d}", .{self.selection_idx + 1});
        }
        return null;
    }

    pub fn interface(self: *SelectionBasedVariableResolver) parser.VariableResolver {
        return .{ .context = self, .resolve = resolveOpaque };
    }

    fn resolveOpaque(context: *anyopaque, allocator: Allocator, variable: *const parser.Marker) anyerror!?[]u8 {
        const self: *SelectionBasedVariableResolver = @ptrCast(@alignCast(context));
        return self.resolve(allocator, variable);
    }
};

fn adjustMultilineSelection(
    allocator: Allocator,
    model: *TextModel,
    selection: Selection,
    variable: *const parser.Marker,
    value: []const u8,
) ![]u8 {
    var line = try model.getLineContent(selection.selectionStartLineNumber);
    defer line.deinit();
    const line_leading_whitespace = strings.getLeadingWhitespace(line.items[0..@min(selection.selectionStartColumn - 1, line.items.len)]);

    var variable_leading_whitespace = line_leading_whitespace;
    if (variable.snippet) |snippet| {
        for (try snippet.walkArena()) |marker| {
            if (marker == variable) break;
            if (marker.kind == .text) {
                const text = marker.value;
                const last_newline = std.mem.lastIndexOfAny(u8, text, "\r\n") orelse 0;
                const last_line = if (std.mem.indexOfAny(u8, text, "\r\n") != null) text[last_newline + 1 ..] else text;
                variable_leading_whitespace = strings.getLeadingWhitespace(last_line);
            }
        }
    }
    const common = strings.commonPrefixLength(variable_leading_whitespace, line_leading_whitespace);
    const prefix = variable_leading_whitespace[common..];

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < value.len) {
        const ch = value[index];
        try out.append(allocator, ch);
        index += 1;
        if (ch == '\r' or ch == '\n') {
            if (ch == '\r' and index < value.len and value[index] == '\n') {
                try out.append(allocator, '\n');
                index += 1;
            }
            try out.appendSlice(allocator, prefix);
        }
    }
    return out.toOwnedSlice(allocator);
}

pub const ModelBasedVariableResolver = struct {
    model_path: []const u8,

    pub fn resolve(self: *const ModelBasedVariableResolver, allocator: Allocator, variable: *const parser.Marker) !?[]u8 {
        const name = variable.name;
        const fs_path = self.model_path;
        if (std.mem.eql(u8, name, "TM_FILENAME")) {
            return try allocator.dupe(u8, std.fs.path.basename(fs_path));
        } else if (std.mem.eql(u8, name, "TM_FILENAME_BASE")) {
            const base = std.fs.path.basename(fs_path);
            const idx = std.mem.lastIndexOfScalar(u8, base, '.') orelse 0;
            if (idx == 0) return try allocator.dupe(u8, base);
            return try allocator.dupe(u8, base[0..idx]);
        } else if (std.mem.eql(u8, name, "TM_DIRECTORY")) {
            const dir = std.fs.path.dirname(fs_path) orelse return try allocator.dupe(u8, "");
            if (std.mem.eql(u8, dir, ".")) return try allocator.dupe(u8, "");
            return try allocator.dupe(u8, dir);
        } else if (std.mem.eql(u8, name, "TM_DIRECTORY_BASE")) {
            const dir = std.fs.path.dirname(fs_path) orelse return try allocator.dupe(u8, "");
            if (std.mem.eql(u8, dir, ".")) return try allocator.dupe(u8, "");
            return try allocator.dupe(u8, std.fs.path.basename(dir));
        } else if (std.mem.eql(u8, name, "TM_FILEPATH")) {
            return try allocator.dupe(u8, fs_path);
        } else if (std.mem.eql(u8, name, "RELATIVE_FILEPATH")) {
            const cwd = std.Io.Dir.cwd().realPathFileAlloc(time_compat.io, ".", allocator) catch return try allocator.dupe(u8, fs_path);
            defer allocator.free(cwd);
            if (std.mem.startsWith(u8, fs_path, cwd)) {
                const rest = std.mem.trimStart(u8, fs_path[cwd.len..], std.fs.path.sep_str);
                return try allocator.dupe(u8, rest);
            }
            return try allocator.dupe(u8, fs_path);
        }
        return null;
    }

    pub fn interface(self: *ModelBasedVariableResolver) parser.VariableResolver {
        return .{ .context = self, .resolve = resolveOpaque };
    }

    fn resolveOpaque(context: *anyopaque, allocator: Allocator, variable: *const parser.Marker) anyerror!?[]u8 {
        const self: *ModelBasedVariableResolver = @ptrCast(@alignCast(context));
        return self.resolve(allocator, variable);
    }
};

pub const ClipboardBasedVariableResolver = struct {
    clipboard_text: ?[]const u8,
    selection_idx: usize,
    selection_count: usize,
    spread: bool,

    pub fn resolve(self: *const ClipboardBasedVariableResolver, allocator: Allocator, variable: *const parser.Marker) !?[]u8 {
        if (!std.mem.eql(u8, variable.name, "CLIPBOARD")) return null;
        const clipboard_text = self.clipboard_text orelse return null;
        if (clipboard_text.len == 0) return null;

        if (self.spread) {
            var lines = std.ArrayListUnmanaged([]const u8).empty;
            defer lines.deinit(allocator);
            var start: usize = 0;
            var index: usize = 0;
            while (index <= clipboard_text.len) : (index += 1) {
                if (index == clipboard_text.len or clipboard_text[index] == '\n' or clipboard_text[index] == '\r') {
                    const line = std.mem.trim(u8, clipboard_text[start..index], " \t");
                    if (line.len > 0) try lines.append(allocator, line);
                    if (index < clipboard_text.len and clipboard_text[index] == '\r' and index + 1 < clipboard_text.len and clipboard_text[index + 1] == '\n') index += 1;
                    start = index + 1;
                }
            }
            if (lines.items.len == self.selection_count) {
                if (self.selection_idx < lines.items.len) return try allocator.dupe(u8, lines.items[self.selection_idx]);
            }
        }
        return try allocator.dupe(u8, clipboard_text);
    }

    pub fn interface(self: *ClipboardBasedVariableResolver) parser.VariableResolver {
        return .{ .context = self, .resolve = resolveOpaque };
    }

    fn resolveOpaque(context: *anyopaque, allocator: Allocator, variable: *const parser.Marker) anyerror!?[]u8 {
        const self: *ClipboardBasedVariableResolver = @ptrCast(@alignCast(context));
        return self.resolve(allocator, variable);
    }
};

pub const CommentBasedVariableResolver = struct {
    model: *TextModel,
    selection: Selection,
    language_service: *LanguageService,

    pub fn resolve(self: *const CommentBasedVariableResolver, allocator: Allocator, variable: *const parser.Marker) !?[]u8 {
        const lang_id = self.model.getLanguageIdAtPosition(
            self.selection.selectionStartLineNumber,
            self.selection.selectionStartColumn,
        );
        const config = self.language_service.getLanguageConfiguration(lang_id) orelse return null;
        const comments = config.comments orelse return null;
        if (std.mem.eql(u8, variable.name, "LINE_COMMENT")) {
            if (comments.lineComment) |token| return try allocator.dupe(u8, token.comment);
            return null;
        } else if (std.mem.eql(u8, variable.name, "BLOCK_COMMENT_START")) {
            if (comments.blockComment) |tokens| return try allocator.dupe(u8, tokens[0]);
            return null;
        } else if (std.mem.eql(u8, variable.name, "BLOCK_COMMENT_END")) {
            if (comments.blockComment) |tokens| return try allocator.dupe(u8, tokens[1]);
            return null;
        }
        return null;
    }

    pub fn interface(self: *CommentBasedVariableResolver) parser.VariableResolver {
        return .{ .context = self, .resolve = resolveOpaque };
    }

    fn resolveOpaque(context: *anyopaque, allocator: Allocator, variable: *const parser.Marker) anyerror!?[]u8 {
        const self: *CommentBasedVariableResolver = @ptrCast(@alignCast(context));
        return self.resolve(allocator, variable);
    }
};

pub const TimeBasedVariableResolver = struct {
    now_seconds: i64,
    now_millis: i64,

    pub fn init() TimeBasedVariableResolver {
        const millis = time_compat.milliTimestamp();
        return .{
            .now_seconds = @divTrunc(millis, 1000),
            .now_millis = millis,
        };
    }

    pub fn resolve(self: *const TimeBasedVariableResolver, allocator: Allocator, variable: *const parser.Marker) !?[]u8 {
        const name = variable.name;
        const seconds: u64 = if (self.now_seconds < 0) 0 else @intCast(self.now_seconds);
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
        const day_seconds = epoch_seconds.getDaySeconds();
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const hour: u5 = day_seconds.getHoursIntoDay();
        const minute: u6 = day_seconds.getMinutesIntoHour();
        const second: u6 = day_seconds.getSecondsIntoMinute();
        const millis: u16 = @intCast(@mod(self.now_millis, 1000));

        if (std.mem.eql(u8, name, "CURRENT_YEAR")) return try std.fmt.allocPrint(allocator, "{d}", .{year_day.year});
        if (std.mem.eql(u8, name, "CURRENT_YEAR_SHORT")) {
            const year = year_day.year % 100;
            return try std.fmt.allocPrint(allocator, "{d:0>2}", .{year});
        }
        if (std.mem.eql(u8, name, "CURRENT_MONTH")) {
            return try std.fmt.allocPrint(allocator, "{d:0>2}", .{month_day.month.numeric()});
        }
        if (std.mem.eql(u8, name, "CURRENT_DATE")) {
            return try std.fmt.allocPrint(allocator, "{d:0>2}", .{month_day.day_index + 1});
        }
        if (std.mem.eql(u8, name, "CURRENT_HOUR")) return try std.fmt.allocPrint(allocator, "{d:0>2}", .{hour});
        if (std.mem.eql(u8, name, "CURRENT_MINUTE")) return try std.fmt.allocPrint(allocator, "{d:0>2}", .{minute});
        if (std.mem.eql(u8, name, "CURRENT_SECOND")) return try std.fmt.allocPrint(allocator, "{d:0>2}", .{second});
        if (std.mem.eql(u8, name, "CURRENT_MILLISECOND")) return try std.fmt.allocPrint(allocator, "{d:0>3}", .{millis});
        if (std.mem.eql(u8, name, "CURRENT_DAY_NAME")) return try allocator.dupe(u8, DAY_NAMES[dayOfWeek(epoch_day.day)]);
        if (std.mem.eql(u8, name, "CURRENT_DAY_NAME_SHORT")) return try allocator.dupe(u8, DAY_NAMES_SHORT[dayOfWeek(epoch_day.day)]);
        if (std.mem.eql(u8, name, "CURRENT_MONTH_NAME")) return try allocator.dupe(u8, MONTH_NAMES[@backingInt(month_day.month) - 1]);
        if (std.mem.eql(u8, name, "CURRENT_MONTH_NAME_SHORT")) return try allocator.dupe(u8, MONTH_NAMES_SHORT[@backingInt(month_day.month) - 1]);
        if (std.mem.eql(u8, name, "CURRENT_SECONDS_UNIX")) return try std.fmt.allocPrint(allocator, "{d}", .{seconds});
        if (std.mem.eql(u8, name, "CURRENT_MILLISECONDS_UNIX")) return try std.fmt.allocPrint(allocator, "{d}", .{self.now_millis});
        if (std.mem.eql(u8, name, "CURRENT_TIMEZONE_OFFSET")) return try allocator.dupe(u8, "+00:00");
        if (std.mem.eql(u8, name, "CURRENT_TIMEZONE_NAME")) return try allocator.dupe(u8, "UTC");
        return null;
    }

    pub fn interface(self: *TimeBasedVariableResolver) parser.VariableResolver {
        return .{ .context = self, .resolve = resolveOpaque };
    }

    fn resolveOpaque(context: *anyopaque, allocator: Allocator, variable: *const parser.Marker) anyerror!?[]u8 {
        const self: *TimeBasedVariableResolver = @ptrCast(@alignCast(context));
        return self.resolve(allocator, variable);
    }
};

const DAY_NAMES = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const DAY_NAMES_SHORT = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const MONTH_NAMES = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const MONTH_NAMES_SHORT = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn dayOfWeek(epoch_day: u47) usize {
    return @intCast((epoch_day + 4) % 7);
}

pub const WorkspaceBasedVariableResolver = struct {
    workspace_folder: ?[]const u8,

    pub fn resolve(self: *const WorkspaceBasedVariableResolver, allocator: Allocator, variable: *const parser.Marker) !?[]u8 {
        const folder = self.workspace_folder orelse return null;
        if (std.mem.eql(u8, variable.name, "WORKSPACE_NAME")) {
            return try allocator.dupe(u8, std.fs.path.basename(folder));
        } else if (std.mem.eql(u8, variable.name, "WORKSPACE_FOLDER")) {
            return try allocator.dupe(u8, folder);
        }
        return null;
    }

    pub fn interface(self: *WorkspaceBasedVariableResolver) parser.VariableResolver {
        return .{ .context = self, .resolve = resolveOpaque };
    }

    fn resolveOpaque(context: *anyopaque, allocator: Allocator, variable: *const parser.Marker) anyerror!?[]u8 {
        const self: *WorkspaceBasedVariableResolver = @ptrCast(@alignCast(context));
        return self.resolve(allocator, variable);
    }
};

pub const RandomBasedVariableResolver = struct {
    pub fn resolve(_: *const RandomBasedVariableResolver, allocator: Allocator, variable: *const parser.Marker) !?[]u8 {
        if (std.mem.eql(u8, variable.name, "RANDOM")) {
            var bytes: [4]u8 = undefined;
            std.Io.random(time_compat.io, &bytes);
            const value = std.mem.readInt(u32, &bytes, .little) % 1_000_000;
            return try std.fmt.allocPrint(allocator, "{d:0>6}", .{value});
        } else if (std.mem.eql(u8, variable.name, "RANDOM_HEX")) {
            var bytes: [3]u8 = undefined;
            std.Io.random(time_compat.io, &bytes);
            const value = (@as(u32, bytes[0]) << 16) | (@as(u32, bytes[1]) << 8) | bytes[2];
            return try std.fmt.allocPrint(allocator, "{x:0>6}", .{value});
        } else if (std.mem.eql(u8, variable.name, "UUID")) {
            var bytes: [16]u8 = undefined;
            std.Io.random(time_compat.io, &bytes);
            bytes[6] = (bytes[6] & 0x0f) | 0x40;
            bytes[8] = (bytes[8] & 0x3f) | 0x80;
            return try std.fmt.allocPrint(
                allocator,
                "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
                .{ bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15] },
            );
        }
        return null;
    }

    pub fn interface(self: *RandomBasedVariableResolver) parser.VariableResolver {
        return .{ .context = self, .resolve = resolveOpaque };
    }

    fn resolveOpaque(context: *anyopaque, allocator: Allocator, variable: *const parser.Marker) anyerror!?[]u8 {
        const self: *RandomBasedVariableResolver = @ptrCast(@alignCast(context));
        return self.resolve(allocator, variable);
    }
};
