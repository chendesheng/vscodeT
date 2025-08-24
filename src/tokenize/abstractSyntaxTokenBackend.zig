const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const TextModel = @import("../textModel.zig").TextModel;
const LineTokens = @import("../tokens/lineTokens.zig").LineTokens;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;
const Emitter = @import("../basics/event.zig").Emitter;
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
const ModelContentChangedEvent = @import("../textModelEvents.zig").ModelContentChangedEvent;
const LineRange = @import("../basics/lineRange.zig").LineRange;
const LineRangeSet = @import("../basics/lineRange.zig").LineRangeSet;
const Set = @import("../basics/set.zig").Set;
const Pair = @import("../basics/utils.zig").Pair;
const pair = @import("../basics/utils.zig").pair;
const ModelTokensChangedEvent = @import("../textModelEvents.zig").ModelTokensChangedEvent;

pub const BackgroundTokenizationState = enum(u8) {
    InProgress = 1,
    Completed = 2,
};

pub const AttachedViewAndState = Pair(AttachedView, ?AttachedViewState);

// @internal
pub const AttachedViews = struct {
    _onDidChangeVisibleRanges: Emitter(AttachedViewAndState),
    _views: Set(AttachedView),
    visibleLineRanges: ArrayList(LineRange),

    pub fn init(allocator: Allocator) AttachedViews {
        return AttachedViews{
            ._onDidChangeVisibleRanges = Emitter(AttachedViewAndState).init(allocator),
            ._views = Set(AttachedView).init(allocator),
            .visibleLineRanges = ArrayList(LineRange).init(allocator),
        };
    }

    pub fn deinit(self: *AttachedViews) void {
        self._onDidChangeVisibleRanges.deinit();
        // for (self._views.values()) |*view| {
        //     view.deinit();
        // }
        self._views.deinit();
    }

    fn triggerViewChanged(self: *AttachedViews) !void {
        var set = LineRangeSet.empty(self.visibleLineRanges.allocator);
        defer set.deinit();

        for (self._views.values()) |view| {
            if (view._state) |state| {
                for (state.visibleLineRanges) |lineRange| {
                    try set.addRange(lineRange);
                }
            }
        }

        self.visibleLineRanges.clearRetainingCapacity();
        try self.visibleLineRanges.appendSlice(set.ranges());
    }

    pub fn onDidChangeVisibleRanges(self: *AttachedViews, ctx: anytype, callback: *const fn (e: AttachedViewAndState, ctx: @TypeOf(ctx)) void) !void {
        self._onDidChangeVisibleRanges.event(ctx, callback);
        try self.triggerViewChanged();
    }

    pub fn attachView(self: *AttachedViews) !AttachedView {
        const view = AttachedView.init(struct {
            fn handle(view: *AttachedView, state: AttachedViewState) void {
                self._onDidChangeVisibleRanges.fire(pair(view, state));
            }
        }.handle);
        try self._views.add(view);
        try self.triggerViewChanged();
        return view;
    }

    pub fn detachView(self: *AttachedViews, view: AttachedView) !void {
        self._views.delete(view);
        try self._onDidChangeVisibleRanges.fire(pair(view, null));
        try self.triggerViewChanged();
    }
};

fn lineRangeSliceEquals(a: []const LineRange, b: []const LineRange) bool {
    if (a.len != b.len) {
        return false;
    }
    for (0..a.len) |i| {
        if (!a[i].equals(b[i])) {
            return false;
        }
    }
    return true;
}

// @internal
pub const AttachedViewState = struct {
    visibleLineRanges: ArrayList(LineRange),
    stabilized: bool,

    pub fn init(visibleLineRanges: ArrayList(LineRange), stabilized: bool) AttachedViewState {
        return AttachedViewState{ .visibleLineRanges = visibleLineRanges, .stabilized = stabilized };
    }

    pub fn deinit(self: *AttachedViewState) void {
        self.visibleLineRanges.deinit();
    }

    pub fn equals(self: AttachedViewState, other: AttachedViewState) bool {
        if (self == other) {
            return true;
        }
        if (!lineRangeSliceEquals(self.visibleLineRanges.items, other.visibleLineRanges.items)) {
            return false;
        }
        if (self.stabilized != other.stabilized) {
            return false;
        }
        return true;
    }
};

