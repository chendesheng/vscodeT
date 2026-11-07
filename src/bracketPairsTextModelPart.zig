const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TextModel = @import("textModel.zig").TextModel;
const LanguageService = @import("languages/languageService.zig").LanguageService;
const LanguageConfiguration = @import("languages/languageConfiguration.zig").LanguageConfiguration;
const Range = @import("basics/range.zig").Range;
const Position = @import("basics/position.zig").Position;
const Emitter = @import("basics/event.zig").Emitter;
const tree = @import("bracketPairs/bracketPairsTree.zig");
const TextEditInfo = @import("bracketPairs/beforeEditPositionMapper.zig").TextEditInfo;
const combineTextEditInfos = @import("bracketPairs/combineTextEditInfos.zig").combineTextEditInfos;
const ModelContentChangedEvent = @import("textModelEvents.zig").ModelContentChangedEvent;

/// A single bracket, used by bracket-pair colorization.
pub const BracketInfo = struct {
    range: Range,
    /// 0-based bracket-pair nesting level.
    nestingLevel: usize,
    nestingLevelOfEqualBracketType: usize,
    isInvalid: bool,
    isColorized: bool,
    bracketText: []const u8,
    languageId: []const u8,
    _startOffset: usize,
    _endOffset: usize,
};

pub const BracketPairInfo = struct {
    range: Range,
    openingBracketRange: Range,
    closingBracketRange: ?Range,
    nestingLevel: usize,
    nestingLevelOfEqualBracketType: usize,
    openingBracket: []const u8,
    closingBracket: ?[]const u8,
    isColorized: bool,
    _startOffset: usize,
    _endOffset: usize,
};

