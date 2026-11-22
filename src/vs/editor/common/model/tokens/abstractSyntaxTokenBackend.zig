// Port of `src/vs/editor/common/model/tokens/abstractSyntaxTokenBackend.ts`.
//
// The 50 ms RunOnceScheduler is replaced by the TUI's frame-driven refresh;
// the attached-view visible-range plumbing is kept.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TextModel = @import("../textModel.zig").TextModel;
const LineTokens = @import("../../tokens/lineTokens.zig").LineTokens;
const StandardTokenType = @import("../../encodedTokenAttributes.zig").StandardTokenType;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const LanguageIdCodec = @import("../../languages.zig").LanguageIdCodec;
const ModelContentChangedEvent = @import("../../textModelEvents.zig").ModelContentChangedEvent;
const LineRange = @import("../../core/ranges/lineRange.zig").LineRange;
const LineRangeSet = @import("../../core/ranges/lineRange.zig").LineRangeSet;
const Pair = @import("../../../../base/common/utils.zig").Pair;
const pair = @import("../../../../base/common/utils.zig").pair;
const ModelTokensChangedEvent = @import("../../textModelEvents.zig").ModelTokensChangedEvent;

pub const BackgroundTokenizationState = enum(u8) {
    InProgress = 1,
    Completed = 2,
};

pub const AttachedViewAndState = Pair(*AttachedView, ?AttachedViewState);

pub const VisibleLine = struct { startLineNumber: usize, endLineNumber: usize };

pub const AttachedViews = struct {
    _onDidChangeVisibleRanges: Emitter(AttachedViewAndState),
    _views: ArrayList(*AttachedView),
    visibleLineRanges: ArrayList(LineRange),
    allocator: Allocator,

    pub fn init(allocator: Allocator) AttachedViews {
        return .{
            ._onDidChangeVisibleRanges = Emitter(AttachedViewAndState).init(allocator),
            ._views = ArrayList(*AttachedView).init(allocator),
            .visibleLineRanges = ArrayList(LineRange).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AttachedViews) void {
        // Upstream consumers own their IAttachedView. The port keeps the model
        // as owner for views that were never detached (e.g. model teardown),
        // while `detachView` hands the allocation back to the caller.
        for (self._views.items) |view| {
            view.deinit();
            self.allocator.destroy(view);
        }
        self._views.deinit();
        self.visibleLineRanges.deinit();
        self._onDidChangeVisibleRanges.deinit();
    }

    fn triggerViewChanged(self: *AttachedViews) !void {
        var set = LineRangeSet.empty(self.visibleLineRanges.allocator);
        defer set.deinit();

        for (self._views.items) |view| {
            if (view._state) |state| {
                for (state.visibleLineRanges.items) |lineRange| {
                    try set.addRange(lineRange);
                }
            }
        }

        self.visibleLineRanges.clearRetainingCapacity();
        try self.visibleLineRanges.appendSlice(set.ranges());
    }

    pub fn onDidChangeVisibleRanges(self: *AttachedViews, ctx: anytype, callback: fn (e: AttachedViewAndState, ctx: @TypeOf(ctx)) anyerror!void) !Emitter(AttachedViewAndState).ListenerId {
        const id = try self._onDidChangeVisibleRanges.listen(ctx, callback);
        self.triggerViewChanged() catch {};
        return id;
    }

    pub fn unsubscribe(self: *AttachedViews, id: Emitter(AttachedViewAndState).ListenerId) void {
        self._onDidChangeVisibleRanges.unlisten(id);
    }

    pub fn attachView(self: *AttachedViews) !*AttachedView {
        const view = try self.allocator.create(AttachedView);
        view.* = AttachedView.init(self, struct {
            fn handle(ctx: *anyopaque, attachedView: *AttachedView, state: AttachedViewState) void {
                const views: *AttachedViews = @ptrCast(@alignCast(ctx));
                views._onDidChangeVisibleRanges.fire(.{ .first = attachedView, .second = state }) catch {};
            }
        }.handle);
        errdefer self.allocator.destroy(view);
        try self._views.append(view);
        try self.triggerViewChanged();
        return view;
    }

    pub fn detachView(self: *AttachedViews, view: *AttachedView) !void {
        for (self._views.items, 0..) |candidate, i| {
            if (candidate == view) {
                _ = self._views.orderedRemove(i);
                try self._onDidChangeVisibleRanges.fire(.{ .first = view, .second = null });
                // Upstream `detachView` only removes the view from the set; the
                // caller owns the object and destroys it after this call.
                view.deinit();
                try self.triggerViewChanged();
                return;
            }
        }
    }
};

fn lineRangeSliceEquals(a: []const LineRange, b: []const LineRange) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!x.equals(y)) return false;
    }
    return true;
}

pub const AttachedViewState = struct {
    visibleLineRanges: ArrayList(LineRange),
    stabilized: bool,

    pub fn init(visibleLineRanges: ArrayList(LineRange), stabilized: bool) AttachedViewState {
        return .{ .visibleLineRanges = visibleLineRanges, .stabilized = stabilized };
    }

    pub fn deinit(self: *AttachedViewState) void {
        self.visibleLineRanges.deinit();
    }

    pub fn equals(self: AttachedViewState, other: AttachedViewState) bool {
        if (self == other) return true;
        if (!lineRangeSliceEquals(self.visibleLineRanges.items, other.visibleLineRanges.items)) return false;
        return self.stabilized == other.stabilized;
    }
};

