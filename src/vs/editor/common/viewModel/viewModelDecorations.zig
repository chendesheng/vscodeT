// Port of `src/vs/editor/common/viewModel/viewModelDecorations.ts`

const std = @import("std");
const Allocator = std.mem.Allocator;

const Range = @import("../core/range.zig").Range;
const TextModel = @import("../model/textModel.zig").TextModel;
const ModelDecoration = @import("../model.zig").ModelDecoration;
const ICoordinatesConverter = @import("../coordinatesConverter.zig").ICoordinatesConverter;
const IdentityCoordinatesConverter = @import("../coordinatesConverter.zig").IdentityCoordinatesConverter;

const inlineDecorations = @import("./inlineDecorations.zig");
const InlineModelDecorationsComputer = inlineDecorations.InlineModelDecorationsComputer;
const IInlineModelDecorationsComputerContext = inlineDecorations.IInlineModelDecorationsComputerContext;
const ViewDecorationsCollection = inlineDecorations.ViewDecorationsCollection;

const ViewModelDecoration = @import("./viewModelDecoration.zig").ViewModelDecoration;

/// The subset of upstream `IViewModelLines` needed by `ViewModelDecorations`.
/// The full interface is much larger and is ported along with
/// `viewModelLines.ts`.
pub const IViewModelLines = struct {
    context: *anyopaque,
    getDecorationsInRange: *const fn (
        context: *anyopaque,
        viewRange: Range,
        ownerId: i32,
        filterValidationDecorations: bool,
        filterFontDecorations: bool,
        onlyMinimapDecorations: bool,
        onlyMarginDecorations: bool,
    ) []const ModelDecoration,
    getViewLineMinColumn: *const fn (context: *anyopaque, lineNumber: usize) usize,
    getViewLineMaxColumn: *const fn (context: *anyopaque, lineNumber: usize) usize,

    pub fn decorationsInRange(
        self: IViewModelLines,
        view_range: Range,
        owner_id: i32,
        filter_validation_decorations: bool,
        filter_font_decorations: bool,
        only_minimap_decorations: bool,
        only_margin_decorations: bool,
    ) []const ModelDecoration {
        return self.getDecorationsInRange(
            self.context,
            view_range,
            owner_id,
            filter_validation_decorations,
            filter_font_decorations,
            only_minimap_decorations,
            only_margin_decorations,
        );
    }

    pub fn viewLineMinColumn(self: IViewModelLines, line_number: usize) usize {
        return self.getViewLineMinColumn(self.context, line_number);
    }

    pub fn viewLineMaxColumn(self: IViewModelLines, line_number: usize) usize {
        return self.getViewLineMaxColumn(self.context, line_number);
    }
};

