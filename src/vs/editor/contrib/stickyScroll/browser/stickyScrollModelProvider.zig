// Port of
// `src/vs/editor/contrib/stickyScroll/browser/stickyScrollModelProvider.ts`.
//
// Terminal adaptations:
// - the candidate provider owns the pending outline request and the controller
//   supplies the debounce timer;
// - the syntax folding provider is absent because this port has no folding
//   range provider registry, so `foldingProviderModel` falls through to the
//   indentation provider;
// - provider groups preserve upstream preference and total-range selection.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const editor_options = @import("../../../common/config/editorOptions.zig");
const OutlineModel = @import("../../documentSymbols/browser/outlineModel.zig").OutlineModel;
const OutlineElement = @import("../../documentSymbols/browser/outlineModel.zig").OutlineElement;
const folding_ranges = @import("../../folding/browser/foldingRanges.zig");
const FoldingRegions = folding_ranges.FoldingRegions;
const indent_range_provider = @import("../../folding/browser/indentRangeProvider.zig");
const sticky = @import("./stickyScrollElement.zig");
const StickyElement = sticky.StickyElement;
const StickyModel = sticky.StickyModel;
const StickyRange = sticky.StickyRange;

pub const ModelProvider = editor_options.StickyScrollDefaultModel;

/// Port of `IStickyModelProvider`.
pub const IStickyModelProvider = struct {
    context: *anyopaque,
    update: *const fn (context: *anyopaque, provider: ModelProvider) anyerror!?*StickyModel,
    dispose: *const fn (context: *anyopaque) void,
};

/// Port of `StickyModelProvider`.
pub const StickyModelProvider = struct {
    allocator: Allocator,
    editor: *Editor,

    pub fn init(allocator: Allocator, editor: *Editor) StickyModelProvider {
        return .{
            .allocator = allocator,
            .editor = editor,
        };
    }

    pub fn interface(self: *StickyModelProvider) IStickyModelProvider {
        return .{
            .context = self,
            .update = updateInterface,
            .dispose = disposeInterface,
        };
    }

    fn updateInterface(context: *anyopaque, provider: ModelProvider) !?*StickyModel {
        const self: *StickyModelProvider = @ptrCast(@alignCast(context));
        return self.update(provider);
    }

    fn disposeInterface(_: *anyopaque) void {}

    /// Compute the first valid sticky model for `provider`, following the
    /// upstream switch fallthrough order.
    pub fn update(self: *StickyModelProvider, provider: ModelProvider) !?*StickyModel {
        const model = self.editor.model;
        if (model.isTooLargeForTokenization()) return null;

        switch (provider) {
            .outline_model => {
                if (try self.modelFromOutline(model)) |outline_model| return outline_model;
                return self.modelFromIndentation(model);
            },
            .folding_provider_model => {
                // No folding range provider registry in this port: fall through
                // to the indentation model.
                return self.modelFromIndentation(model);
            },
            .indentation_model => return self.modelFromIndentation(model),
        }
    }

    fn modelFromOutline(self: *StickyModelProvider, model: *TextModel) !?*StickyModel {
        const features = self.editor.language_features orelse return null;
        const providers = try features.document_symbol_provider.ordered(self.allocator, model, false);
        defer self.allocator.free(providers);
        if (providers.len == 0) return null;

        const outline = try OutlineModel.createWithProviders(self.allocator, model, providers);
        defer outline.deinit();
        return self.fromOutline(outline, null);
    }

    pub fn fromOutline(self: *StickyModelProvider, outline: *OutlineModel, preferred: ?[]const u8) !?*StickyModel {
        if (outline.roots.len == 0) return null;
        var elements = outline.roots;
        var provider_id = preferred;
        if (outline.groups.len > 1) {
            var best_sum: isize = -1;
            for (outline.groups) |group| {
                if (preferred) |id| if (std.mem.eql(u8, group.id, id)) {
                    elements = group.children;
                    provider_id = group.id;
                    break;
                };
                const sum = sumOfOutlineRanges(group.children);
                if (sum > best_sum) {
                    best_sum = sum;
                    elements = group.children;
                    provider_id = group.id;
                }
            }
        }
        const model = self.editor.model;
        const candidate = try StickyModel.init(self.allocator, model.uri(), model.getVersionId(), provider_id);
        errdefer candidate.deinit();
        candidate.element = try stickyModelFromOutlineModel(candidate.arenaAllocator(), elements);
        return candidate;
    }

    pub fn modelFromIndentation(self: *StickyModelProvider, model: *TextModel) !?*StickyModel {
        var reporter = indent_range_provider.FoldingLimitReporter{
            .limit = indent_range_provider.MAX_FOLDING_REGIONS_FOR_INDENT_DEFAULT,
        };
        const rules = self.editor.foldingRules();
        var regions = try indent_range_provider.computeRanges(
            self.allocator,
            model,
            rules.offSide orelse false,
            rules.markers,
            &reporter,
        );
        defer regions.deinit();

        const sticky_model = try StickyModel.init(
            self.allocator,
            model.uri(),
            model.getVersionId(),
            null,
        );
        errdefer sticky_model.deinit();
        sticky_model.element = try stickyModelFromFoldingRegions(
            sticky_model.arenaAllocator(),
            &regions,
        );
        return sticky_model;
    }
};

