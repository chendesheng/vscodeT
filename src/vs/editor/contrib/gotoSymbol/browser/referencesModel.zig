// Port of the portable model subset of
// `src/vs/editor/contrib/gotoSymbol/browser/referencesModel.ts`.
//
// Terminal adaptations:
// - results are grouped into a self-contained arena-backed model;
// - file previews are omitted (they need the browser text-model resolver);
//   the TUI reference picker obtains preview text from open editors instead;
// - URI identity is compared through the canonical resource key string.
const std = @import("std");
const Allocator = std.mem.Allocator;
const strings = @import("../../../../base/common/strings.zig");
const range_mod = @import("../../../common/core/range.zig");
const Range = range_mod.Range;
const Position = @import("../../../common/core/position.zig").Position;
const LocationLink = @import("../../../common/languages.zig").LocationLink;

pub const OneReference = struct {
    is_provider_first: bool,
    parent: *FileReferences,
    link: LocationLink,

    pub fn uri(self: *const OneReference) []const u8 {
        return self.link.uri;
    }

    pub fn range(self: *const OneReference) Range {
        return self.link.target_selection_range;
    }
};

pub const FileReferences = struct {
    uri: []const u8,
    index: usize,
    children: []OneReference = &.{},
};

pub const ReferencesModel = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    groups: []FileReferences,
    references: []OneReference,

    pub fn init(allocator: Allocator, links: []const LocationLink, title: []const u8) !ReferencesModel {
        var model = ReferencesModel{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .title = title,
            .groups = &.{},
            .references = &.{},
        };
        errdefer model.arena.deinit();

        if (links.len == 0) return model;

        const Entry = struct {
            link: LocationLink,
            original_index: usize,
        };
        const entries = try allocator.alloc(Entry, links.len);
        defer allocator.free(entries);
        for (links, 0..) |link, index| entries[index] = .{ .link = link, .original_index = index };
        std.mem.sort(Entry, entries, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return compareLocations(a.link, b.link) < 0;
            }
        }.lessThan);

        var unique_count: usize = 0;
        var group_count: usize = 0;
        var previous: ?LocationLink = null;
        for (entries) |entry| {
            if (previous) |last| {
                if (sameLocation(last, entry.link)) continue;
                if (!std.mem.eql(u8, last.uri, entry.link.uri)) group_count += 1;
            } else {
                group_count = 1;
            }
            previous = entry.link;
            unique_count += 1;
        }

        const arena = model.arena.allocator();
        model.references = try arena.alloc(OneReference, unique_count);
        model.groups = try arena.alloc(FileReferences, group_count);

        var reference_index: usize = 0;
        var group_index: usize = 0;
        var group_start: usize = 0;
        previous = null;
        for (entries) |entry| {
            if (previous) |last| {
                if (sameLocation(last, entry.link)) continue;
                if (!std.mem.eql(u8, last.uri, entry.link.uri)) {
                    model.groups[group_index].children = model.references[group_start..reference_index];
                    group_index += 1;
                    group_start = reference_index;
                    model.groups[group_index] = .{
                        .uri = entry.link.uri,
                        .index = group_index,
                    };
                }
            } else {
                model.groups[0] = .{
                    .uri = entry.link.uri,
                    .index = 0,
                };
            }
            model.references[reference_index] = .{
                .is_provider_first = entry.original_index == 0,
                .parent = &model.groups[group_index],
                .link = entry.link,
            };
            reference_index += 1;
            previous = entry.link;
        }
        model.groups[group_index].children = model.references[group_start..reference_index];

        return model;
    }

    pub fn deinit(self: *ReferencesModel) void {
        self.arena.deinit();
    }

    pub fn isEmpty(self: *const ReferencesModel) bool {
        return self.groups.len == 0;
    }

    pub fn referenceCount(self: *const ReferencesModel) usize {
        return self.references.len;
    }

    pub fn firstReference(self: *const ReferencesModel) ?*const OneReference {
        for (self.references) |*reference| {
            if (reference.is_provider_first) return reference;
        }
        if (self.references.len == 0) return null;
        return &self.references[0];
    }

    pub fn nextOrPreviousReference(self: *const ReferencesModel, reference: *const OneReference, next: bool) *const OneReference {
        const parent = reference.parent;
        const child_count = parent.children.len;
        if (child_count == 0) return reference;
        var child_index: usize = 0;
        for (parent.children, 0..) |*child, index| {
            if (child == reference) {
                child_index = index;
                break;
            }
        }

        if (self.groups.len == 1 or (next and child_index + 1 < child_count) or (!next and child_index > 0)) {
            const index = if (next)
                (child_index + 1) % child_count
            else
                (child_index + child_count - 1) % child_count;
            return &parent.children[index];
        }

        const group_index = if (next)
            (parent.index + 1) % self.groups.len
        else
            (parent.index + self.groups.len - 1) % self.groups.len;
        const group = &self.groups[group_index];
        if (group.children.len == 0) return reference;
        return if (next) &group.children[0] else &group.children[group.children.len - 1];
    }

    pub fn nearestReference(self: *const ReferencesModel, resource: []const u8, position: Position) ?*const OneReference {
        if (self.references.len == 0) return null;
        var best_index: usize = 0;
        var best_prefix: usize = 0;
        var best_distance: usize = std.math.maxInt(usize);
        for (self.references, 0..) |reference, index| {
            const prefix = strings.commonPrefixLength(reference.uri(), resource);
            const range = reference.range();
            const distance = distanceTo(range.startLineNumber, range.startColumn, position);
            if (prefix > best_prefix or (prefix == best_prefix and distance < best_distance)) {
                best_index = index;
                best_prefix = prefix;
                best_distance = distance;
            }
        }
        return &self.references[best_index];
    }

    pub fn referenceAt(self: *const ReferencesModel, resource: []const u8, position: Position) ?*const OneReference {
        var owned_position = position;
        for (self.references) |*reference| {
            if (!std.mem.eql(u8, reference.uri(), resource)) continue;
            var range = reference.range();
            if (range.containsPosition(&owned_position)) return reference;
        }
        return null;
    }
};

fn compareLocations(a: LocationLink, b: LocationLink) isize {
    const uri_order = std.mem.order(u8, a.uri, b.uri);
    if (uri_order != .eq) return if (uri_order == .lt) -1 else 1;
    return range_mod.compareRangesUsingStarts(&a.range, &b.range);
}

fn sameLocation(a: LocationLink, b: LocationLink) bool {
    return std.mem.eql(u8, a.uri, b.uri) and range_mod.compareRangesUsingStarts(&a.range, &b.range) == 0;
}

fn distanceTo(line: usize, column: usize, position: Position) usize {
    const line_delta = @abs(@as(isize, @intCast(line)) - @as(isize, @intCast(position.lineNumber)));
    const column_delta = @abs(@as(isize, @intCast(column)) - @as(isize, @intCast(position.column)));
    return @intCast(line_delta * 100 + column_delta);
}