pub const AttachedView = struct {
    _state: ?AttachedViewState,
    _ctx: *anyopaque,
    handleStateChange: *const fn (ctx: *anyopaque, view: *AttachedView, state: AttachedViewState) void,

    pub fn init(ctx: *anyopaque, handleStateChange: *const fn (ctx: *anyopaque, view: *AttachedView, state: AttachedViewState) void) AttachedView {
        return .{ ._state = null, ._ctx = ctx, .handleStateChange = handleStateChange };
    }

    pub fn deinit(self: *AttachedView) void {
        if (self._state) |*state| {
            state.deinit();
            self._state = null;
        }
    }

    pub fn setVisibleLines(self: *AttachedView, allocator: Allocator, visibleLines: []const VisibleLine, stabilized: bool) !void {
        var visibleLineRanges = ArrayList(LineRange).init(allocator);
        errdefer visibleLineRanges.deinit();
        for (visibleLines) |line| {
            try visibleLineRanges.append(LineRange.init(line.startLineNumber, line.endLineNumber + 1));
        }

        if (self._state) |*state| state.deinit();
        const state = AttachedViewState.init(visibleLineRanges, stabilized);
        self._state = state;
        self.handleStateChange(self._ctx, self, state);
    }
};

pub const AttachedViewHandler = struct {
    allocator: Allocator,
    _computedLineRanges: []const LineRange,
    _lineRanges: []const LineRange,
    /// Owned copy of the last visible ranges. The view's state array is freed
    /// on the next `setVisibleLines`, while upstream keeps the JS array alive.
    _ownedLineRanges: []LineRange = &[_]LineRange{},
    refreshTokens: *const fn (ctx: *anyopaque, handler: *AttachedViewHandler) void,
    _ctx: *anyopaque,

    pub fn init(allocator: Allocator, ctx: *anyopaque, refreshTokens: *const fn (ctx: *anyopaque, handler: *AttachedViewHandler) void) AttachedViewHandler {
        return .{
            .allocator = allocator,
            ._computedLineRanges = &[_]LineRange{},
            ._lineRanges = &[_]LineRange{},
            .refreshTokens = refreshTokens,
            ._ctx = ctx,
        };
    }

    pub fn deinit(self: *AttachedViewHandler) void {
        if (self._ownedLineRanges.len > 0) self.allocator.free(self._ownedLineRanges);
        self._ownedLineRanges = &[_]LineRange{};
        self._lineRanges = &[_]LineRange{};
        self._computedLineRanges = &[_]LineRange{};
    }

    pub fn update(self: *AttachedViewHandler) void {
        if (lineRangeSliceEquals(self._computedLineRanges, self._lineRanges)) return;
        self._computedLineRanges = self._lineRanges;
        self.refreshTokens(self._ctx, self);
    }

    pub fn handleStateChange(self: *AttachedViewHandler, state: AttachedViewState) void {
        const new_ranges = self.allocator.dupe(LineRange, state.visibleLineRanges.items) catch {
            self._lineRanges = &[_]LineRange{};
            return;
        };
        if (self._ownedLineRanges.len > 0) self.allocator.free(self._ownedLineRanges);
        self._ownedLineRanges = new_ranges;
        self._lineRanges = self._ownedLineRanges;
        if (state.stabilized) {
            self.update();
        }
    }
};

pub const AbstractSyntaxTokenBackend = struct {
    _backgroundTokenizationState: BackgroundTokenizationState,
    _languageIdCodec: *LanguageIdCodec,
    _textModel: *anyopaque,

    _onDidChangeBackgroundTokenizationState: Emitter(void),
    _onDidChangeTokens: Emitter(ModelTokensChangedEvent),

    pub fn init(
        backgroundTokenizationState: BackgroundTokenizationState,
        languageIdCodec: *LanguageIdCodec,
        textModel_: *TextModel,
    ) AbstractSyntaxTokenBackend {
        const allocator = textModel_.getAllocator();
        return .{
            ._backgroundTokenizationState = backgroundTokenizationState,
            ._languageIdCodec = languageIdCodec,
            ._textModel = textModel_,
            ._onDidChangeBackgroundTokenizationState = Emitter(void).init(allocator),
            ._onDidChangeTokens = Emitter(ModelTokensChangedEvent).init(allocator),
        };
    }

    pub fn deinit(self: *AbstractSyntaxTokenBackend) void {
        self._onDidChangeBackgroundTokenizationState.deinit();
        self._onDidChangeTokens.deinit();
    }

    pub fn textModel(self: *AbstractSyntaxTokenBackend) *TextModel {
        return @ptrCast(@alignCast(self._textModel));
    }

    pub fn getBackgroundTokenizationState(self: *const AbstractSyntaxTokenBackend) BackgroundTokenizationState {
        return self._backgroundTokenizationState;
    }

    pub fn onDidChangeBackgroundTokenizationState(self: *AbstractSyntaxTokenBackend, ctx: anytype, callback: fn (e: void, ctx: @TypeOf(ctx)) anyerror!void) !void {
        try self._onDidChangeBackgroundTokenizationState.event(ctx, callback);
    }

    pub fn onDidChangeTokens(self: *AbstractSyntaxTokenBackend, ctx: anytype, callback: fn (e: ModelTokensChangedEvent, ctx: @TypeOf(ctx)) anyerror!void) !void {
        try self._onDidChangeTokens.event(ctx, callback);
    }
};