/// Port of `_stickyModelFromOutlineModel` for one provider group.
fn stickyModelFromOutlineModel(arena: Allocator, roots: []*OutlineElement) !*StickyElement {
    const elements = try arena.alloc(*StickyElement, roots.len);
    var count: usize = 0;
    for (roots) |element| {
        elements[count] = try stickyModelFromOutlineElement(
            arena,
            element,
            element.symbol.selection_range.startLineNumber,
        );
        count += 1;
    }
    sortStickyElements(elements);

    const root = try arena.create(StickyElement);
    root.* = .{
        .range = null,
        .children = elements,
        .parent = null,
    };
    for (elements) |child| child.parent = root;
    return root;
}

/// Port of `_stickyModelFromOutlineElement`.
fn stickyModelFromOutlineElement(
    arena: Allocator,
    outline_element: *OutlineElement,
    previous_start_line: usize,
) !*StickyElement {
    var children = std.array_list.Managed(*StickyElement).init(arena);
    errdefer children.deinit();

    for (outline_element.children) |child| {
        const start_line = child.symbol.selection_range.startLineNumber;
        if (start_line == child.symbol.range.endLineNumber) continue;

        if (start_line != previous_start_line) {
            try children.append(try stickyModelFromOutlineElement(arena, child, start_line));
        } else {
            for (child.children) |subchild| {
                try children.append(try stickyModelFromOutlineElement(arena, subchild, start_line));
            }
        }
    }

    const owned = try children.toOwnedSlice();
    sortStickyElements(owned);

    const element = try arena.create(StickyElement);
    element.* = .{
        .range = StickyRange.init(
            outline_element.symbol.selection_range.startLineNumber,
            outline_element.symbol.range.endLineNumber,
        ),
        .children = owned,
        .parent = null,
    };
    for (owned) |child| child.parent = element;
    return element;
}

fn sortStickyElements(elements: []*StickyElement) void {
    std.mem.sort(*StickyElement, elements, {}, struct {
        fn lessThan(_: void, left: *StickyElement, right: *StickyElement) bool {
            const left_range = left.range orelse return false;
            const right_range = right.range orelse return true;
            if (left_range.start_line_number != right_range.start_line_number) {
                return left_range.start_line_number < right_range.start_line_number;
            }
            return left_range.end_line_number > right_range.end_line_number;
        }
    }.lessThan);
}

fn sumOfOutlineRanges(roots: []*OutlineElement) isize {
    var sum: isize = 0;
    for (roots) |element| sum += sumOfOutlineElement(element);
    return sum;
}

fn sumOfOutlineElement(element: *OutlineElement) isize {
    var sum: isize = @as(isize, @intCast(element.symbol.range.endLineNumber)) -
        @as(isize, @intCast(element.symbol.selection_range.startLineNumber));
    for (element.children) |child| sum += sumOfOutlineElement(child);
    return sum;
}

/// Port of `StickyModelFromCandidateFoldingProvider._fromFoldingRegions`.
fn stickyModelFromFoldingRegions(
    arena: Allocator,
    regions: *FoldingRegions,
) !*StickyElement {
    const length = regions.length();
    const ordered = try arena.alloc(*StickyElement, length);
    const child_lists = try arena.alloc(
        std.array_list.Managed(*StickyElement),
        length,
    );
    for (child_lists, 0..) |*list, index| {
        list.* = std.array_list.Managed(*StickyElement).init(arena);
        ordered[index] = try arena.create(StickyElement);
    }

    var root_children = std.array_list.Managed(*StickyElement).init(arena);

    for (0..length) |index| {
        const parent_index = try regions.getParentIndex(index);
        const child = ordered[index];
        child.* = .{
            .range = StickyRange.init(
                regions.getStartLineNumber(index),
                regions.getEndLineNumber(index) + 1,
            ),
            .children = &.{},
            .parent = null,
        };

        if (parent_index >= 0) {
            const parent = ordered[@intCast(parent_index)];
            child.parent = parent;
            try child_lists[@intCast(parent_index)].append(child);
        } else {
            try root_children.append(child);
        }
    }

    for (0..length) |index| {
        ordered[index].children = try child_lists[index].toOwnedSlice();
    }

    const root = try arena.create(StickyElement);
    root.* = .{
        .range = null,
        .children = try root_children.toOwnedSlice(),
        .parent = null,
    };
    for (root.children) |child| child.parent = root;
    return root;
}
