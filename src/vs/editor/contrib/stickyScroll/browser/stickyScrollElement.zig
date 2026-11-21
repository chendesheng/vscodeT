// Port of `src/vs/editor/contrib/stickyScroll/browser/stickyScrollElement.ts`.
//
// The portable tree is unchanged. Ownership is explicit: every `StickyElement`
// is allocated in the owning `StickyModel` arena, so replacing the model frees
// the whole outline at once.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Uri = std.Uri;

/// Port of `StickyRange`.
pub const StickyRange = struct {
    start_line_number: usize,
    end_line_number: usize,

    pub fn init(start_line_number: usize, end_line_number: usize) StickyRange {
        return .{
            .start_line_number = start_line_number,
            .end_line_number = end_line_number,
        };
    }

    pub fn equals(self: StickyRange, other: StickyRange) bool {
        return self.start_line_number == other.start_line_number and
            self.end_line_number == other.end_line_number;
    }
};

/// Port of `StickyElement`.
pub const StickyElement = struct {
    /// Range of model line numbers spanned by the current scope. The root
    /// element has no range.
    range: ?StickyRange,
    /// Sorted by start line number.
    children: []*StickyElement,
    /// Parent sticky outline element.
    parent: ?*StickyElement = null,

    pub fn init(range: ?StickyRange, children: []*StickyElement) StickyElement {
        return .{
            .range = range,
            .children = children,
        };
    }
};

/// Port of `StickyModel`.
///
/// Terminal adaptation: the model owns the arena that backs its element tree
/// instead of relying on the JS garbage collector.
pub const StickyModel = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    uri: Uri,
    version: u32,
    element: ?*StickyElement,
    outline_provider_id: ?[]const u8,

    pub fn init(
        allocator: Allocator,
        uri: Uri,
        version: u32,
        outline_provider_id: ?[]const u8,
    ) !*StickyModel {
        const self = try allocator.create(StickyModel);
        errdefer allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned_provider_id = if (outline_provider_id) |id|
            try arena.allocator().dupe(u8, id)
        else
            null;
        self.* = .{
            .allocator = allocator,
            .arena = arena,
            .uri = uri,
            .version = version,
            .element = null,
            .outline_provider_id = owned_provider_id,
        };
        return self;
    }

    /// Arena used for the element tree. Elements must outlive the model.
    pub fn arenaAllocator(self: *StickyModel) Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *StickyModel) void {
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

const testing = std.testing;

test "StickyRange compares its line numbers" {
    const first = StickyRange.init(1, 3);
    try testing.expect(first.equals(.{ .start_line_number = 1, .end_line_number = 3 }));
    try testing.expect(!first.equals(.{ .start_line_number = 1, .end_line_number = 4 }));
}
