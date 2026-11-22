// Port of `src/vs/editor/common/model/bracketPairsTextModelPart/bracketPairsImpl.ts`.
//
// The AST-backed queries and the upstream fallback matching/search helpers are
// both ported. Terminal adaptation: bracket colorization and guides consume the
// same AST. The view prepares it before resolving decorations; a large
// document's initial build is deferred to the maintenance pass. Small documents
// are tokenized eagerly so their first tree sees string/comment tokens; larger
// ones start from upstream's fast tree and are rebuilt token-aware when the
// background tokenizer completes. Matching uses the upstream fallback only when
// colorization is off (or the document exceeds the upstream AST size limit).
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TextModel = @import("../textModel.zig").TextModel;
const LanguageService = @import("../../services/languageService.zig").LanguageService;
const LanguageConfiguration = @import("../../languages/languageConfiguration.zig").LanguageConfiguration;
const range_module = @import("../../core/range.zig");
const Range = range_module.Range;
const Position = @import("../../core/position.zig").Position;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const tree = @import("./bracketPairsTree/bracketPairsTree.zig");
const TextEditInfo = @import("./bracketPairsTree/beforeEditPositionMapper.zig").TextEditInfo;
const combineTextEditInfos = @import("./bracketPairsTree/combineTextEditInfos.zig").combineTextEditInfos;
const ModelContentChangedEvent = @import("../../textModelEvents.zig").ModelContentChangedEvent;
const ModelTokensChangedEvent = @import("../../textModelEvents.zig").ModelTokensChangedEvent;
const ResolvedLanguageConfiguration = @import("../../languages/languageConfigurationRegistry.zig").ResolvedLanguageConfiguration;
const RichEditBrackets = @import("../../languages/supports/richEditBrackets.zig").RichEditBrackets;
const RichEditBracket = @import("../../languages/supports/richEditBrackets.zig").RichEditBracket;
const BracketsUtils = @import("../../languages/supports/richEditBrackets.zig").BracketsUtils;
const ignoreBracketsInToken = @import("../../languages/supports.zig").ignoreBracketsInToken;
const LineTokens = @import("../../tokens/lineTokens.zig").LineTokens;
const StandardTokenType = @import("../../encodedTokenAttributes.zig").StandardTokenType;
const time_compat = @import("../../../../base/common/timeCompat.zig");
const NULL_LANGUAGE_ID = @import("../../languages.zig").NULL_LANGUAGE_ID;

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

/// Upstream `BracketPairWithMinIndentationInfo`. The port keeps the pair info
/// and the computed indentation side by side instead of subclassing.
pub const BracketPairWithMinIndentationInfo = struct {
    pair: BracketPairInfo,
    /// `tree.max_safe_integer` when the pair contains no non-whitespace text.
    minVisibleColumnIndentation: i64,
};

