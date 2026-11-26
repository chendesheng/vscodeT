// Port of `src/vs/workbench/contrib/scm/common/quickDiff.ts`.
//
// Terminal adaptations:
// - Git returns its canonical original URI; QuickDiffModel resolves and owns
//   the actual URI-backed model asynchronously through ITextModelService.
//   The native Original descriptor still supports inline content from older
//   in-process providers while migrating those callers to the URI contract.
// - Resource arguments use std.Uri; encoded original descriptors retain their owned backing slices.
// - The upstream color registrations become terminal RGB defaults. Cells have
//   no alpha, so translucent overview colors are composited over the dark
//   editor background and the secondary gutter colors are pre-darkened.
const std = @import("std");
const Allocator = std.mem.Allocator;

const language_selector = @import("../../../../editor/common/languageSelector.zig");
const legacy_diff = @import("../../../../editor/common/diff/linesDiffComputer.zig");
const range_mapping = @import("../../../../editor/common/diff/rangeMapping.zig");
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;

pub const Selector = language_selector.Selector;
pub const IChange = legacy_diff.IChange;
pub const LineRangeMapping = range_mapping.LineRangeMapping;

pub const QuickDiffProviderKind = enum {
    primary,
    secondary,
    contributed,
};

/// Original URI/label descriptor and the optional immutable text captured
/// for the native worker. Owned by the receiver.
pub const Original = struct {
    content: []u8,
    ref_label: []u8,
    /// Canonical provider resource; legacy providers may supply only text.
    resource_uri: ?[]u8 = null,

    pub fn deinit(self: *Original, allocator: Allocator) void {
        allocator.free(self.content);
        allocator.free(self.ref_label);
        if (self.resource_uri) |uri| allocator.free(uri);
        self.* = undefined;
    }
};

pub const QuickDiffProvider = struct {
    context: *anyopaque,
    id: []const u8,
    label: []const u8,
    root_uri: ?std.Uri = null,
    selector: ?Selector = null,
    kind: QuickDiffProviderKind = .contributed,
    /// Returns the original resource for `resource`, or null when the provider
    /// has no baseline. The returned value owns its slices.
    get_original_fn: *const fn (context: *anyopaque, allocator: Allocator, resource: std.Uri) anyerror!?Original,

    pub fn getOriginalResource(self: QuickDiffProvider, allocator: Allocator, resource: std.Uri) !?Original {
        return self.get_original_fn(self.context, allocator, resource);
    }
};

pub const QuickDiff = struct {
    id: []const u8,
    label: []const u8,
    original: Original,
    kind: QuickDiffProviderKind,

    pub fn deinit(self: *QuickDiff, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        self.original.deinit(allocator);
        self.* = undefined;
    }
};

pub const QuickDiffChange = struct {
    provider_id: []const u8,
    original_path: []const u8,
    modified_path: []const u8,
    change: IChange,
    change2: LineRangeMapping,
};

pub const QuickDiffResult = struct {
    provider_id: []const u8,
    provider_kind: QuickDiffProviderKind,
    original_path: []const u8,
    modified_path: []const u8,
    changes: []IChange,
    changes2: []LineRangeMapping,
};

pub const IQuickDiffService = struct {
    context: *anyopaque,
    providers_fn: *const fn (context: *anyopaque) []const *QuickDiffProvider,
    add_quick_diff_provider_fn: *const fn (context: *anyopaque, provider: *QuickDiffProvider) anyerror!IDisposable,
    remove_quick_diff_provider_fn: *const fn (context: *anyopaque, id: []const u8) void,
    get_quick_diffs_fn: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        resource: std.Uri,
        language: ?[]const u8,
        is_synchronized: bool,
    ) anyerror![]QuickDiff,
    toggle_visibility_fn: *const fn (context: *anyopaque, id: []const u8) void,
    is_visible_fn: *const fn (context: *anyopaque, id: []const u8) bool,
    on_did_change_providers: *Emitter(void),

    pub fn providers(self: IQuickDiffService) []const *QuickDiffProvider {
        return self.providers_fn(self.context);
    }

    pub fn addQuickDiffProvider(self: IQuickDiffService, provider: *QuickDiffProvider) !IDisposable {
        return self.add_quick_diff_provider_fn(self.context, provider);
    }

    pub fn getQuickDiffs(
        self: IQuickDiffService,
        allocator: Allocator,
        resource: std.Uri,
        language: ?[]const u8,
        is_synchronized: bool,
    ) ![]QuickDiff {
        return self.get_quick_diffs_fn(self.context, allocator, resource, language, is_synchronized);
    }

    pub fn toggleQuickDiffProviderVisibility(self: IQuickDiffService, id: []const u8) void {
        self.toggle_visibility_fn(self.context, id);
    }

    pub fn isQuickDiffProviderVisible(self: IQuickDiffService, id: []const u8) bool {
        return self.is_visible_fn(self.context, id);
    }
};

pub const ChangeType = enum {
    modify,
    add,
    delete,
};

pub fn getChangeType(change: IChange) ChangeType {
    if (change.originalEndLineNumber == 0) return .add;
    if (change.modifiedEndLineNumber == 0) return .delete;
    return .modify;
}