pub const BracketPairsTextModelPart = struct {
    const Self = @This();

    allocator: Allocator,
    textModel: *TextModel,
    languageService: *LanguageService,
    _pairs: ArrayList(BracketPairInfo),
    _brackets: ArrayList(BracketInfo),
    _dirty: bool,
    _fullRebuild: bool,
    _document: ?tree.ParsedDocument,
    _queuedEdits: ArrayList(TextEditInfo),
    _onDidChange: Emitter(void),

    pub fn init(allocator: Allocator, textModel: *TextModel, languageService: *LanguageService) Self {
        return .{
            .allocator = allocator,
            .textModel = textModel,
            .languageService = languageService,
            ._pairs = ArrayList(BracketPairInfo).init(allocator),
            ._brackets = ArrayList(BracketInfo).init(allocator),
            ._dirty = true,
            ._fullRebuild = true,
            ._document = null,
            ._queuedEdits = ArrayList(TextEditInfo).init(allocator),
            ._onDidChange = Emitter(void).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self._pairs.deinit();
        self._brackets.deinit();
        self._queuedEdits.deinit();
        if (self._document) |*doc| doc.deinit();
        self._onDidChange.deinit();
    }

    pub fn onDidChange(self: *Self, callback: *const fn (void) void) !void {
        try self._onDidChange.eventVoid(callback);
    }

    pub fn handleDidChangeContent(self: *Self, change: ModelContentChangedEvent) void {
        if (self._fullRebuild or self._document == null) return;
        var edits = ArrayList(TextEditInfo).init(self.allocator);
        defer edits.deinit();
        for (change.changes.items) |c| {
            edits.append(.{
                .startOffset = tree.toLength(c.range.startLineNumber - 1, c.range.startColumn - 1),
                .endOffset = tree.toLength(c.range.endLineNumber - 1, c.range.endColumn - 1),
                .newLength = tree.lengthOfString(c.text.items()),
            }) catch {
                self.markDirty();
                return;
            };
        }
        std.mem.reverse(TextEditInfo, edits.items);
        if (self._queuedEdits.items.len == 0) {
            self._queuedEdits.appendSlice(edits.items) catch {
                self.markDirty();
                return;
            };
        } else {
            const combined = combineTextEditInfos(self.allocator, self._queuedEdits.items, edits.items) catch {
                self.markDirty();
                return;
            };
            self._queuedEdits.deinit();
            self._queuedEdits = combined;
        }
        self._dirty = true;
    }

    pub fn handleDidChangeOptions(self: *Self) void {
        self.markDirty();
    }

    pub fn handleDidChangeLanguage(self: *Self) void {
        self.markDirty();
    }

    pub fn markDirty(self: *Self) void {
        self._dirty = true;
        self._fullRebuild = true;
        self._queuedEdits.clearRetainingCapacity();
    }

    fn ensureUpToDate(self: *Self) !void {
        if (!self._dirty) return;
        self._dirty = false;
        self._pairs.clearRetainingCapacity();
        self._brackets.clearRetainingCapacity();

        var doc: tree.ParsedDocument = undefined;
        if (self._fullRebuild or self._document == null) {
            doc = tree.parseDocument(self.allocator, self.textModel, self.languageService) catch |err| {
                self._dirty = true;
                return err;
            };
        } else {
            doc = tree.parseDocumentIncremental(self.allocator, self.textModel, self.languageService, self._queuedEdits.items, self._document.?.root) catch blk: {
                break :blk try tree.parseDocument(self.allocator, self.textModel, self.languageService);
            };
        }
        if (self._document) |*old| old.deinit();
        self._document = doc;
        self._fullRebuild = false;
        self._queuedEdits.clearRetainingCapacity();
        var counts = std.StringHashMap(usize).init(self.allocator);
        defer counts.deinit();
        try self.walk(doc.root, 0, &counts);

        std.sort.heap(BracketPairInfo, self._pairs.items, {}, struct {
            fn lessThan(_: void, a: BracketPairInfo, b: BracketPairInfo) bool {
                return a._startOffset < b._startOffset;
            }
        }.lessThan);
        std.sort.heap(BracketInfo, self._brackets.items, {}, struct {
            fn lessThan(_: void, a: BracketInfo, b: BracketInfo) bool {
                return a._startOffset < b._startOffset;
            }
        }.lessThan);
        self._onDidChange.fire({}) catch {};
    }

    fn walk(self: *Self, node: *tree.AstNode, depth: usize, counts: *std.StringHashMap(usize)) !void {
        switch (node.data) {
            .text => {},
            .invalid_bracket => |invalid| {
                try self.appendBracketInfo(invalid.info, depth, 0, true);
            },
            .bracket => {
                try self.appendBracketInfo(node.data.bracket.info, depth, 0, false);
            },
            .pair => |pair| {
                const open = pair.opening;
                const info = open.data.bracket.info;
                const equalLevel = counts.get(info.bracket_text) orelse 0;
                try self.appendBracketInfo(info, depth, equalLevel, false);
                try counts.put(info.bracket_text, equalLevel + 1);
                defer counts.put(info.bracket_text, equalLevel) catch {};
                if (pair.child) |child| try self.walk(child, depth + 1, counts);

                var endPosition = tree.lengthToPosition(tree.lengthAdd(tree.positionToLength(info.range.startPosition()), node.length));
                if (pair.closing) |closing| {
                    const closeInfo = closing.data.bracket.info;
                    try self.appendBracketInfo(closeInfo, depth, equalLevel, false);
                    endPosition = closeInfo.range.endPosition();
                }
                try self._pairs.append(.{
                    .range = Range.init(info.range.startLineNumber, info.range.startColumn, endPosition.lineNumber, endPosition.column),
                    .openingBracketRange = info.range,
                    .closingBracketRange = if (pair.closing) |closing| closing.data.bracket.info.range else null,
                    .nestingLevel = depth,
                    .nestingLevelOfEqualBracketType = equalLevel,
                    .openingBracket = info.bracket_text,
                    .closingBracket = if (pair.closing) |closing| closing.data.bracket.info.bracket_text else null,
                    .isColorized = info.colorized,
                    ._startOffset = self.textModel.getOffsetAt(info.range.startPosition()),
                    ._endOffset = self.textModel.getOffsetAt(endPosition),
                });
            },
            .list => |list| {
                for (list.children.items) |child| try self.walk(child, depth, counts);
            },
        }
    }

    fn appendBracketInfo(self: *Self, info: tree.BracketInfo, depth: usize, equalLevel: usize, invalid: bool) !void {
        try self._brackets.append(.{
            .range = info.range,
            .nestingLevel = depth,
            .nestingLevelOfEqualBracketType = equalLevel,
            .isInvalid = invalid,
            .isColorized = info.colorized,
            .bracketText = info.bracket_text,
            .languageId = info.language_id,
            ._startOffset = self.textModel.getOffsetAt(info.range.startPosition()),
            ._endOffset = self.textModel.getOffsetAt(info.range.endPosition()),
        });
    }

    pub fn getBracketPairsInRange(self: *Self, range: Range) !ArrayList(BracketPairInfo) {
        try self.ensureUpToDate();
        const start = self.textModel.getOffsetAt(range.startPosition());
        const end = self.textModel.getOffsetAt(range.endPosition());
        var result = ArrayList(BracketPairInfo).init(self.allocator);
        errdefer result.deinit();
        for (self._pairs.items) |pair| {
            if (pair._startOffset <= end and pair._endOffset >= start) try result.append(pair);
        }
        return result;
    }

    pub fn getBracketPairsInRangeWithMinIndentation(self: *Self, range: Range) !ArrayList(BracketPairInfo) {
        return self.getBracketPairsInRange(range);
    }

    pub fn getBracketsInRange(self: *Self, range: Range, onlyColorized: bool) !ArrayList(BracketInfo) {
        try self.ensureUpToDate();
        const start = self.textModel.getOffsetAt(range.startPosition());
        const end = self.textModel.getOffsetAt(range.endPosition());
        var result = ArrayList(BracketInfo).init(self.allocator);
        errdefer result.deinit();
        for (self._brackets.items) |bracket| {
            if (bracket._startOffset <= end and bracket._endOffset >= start and (!onlyColorized or bracket.isColorized)) {
                try result.append(bracket);
            }
        }
        return result;
    }

    pub fn hasUnmatchedClosingBracketAfter(self: *Self, position: Position, openingBracket: []const u8) bool {
        var lineNumber: usize = 1;
        while (lineNumber <= self.textModel.getLineCount()) : (lineNumber += 1) {
            if (!self.textModel.hasAccurateTokensForLine(lineNumber)) return false;
        }
        self.ensureUpToDate() catch return false;
        const offset = self.textModel.getOffsetAt(position);
        for (self._brackets.items) |bracket| {
            if (!bracket.isInvalid or bracket._startOffset < offset) continue;
            if (isClosingBracketOf(self.languageService, bracket.languageId, openingBracket, bracket.bracketText)) return true;
        }
        return false;
    }

    pub fn findMatchingBracketUp(self: *Self, bracket: []const u8, position: Position, maxDuration: ?i64) ?Range {
        _ = maxDuration;
        self.ensureUpToDate() catch return null;
        const offset = self.textModel.getOffsetAt(position);
        var result: ?BracketPairInfo = null;
        for (self._pairs.items) |pair| {
            if (pair._startOffset <= offset and pair._endOffset >= offset) {
                if (pair.closingBracket) |closing| {
                    if (std.mem.eql(u8, closing, bracket)) result = pair;
                }
            }
        }
        return if (result) |pair| pair.openingBracketRange else null;
    }

    pub fn findPrevBracket(self: *Self, position: Position) ?BracketInfo {
        self.ensureUpToDate() catch return null;
        const offset = self.textModel.getOffsetAt(position);
        var result: ?BracketInfo = null;
        for (self._brackets.items) |bracket| {
            if (bracket._endOffset <= offset) result = bracket;
        }
        return result;
    }

    pub fn findNextBracket(self: *Self, position: Position) ?BracketInfo {
        self.ensureUpToDate() catch return null;
        const offset = self.textModel.getOffsetAt(position);
        for (self._brackets.items) |bracket| {
            if (bracket._startOffset >= offset) return bracket;
        }
        return null;
    }

    pub fn findEnclosingBrackets(self: *Self, position: Position, maxDuration: ?i64) ?[2]Range {
        _ = maxDuration;
        self.ensureUpToDate() catch return null;
        const offset = self.textModel.getOffsetAt(position);
        var best: ?BracketPairInfo = null;
        for (self._pairs.items) |pair| {
            if (pair._startOffset <= offset and pair._endOffset >= offset) {
                if (best == null or pair._endOffset - pair._startOffset < best.?._endOffset - best.?._startOffset) {
                    best = pair;
                }
            }
        }
        if (best) |pair| {
            if (pair.closingBracketRange) |closeRange| return .{ pair.openingBracketRange, closeRange };
        }
        return null;
    }

    pub fn matchBracket(self: *Self, position: Position, maxDuration: ?i64) ?[2]Range {
        _ = maxDuration;
        self.ensureUpToDate() catch return null;
        const offset = self.textModel.getOffsetAt(position);
        for (self._brackets.items) |bracket| {
            if (bracket._startOffset <= offset and bracket._endOffset >= offset) {
                for (self._pairs.items) |pair| {
                    if (pair._startOffset == bracket._startOffset) {
                        if (pair.closingBracketRange) |closeRange| return .{ pair.openingBracketRange, closeRange };
                    } else if (pair.closingBracketRange) |closeRange| {
                        const closeStart = self.textModel.getOffsetAt(closeRange.startPosition());
                        if (closeStart == bracket._startOffset) return .{ pair.openingBracketRange, closeRange };
                    }
                }
            }
        }
        return null;
    }
};

fn isClosingBracketOf(service: *LanguageService, languageId: []const u8, openingBracket: []const u8, closingText: []const u8) bool {
    const config = service.getLanguageConfiguration(languageId) orelse return false;
    if (config.brackets) |brackets| {
        for (brackets) |pair| {
            if (std.mem.eql(u8, pair[0], openingBracket) and std.mem.eql(u8, pair[1], closingText)) return true;
        }
    }
    return false;
}