/// Upstream obtains `RichEditBrackets`/`bracketsNew` from the language
/// configuration service. The terminal host owns the resolved configuration
/// in its registry, so the provider hands out a stable pointer instead of a
/// by-value copy.
pub const LanguageConfigurationProvider = struct {
    context: *anyopaque,
    get: *const fn (context: *anyopaque, language_id: []const u8) ?*const ResolvedLanguageConfiguration,
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
    _building: bool,
    _document: ?tree.ParsedDocument,
    /// Whether the current document was parsed without token metadata. Such a
    /// tree has to be rebuilt when background tokenization completes.
    _uses_fast_tokens: bool,
    _queuedEdits: ArrayList(TextEditInfo),
    _onDidChange: Emitter(void),
    language_configuration_provider: ?LanguageConfigurationProvider = null,

    pub fn init(allocator: Allocator, textModel: *TextModel, languageService: *LanguageService) Self {
        return .{
            .allocator = allocator,
            .textModel = textModel,
            .languageService = languageService,
            ._pairs = ArrayList(BracketPairInfo).init(allocator),
            ._brackets = ArrayList(BracketInfo).init(allocator),
            ._dirty = true,
            ._fullRebuild = true,
            ._building = false,
            ._document = null,
            ._uses_fast_tokens = true,
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

    /// Installs the resolved-language-configuration provider used by the
    /// upstream fallback matcher.
    pub fn setLanguageConfigurationProvider(self: *Self, provider: LanguageConfigurationProvider) void {
        self.language_configuration_provider = provider;
    }

    fn resolvedConfig(self: *Self, language_id: []const u8) ?*const ResolvedLanguageConfiguration {
        const provider = self.language_configuration_provider orelse return null;
        return provider.get(provider.context, language_id);
    }

    /// Upstream builds the bracket AST only below this size.
    fn canBuildAst(self: *Self) bool {
        const max_supported_document_length: usize = 50_000 * 100;
        return self.textModel.getValueLength(null, false) <= max_supported_document_length;
    }

    /// The terminal has no background tokenizer and disables bracket-pair
    /// colorization, so the AST has no consumer beyond guides; matching uses
    /// the upstream fallback (which tokenizes only the lines it scans) when
    /// colorization is off or the document is too large for the AST.
    pub fn useFallbackMatcher(self: *Self) bool {
        return !self.textModel.getOptions().bracketPairColorizationOptions.enabled or !self.canBuildAst();
    }

    pub fn onDidChange(self: *Self, callback: *const fn (void) void) !void {
        try self._onDidChange.eventVoid(callback);
    }

    pub fn onDidChangeWithContext(self: *Self, ctx: anytype, callback: fn (void, @TypeOf(ctx)) anyerror!void) !void {
        try self._onDidChange.event(ctx, callback);
    }

    /// Whether an AST has been built already. The view uses this to defer only
    /// the initial whole-document build for large documents.
    pub fn hasDocument(self: *const Self) bool {
        return self._document != null;
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
        self._onDidChange.fire({}) catch {};
    }

    pub fn handleDidChangeLanguage(self: *Self) void {
        self.markDirty();
        self._onDidChange.fire({}) catch {};
    }

    /// Upstream `handleDidChangeBackgroundTokenizationState`: the fast initial
    /// tree is only a lower-fidelity stand-in, so replace it with the
    /// token-aware tree once the background tokenizer has seen every line.
    pub fn handleDidChangeBackgroundTokenizationState(self: *Self) void {
        if (!self.textModel.getOptions().bracketPairColorizationOptions.enabled) return;
        const had_document = self._document != null;
        self.markDirty();
        if (had_document) {
            // Running from the idle maintenance pass: update now so the view
            // never repaints with the fast tree's colors once accurate tokens
            // are available.
            self.updateNow() catch {
                self._onDidChange.fire({}) catch {};
            };
        } else {
            self._onDidChange.fire({}) catch {};
        }
    }

    /// Upstream `handleDidChangeTokens`: queue a same-length reparse of every
    /// retokenized line range. While the initial fast tree is still in use,
    /// token updates cannot change it; the background-tokenization completion
    /// event performs the one-time switch to the token-aware tree instead.
    pub fn handleDidChangeTokens(self: *Self, event: ModelTokensChangedEvent) void {
        if (self._uses_fast_tokens) {
            if (self.textModel.getBackgroundTokenizationState() != .Completed) return;
            self.markDirty();
            self._onDidChange.fire({}) catch {};
            return;
        }
        if (self._document == null or event.ranges.len == 0) return;

        var edits = ArrayList(TextEditInfo).init(self.allocator);
        defer edits.deinit();
        for (event.ranges) |range| {
            if (range.fromLineNumber == 0 or range.toLineNumber < range.fromLineNumber) continue;
            edits.append(.{
                .startOffset = tree.toLength(range.fromLineNumber - 1, 0),
                .endOffset = tree.toLength(range.toLineNumber, 0),
                .newLength = tree.toLength(range.toLineNumber - range.fromLineNumber + 1, 0),
            }) catch {
                self.markDirty();
                return;
            };
        }
        if (edits.items.len == 0) return;
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

    pub fn markDirty(self: *Self) void {
        self._dirty = true;
        self._fullRebuild = true;
        self._queuedEdits.clearRetainingCapacity();
    }

    pub fn isDirty(self: *const Self) bool {
        return self._dirty;
    }

    /// Builds/refreshes the AST immediately. Used by the deferred
    /// bracket-guide pass in the terminal main loop.
    pub fn updateNow(self: *Self) !void {
        try self.ensureUpToDate();
    }

    fn ensureUpToDate(self: *Self) !void {
        if (self._building) {
            self._dirty = true;
            return;
        }
        if (!self._dirty) return;
        self._dirty = false;
        self._building = true;
        defer self._building = false;
        self._pairs.clearRetainingCapacity();
        self._brackets.clearRetainingCapacity();

        const full_rebuild = self._fullRebuild or self._document == null;
        const colorization_enabled = self.textModel.getOptions().bracketPairColorizationOptions.enabled;
        if (full_rebuild) {
            if (colorization_enabled and self.textModel.getLineCount() <= tree.eager_build_line_count and
                !tree.allLinesHaveAccurateTokens(self.textModel))
            {
                // Eager whole-document tokenization is only affordable for
                // small documents; above the threshold the fast initial tree
                // is used until the background tokenizer completes.
                self.textModel.forceTokenization(self.textModel.getLineCount());
            }
            self._uses_fast_tokens = colorization_enabled and
                !tree.allLinesHaveAccurateTokens(self.textModel) and
                self.textModel.getBackgroundTokenizationState() != .Completed;
        }

        var doc: tree.ParsedDocument = undefined;
        if (full_rebuild) {
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
        self._dirty = false;
        self._fullRebuild = false;
        self._queuedEdits.clearRetainingCapacity();
        var counts = std.StringHashMap(usize).init(self.allocator);
        defer counts.deinit();
        try self.walk(doc.root, 0, 0, &counts);

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

    fn walk(self: *Self, node: *tree.AstNode, nodeOffset: tree.Length, depth: usize, counts: *std.StringHashMap(usize)) !void {
        switch (node.data) {
            .text => {},
            .invalid_bracket => |invalid| {
                const range = tree.lengthsToRange(nodeOffset, tree.lengthAdd(nodeOffset, node.length));
                try self.appendBracketInfo(invalid.info, range, depth, 0, true);
            },
            .bracket => {
                const range = tree.lengthsToRange(nodeOffset, tree.lengthAdd(nodeOffset, node.length));
                try self.appendBracketInfo(node.data.bracket.info, range, depth, 0, false);
            },
            .pair => |pair| {
                const open = pair.opening;
                const info = open.data.bracket.info;
                const equalLevel = counts.get(info.bracket_text) orelse 0;
                const openingRange = tree.lengthsToRange(nodeOffset, tree.lengthAdd(nodeOffset, open.length));
                try self.appendBracketInfo(info, openingRange, depth, equalLevel, false);
                try counts.put(info.bracket_text, equalLevel + 1);
                defer counts.put(info.bracket_text, equalLevel) catch {};
                var offset = tree.lengthAdd(nodeOffset, open.length);
                if (pair.child) |child| {
                    try self.walk(child, offset, depth + 1, counts);
                    offset = tree.lengthAdd(offset, child.length);
                }

                var closingRange: ?Range = null;
                if (pair.closing) |closing| {
                    const closeInfo = closing.data.bracket.info;
                    closingRange = tree.lengthsToRange(offset, tree.lengthAdd(offset, closing.length));
                    try self.appendBracketInfo(closeInfo, closingRange.?, depth, equalLevel, false);
                    offset = tree.lengthAdd(offset, closing.length);
                }
                const pairRange = tree.lengthsToRange(nodeOffset, offset);
                try self._pairs.append(.{
                    .range = pairRange,
                    .openingBracketRange = openingRange,
                    .closingBracketRange = closingRange,
                    .nestingLevel = depth,
                    .nestingLevelOfEqualBracketType = equalLevel,
                    .openingBracket = info.bracket_text,
                    .closingBracket = if (pair.closing) |closing| closing.data.bracket.info.bracket_text else null,
                    .isColorized = info.colorized,
                    ._startOffset = self.textModel.getOffsetAt(pairRange.startPosition()),
                    ._endOffset = self.textModel.getOffsetAt(pairRange.endPosition()),
                });
            },
            .list => |list| {
                var offset = nodeOffset;
                for (list.children.items) |child| {
                    try self.walk(child, offset, depth, counts);
                    offset = tree.lengthAdd(offset, child.length);
                }
            },
        }
    }

    fn appendBracketInfo(self: *Self, info: tree.BracketInfo, range: Range, depth: usize, equalLevel: usize, invalid: bool) !void {
        try self._brackets.append(.{
            .range = range,
            .nestingLevel = depth,
            .nestingLevelOfEqualBracketType = equalLevel,
            .isInvalid = invalid,
            .isColorized = info.colorized,
            .bracketText = info.bracket_text,
            .languageId = info.language_id,
            ._startOffset = self.textModel.getOffsetAt(range.startPosition()),
            ._endOffset = self.textModel.getOffsetAt(range.endPosition()),
        });
    }

    pub fn getBracketPairsInRange(self: *Self, range: Range) !ArrayList(BracketPairInfo) {
        if (!self.canBuildAst()) return ArrayList(BracketPairInfo).init(self.allocator);
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

    pub fn getBracketPairsInRangeWithMinIndentation(self: *Self, range: Range) !ArrayList(BracketPairWithMinIndentationInfo) {
        if (!self.canBuildAst()) return ArrayList(BracketPairWithMinIndentationInfo).init(self.allocator);
        try self.ensureUpToDate();

        const document = self._document orelse return ArrayList(BracketPairWithMinIndentationInfo).init(self.allocator);
        const start_length = tree.positionToLength(range.getStartPosition());
        const end_length = tree.positionToLength(range.getEndPosition());

        var result = ArrayList(BracketPairWithMinIndentationInfo).init(self.allocator);
        errdefer result.deinit();
        var counts = std.StringHashMap(usize).init(self.allocator);
        defer counts.deinit();
        _ = try self.collectBracketPairsWithMinIndentation(
            document.root,
            0,
            start_length,
            end_length,
            0,
            &counts,
            &result,
        );
        return result;
    }

    /// Upstream `collectBracketPairs` with `includeMinIndentation = true`.
    fn collectBracketPairsWithMinIndentation(
        self: *Self,
        node: *tree.AstNode,
        node_offset: tree.Length,
        start_offset: tree.Length,
        end_offset: tree.Length,
        level: usize,
        counts: *std.StringHashMap(usize),
        result: *ArrayList(BracketPairWithMinIndentationInfo),
    ) !bool {
        if (level > 200) {
            return true;
        }

        switch (node.data) {
            .pair => |pair| {
                const info = pair.opening.data.bracket.info;
                const equal_level = counts.get(info.bracket_text) orelse 0;
                try counts.put(info.bracket_text, equal_level + 1);
                defer counts.put(info.bracket_text, equal_level) catch {};

                const opening_end = tree.lengthAdd(node_offset, pair.opening.length);
                const pair_end = tree.lengthAdd(node_offset, node.length);
                const pair_range = tree.lengthsToRange(node_offset, pair_end);
                const min_indentation = try tree.computeMinIndentation(node, node_offset, self.textModel);
                const child_length: tree.Length = if (pair.child) |child| child.length else 0;

                try result.append(.{
                    .pair = .{
                        .range = pair_range,
                        .openingBracketRange = tree.lengthsToRange(node_offset, opening_end),
                        .closingBracketRange = if (pair.closing != null)
                            tree.lengthsToRange(tree.lengthAdd(opening_end, child_length), pair_end)
                        else
                            null,
                        .nestingLevel = level,
                        .nestingLevelOfEqualBracketType = equal_level,
                        .openingBracket = info.bracket_text,
                        .closingBracket = if (pair.closing) |closing| closing.data.bracket.info.bracket_text else null,
                        .isColorized = info.colorized,
                        ._startOffset = self.textModel.getOffsetAt(pair_range.startPosition()),
                        ._endOffset = self.textModel.getOffsetAt(pair_range.endPosition()),
                    },
                    .minVisibleColumnIndentation = min_indentation,
                });

                if (pair.child) |child| {
                    const child_end = tree.lengthAdd(opening_end, child.length);
                    if (tree.lengthLessThanEqual(opening_end, end_offset) and
                        tree.lengthLessThanEqual(start_offset, child_end))
                    {
                        if (!try self.collectBracketPairsWithMinIndentation(
                            child,
                            opening_end,
                            start_offset,
                            end_offset,
                            level + 1,
                            counts,
                            result,
                        )) return false;
                    }
                }
            },
            .list => |list| {
                var offset = node_offset;
                for (list.children.items) |child| {
                    const child_offset = offset;
                    offset = tree.lengthAdd(offset, child.length);

                    if (tree.lengthLessThanEqual(child_offset, end_offset) and
                        tree.lengthLessThanEqual(start_offset, offset))
                    {
                        if (!try self.collectBracketPairsWithMinIndentation(
                            child,
                            child_offset,
                            start_offset,
                            end_offset,
                            level,
                            counts,
                            result,
                        )) return false;
                    }
                }
            },
            .text, .bracket, .invalid_bracket => {},
        }

        return true;
    }

    pub fn getBracketsInRange(self: *Self, range: Range, onlyColorized: bool) !ArrayList(BracketInfo) {
        if (!self.canBuildAst()) return ArrayList(BracketInfo).init(self.allocator);
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
        if (!self.canBuildAst()) return false;
        // The query is only meaningful once the AST can see every line.
        var line_number: usize = 1;
        while (line_number <= self.textModel.getLineCount()) : (line_number += 1) {
            if (!self.textModel.hasAccurateTokensForLine(line_number)) return false;
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
        if (!self.canBuildAst()) {
            return self.findMatchingBracketUpFallback(bracket, position, maxDuration);
        }
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
        if (self.useFallbackMatcher()) return self.findPrevBracketFallback(position);
        self.ensureUpToDate() catch return null;
        const offset = self.textModel.getOffsetAt(position);
        var result: ?BracketInfo = null;
        for (self._brackets.items) |bracket| {
            if (bracket._endOffset <= offset) result = bracket;
        }
        return result;
    }

    pub fn findNextBracket(self: *Self, position: Position) ?BracketInfo {
        if (self.useFallbackMatcher()) return self.findNextBracketFallback(position);
        self.ensureUpToDate() catch return null;
        const offset = self.textModel.getOffsetAt(position);
        for (self._brackets.items) |bracket| {
            if (bracket._startOffset >= offset) return bracket;
        }
        return null;
    }

    pub fn findEnclosingBrackets(self: *Self, position: Position, maxDuration: ?i64) ?[2]Range {
        if (self.useFallbackMatcher()) return self.findEnclosingBracketsFallback(position, maxDuration);
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
        if (self.useFallbackMatcher()) return self.matchBracketFallback(position, maxDuration);
        self.ensureUpToDate() catch return null;

        // Upstream picks the rightmost bracket range containing the position.
        // This matters when two adjacent bracket ranges share a boundary, e.g.
        // `(())` at the column between `)` and `)`: the closing bracket starts
        // where the inner one ends.
        var best: ?BracketPairInfo = null;
        var best_range: ?Range = null;
        for (self._pairs.items) |pair| {
            const close_range = pair.closingBracketRange orelse continue;
            const bracket_range = if (pair.openingBracketRange.containsPosition(&position))
                pair.openingBracketRange
            else if (close_range.containsPosition(&position))
                close_range
            else
                continue;

            if (best_range == null or
                range_module.compareRangesUsingStarts(&bracket_range, &best_range.?) > 0)
            {
                best = pair;
                best_range = bracket_range;
            }
        }

        if (best) |pair| {
            if (pair.closingBracketRange) |close_range| {
                return .{ pair.openingBracketRange, close_range };
            }
        }
        return null;
    }

    // #region Upstream fallback bracket matcher
    //
    // Port of the non-AST branch of `bracketPairsImpl.ts`. The terminal uses
    // it when bracket-pair colorization is disabled (no AST consumer) or the
    // document exceeds the AST size limit. Unlike the AST parser it tokenizes
    // only the lines it actually scans.

    const BracketRangeResult = union(enum) {
        range: Range,
        none,
        canceled,
    };

    const BracketMatchResult = union(enum) {
        pair: [2]Range,
        none,
        canceled,
    };

    const ContinueSearchPredicate = struct {
        deadline_ms: i64,
        calls: usize = 0,

        fn init(max_duration: ?i64) ContinueSearchPredicate {
            return .{ .deadline_ms = if (max_duration) |d| time_compat.milliTimestamp() + d else 0 };
        }

        fn tick(self: *ContinueSearchPredicate) bool {
            self.calls += 1;
            if (self.calls % 100 != 0) return true;
            if (self.deadline_ms == 0) return true;
            return time_compat.milliTimestamp() < self.deadline_ms;
        }
    };

    fn ensureLineTokenized(self: *Self, line_number: usize) void {
        if (!self.textModel.hasAccurateTokensForLine(line_number)) {
            self.textModel.forceTokenization(line_number);
        }
    }

    /// The TextMate adapter in this port leaves token language ids at
    /// `nullLanguage`; the bracket AST parser falls back to the model
    /// language, so the fallback matcher does the same.
    fn tokenLanguage(self: *Self, line_tokens: *const LineTokens, index: usize) []const u8 {
        const language = line_tokens.getLanguageId(index);
        if (std.mem.eql(u8, language, NULL_LANGUAGE_ID)) return self.textModel.getLanguageId();
        return language;
    }

    fn lowerInto(buf: []u8, text: []const u8) ?[]const u8 {
        if (text.len > buf.len) return null;
        for (text, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
        return buf[0..text.len];
    }

    const SearchOffsets = struct {
        start: usize,
        end: usize,
    };

    fn establishBracketSearchOffsets(
        self: *Self,
        line_tokens: *const LineTokens,
        line_text: []const u8,
        position: Position,
        brackets: *const RichEditBrackets,
        token_index: usize,
    ) SearchOffsets {
        const token_count = line_tokens.getCount();
        const current_language = self.tokenLanguage(line_tokens, token_index);
        var start = position.column - 1;
        if (start > brackets.maxBracketLength) start -= brackets.maxBracketLength else start = 0;
        var i = token_index;
        while (i > 0) {
            i -= 1;
            const token_end = line_tokens.getEndOffset(i);
            if (token_end <= start) break;
            if (ignoreBracketsInToken(line_tokens.getStandardTokenType(i)) or
                !std.mem.eql(u8, self.tokenLanguage(line_tokens, i), current_language))
            {
                start = token_end;
                break;
            }
        }

        var end = @min(line_text.len, position.column - 1 + brackets.maxBracketLength);
        i = token_index + 1;
        while (i < token_count) : (i += 1) {
            const token_start = line_tokens.getStartOffset(i);
            if (token_start >= end) break;
            if (ignoreBracketsInToken(line_tokens.getStandardTokenType(i)) or
                !std.mem.eql(u8, self.tokenLanguage(line_tokens, i), current_language))
            {
                end = token_start;
                break;
            }
        }
        return .{ .start = start, .end = end };
    }

    fn matchBracketFallback(self: *Self, position: Position, max_duration: ?i64) ?[2]Range {
        var predicate = ContinueSearchPredicate.init(max_duration);
        return switch (self.matchBracketWithPredicate(position, &predicate)) {
            .pair => |pair| pair,
            else => null,
        };
    }

    fn matchBracketWithPredicate(
        self: *Self,
        position: Position,
        predicate: *ContinueSearchPredicate,
    ) BracketMatchResult {
        const line_number = position.lineNumber;
        self.ensureLineTokenized(line_number);
        var line_text = self.textModel.getLineContent(line_number) catch return .none;
        defer line_text.deinit();
        var line_tokens = self.textModel.tokenization().getLineTokens(line_number) catch return .none;
        defer line_tokens.deinit();
        const token_count = line_tokens.getCount();
        if (token_count == 0) return .none;
        const token_index = line_tokens.findTokenIndexAtOffset(position.column - 1);
        if (token_index >= token_count) return .none;

        const resolved = self.resolvedConfig(self.tokenLanguage(&line_tokens, token_index)) orelse return .none;
        const brackets = resolved.getBrackets() orelse return .none;
        if (!ignoreBracketsInToken(line_tokens.getStandardTokenType(token_index))) {
            const offsets = establishBracketSearchOffsets(self, &line_tokens, line_text.items, position, brackets, token_index);
            var search_start = offsets.start;
            var best: ?[2]Range = null;
            while (true) {
                const found = BracketsUtils.findNextBracketInRange(
                    &brackets.forwardRegex,
                    line_number,
                    line_text.items,
                    search_start,
                    offsets.end,
                ) orelse break;
                if (found.startColumn <= position.column and position.column <= found.endColumn) {
                    var lower_buf: [64]u8 = undefined;
                    const lowered = lowerInto(&lower_buf, line_text.items[found.startColumn - 1 .. found.endColumn - 1]) orelse break;
                    const bracket = brackets.textIsBracket.get(lowered) orelse break;
                    const is_open = brackets.textIsOpenBracket.get(lowered) orelse false;
                    switch (self.matchFoundBracket(found, bracket, is_open, predicate)) {
                        .pair => |pair| best = pair,
                        .canceled => return .canceled,
                        .none => {},
                    }
                }
                search_start = found.endColumn - 1;
            }
            if (best) |pair| return .{ .pair = pair };
        }

        // If the position is between two tokens, also try the previous token.
        if (token_index > 0 and line_tokens.getStartOffset(token_index) == position.column - 1) {
            const prev_index = token_index - 1;
            if (!ignoreBracketsInToken(line_tokens.getStandardTokenType(prev_index))) {
                const prev_resolved = self.resolvedConfig(self.tokenLanguage(&line_tokens, prev_index)) orelse return .none;
                const prev_brackets = prev_resolved.getBrackets() orelse return .none;
                const offsets = establishBracketSearchOffsets(self, &line_tokens, line_text.items, position, prev_brackets, prev_index);
                const found = (BracketsUtils.findPrevBracketInRange(
                    self.allocator,
                    &prev_brackets.reversedRegex,
                    line_number,
                    line_text.items,
                    offsets.start,
                    offsets.end,
                ) catch null) orelse return .none;
                if (found.startColumn <= position.column and position.column <= found.endColumn) {
                    var lower_buf: [64]u8 = undefined;
                    const lowered = lowerInto(&lower_buf, line_text.items[found.startColumn - 1 .. found.endColumn - 1]) orelse return .none;
                    const bracket = prev_brackets.textIsBracket.get(lowered) orelse return .none;
                    const is_open = prev_brackets.textIsOpenBracket.get(lowered) orelse false;
                    return self.matchFoundBracket(found, bracket, is_open, predicate);
                }
            }
        }
        return .none;
    }

    fn matchFoundBracket(
        self: *Self,
        found: Range,
        bracket: *const RichEditBracket,
        is_open: bool,
        predicate: *ContinueSearchPredicate,
    ) BracketMatchResult {
        const matched = if (is_open)
            self.findMatchingBracketDown(bracket, found.getEndPosition(), predicate)
        else
            self.findMatchingBracketUpGroup(bracket, found.getStartPosition(), predicate);
        // The port's AST path returns opening-first; keep the fallback pair
        // ordered the same way (upstream treats the pair as unordered).
        return switch (matched) {
            .range => |range| .{ .pair = if (is_open) .{ found, range } else .{ range, found } },
            .canceled => .canceled,
            .none => .none,
        };
    }

    fn findMatchingBracketUpGroup(
        self: *Self,
        bracket: *const RichEditBracket,
        position: Position,
        predicate: *ContinueSearchPredicate,
    ) BracketRangeResult {
        var count: isize = -1;
        var line_number = position.lineNumber;
        while (line_number >= 1) : (line_number -= 1) {
            self.ensureLineTokenized(line_number);
            var line_text = self.textModel.getLineContent(line_number) catch return .none;
            defer line_text.deinit();
            var line_tokens = self.textModel.tokenization().getLineTokens(line_number) catch return .none;
            defer line_tokens.deinit();
            const token_count = line_tokens.getCount();
            if (token_count == 0) continue;

            var token_index: usize = token_count - 1;
            var search_start = line_text.items.len;
            var search_end = line_text.items.len;
            if (line_number == position.lineNumber) {
                token_index = @min(line_tokens.findTokenIndexAtOffset(position.column - 1), token_count - 1);
                search_start = position.column - 1;
                search_end = position.column - 1;
            }

            var prev_search_in_token = true;
            while (true) {
                const search_in_token = std.mem.eql(u8, self.tokenLanguage(&line_tokens, token_index), bracket.languageId) and
                    !ignoreBracketsInToken(line_tokens.getStandardTokenType(token_index));
                if (search_in_token) {
                    if (prev_search_in_token) {
                        search_start = line_tokens.getStartOffset(token_index);
                    } else {
                        search_start = line_tokens.getStartOffset(token_index);
                        search_end = line_tokens.getEndOffset(token_index);
                    }
                } else if (prev_search_in_token and search_start != search_end) {
                    switch (self.searchPrevMatchingBracketInRange(
                        bracket,
                        line_number,
                        line_text.items,
                        search_start,
                        search_end,
                        &count,
                        predicate,
                    )) {
                        .range => |range| return .{ .range = range },
                        .canceled => return .canceled,
                        .none => {},
                    }
                }
                prev_search_in_token = search_in_token;
                if (token_index == 0) break;
                token_index -= 1;
            }

            if (prev_search_in_token and search_start != search_end) {
                switch (self.searchPrevMatchingBracketInRange(
                    bracket,
                    line_number,
                    line_text.items,
                    search_start,
                    search_end,
                    &count,
                    predicate,
                )) {
                    .range => |range| return .{ .range = range },
                    .canceled => return .canceled,
                    .none => {},
                }
            }
        }
        return .none;
    }

    fn searchPrevMatchingBracketInRange(
        self: *Self,
        bracket: *const RichEditBracket,
        line_number: usize,
        line_text: []const u8,
        start_offset: usize,
        end_offset: usize,
        count: *isize,
        predicate: *ContinueSearchPredicate,
    ) BracketRangeResult {
        var search_end = end_offset;
        while (true) {
            if (!predicate.tick()) return .canceled;
            const found = (BracketsUtils.findPrevBracketInRange(
                self.allocator,
                &bracket.reversedRegex,
                line_number,
                line_text,
                start_offset,
                search_end,
            ) catch return .none) orelse return .none;
            var lower_buf: [64]u8 = undefined;
            const lowered = lowerInto(&lower_buf, line_text[found.startColumn - 1 .. found.endColumn - 1]) orelse return .none;
            if (bracket.isOpen(lowered)) {
                count.* += 1;
            } else if (bracket.isClose(lowered)) {
                count.* -= 1;
            }
            if (count.* == 0) return .{ .range = found };
            search_end = found.startColumn - 1;
        }
    }

    fn findMatchingBracketDown(
        self: *Self,
        bracket: *const RichEditBracket,
        position: Position,
        predicate: *ContinueSearchPredicate,
    ) BracketRangeResult {
        var count: isize = 1;
        const line_count = self.textModel.getLineCount();
        var line_number = position.lineNumber;
        while (line_number <= line_count) : (line_number += 1) {
            self.ensureLineTokenized(line_number);
            var line_text = self.textModel.getLineContent(line_number) catch return .none;
            defer line_text.deinit();
            var line_tokens = self.textModel.tokenization().getLineTokens(line_number) catch return .none;
            defer line_tokens.deinit();
            const token_count = line_tokens.getCount();
            if (token_count == 0) continue;

            var token_index: usize = 0;
            var search_start: usize = 0;
            var search_end: usize = 0;
            if (line_number == position.lineNumber) {
                token_index = @min(line_tokens.findTokenIndexAtOffset(position.column - 1), token_count - 1);
                search_start = position.column - 1;
                search_end = position.column - 1;
            }

            var prev_search_in_token = true;
            while (token_index < token_count) : (token_index += 1) {
                const search_in_token = std.mem.eql(u8, self.tokenLanguage(&line_tokens, token_index), bracket.languageId) and
                    !ignoreBracketsInToken(line_tokens.getStandardTokenType(token_index));
                if (search_in_token) {
                    if (prev_search_in_token) {
                        search_end = line_tokens.getEndOffset(token_index);
                    } else {
                        search_start = line_tokens.getStartOffset(token_index);
                        search_end = line_tokens.getEndOffset(token_index);
                    }
                } else if (prev_search_in_token and search_start != search_end) {
                    switch (searchNextMatchingBracketInRange(
                        bracket,
                        line_number,
                        line_text.items,
                        search_start,
                        search_end,
                        &count,
                        predicate,
                    )) {
                        .range => |range| return .{ .range = range },
                        .canceled => return .canceled,
                        .none => {},
                    }
                }
                prev_search_in_token = search_in_token;
            }

            if (prev_search_in_token and search_start != search_end) {
                switch (searchNextMatchingBracketInRange(
                    bracket,
                    line_number,
                    line_text.items,
                    search_start,
                    search_end,
                    &count,
                    predicate,
                )) {
                    .range => |range| return .{ .range = range },
                    .canceled => return .canceled,
                    .none => {},
                }
            }
        }
        return .none;
    }

    fn searchNextMatchingBracketInRange(
        bracket: *const RichEditBracket,
        line_number: usize,
        line_text: []const u8,
        start_offset: usize,
        end_offset: usize,
        count: *isize,
        predicate: *ContinueSearchPredicate,
    ) BracketRangeResult {
        var search_start = start_offset;
        while (true) {
            if (!predicate.tick()) return .canceled;
            const found = BracketsUtils.findNextBracketInRange(
                &bracket.forwardRegex,
                line_number,
                line_text,
                search_start,
                end_offset,
            ) orelse return .none;
            var lower_buf: [64]u8 = undefined;
            const lowered = lowerInto(&lower_buf, line_text[found.startColumn - 1 .. found.endColumn - 1]) orelse return .none;
            if (bracket.isOpen(lowered)) {
                count.* += 1;
            } else if (bracket.isClose(lowered)) {
                count.* -= 1;
            }
            if (count.* == 0) return .{ .range = found };
            search_start = found.endColumn - 1;
        }
    }

    fn findMatchingBracketUpFallback(self: *Self, bracket: []const u8, position: Position, max_duration: ?i64) ?Range {
        const language_id = self.textModel.getLanguageIdAtPosition(position.lineNumber, position.column);
        const resolved = self.resolvedConfig(language_id) orelse return null;
        const closing = resolved.bracketsNew.getClosingBracketInfo(bracket) orelse return null;
        const rich = resolved.getBrackets() orelse return null;
        const data = rich.textIsBracket.get(closing.bracketText) orelse return null;
        var predicate = ContinueSearchPredicate.init(max_duration);
        return switch (self.findMatchingBracketUpGroup(data, position, &predicate)) {
            .range => |range| range,
            else => null,
        };
    }

    const CountsEntry = struct {
        language_id: []const u8,
        counts: []isize,
    };

    fn savedCounts(
        self: *Self,
        saved: *ArrayList(CountsEntry),
        language_id: []const u8,
        count: usize,
    ) ![]isize {
        for (saved.items) |entry| {
            if (std.mem.eql(u8, entry.language_id, language_id)) return entry.counts;
        }
        const counts = try self.allocator.alloc(isize, count);
        @memset(counts, 0);
        try saved.append(.{ .language_id = language_id, .counts = counts });
        return counts;
    }

    fn searchEnclosingInRange(
        self: *Self,
        brackets: *const RichEditBrackets,
        counts: []isize,
        line_number: usize,
        line_text: []const u8,
        start_offset: usize,
        end_offset: usize,
        predicate: *ContinueSearchPredicate,
    ) BracketMatchResult {
        var search_start = start_offset;
        while (true) {
            if (!predicate.tick()) return .canceled;
            const found = BracketsUtils.findNextBracketInRange(
                &brackets.forwardRegex,
                line_number,
                line_text,
                search_start,
                end_offset,
            ) orelse return .none;
            var lower_buf: [64]u8 = undefined;
            const lowered = lowerInto(&lower_buf, line_text[found.startColumn - 1 .. found.endColumn - 1]) orelse return .none;
            const bracket = brackets.textIsBracket.get(lowered) orelse {
                search_start = found.endColumn - 1;
                continue;
            };
            if (bracket.index >= counts.len) return .none;
            if (bracket.isOpen(lowered)) {
                counts[bracket.index] += 1;
            } else if (bracket.isClose(lowered)) {
                counts[bracket.index] -= 1;
            }
            if (counts[bracket.index] == -1) {
                return self.matchFoundBracket(found, bracket, false, predicate);
            }
            search_start = found.endColumn - 1;
        }
    }

    fn findEnclosingBracketsFallback(self: *Self, position: Position, max_duration: ?i64) ?[2]Range {
        var predicate = ContinueSearchPredicate.init(max_duration);
        const line_count = self.textModel.getLineCount();
        var saved = ArrayList(CountsEntry).init(self.allocator);
        defer {
            for (saved.items) |entry| self.allocator.free(entry.counts);
            saved.deinit();
        }

        var language_id: ?[]const u8 = null;
        var resolved: ?*const ResolvedLanguageConfiguration = null;
        var brackets: ?*const RichEditBrackets = null;
        var counts: []isize = &.{};

        var line_number = position.lineNumber;
        while (line_number <= line_count) : (line_number += 1) {
            self.ensureLineTokenized(line_number);
            var line_text = self.textModel.getLineContent(line_number) catch return null;
            defer line_text.deinit();
            var line_tokens = self.textModel.tokenization().getLineTokens(line_number) catch return null;
            defer line_tokens.deinit();
            const token_count = line_tokens.getCount();
            if (token_count == 0) continue;

            var token_index: usize = 0;
            var search_start: usize = 0;
            var search_end: usize = 0;
            if (line_number == position.lineNumber) {
                token_index = @min(line_tokens.findTokenIndexAtOffset(position.column - 1), token_count - 1);
                search_start = position.column - 1;
                search_end = position.column - 1;
            }

            var prev_search_in_token = true;
            while (token_index < token_count) : (token_index += 1) {
                const token_language = self.tokenLanguage(&line_tokens, token_index);
                if (language_id == null or !std.mem.eql(u8, language_id.?, token_language)) {
                    if (resolved != null and brackets != null and prev_search_in_token and search_start != search_end) {
                        switch (self.searchEnclosingInRange(
                            brackets.?,
                            counts,
                            line_number,
                            line_text.items,
                            search_start,
                            search_end,
                            &predicate,
                        )) {
                            .pair => |pair| return pair,
                            .canceled => return null,
                            .none => {},
                        }
                        prev_search_in_token = false;
                    }
                    language_id = token_language;
                    resolved = self.resolvedConfig(token_language);
                    brackets = if (resolved) |r| r.getBrackets() else null;
                    counts = if (brackets) |b| (self.savedCounts(&saved, token_language, b.brackets.len) catch return null) else &.{};
                }

                const search_in_token = brackets != null and
                    !ignoreBracketsInToken(line_tokens.getStandardTokenType(token_index));
                if (search_in_token) {
                    if (prev_search_in_token) {
                        search_end = line_tokens.getEndOffset(token_index);
                    } else {
                        search_start = line_tokens.getStartOffset(token_index);
                        search_end = line_tokens.getEndOffset(token_index);
                    }
                } else if (resolved != null and brackets != null and prev_search_in_token and search_start != search_end) {
                    switch (self.searchEnclosingInRange(
                        brackets.?,
                        counts,
                        line_number,
                        line_text.items,
                        search_start,
                        search_end,
                        &predicate,
                    )) {
                        .pair => |pair| return pair,
                        .canceled => return null,
                        .none => {},
                    }
                }
                prev_search_in_token = search_in_token;
            }

            if (resolved != null and brackets != null and prev_search_in_token and search_start != search_end) {
                switch (self.searchEnclosingInRange(
                    brackets.?,
                    counts,
                    line_number,
                    line_text.items,
                    search_start,
                    search_end,
                    &predicate,
                )) {
                    .pair => |pair| return pair,
                    .canceled => return null,
                    .none => {},
                }
            }
        }
        return null;
    }

    fn toFoundBracket(self: *Self, resolved: *const ResolvedLanguageConfiguration, found: Range) ?BracketInfo {
        var raw = self.textModel.getValueInRange(found, .TextDefined) catch return null;
        defer raw.deinit();
        var lower_buf: [64]u8 = undefined;
        const lowered = lowerInto(&lower_buf, raw.items) orelse return null;
        const kind = resolved.bracketsNew.getBracketInfo(lowered) orelse return null;
        const bracket_text = switch (kind) {
            .openingBracketKind => |opening| opening.bracketText,
            .closingBracketKind => |closing| closing.bracketText,
        };
        return .{
            .range = found,
            .nestingLevel = 0,
            .nestingLevelOfEqualBracketType = 0,
            .isInvalid = false,
            .isColorized = false,
            .bracketText = bracket_text,
            .languageId = kind.languageId(),
            ._startOffset = self.textModel.getOffsetAt(found.startPosition()),
            ._endOffset = self.textModel.getOffsetAt(found.endPosition()),
        };
    }

    fn findNextBracketFallback(self: *Self, position: Position) ?BracketInfo {
        var resolved: ?*const ResolvedLanguageConfiguration = null;
        var brackets: ?*const RichEditBrackets = null;
        var language_id: ?[]const u8 = null;
        const line_count = self.textModel.getLineCount();

        var line_number = position.lineNumber;
        while (line_number <= line_count) : (line_number += 1) {
            self.ensureLineTokenized(line_number);
            var line_text = self.textModel.getLineContent(line_number) catch return null;
            defer line_text.deinit();
            var line_tokens = self.textModel.tokenization().getLineTokens(line_number) catch return null;
            defer line_tokens.deinit();
            const token_count = line_tokens.getCount();
            if (token_count == 0) continue;

            var token_index: usize = 0;
            var search_start: usize = 0;
            var search_end: usize = 0;
            if (line_number == position.lineNumber) {
                token_index = @min(line_tokens.findTokenIndexAtOffset(position.column - 1), token_count - 1);
                search_start = position.column - 1;
                search_end = position.column - 1;
                const token_language = self.tokenLanguage(&line_tokens, token_index);
                if (language_id == null or !std.mem.eql(u8, language_id.?, token_language)) {
                    language_id = token_language;
                    resolved = self.resolvedConfig(token_language);
                    brackets = if (resolved) |r| r.getBrackets() else null;
                }
            }

            var prev_search_in_token = true;
            while (token_index < token_count) : (token_index += 1) {
                const token_language = self.tokenLanguage(&line_tokens, token_index);
                if (language_id == null or !std.mem.eql(u8, language_id.?, token_language)) {
                    if (resolved != null and brackets != null and prev_search_in_token and search_start != search_end) {
                        const found = BracketsUtils.findNextBracketInRange(
                            &brackets.?.forwardRegex,
                            line_number,
                            line_text.items,
                            search_start,
                            search_end,
                        ) orelse null;
                        if (found) |range| {
                            if (self.toFoundBracket(resolved.?, range)) |info| return info;
                        }
                        prev_search_in_token = false;
                    }
                    language_id = token_language;
                    resolved = self.resolvedConfig(token_language);
                    brackets = if (resolved) |r| r.getBrackets() else null;
                }

                const search_in_token = brackets != null and
                    !ignoreBracketsInToken(line_tokens.getStandardTokenType(token_index));
                if (search_in_token) {
                    if (prev_search_in_token) {
                        search_end = line_tokens.getEndOffset(token_index);
                    } else {
                        search_start = line_tokens.getStartOffset(token_index);
                        search_end = line_tokens.getEndOffset(token_index);
                    }
                } else if (resolved != null and brackets != null and prev_search_in_token and search_start != search_end) {
                    const found = BracketsUtils.findNextBracketInRange(
                        &brackets.?.forwardRegex,
                        line_number,
                        line_text.items,
                        search_start,
                        search_end,
                    ) orelse null;
                    if (found) |range| {
                        if (self.toFoundBracket(resolved.?, range)) |info| return info;
                    }
                }
                prev_search_in_token = search_in_token;
            }

            if (resolved != null and brackets != null and prev_search_in_token and search_start != search_end) {
                const found = BracketsUtils.findNextBracketInRange(
                    &brackets.?.forwardRegex,
                    line_number,
                    line_text.items,
                    search_start,
                    search_end,
                ) orelse null;
                if (found) |range| {
                    if (self.toFoundBracket(resolved.?, range)) |info| return info;
                }
            }
        }
        return null;
    }

    fn findPrevBracketFallback(self: *Self, position: Position) ?BracketInfo {
        var resolved: ?*const ResolvedLanguageConfiguration = null;
        var brackets: ?*const RichEditBrackets = null;
        var language_id: ?[]const u8 = null;

        var line_number = position.lineNumber;
        while (line_number >= 1) : (line_number -= 1) {
            self.ensureLineTokenized(line_number);
            var line_text = self.textModel.getLineContent(line_number) catch return null;
            defer line_text.deinit();
            var line_tokens = self.textModel.tokenization().getLineTokens(line_number) catch return null;
            defer line_tokens.deinit();
            const token_count = line_tokens.getCount();
            if (token_count == 0) continue;

            var token_index: usize = token_count - 1;
            var search_start = line_text.items.len;
            var search_end = line_text.items.len;
            if (line_number == position.lineNumber) {
                token_index = @min(line_tokens.findTokenIndexAtOffset(position.column - 1), token_count - 1);
                search_start = position.column - 1;
                search_end = position.column - 1;
                const token_language = self.tokenLanguage(&line_tokens, token_index);
                if (language_id == null or !std.mem.eql(u8, language_id.?, token_language)) {
                    language_id = token_language;
                    resolved = self.resolvedConfig(token_language);
                    brackets = if (resolved) |r| r.getBrackets() else null;
                }
            }

            var prev_search_in_token = true;
            while (true) {
                const token_language = self.tokenLanguage(&line_tokens, token_index);
                if (language_id == null or !std.mem.eql(u8, language_id.?, token_language)) {
                    if (resolved != null and brackets != null and prev_search_in_token and search_start != search_end) {
                        const found = (BracketsUtils.findPrevBracketInRange(
                            self.allocator,
                            &brackets.?.reversedRegex,
                            line_number,
                            line_text.items,
                            search_start,
                            search_end,
                        ) catch null) orelse null;
                        if (found) |range| {
                            if (self.toFoundBracket(resolved.?, range)) |info| return info;
                        }
                        prev_search_in_token = false;
                    }
                    language_id = token_language;
                    resolved = self.resolvedConfig(token_language);
                    brackets = if (resolved) |r| r.getBrackets() else null;
                }

                const search_in_token = brackets != null and
                    !ignoreBracketsInToken(line_tokens.getStandardTokenType(token_index));
                if (search_in_token) {
                    if (prev_search_in_token) {
                        search_start = line_tokens.getStartOffset(token_index);
                    } else {
                        search_start = line_tokens.getStartOffset(token_index);
                        search_end = line_tokens.getEndOffset(token_index);
                    }
                } else if (resolved != null and brackets != null and prev_search_in_token and search_start != search_end) {
                    const found = (BracketsUtils.findPrevBracketInRange(
                        self.allocator,
                        &brackets.?.reversedRegex,
                        line_number,
                        line_text.items,
                        search_start,
                        search_end,
                    ) catch null) orelse null;
                    if (found) |range| {
                        if (self.toFoundBracket(resolved.?, range)) |info| return info;
                    }
                }
                prev_search_in_token = search_in_token;
                if (token_index == 0) break;
                token_index -= 1;
            }

            if (resolved != null and brackets != null and prev_search_in_token and search_start != search_end) {
                const found = (BracketsUtils.findPrevBracketInRange(
                    self.allocator,
                    &brackets.?.reversedRegex,
                    line_number,
                    line_text.items,
                    search_start,
                    search_end,
                ) catch null) orelse null;
                if (found) |range| {
                    if (self.toFoundBracket(resolved.?, range)) |info| return info;
                }
            }
        }
        return null;
    }

    // #endregion
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