/// Owns the inline decoration computer and caches the decorations resolved for
/// the last requested view range.
///
/// Upstream passes the full `IEditorConfiguration` and derives the decoration
/// filters from it; here the two filter flags are passed in directly because the
/// editor options system is not ported yet.
pub const ViewModelDecorations = struct {
    allocator: Allocator,
    editorId: i32,
    _linesCollection: IViewModelLines,
    _filterValidationDecorations: bool,
    _filterFontDecorations: bool,
    _inlineDecorationsComputer: InlineModelDecorationsComputer,
    _cachedModelDecorationsResolver: ?ViewDecorationsCollection,
    _cachedModelDecorationsResolverViewRange: ?Range,

    pub fn create(
        allocator: Allocator,
        editorId: i32,
        model: *TextModel,
        filterValidationDecorations: bool,
        filterFontDecorations: bool,
        linesCollection: IViewModelLines,
        coordinatesConverter: ICoordinatesConverter,
    ) !*ViewModelDecorations {
        const self = try allocator.create(ViewModelDecorations);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .editorId = editorId,
            ._linesCollection = linesCollection,
            ._filterValidationDecorations = filterValidationDecorations,
            ._filterFontDecorations = filterFontDecorations,
            ._inlineDecorationsComputer = undefined,
            ._cachedModelDecorationsResolver = null,
            ._cachedModelDecorationsResolverViewRange = null,
        };
        self._inlineDecorationsComputer = InlineModelDecorationsComputer.init(
            allocator,
            IInlineModelDecorationsComputerContext{
                .context = @ptrCast(self),
                .getModelDecorations = getModelDecorations,
            },
            model,
            coordinatesConverter,
        );
        return self;
    }

    pub fn destroy(self: *ViewModelDecorations) void {
        self.dispose();
        self._inlineDecorationsComputer.deinit();
        self.allocator.destroy(self);
    }

    fn getModelDecorations(
        context: *anyopaque,
        viewRange: Range,
        onlyMinimapDecorations: bool,
        onlyMarginDecorations: bool,
    ) []const ModelDecoration {
        const self: *ViewModelDecorations = @ptrCast(@alignCast(context));
        return self._linesCollection.decorationsInRange(
            viewRange,
            self.editorId,
            self._filterValidationDecorations,
            self._filterFontDecorations,
            onlyMinimapDecorations,
            onlyMarginDecorations,
        );
    }

    fn clearCachedModelDecorationsResolver(self: *ViewModelDecorations) void {
        if (self._cachedModelDecorationsResolver) |*collection| collection.deinit();
        self._cachedModelDecorationsResolver = null;
        self._cachedModelDecorationsResolverViewRange = null;
    }

    pub fn dispose(self: *ViewModelDecorations) void {
        self._inlineDecorationsComputer.reset();
        self.clearCachedModelDecorationsResolver();
    }

    pub fn reset(self: *ViewModelDecorations) void {
        self._inlineDecorationsComputer.reset();
        self.clearCachedModelDecorationsResolver();
    }

    pub fn onModelDecorationsChanged(self: *ViewModelDecorations) void {
        self._inlineDecorationsComputer.onModelDecorationsChanged();
        self.clearCachedModelDecorationsResolver();
    }

    pub fn onLineMappingChanged(self: *ViewModelDecorations) void {
        self._inlineDecorationsComputer.onLineMappingChanged();
        self.clearCachedModelDecorationsResolver();
    }

    /// The returned slice is owned by the caller.
    pub fn getMinimapDecorationsInRange(self: *ViewModelDecorations, range: Range) ![]ViewModelDecoration {
        var collection = try self._inlineDecorationsComputer.getDecorations(range, true, false);
        const decorations = collection.decorations;
        // Hand the decorations slice over to the caller before releasing the
        // rest of the collection.
        collection.decorations = collection.decorations[0..0];
        collection.deinit();
        return decorations;
    }

    /// Returns the cached collection for `viewRange`; it stays owned by this
    /// object and is invalidated by the `on*Changed`/`reset` methods.
    pub fn getDecorationsViewportData(self: *ViewModelDecorations, viewRange: Range) !*ViewDecorationsCollection {
        var cache_is_valid = self._cachedModelDecorationsResolver != null;
        if (cache_is_valid) {
            cache_is_valid = Range.equalsRange(self._cachedModelDecorationsResolverViewRange, viewRange);
        }
        if (!cache_is_valid) {
            if (self._cachedModelDecorationsResolver) |*old| old.deinit();
            self._cachedModelDecorationsResolver = try self._inlineDecorationsComputer.getDecorations(viewRange, false, false);
            self._cachedModelDecorationsResolverViewRange = viewRange;
        }
        return if (self._cachedModelDecorationsResolver) |*collection| collection else unreachable;
    }

    /// The returned collection is owned by the caller.
    pub fn getDecorationsOnLine(
        self: *ViewModelDecorations,
        lineNumber: usize,
        onlyMinimapDecorations: bool,
        onlyMarginDecorations: bool,
    ) !ViewDecorationsCollection {
        const range = Range.init(
            lineNumber,
            self._linesCollection.viewLineMinColumn(lineNumber),
            lineNumber,
            self._linesCollection.viewLineMaxColumn(lineNumber),
        );
        return self._inlineDecorationsComputer.getDecorations(range, onlyMinimapDecorations, onlyMarginDecorations);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const Position = @import("../core/position.zig").Position;
const ModelDecorationOptions = @import("../model.zig").ModelDecorationOptions;
const PositionAffinity = @import("../model.zig").PositionAffinity;
const TestModel = @import("../../test/common/port/testSupport.zig").TestModel;

var empty_decoration_options: ModelDecorationOptions = std.mem.zeroes(ModelDecorationOptions);

const TestLines = struct {
    var call_count: usize = 0;
    var last_view_range: ?Range = null;
    var last_owner_id: i32 = 0;
    var last_only_minimap: bool = false;
    var last_only_margin: bool = false;

    var decorations: [2]ModelDecoration = undefined;

    fn getDecorationsInRange(
        _: *anyopaque,
        viewRange: Range,
        ownerId: i32,
        filterValidationDecorations: bool,
        filterFontDecorations: bool,
        onlyMinimapDecorations: bool,
        onlyMarginDecorations: bool,
    ) []const ModelDecoration {
        _ = filterValidationDecorations;
        _ = filterFontDecorations;
        call_count += 1;
        last_view_range = viewRange;
        last_owner_id = ownerId;
        last_only_minimap = onlyMinimapDecorations;
        last_only_margin = onlyMarginDecorations;
        return &decorations;
    }

    fn getViewLineMinColumn(_: *anyopaque, _: usize) usize {
        return 1;
    }

    fn getViewLineMaxColumn(_: *anyopaque, line_number: usize) usize {
        return line_number * 10;
    }

    fn interface() IViewModelLines {
        return .{
            .context = @ptrFromInt(@alignOf(usize)),
            .getDecorationsInRange = getDecorationsInRange,
            .getViewLineMinColumn = getViewLineMinColumn,
            .getViewLineMaxColumn = getViewLineMaxColumn,
        };
    }
};

const TestModelText = "aaa\nbbb\nccc\nddd\neee";

test "ViewModelDecorations resolves and caches viewport decorations" {
    const allocator = testing.allocator;
    var test_model = try TestModel.init(allocator, TestModelText, "plaintext");
    defer test_model.deinit();
    const model = test_model.model;

    var identity_converter = IdentityCoordinatesConverter.init(model);
    TestLines.call_count = 0;
    TestLines.decorations[0] = .{ .id = 1, .ownerId = 0, .range = Range.init(1, 1, 1, 2), .options = &empty_decoration_options };
    TestLines.decorations[1] = .{ .id = 2, .ownerId = 0, .range = Region(), .options = &empty_decoration_options };

    const decorations = try ViewModelDecorations.create(
        allocator,
        7,
        model,
        false,
        false,
        TestLines.interface(),
        identity_converter.toInterface(),
    );
    defer decorations.destroy();

    const view_range = Range.init(1, 1, 2, 1);
    const first = try decorations.getDecorationsViewportData(view_range);
    try testing.expectEqual(@as(usize, 2), first.decorations.len);
    try testing.expectEqual(@as(usize, 1), TestLines.call_count);
    try testing.expectEqual(@as(i32, 7), TestLines.last_owner_id);
    try testing.expect(!TestLines.last_only_minimap);
    try testing.expectEqual(@as(usize, 1), TestLines.last_view_range.?.startLineNumber);

    // The same range is served from the cache.
    const again = try decorations.getDecorationsViewportData(view_range);
    try testing.expectEqual(@as(usize, 1), TestLines.call_count);
    try testing.expectEqual(first, again);

    // A different range re-resolves.
    const next = try decorations.getDecorationsViewportData(Range.init(2, 1, 3, 1));
    try testing.expectEqual(@as(usize, 2), TestLines.call_count);
    try testing.expectEqual(@as(usize, 2), next.decorations.len);

    // Invalidating forces a fresh resolve even for the same range.
    decorations.onModelDecorationsChanged();
    _ = try decorations.getDecorationsViewportData(Range.init(2, 1, 3, 1));
    try testing.expectEqual(@as(usize, 3), TestLines.call_count);
}

test "ViewModelDecorations minimap query only asks for minimap decorations" {
    const allocator = testing.allocator;
    var test_model = try TestModel.init(allocator, TestModelText, "plaintext");
    defer test_model.deinit();
    const model = test_model.model;

    var identity_converter = IdentityCoordinatesConverter.init(model);
    TestLines.call_count = 0;
    TestLines.decorations[0] = .{ .id = 3, .ownerId = 0, .range = Range.init(1, 1, 1, 2), .options = &empty_decoration_options };
    TestLines.decorations[1] = .{ .id = 4, .ownerId = 0, .range = Range.init(1, 3, 1, 4), .options = &empty_decoration_options };

    const decorations = try ViewModelDecorations.create(
        allocator,
        1,
        model,
        true,
        true,
        TestLines.interface(),
        identity_converter.toInterface(),
    );
    defer decorations.destroy();

    const minimap = try decorations.getMinimapDecorationsInRange(Range.init(1, 1, 5, 1));
    defer allocator.free(minimap);

    try testing.expectEqual(@as(usize, 2), minimap.len);
    try testing.expect(TestLines.last_only_minimap);
    try testing.expect(!TestLines.last_only_margin);
}

test "ViewModelDecorations decorations on a line use the view line columns" {
    const allocator = testing.allocator;
    var test_model = try TestModel.init(allocator, TestModelText, "plaintext");
    defer test_model.deinit();
    const model = test_model.model;

    var identity_converter = IdentityCoordinatesConverter.init(model);
    TestLines.call_count = 0;
    TestLines.decorations[0] = .{ .id = 5, .ownerId = 0, .range = Range.init(3, 1, 3, 2), .options = &empty_decoration_options };
    TestLines.decorations[1] = .{ .id = 6, .ownerId = 0, .range = Range.init(3, 3, 3, 4), .options = &empty_decoration_options };

    const decorations = try ViewModelDecorations.create(
        allocator,
        1,
        model,
        false,
        false,
        TestLines.interface(),
        identity_converter.toInterface(),
    );
    defer decorations.destroy();

    var collection = try decorations.getDecorationsOnLine(3, false, true);
    defer collection.deinit();

    try testing.expect(TestLines.last_only_margin);
    try testing.expectEqual(@as(usize, 3), TestLines.last_view_range.?.startLineNumber);
    try testing.expectEqual(@as(usize, 1), TestLines.last_view_range.?.startColumn);
    try testing.expectEqual(@as(usize, 30), TestLines.last_view_range.?.endColumn);
}

fn Region() Range {
    return Range.init(2, 1, 3, 1);
}