pub const AttachedView = struct {
    _state: ?AttachedViewState,
    handleStateChange: *const fn (self: *AttachedView, state: AttachedViewState) void,

    pub fn init(handleStateChange: *const fn (self: *AttachedView, state: AttachedViewState) void) AttachedView {
        return AttachedView{
            ._state = null,
            .handleStateChange = handleStateChange,
        };
    }

    pub fn deinit(self: *AttachedView) void {
        if (self._state) |state| {
            state.deinit();
        }
    }

    pub fn setVisibleLines(self: *AttachedView, allocator: Allocator, visibleLines: []const struct { startLineNumber: usize, endLineNumber: usize }, stabilized: bool) !void {
        var visibleLineRanges = ArrayList(LineRange).init(allocator);
        for (visibleLines) |line| {
            try visibleLineRanges.append(LineRange.init(line.startLineNumber, line.endLineNumber + 1));
        }

        if (self._state) |state| {
            state.deinit();
            self._state = null;
        }

        const state = AttachedViewState.init(visibleLineRanges, stabilized);
        self._state = state;
        self.handleStateChange(self.*, state);
    }
};

pub const AttachedViewHandler = struct {
    _computedLineRanges: []LineRange,
    _lineRanges: []LineRange,
    refreshTokens: *const fn (AttachedViewHandler) void,

    pub fn init(refreshTokens: *const fn (AttachedViewHandler) void) AttachedViewHandler {
        return AttachedViewHandler{
            ._computedLineRanges = &[_]LineRange{},
            ._lineRanges = &[_]LineRange{},
            .refreshTokens = refreshTokens,
        };
    }

    pub fn update(self: *AttachedViewHandler) void {
        if (lineRangeSliceEquals(self._computedLineRanges, self._lineRanges)) {
            return;
        }
        self._computedLineRanges = self._lineRanges;
        self.refreshTokens(self);
    }

    pub fn handleStateChange(self: *AttachedViewHandler, state: AttachedViewState) void {
        self._lineRanges = state.visibleLineRanges.items;
        if (state.stabilized) {
            self.update();
        }
    }
};

pub const AbstractSyntaxTokenBackend = struct {
    _backgroundTokenizationState: BackgroundTokenizationState,
    _languageIdCodec: LanguageIdCodec,
    _textModel: *anyopaque,

    _onDidChangeBackgroundTokenizationState: Emitter(void),
    _onDidChangeTokens: Emitter(ModelTokensChangedEvent),

    // handleDidChangeAttached: fn () void,
    // handleDidChangeContent: fn (e: ModelContentChangedEvent) void,
    forceTokenization: *const fn (lineNumber: usize) void,
    // hasAccurateTokensForLine: fn (lineNumber: usize) bool,
    isCheapToTokenize: *const fn (lineNumber: usize) bool,

    getLineTokens: *const fn (lineNumber: usize) LineTokens,
    getTokenTypeIfInsertingCharacter: *const fn (lineNumber: usize, column: usize, character: []const u8) StandardTokenType,
    tokenizeLinesAt: *const fn (lineNumber: usize, lines: []const []const u8) ?[]LineTokens,
    hasTokens: *const fn () bool,

    pub fn init(
        backgroundTokenizationState: BackgroundTokenizationState,
        languageIdCodec: LanguageIdCodec,
        textModel_: *TextModel,
    ) AbstractSyntaxTokenBackend {
        const allocator = textModel_.getAllocator();
        return AbstractSyntaxTokenBackend{
            ._backgroundTokenizationState = backgroundTokenizationState,
            ._languageIdCodec = languageIdCodec,
            ._textModel = textModel_,
            ._onDidChangeBackgroundTokenizationState = Emitter(void).init(allocator),
            ._onDidChangeTokens = Emitter(ModelTokensChangedEvent).init(allocator),
            .forceTokenization = undefined,
            .isCheapToTokenize = undefined,
            .getLineTokens = undefined,
            .getTokenTypeIfInsertingCharacter = undefined,
            .tokenizeLinesAt = undefined,
            .hasTokens = undefined,
        };
    }

    pub fn textModel(self: *AbstractSyntaxTokenBackend) *TextModel {
        return @alignCast(@ptrCast(self._textModel));
    }

    pub fn tokenizeIfCheap(self: *AbstractSyntaxTokenBackend, lineNumber: usize) void {
        if (self.isCheapToTokenize(lineNumber)) {
            self.forceTokenization(lineNumber);
        }
    }

    // @internal, should not be exposed by the text model!
    pub fn onDidChangeBackgroundTokenizationState(self: *AbstractSyntaxTokenBackend, f: *const fn (void) void) void {
        self._onDidChangeBackgroundTokenizationState.event({}, f);
    }

    // //** @internal, should not be exposed by the text model! */
    pub fn onDidChangeTokens(self: *AbstractSyntaxTokenBackend, f: *const fn (ModelTokensChangedEvent, void) void) void {
        self._onDidChangeTokens.event({}, f);
    }
};