/// Terminal defaults for `editorGutter.modifiedBackground`,
/// `editorGutter.addedBackground` and `editorGutter.deletedBackground`.
pub const gutter_modified_background = [3]u8{ 27, 129, 168 };
pub const gutter_added_background = [3]u8{ 72, 126, 2 };
pub const gutter_deleted_background = [3]u8{ 244, 135, 113 };
/// Darkened secondary variants of the gutter colors.
pub const gutter_modified_secondary_background = [3]u8{ 14, 65, 84 };
pub const gutter_added_secondary_background = [3]u8{ 36, 63, 1 };
pub const gutter_deleted_secondary_background = [3]u8{ 98, 54, 45 };
/// `editorOverviewRuler.{modified,added,deleted}Foreground` at 60% alpha,
/// composited over the dark editor background.
pub const overview_modified_foreground = [3]u8{ 28, 89, 113 };
pub const overview_added_foreground = [3]u8{ 55, 88, 13 };
pub const overview_deleted_foreground = [3]u8{ 158, 93, 80 };

pub fn getChangeTypeColor(change_type: ChangeType) [3]u8 {
    return switch (change_type) {
        .modify => gutter_modified_background,
        .add => gutter_added_background,
        .delete => gutter_deleted_background,
    };
}

pub fn compareChanges(a: IChange, b: IChange) i32 {
    var result = compareUsize(a.modifiedStartLineNumber, b.modifiedStartLineNumber);
    if (result != 0) return result;
    result = compareUsize(a.modifiedEndLineNumber, b.modifiedEndLineNumber);
    if (result != 0) return result;
    result = compareUsize(a.originalStartLineNumber, b.originalStartLineNumber);
    if (result != 0) return result;
    return compareUsize(a.originalEndLineNumber, b.originalEndLineNumber);
}

fn compareUsize(a: usize, b: usize) i32 {
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
}

pub fn getChangeHeight(change: IChange) usize {
    // Upstream computes negative lengths for insert/delete ranges and then
    // ignores them; saturating subtraction keeps the same branch behaviour
    // without a debug-mode underflow.
    const modified = (change.modifiedEndLineNumber -| change.modifiedStartLineNumber) + 1;
    const original = (change.originalEndLineNumber -| change.originalStartLineNumber) + 1;
    if (change.originalEndLineNumber == 0) return modified;
    if (change.modifiedEndLineNumber == 0) return original;
    return modified + original;
}

pub fn getModifiedEndLineNumber(change: IChange) usize {
    if (change.modifiedEndLineNumber == 0) {
        return if (change.modifiedStartLineNumber == 0) 1 else change.modifiedStartLineNumber;
    }
    return change.modifiedEndLineNumber;
}

pub fn lineIntersectsChange(line_number: usize, change: IChange) bool {
    // Deletion at the beginning of the file.
    if (line_number == 1 and change.modifiedStartLineNumber == 0 and change.modifiedEndLineNumber == 0) {
        return true;
    }
    const end = if (change.modifiedEndLineNumber == 0) change.modifiedStartLineNumber else change.modifiedEndLineNumber;
    return line_number >= change.modifiedStartLineNumber and line_number <= end;
}

test "quickDiff: change classification and helpers" {
    const add = IChange{ .originalStartLineNumber = 1, .originalEndLineNumber = 0, .modifiedStartLineNumber = 2, .modifiedEndLineNumber = 4 };
    const delete = IChange{ .originalStartLineNumber = 1, .originalEndLineNumber = 3, .modifiedStartLineNumber = 2, .modifiedEndLineNumber = 0 };
    const modify = IChange{ .originalStartLineNumber = 1, .originalEndLineNumber = 2, .modifiedStartLineNumber = 3, .modifiedEndLineNumber = 4 };

    try std.testing.expectEqual(ChangeType.add, getChangeType(add));
    try std.testing.expectEqual(ChangeType.delete, getChangeType(delete));
    try std.testing.expectEqual(ChangeType.modify, getChangeType(modify));

    try std.testing.expectEqual(@as(usize, 3), getChangeHeight(add));
    try std.testing.expectEqual(@as(usize, 3), getChangeHeight(delete));
    try std.testing.expectEqual(@as(usize, 4), getChangeHeight(modify));

    try std.testing.expectEqual(@as(usize, 4), getModifiedEndLineNumber(add));
    try std.testing.expectEqual(@as(usize, 2), getModifiedEndLineNumber(delete));

    try std.testing.expect(lineIntersectsChange(3, add));
    try std.testing.expect(!lineIntersectsChange(1, add));
    try std.testing.expect(lineIntersectsChange(2, delete));
    try std.testing.expect(!lineIntersectsChange(1, delete));
    const leading_delete = IChange{ .originalStartLineNumber = 1, .originalEndLineNumber = 1, .modifiedStartLineNumber = 0, .modifiedEndLineNumber = 0 };
    try std.testing.expect(lineIntersectsChange(1, leading_delete));
}

test "quickDiff: compareChanges orders by modified then original range" {
    const a = IChange{ .originalStartLineNumber = 2, .originalEndLineNumber = 2, .modifiedStartLineNumber = 1, .modifiedEndLineNumber = 1 };
    const b = IChange{ .originalStartLineNumber = 1, .originalEndLineNumber = 1, .modifiedStartLineNumber = 2, .modifiedEndLineNumber = 2 };
    try std.testing.expect(compareChanges(a, b) < 0);
    try std.testing.expect(compareChanges(b, a) > 0);
    try std.testing.expectEqual(@as(i32, 0), compareChanges(a, a));
}

test "quickDiff: provider color defaults are the composited terminal values" {
    try std.testing.expectEqual(@as([3]u8, .{ 27, 129, 168 }), getChangeTypeColor(.modify));
    try std.testing.expectEqual(@as([3]u8, .{ 72, 126, 2 }), getChangeTypeColor(.add));
    // The secondary variants are darker than the primary ones.
    try std.testing.expect(gutter_modified_secondary_background[1] < gutter_modified_background[1]);
    try std.testing.expect(!std.mem.eql(u8, &overview_added_foreground, &gutter_added_background));
}
