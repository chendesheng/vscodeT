const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TextModel = @import("../textModel.zig").TextModel;
const Model = @import("../../model.zig");
const ModelDecoration = Model.ModelDecoration;
const ModelDecorationOptions = Model.ModelDecorationOptions;
const TrackedRangeStickiness = Model.TrackedRangeStickiness;
const Range = @import("../../core/range.zig").Range;
const BracketInfo = @import("./bracketPairsImpl.zig").BracketInfo;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

/// Decoration provider that materializes bracket-pair colorization as
/// decorations with `bracket-highlighting-N` inline class names.
///
/// Terminal adaptation: the view builds the bracket AST before it resolves
/// decorations, so this provider never builds it from a decoration query.
/// While the AST is dirty it reports no decorations, which keeps a paint from
/// triggering a whole-document tokenization/parse. The rebuilt AST notifies
/// `onDidChange`, and `TextModel` forwards that to the decoration-change event
/// so the view refreshes with the new ranges.
pub const ColorizedBracketPairsDecorationProvider = struct {
    allocator: Allocator,
    textModel: *TextModel,
    _options: [30]ModelDecorationOptions,
    _classNames: [30][]u8,
    _unexpectedOption: ModelDecorationOptions,
    _nextId: u64,
    _onDidChange: Emitter(void),

    pub fn init(allocator: Allocator, textModel: *TextModel) ColorizedBracketPairsDecorationProvider {
        var self = ColorizedBracketPairsDecorationProvider{
            .allocator = allocator,
            .textModel = textModel,
            ._options = undefined,
            ._classNames = undefined,
            ._unexpectedOption = ModelDecorationOptions.init("BracketPairColorization", .NeverGrowsWhenTypingAtEdges),
            ._nextId = 0,
            ._onDidChange = Emitter(void).init(allocator),
        };
        self._unexpectedOption.inlineClassName = "unexpected-closing-bracket";
        for (&self._options, 0..) |*options, i| {
            options.* = ModelDecorationOptions.init("BracketPairColorization", .NeverGrowsWhenTypingAtEdges);
            self._classNames[i] = std.fmt.allocPrint(allocator, "bracket-highlighting-{d}", .{i}) catch unreachable;
            options.inlineClassName = self._classNames[i];
        }
        return self;
    }

    pub fn deinit(self: *ColorizedBracketPairsDecorationProvider) void {
        self._onDidChange.deinit();
        for (self._classNames) |name| self.allocator.free(name);
    }

    /// Upstream `onDidChange`: fired when the bracket tree was rebuilt, which
    /// changes the colorization decorations even though no model decoration
    /// was edited directly.
    pub fn onDidChangeWithContext(self: *ColorizedBracketPairsDecorationProvider, ctx: anytype, callback: fn (void, @TypeOf(ctx)) anyerror!void) !void {
        try self._onDidChange.event(ctx, callback);
    }

    pub fn handleDidChange(self: *ColorizedBracketPairsDecorationProvider) void {
        self._onDidChange.fire({}) catch {};
    }

    pub fn getDecorationsInRange(self: *ColorizedBracketPairsDecorationProvider, range: Range, ownerId: usize, filterOutValidation: bool, onlyMinimapDecorations: bool) !ArrayList(ModelDecoration) {
        _ = filterOutValidation;
        // Upstream only requires an owner id to be supplied; a numeric owner
        // (for example the editor id used by the view model) does not filter
        // these model-wide decorations.
        _ = ownerId;
        var result = ArrayList(ModelDecoration).init(self.allocator);
        if (onlyMinimapDecorations) return result;
        if (!self.textModel.getOptions().bracketPairColorizationOptions.enabled) return result;
        if (self.textModel.bracketPairs().isDirty()) return result;

        var brackets = try self.textModel.bracketPairs().getBracketsInRange(range, true);
        defer brackets.deinit();
        const independent = self.textModel.getOptions().bracketPairColorizationOptions.independentColorPoolPerBracketType;
        for (brackets.items) |bracket| {
            self._nextId += 1;
            const id = (1 << 63) | self._nextId;
            const options = if (bracket.isInvalid) &self._unexpectedOption else blk: {
                const level = if (independent) bracket.nestingLevelOfEqualBracketType else bracket.nestingLevel;
                break :blk &self._options[level % self._options.len];
            };
            try result.append(.{
                .id = id,
                .ownerId = 0,
                .range = bracket.range,
                .options = options,
            });
        }
        return result;
    }

    pub fn getDecorationsInRangeDefault(self: *ColorizedBracketPairsDecorationProvider, range: Range, ownerId: usize, filterOutValidation: bool) !ArrayList(ModelDecoration) {
        return self.getDecorationsInRange(range, ownerId, filterOutValidation, false);
    }

    pub fn getAllDecorations(self: *ColorizedBracketPairsDecorationProvider, ownerId: usize, filterOutValidation: bool) !ArrayList(ModelDecoration) {
        const fullRange = Range.init(1, 1, self.textModel.getLineCount(), self.textModel.getLineMaxColumn(self.textModel.getLineCount()));
        return self.getDecorationsInRange(fullRange, ownerId, filterOutValidation, false);
    }
};
