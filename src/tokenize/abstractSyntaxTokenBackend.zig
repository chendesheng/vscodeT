const std = @import("std");
const ArrayList = std.ArrayList;
const TextModel = @import("../textModel.zig").TextModel;
const LineTokens = @import("../tokens/lineTokens.zig").LineTokens;
const StandardTokenType = @import("../encodedTokenAttributes.zig").StandardTokenType;
const Emitter = @import("../basics/event.zig").Emitter;
const LanguageIdCodec = @import("../languages.zig").LanguageIdCodec;
const ModelContentChangedEvent = @import("../textModelEvents.zig").ModelContentChangedEvent;
const LineRange = @import("../basics/lineRange.zig").LineRange;
const Set = @import("../basics/set.zig").Set;
const Pair = @import("../basics/utils.zig").Pair;
const pair = @import("../basics/utils.zig").pair;

pub const BackgroundTokenizationState = enum(u8) {
    InProgress = 1,
    Completed = 2,
};

// @internal
pub const AttachedViews = struct {
    _onDidChangeVisibleRanges: Emitter(Pair(AttachedView, ?AttachedViewState)),
    _views: Set(AttachedView),
    _viewsChanged: Emitter(void),
    visibleLineRanges: []const LineRange,

    // constructor() {
    //    this.visibleLineRanges = derivedOpts({
    //       owner: this,
    //       equalsFn: itemsEquals(itemEquals())
    //    }, reader => {
    //       this._viewsChanged.read(reader);
    //       const ranges = LineRange.joinMany(
    //          [...this._views].map(view => view.state.read(reader)?.visibleLineRanges ?? [])
    //       );
    //       return ranges;
    //    });
    // }

    pub fn attachView(self: *AttachedViews) AttachedView {
        const view = AttachedView{
            .handleStateChange = struct {
                fn handle(view: AttachedView, state: AttachedViewState) void {
                    self._onDidChangeVisibleRanges.fire(pair(view, state));
                }
            }.handle,
        };
        self._views.add(view);
        self._viewsChanged.trigger(null);
        return view;
    }

    pub fn detachView(self: *AttachedViews, view: AttachedView) void {
        self._views.delete(view);
        self._onDidChangeVisibleRanges.fire(pair(view, null));
        self._viewsChanged.trigger(null);
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
    visibleLineRanges: []const LineRange,
    stabilized: bool,

    pub fn equals(self: AttachedViewState, other: AttachedViewState) bool {
        if (self == other) {
            return true;
        }
        if (!lineRangeSliceEquals(self.visibleLineRanges, other.visibleLineRanges)) {
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
    handleStateChange: fn (self: AttachedView, state: AttachedViewState) void,

    pub fn setVisibleLines(self: *AttachedView, visibleLines: []const struct { startLineNumber: usize, endLineNumber: usize }, stabilized: bool) !void {
        const allocator = std.testing.allocator; // FIXME: use a real allocator
        const visibleLineRanges = ArrayList(LineRange).init(allocator);
        defer visibleLineRanges.deinit();
        for (visibleLines) |line| {
            try visibleLineRanges.append(LineRange.init(line.startLineNumber, line.endLineNumber + 1));
        }

        const state = AttachedViewState{ .visibleLineRanges = visibleLineRanges.items, .stabilized = stabilized };
        self._state = state;
        self.handleStateChange(self.*, state);
    }
};

pub const AttachedViewHandler = struct {
    _computedLineRanges: []LineRange,
    _lineRanges: []LineRange,
    refreshTokens: fn () void,

    pub fn update(self: *AttachedViewHandler) void {
        if (lineRangeSliceEquals(self._computedLineRanges, self._lineRanges)) {
            return;
        }
        self._computedLineRanges = self._lineRanges;
        self.refreshTokens();
    }

    pub fn handleStateChange(self: *AttachedViewHandler, state: AttachedViewState) void {
        self._lineRanges = state.visibleLineRanges;
        if (state.stabilized) {
            self.update();
        }
    }
};

pub const AbstractSyntaxTokenBackend = struct {
    _backgroundTokenizationState: BackgroundTokenizationState,
    _languageIdCodec: LanguageIdCodec,
    _textModel: TextModel,

    _onDidChangeBackgroundTokenizationState: Emitter(void),
    // @internal, should not be exposed by the text model!
    onDidChangeBackgroundTokenizationState: fn () void,
    onDidChangeTokens: fn () void,

    // protected readonly _onDidChangeTokens = this._register(new Emitter<IModelTokensChangedEvent>());
    // //** @internal, should not be exposed by the text model! */
    // public readonly onDidChangeTokens: Event<IModelTokensChangedEvent> = this._onDidChangeTokens.event;

    // todo_resetTokenization: fn (fireTokenChangeEvent: ?bool) void,
    handleDidChangeAttached: fn () void,
    handleDidChangeContent: fn (e: ModelContentChangedEvent) void,
    forceTokenization: fn (lineNumber: usize) void,
    hasAccurateTokensForLine: fn (lineNumber: usize) bool,
    isCheapToTokenize: fn (lineNumber: usize) bool,

    getLineTokens: fn (lineNumber: usize) LineTokens,
    getTokenTypeIfInsertingCharacter: fn (lineNumber: usize, column: usize, character: []const u8) StandardTokenType,
    tokenizeLinesAt: fn (lineNumber: usize, lines: []const []const u8) ?[]LineTokens,
    hasTokens: fn () bool,

    pub fn init(
        backgroundTokenizationState: BackgroundTokenizationState,
        languageIdCodec: LanguageIdCodec,
        textModel: TextModel,
    ) AbstractSyntaxTokenBackend {
        return AbstractSyntaxTokenBackend{
            ._backgroundTokenizationState = backgroundTokenizationState,
            ._languageIdCodec = languageIdCodec,
            ._textModel = textModel,
        };
    }

    pub fn tokenizeIfCheap(self: *AbstractSyntaxTokenBackend, lineNumber: usize) void {
        if (self.isCheapToTokenize(lineNumber)) {
            self.forceTokenization(lineNumber);
        }
    }
};
