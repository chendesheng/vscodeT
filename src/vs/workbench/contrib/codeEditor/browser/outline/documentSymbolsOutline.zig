// Terminal adapter for
// `src/vs/workbench/contrib/codeEditor/browser/outline/documentSymbolsOutline.ts`.
//
// The browser outline supplies a tree view, quick pick and drag/drop. The
// terminal port supplies only the breadcrumbs data source and reveal callback
// through the existing `IOutline` contract.

const std = @import("std");
const Allocator = std.mem.Allocator;
const outline = @import("../../../../services/outline/browser/outline.zig");
const IOutline = outline.IOutline;

const BreadcrumbsOutlineElement = outline.BreadcrumbsOutlineElement;
const OutlineChangeEvent = outline.OutlineChangeEvent;
const RevealOptions = outline.RevealOptions;
const Emitter = @import("../../../../../base/common/event.zig").Emitter;
const Position = @import("../../../../../editor/common/core/position.zig").Position;
const Range = @import("../../../../../editor/common/core/range.zig").Range;
const outline_model_mod = @import("../../../../../editor/contrib/documentSymbols/browser/outlineModel.zig");
const OutlineModel = outline_model_mod.OutlineModel;
const SymbolElement = outline_model_mod.OutlineElement;

pub const Host = struct {
    context: *anyopaque,
    current_position: *const fn (context: *anyopaque) ?Position,
    reveal_range: *const fn (context: *anyopaque, range: Range) anyerror!void,
    request_render: *const fn (context: *anyopaque) void,
};

pub const DocumentSymbolsOutline = struct {
    allocator: Allocator,
    model: *OutlineModel,
    host: Host,
    emitter: Emitter(OutlineChangeEvent),
    elements: std.array_list.Managed(BreadcrumbsOutlineElement),
    interface_value: IOutline = undefined,

    pub fn create(allocator: Allocator, model: *OutlineModel, host: Host) !*DocumentSymbolsOutline {
        const self = try allocator.create(DocumentSymbolsOutline);
        self.* = .{
            .allocator = allocator,
            .model = model,
            .host = host,
            .emitter = Emitter(OutlineChangeEvent).init(allocator),
            .elements = std.array_list.Managed(BreadcrumbsOutlineElement).init(allocator),
        };
        self.interface_value = self.buildInterface();
        return self;
    }

    fn buildInterface(self: *DocumentSymbolsOutline) IOutline {
        return .{
            .context = self,
            .uri = null,
            .outline_kind = "documentSymbols",
            .is_empty = self.model.roots.len == 0,
            .config = .{ .breadcrumbs_data_source = .{
                .context = self,
                .get_breadcrumb_elements = getBreadcrumbElements,
            } },
            .on_did_change = &self.emitter,
            .revealFn = reveal,
            .disposeFn = dispose,
        };
    }

    pub fn interfacePtr(self: *DocumentSymbolsOutline) *IOutline {
        return &self.interface_value;
    }

    fn getBreadcrumbElements(context: *anyopaque) []const BreadcrumbsOutlineElement {
        const self: *DocumentSymbolsOutline = @ptrCast(@alignCast(context));
        self.elements.clearRetainingCapacity();
        const position = self.host.current_position(self.host.context) orelse return &.{};
        const chain = self.model.elementChain(self.allocator, position) catch return &.{};
        defer self.allocator.free(chain);
        for (chain) |element| {
            self.elements.append(.{
                .element = @ptrCast(element),
                .label = element.symbol.name,
                .symbol_kind = element.symbol.kind,
            }) catch break;
        }
        return self.elements.items;
    }

    fn reveal(context: *anyopaque, element: *anyopaque, options: RevealOptions) !void {
        _ = options;
        const self: *DocumentSymbolsOutline = @ptrCast(@alignCast(context));
        const target: *SymbolElement = @ptrCast(@alignCast(element));
        try self.host.reveal_range(self.host.context, target.symbol.selection_range);
        self.host.request_render(self.host.context);
    }

    fn dispose(context: *anyopaque) void {
        const self: *DocumentSymbolsOutline = @ptrCast(@alignCast(context));
        self.elements.deinit();
        self.emitter.deinit();
        self.model.deinit();
        self.allocator.destroy(self);
    }
};
