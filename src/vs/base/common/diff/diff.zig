// Port of `src/vs/base/common/diff/diff.ts`.
//
// An implementation of the difference algorithm described in
// "An O(ND) Difference Algorithm and its variations" by Eugene W. Myers.
//
// The original code was ported from a C# implementation in Visual Studio.
const std = @import("std");
const Allocator = std.mem.Allocator;
const hash = @import("../hash.zig");
const diffChange = @import("diffChange.zig");

pub const DiffChange = diffChange.DiffChange;

const Changes = std.array_list.Managed(DiffChange);

const MAX_SAFE_SMALL_INTEGER: isize = 1 << 30;
const MIN_SAFE_SMALL_INTEGER: isize = -(1 << 30);

/// Our total memory usage for storing history is bounded by this many
/// differences; beyond that we fall back to a best-effort result.
const MAX_DIFFERENCES_HISTORY: usize = 1447;

/// The elements of a sequence. Mirrors `Int32Array | number[] | string[]` of
/// the TypeScript implementation, where an array of strings is hashed and
/// additionally compared by value.
pub const Elements = union(enum) {
    ints: []const i32,
    strings: []const []const u8,

    pub fn len(self: Elements) usize {
        return switch (self) {
            .ints => |values| values.len,
            .strings => |values| values.len,
        };
    }
};

/// A sequence of elements to diff. Implementations provide the elements and
/// optionally a "strict" element used to break ties between elements with the
/// same hash.
pub const ISequence = struct {
    context: *anyopaque,
    getElementsFn: *const fn (context: *anyopaque) Elements,
    getStrictElementFn: ?*const fn (context: *anyopaque, index: usize) []const u8 = null,

    pub fn getElements(self: ISequence) Elements {
        return self.getElementsFn(self.context);
    }

    pub fn getStrictElement(self: ISequence, index: usize) ?[]const u8 {
        const function = self.getStrictElementFn orelse return null;
        return function(self.context, index);
    }
};

/// Sequence over the bytes (UTF-8 code units) of a string.
pub const StringDiffSequence = struct {
    allocator: Allocator,
    elements: []i32,

    pub fn init(allocator: Allocator, source: []const u8) !StringDiffSequence {
        const elements = try allocator.alloc(i32, source.len);
        for (source, 0..) |character, i| {
            elements[i] = @as(i32, character);
        }
        return .{ .allocator = allocator, .elements = elements };
    }

    pub fn deinit(self: *StringDiffSequence) void {
        self.allocator.free(self.elements);
    }

    pub fn sequence(self: *StringDiffSequence) ISequence {
        return .{
            .context = self,
            .getElementsFn = struct {
                fn get(context: *anyopaque) Elements {
                    const self_: *StringDiffSequence = @ptrCast(@alignCast(context));
                    return .{ .ints = self_.elements };
                }
            }.get,
        };
    }
};

fn codePointAt(source: []const u8, offset: usize, byte_length: *usize) i32 {
    const first = source[offset];
    if (first < 0x80) {
        byte_length.* = 1;
        return @as(i32, first);
    }
    const sequence_length = std.unicode.utf8ByteSequenceLength(first) catch {
        byte_length.* = 1;
        return @as(i32, first);
    };
    if (offset + sequence_length <= source.len) {
        if (std.unicode.utf8Decode(source[offset..][0..sequence_length])) |code_point| {
            byte_length.* = sequence_length;
            return @intCast(code_point);
        } else |_| {}
    }
    byte_length.* = 1;
    return @as(i32, first);
}

/// Sequence over the unicode code points of a string, remembering the byte
/// offset of every code point so results can be mapped back.
pub const CodePointDiffSequence = struct {
    allocator: Allocator,
    elements: []i32,
    /// Byte offsets; `offsets.len == elements.len + 1`, the last entry being
    /// the length of the source.
    offsets: []usize,

    pub fn init(allocator: Allocator, source: []const u8) !CodePointDiffSequence {
        var element_count: usize = 0;
        {
            var offset: usize = 0;
            while (offset < source.len) {
                var byte_length: usize = undefined;
                _ = codePointAt(source, offset, &byte_length);
                offset += byte_length;
                element_count += 1;
            }
        }

        const elements = try allocator.alloc(i32, element_count);
        errdefer allocator.free(elements);
        const offsets = try allocator.alloc(usize, element_count + 1);
        errdefer allocator.free(offsets);

        var element_index: usize = 0;
        var offset: usize = 0;
        while (offset < source.len) : (element_index += 1) {
            offsets[element_index] = offset;
            var byte_length: usize = undefined;
            elements[element_index] = codePointAt(source, offset, &byte_length);
            offset += byte_length;
        }
        offsets[element_count] = source.len;

        return .{ .allocator = allocator, .elements = elements, .offsets = offsets };
    }

    pub fn deinit(self: *CodePointDiffSequence) void {
        self.allocator.free(self.elements);
        self.allocator.free(self.offsets);
    }

    pub fn getOffset(self: *const CodePointDiffSequence, element_index: usize) usize {
        return self.offsets[element_index];
    }

    pub fn sequence(self: *CodePointDiffSequence) ISequence {
        return .{
            .context = self,
            .getElementsFn = struct {
                fn get(context: *anyopaque) Elements {
                    const self_: *CodePointDiffSequence = @ptrCast(@alignCast(context));
                    return .{ .ints = self_.elements };
                }
            }.get,
        };
    }
};

/// Diffs two strings on code point boundaries and reports byte offsets. The
/// returned slice is owned by the caller.
pub fn stringDiff(allocator: Allocator, original: []const u8, modified: []const u8, pretty: bool) ![]DiffChange {
    var original_sequence = try CodePointDiffSequence.init(allocator, original);
    defer original_sequence.deinit();
    var modified_sequence = try CodePointDiffSequence.init(allocator, modified);
    defer modified_sequence.deinit();

    var diff = try LcsDiff.init(allocator, original_sequence.sequence(), modified_sequence.sequence(), null);
    defer diff.deinit();

    var result = try diff.computeDiff(pretty);
    defer result.deinit(allocator);

    const changes = try allocator.alloc(DiffChange, result.changes.len);
    errdefer allocator.free(changes);
    for (result.changes, 0..) |change, i| {
        const original_start = original_sequence.getOffset(@intCast(change.originalStart));
        const original_end = original_sequence.getOffset(@intCast(change.getOriginalEnd()));
        const modified_start = modified_sequence.getOffset(@intCast(change.modifiedStart));
        const modified_end = modified_sequence.getOffset(@intCast(change.getModifiedEnd()));
        changes[i] = DiffChange.init(
            @intCast(original_start),
            @intCast(original_end - original_start),
            @intCast(modified_start),
            @intCast(modified_end - modified_start),
        );
    }
    return changes;
}

/// Allows a client to stop the diff early, e.g. because it is taking too long.
pub const IContinueProcessingPredicate = struct {
    context: *anyopaque,
    predicateFn: *const fn (context: *anyopaque, furthestOriginalIndex: isize, matchLengthOfLongest: isize) bool,

    pub fn call(self: IContinueProcessingPredicate, furthest_original_index: isize, match_length_of_longest: isize) bool {
        return self.predicateFn(self.context, furthest_original_index, match_length_of_longest);
    }
};

pub const IDiffResult = struct {
    quitEarly: bool,
    changes: []DiffChange,

    pub fn deinit(self: *IDiffResult, allocator: Allocator) void {
        allocator.free(self.changes);
    }
};

/// A utility class which helps to create the set of `DiffChange`s from a
/// difference operation. It accepts original and modified elements that are
/// involved in a particular change; `markNextChange` marks the separation
/// between distinct changes.
const DiffChangeHelper = struct {
    allocator: Allocator,
    changes: Changes,
    m_originalStart: isize = MAX_SAFE_SMALL_INTEGER,
    m_modifiedStart: isize = MAX_SAFE_SMALL_INTEGER,
    m_originalCount: isize = 0,
    m_modifiedCount: isize = 0,

    fn init(allocator: Allocator) DiffChangeHelper {
        return .{ .allocator = allocator, .changes = Changes.init(allocator) };
    }

    /// Marks the beginning of the next change in the set of differences.
    fn markNextChange(self: *DiffChangeHelper) !void {
        if (self.m_originalCount > 0 or self.m_modifiedCount > 0) {
            try self.changes.append(DiffChange.init(
                self.m_originalStart,
                self.m_originalCount,
                self.m_modifiedStart,
                self.m_modifiedCount,
            ));
        }

        self.m_originalCount = 0;
        self.m_modifiedCount = 0;
        self.m_originalStart = MAX_SAFE_SMALL_INTEGER;
        self.m_modifiedStart = MAX_SAFE_SMALL_INTEGER;
    }

    fn addOriginalElement(self: *DiffChangeHelper, original_index: isize, modified_index: isize) void {
        // The 'true' start index is the smallest of the ones we've seen.
        self.m_originalStart = @min(self.m_originalStart, original_index);
        self.m_modifiedStart = @min(self.m_modifiedStart, modified_index);
        self.m_originalCount += 1;
    }

    fn addModifiedElement(self: *DiffChangeHelper, original_index: isize, modified_index: isize) void {
        self.m_originalStart = @min(self.m_originalStart, original_index);
        self.m_modifiedStart = @min(self.m_modifiedStart, modified_index);
        self.m_modifiedCount += 1;
    }

    /// Retrieves all of the changes marked by the helper.
    fn getChanges(self: *DiffChangeHelper) !Changes {
        if (self.m_originalCount > 0 or self.m_modifiedCount > 0) {
            try self.markNextChange();
        }
        return self.take();
    }

    /// Retrieves all of the changes marked by the helper in reverse order.
    fn getReverseChanges(self: *DiffChangeHelper) !Changes {
        if (self.m_originalCount > 0 or self.m_modifiedCount > 0) {
            try self.markNextChange();
        }
        const result = self.take();
        std.mem.reverse(DiffChange, result.items);
        return result;
    }

    fn take(self: *DiffChangeHelper) Changes {
        const result = self.changes;
        self.changes = Changes.init(self.allocator);
        return result;
    }
};

const SequenceElements = struct {
    strings: []const []const u8,
    hashes: []const i32,
    hasStrings: bool,
};

fn getElements(allocator: Allocator, sequence: ISequence) !SequenceElements {
    return switch (sequence.getElements()) {
        .strings => |strings| blk: {
            const hashes = try allocator.alloc(i32, strings.len);
            for (strings, 0..) |element, i| {
                hashes[i] = hash.stringHash(element, 0);
            }
            break :blk .{ .strings = strings, .hashes = hashes, .hasStrings = true };
        },
        .ints => |ints| .{ .strings = &.{}, .hashes = ints, .hasStrings = false },
    };
}

fn isWhitespaceOnly(value: []const u8) bool {
    for (value) |character| {
        if (!std.ascii.isWhitespace(character)) {
            return false;
        }
    }
    return true;
}

/// Diagonal bookkeeping passed to `walkTrace`.
const Diagonals = struct {
    forwardBase: isize,
    forwardStart: isize,
    forwardEnd: isize,
    forwardOffset: isize,
    reverseBase: isize,
    reverseStart: isize,
    reverseEnd: isize,
    reverseOffset: isize,
};

/// An implementation of the difference algorithm described in
/// "An O(ND) Difference Algorithm and its variations" by Eugene W. Myers.
pub const LcsDiff = struct {
    allocator: Allocator,
    continueProcessingPredicate: ?IContinueProcessingPredicate,
    originalSequence: ISequence,
    modifiedSequence: ISequence,
    hasStrings: bool,
    originalStringElements: []const []const u8,
    originalElementsOrHash: []const i32,
    modifiedStringElements: []const []const u8,
    modifiedElementsOrHash: []const i32,
    /// Hashes computed by `init` for string sequences (owned).
    ownedHashes: [2]?[]i32 = .{ null, null },
    forwardHistory: std.array_list.Managed([]i32),
    reverseHistory: std.array_list.Managed([]i32),

    /// Constructs the diff finder.
    pub fn init(
        allocator: Allocator,
        original_sequence: ISequence,
        modified_sequence: ISequence,
        continue_processing_predicate: ?IContinueProcessingPredicate,
    ) !LcsDiff {
        var self = LcsDiff{
            .allocator = allocator,
            .continueProcessingPredicate = continue_processing_predicate,
            .originalSequence = original_sequence,
            .modifiedSequence = modified_sequence,
            .hasStrings = false,
            .originalStringElements = &.{},
            .originalElementsOrHash = &.{},
            .modifiedStringElements = &.{},
            .modifiedElementsOrHash = &.{},
            .forwardHistory = std.array_list.Managed([]i32).init(allocator),
            .reverseHistory = std.array_list.Managed([]i32).init(allocator),
        };
        errdefer self.deinit();

        const original = try getElements(allocator, original_sequence);
        if (original.hasStrings) {
            self.ownedHashes[0] = @constCast(original.hashes);
        }
        const modified = try getElements(allocator, modified_sequence);
        if (modified.hasStrings) {
            self.ownedHashes[1] = @constCast(modified.hashes);
        }

        self.hasStrings = original.hasStrings and modified.hasStrings;
        self.originalStringElements = original.strings;
        self.originalElementsOrHash = original.hashes;
        self.modifiedStringElements = modified.strings;
        self.modifiedElementsOrHash = modified.hashes;
        return self;
    }

    pub fn deinit(self: *LcsDiff) void {
        for (self.ownedHashes) |maybe_hashes| {
            if (maybe_hashes) |hashes| {
                self.allocator.free(hashes);
            }
        }
        self.ownedHashes = .{ null, null };
        for (self.forwardHistory.items) |history| {
            self.allocator.free(history);
        }
        for (self.reverseHistory.items) |history| {
            self.allocator.free(history);
        }
        self.forwardHistory.deinit();
        self.reverseHistory.deinit();
    }

    fn elementsAreEqual(self: *const LcsDiff, original_index: isize, new_index: isize) bool {
        if (self.originalElementsOrHash[@intCast(original_index)] != self.modifiedElementsOrHash[@intCast(new_index)]) {
            return false;
        }
        return if (self.hasStrings)
            std.mem.eql(
                u8,
                self.originalStringElements[@intCast(original_index)],
                self.modifiedStringElements[@intCast(new_index)],
            )
        else
            true;
    }

    fn elementsAreStrictEqual(self: *const LcsDiff, original_index: isize, new_index: isize) bool {
        if (!self.elementsAreEqual(original_index, new_index)) {
            return false;
        }
        const original_element = self.originalSequence.getStrictElement(@intCast(original_index));
        const modified_element = self.modifiedSequence.getStrictElement(@intCast(new_index));
        // A sequence without strict elements yields `null` on both sides, which
        // compares equal in the TypeScript implementation.
        if (original_element == null and modified_element == null) {
            return true;
        }
        if (original_element == null or modified_element == null) {
            return false;
        }
        return std.mem.eql(u8, original_element.?, modified_element.?);
    }

    fn originalElementsAreEqual(self: *const LcsDiff, index1: isize, index2: isize) bool {
        if (self.originalElementsOrHash[@intCast(index1)] != self.originalElementsOrHash[@intCast(index2)]) {
            return false;
        }
        return if (self.hasStrings)
            std.mem.eql(
                u8,
                self.originalStringElements[@intCast(index1)],
                self.originalStringElements[@intCast(index2)],
            )
        else
            true;
    }

    fn modifiedElementsAreEqual(self: *const LcsDiff, index1: isize, index2: isize) bool {
        if (self.modifiedElementsOrHash[@intCast(index1)] != self.modifiedElementsOrHash[@intCast(index2)]) {
            return false;
        }
        return if (self.hasStrings)
            std.mem.eql(
                u8,
                self.modifiedStringElements[@intCast(index1)],
                self.modifiedStringElements[@intCast(index2)],
            )
        else
            true;
    }

    /// Computes the differences between the original and modified input
    /// sequences. The returned changes are owned by the caller.
    pub fn computeDiff(self: *LcsDiff, pretty: bool) !IDiffResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const result = try self.computeDiffRange(
            arena.allocator(),
            0,
            @as(isize, @intCast(self.originalElementsOrHash.len)) - 1,
            0,
            @as(isize, @intCast(self.modifiedElementsOrHash.len)) - 1,
            pretty,
        );

        const changes = try self.allocator.dupe(DiffChange, result.changes.items);
        return .{ .quitEarly = result.quitEarly, .changes = changes };
    }

    const DiffResult = struct {
        quitEarly: bool,
        changes: Changes,
    };

    fn computeDiffRange(
        self: *LcsDiff,
        allocator: Allocator,
        original_start: isize,
        original_end: isize,
        modified_start: isize,
        modified_end: isize,
        pretty: bool,
    ) !DiffResult {
        var quit_early = false;
        var changes = try self.computeDiffRecursive(
            allocator,
            original_start,
            original_end,
            modified_start,
            modified_end,
            &quit_early,
        );

        if (pretty) {
            // We have to clean up the computed diff to be more intuitive, but
            // it turns out this cannot be done correctly until the entire set
            // of diffs has been computed.
            self.prettifyChanges(&changes);
        }

        return .{ .quitEarly = quit_early, .changes = changes };
    }

    /// Computes the differences on the bounded range recursively.
    fn computeDiffRecursive(
        self: *LcsDiff,
        allocator: Allocator,
        original_start_in: isize,
        original_end_in: isize,
        modified_start_in: isize,
        modified_end_in: isize,
        quit_early: *bool,
    ) !Changes {
        var original_start = original_start_in;
        var original_end = original_end_in;
        var modified_start = modified_start_in;
        var modified_end = modified_end_in;

        quit_early.* = false;

        // Find the start of the differences
        while (original_start <= original_end and modified_start <= modified_end and self.elementsAreEqual(original_start, modified_start)) {
            original_start += 1;
            modified_start += 1;
        }

        // Find the end of the differences
        while (original_end >= original_start and modified_end >= modified_start and self.elementsAreEqual(original_end, modified_end)) {
            original_end -= 1;
            modified_end -= 1;
        }

        // In the special case where we either have all insertions or all
        // deletions or the sequences are identical.
        if (original_start > original_end or modified_start > modified_end) {
            var changes = Changes.init(allocator);
            if (modified_start <= modified_end) {
                std.debug.assert(original_start == original_end + 1);
                try changes.append(DiffChange.init(original_start, 0, modified_start, modified_end - modified_start + 1));
            } else if (original_start <= original_end) {
                std.debug.assert(modified_start == modified_end + 1);
                try changes.append(DiffChange.init(original_start, original_end - original_start + 1, modified_start, 0));
            }
            return changes;
        }

        var mid_original: isize = 0;
        var mid_modified: isize = 0;
        const result = try self.computeRecursionPoint(
            allocator,
            original_start,
            original_end,
            modified_start,
            modified_end,
            &mid_original,
            &mid_modified,
            quit_early,
        );

        if (result) |changes| {
            // Result is non-null when there was enough memory to compute the
            // changes while searching for the recursion point.
            return changes;
        }

        if (!quit_early.*) {
            // Break the problem down recursively by finding the changes in the
            // first half and the second half. `computeDiffRecursive` is
            // inclusive, therefore the second range starts on the next point.
            const left_changes = try self.computeDiffRecursive(
                allocator,
                original_start,
                mid_original,
                modified_start,
                mid_modified,
                quit_early,
            );

            if (!quit_early.*) {
                const right_changes = try self.computeDiffRecursive(
                    allocator,
                    mid_original + 1,
                    original_end,
                    mid_modified + 1,
                    modified_end,
                    quit_early,
                );
                return self.concatenateChanges(allocator, left_changes, right_changes);
            }

            // We didn't have time to finish the first half, so we don't have
            // time to compute this half. Consider the entire rest of the
            // sequence different.
            var right_changes = Changes.init(allocator);
            try right_changes.append(DiffChange.init(
                mid_original + 1,
                original_end - (mid_original + 1) + 1,
                mid_modified + 1,
                modified_end - (mid_modified + 1) + 1,
            ));
            return self.concatenateChanges(allocator, left_changes, right_changes);
        }

        // If we hit here, we quit early, and so can't return anything meaningful.
        var changes = Changes.init(allocator);
        try changes.append(DiffChange.init(
            original_start,
            original_end - original_start + 1,
            modified_start,
            modified_end - modified_start + 1,
        ));
        return changes;
    }

    fn walkTrace(
        self: *LcsDiff,
        allocator: Allocator,
        diagonals: Diagonals,
        forward_points_in: []i32,
        reverse_points_in: []i32,
        original_end: isize,
        mid_original: *isize,
        modified_end: isize,
        mid_modified: *isize,
        delta_is_even: bool,
        quit_early: *bool,
    ) !Changes {
        var forward_points = forward_points_in;
        var reverse_points = reverse_points_in;
        var diagonal_forward_base = diagonals.forwardBase;
        const diagonal_forward_offset = diagonals.forwardOffset;
        var diagonal_reverse_base = diagonals.reverseBase;
        const diagonal_reverse_offset = diagonals.reverseOffset;

        var forward_changes: ?Changes = null;
        var reverse_changes: ?Changes = null;

        // First, walk backward through the forward diagonals history.
        var change_helper = DiffChangeHelper.init(allocator);
        var diagonal_min = diagonals.forwardStart;
        var diagonal_max = diagonals.forwardEnd;
        var diagonal_relative = (mid_original.* - mid_modified.*) - diagonal_forward_offset;
        var last_original_index: isize = MIN_SAFE_SMALL_INTEGER;
        var history_index: isize = @as(isize, @intCast(self.forwardHistory.items.len)) - 1;

        while (true) {
            // Get the diagonal index from the relative diagonal number
            const diagonal = diagonal_relative + diagonal_forward_base;

            // Figure out where we came from
            if (diagonal == diagonal_min or (diagonal < diagonal_max and forward_points[@intCast(diagonal - 1)] < forward_points[@intCast(diagonal + 1)])) {
                // Vertical line (the element is an insert)
                const original_index = forward_points[@intCast(diagonal + 1)];
                const modified_index = original_index - diagonal_relative - diagonal_forward_offset;
                if (original_index < last_original_index) {
                    try change_helper.markNextChange();
                }
                last_original_index = original_index;
                change_helper.addModifiedElement(original_index + 1, modified_index);
                diagonal_relative = (diagonal + 1) - diagonal_forward_base;
            } else {
                // Horizontal line (the element is a deletion)
                const original_index = forward_points[@intCast(diagonal - 1)] + 1;
                const modified_index = original_index - diagonal_relative - diagonal_forward_offset;
                if (original_index < last_original_index) {
                    try change_helper.markNextChange();
                }
                last_original_index = original_index - 1;
                change_helper.addOriginalElement(original_index, modified_index + 1);
                diagonal_relative = (diagonal - 1) - diagonal_forward_base;
            }

            if (history_index >= 0) {
                forward_points = self.forwardHistory.items[@intCast(history_index)];
                diagonal_forward_base = forward_points[0]; // We stored this in the first spot
                diagonal_min = 1;
                // The history buffer carries a trailing sentinel, hence `- 2`.
                diagonal_max = @as(isize, @intCast(forward_points.len)) - 2;
            }

            history_index -= 1;
            if (history_index < -1) {
                break;
            }
        }

        // Ironically, we get the forward changes as the reverse of the order
        // we added them since we technically added them backwards.
        forward_changes = try change_helper.getReverseChanges();

        if (quit_early.*) {
            // Calculate a partial from the reverse diagonals. For now, just
            // assume everything after the midOriginal/midModified point is a
            // diff.
            var original_start_point = mid_original.* + 1;
            var modified_start_point = mid_modified.* + 1;

            if (forward_changes.?.items.len > 0) {
                const last_forward_change = forward_changes.?.items[forward_changes.?.items.len - 1];
                original_start_point = @max(original_start_point, last_forward_change.getOriginalEnd());
                modified_start_point = @max(modified_start_point, last_forward_change.getModifiedEnd());
            }

            var changes = Changes.init(allocator);
            try changes.append(DiffChange.init(
                original_start_point,
                original_end - original_start_point + 1,
                modified_start_point,
                modified_end - modified_start_point + 1,
            ));
            reverse_changes = changes;
        } else {
            // Now walk backward through the reverse diagonals history.
            change_helper = DiffChangeHelper.init(allocator);
            diagonal_min = diagonals.reverseStart;
            diagonal_max = diagonals.reverseEnd;
            diagonal_relative = (mid_original.* - mid_modified.*) - diagonal_reverse_offset;
            last_original_index = MAX_SAFE_SMALL_INTEGER;
            history_index = if (delta_is_even)
                @as(isize, @intCast(self.reverseHistory.items.len)) - 1
            else
                @as(isize, @intCast(self.reverseHistory.items.len)) - 2;

            while (true) {
                // Get the diagonal index from the relative diagonal number
                const diagonal = diagonal_relative + diagonal_reverse_base;

                if (diagonal == diagonal_min or (diagonal < diagonal_max and reverse_points[@intCast(diagonal - 1)] >= reverse_points[@intCast(diagonal + 1)])) {
                    // Horizontal line (the element is a deletion)
                    const original_index = reverse_points[@intCast(diagonal + 1)] - 1;
                    const modified_index = original_index - diagonal_relative - diagonal_reverse_offset;
                    if (original_index > last_original_index) {
                        try change_helper.markNextChange();
                    }
                    last_original_index = original_index + 1;
                    change_helper.addOriginalElement(original_index + 1, modified_index + 1);
                    diagonal_relative = (diagonal + 1) - diagonal_reverse_base;
                } else {
                    // Vertical line (the element is an insertion)
                    const original_index = reverse_points[@intCast(diagonal - 1)];
                    const modified_index = original_index - diagonal_relative - diagonal_reverse_offset;
                    if (original_index > last_original_index) {
                        try change_helper.markNextChange();
                    }
                    last_original_index = original_index;
                    change_helper.addModifiedElement(original_index + 1, modified_index + 1);
                    diagonal_relative = (diagonal - 1) - diagonal_reverse_base;
                }

                if (history_index >= 0) {
                    reverse_points = self.reverseHistory.items[@intCast(history_index)];
                    diagonal_reverse_base = reverse_points[0]; // We stored this in the first spot
                    diagonal_min = 1;
                    // The history buffer carries a trailing sentinel, hence `- 2`.
                    diagonal_max = @as(isize, @intCast(reverse_points.len)) - 2;
                }

                history_index -= 1;
                if (history_index < -1) {
                    break;
                }
            }

            // There are cases where the reverse history will find diffs that
            // are correct, but not intuitive, so we need shift them.
            reverse_changes = try change_helper.getChanges();
        }

        return self.concatenateChanges(allocator, forward_changes.?, reverse_changes.?);
    }

    /// Given the range to compute the diff on, finds the point
    /// `(midOriginal, midModified)` in the middle of the LCS of the two
    /// sequences at which the LCS problem may be broken down recursively.
    /// Returns the change list when the full trace is available in memory and
    /// `null` when it is not.
    fn computeRecursionPoint(
        self: *LcsDiff,
        allocator: Allocator,
        original_start_in: isize,
        original_end: isize,
        modified_start_in: isize,
        modified_end: isize,
        mid_original: *isize,
        mid_modified: *isize,
        quit_early: *bool,
    ) !?Changes {
        var original_index: isize = 0;
        var modified_index: isize = 0;
        var diagonal_forward_start: isize = 0;
        var diagonal_forward_end: isize = 0;
        var diagonal_reverse_start: isize = 0;
        var diagonal_reverse_end: isize = 0;

        // To traverse the edit graph and produce the proper LCS, our actual
        // start position is just outside the given boundary.
        var original_start = original_start_in - 1;
        var modified_start = modified_start_in - 1;

        // We set these up to make the compiler happy, but they will be
        // replaced before we return with the actual recursion point.
        mid_original.* = 0;
        mid_modified.* = 0;

        // Clear out the history
        for (self.forwardHistory.items) |history| {
            self.allocator.free(history);
        }
        for (self.reverseHistory.items) |history| {
            self.allocator.free(history);
        }
        self.forwardHistory.clearRetainingCapacity();
        self.reverseHistory.clearRetainingCapacity();

        // Each cell in the two arrays corresponds to a diagonal in the edit
        // graph. The integer value in the cell represents the originalIndex of
        // the furthest reaching point found so far that ends in that diagonal.
        // The modifiedIndex can be computed mathematically from the
        // originalIndex and the diagonal number.
        const max_differences = (original_end - original_start) + (modified_end - modified_start);
        const num_diagonals = max_differences + 1;
        const forward_points = try allocator.alloc(i32, @intCast(num_diagonals));
        const reverse_points = try allocator.alloc(i32, @intCast(num_diagonals));
        // diagonalForwardBase: index into forwardPoints of the diagonal which
        // passes through (originalStart, modifiedStart).
        // diagonalReverseBase: index into reversePoints of the diagonal which
        // passes through (originalEnd, modifiedEnd).
        const diagonal_forward_base = modified_end - modified_start;
        const diagonal_reverse_base = original_end - original_start;
        // Offsets which allow the modified index to be computed from the
        // original index and the relative diagonal number.
        const diagonal_forward_offset = original_start - modified_start;
        const diagonal_reverse_offset = original_end - modified_end;

        // delta: the difference between the end diagonal and the start
        // diagonal. Its even/odd-ness is important for determining when we
        // should check for overlap.
        const delta = diagonal_reverse_base - diagonal_forward_base;
        const delta_is_even = @mod(delta, 2) == 0;

        // Set up the start and end points as the furthest points found so far
        // in both the forward and reverse directions.
        forward_points[@intCast(diagonal_forward_base)] = @intCast(original_start);
        reverse_points[@intCast(diagonal_reverse_base)] = @intCast(original_end);

        // Remember if we quit early, and thus need to do a best-effort result
        // instead of a real result.
        quit_early.* = false;

        // With this method, we iterate on the number of differences between
        // the two sequences. The more differences there actually are, the
        // longer this will take. Also, as the number of differences
        // increases, we have to search on diagonals further away from the
        // reference diagonal. We extend on even diagonals (relative to the
        // reference diagonal) only when numDifferences is even and odd
        // diagonals only when numDifferences is odd.
        var num_differences: isize = 1;
        while (num_differences <= @divTrunc(max_differences, 2) + 1) : (num_differences += 1) {
            var furthest_original_index: isize = 0;
            var furthest_modified_index: isize = 0;

            // Run the algorithm in the forward direction
            diagonal_forward_start = clipDiagonalBound(
                diagonal_forward_base - num_differences,
                num_differences,
                diagonal_forward_base,
                num_diagonals,
            );
            diagonal_forward_end = clipDiagonalBound(
                diagonal_forward_base + num_differences,
                num_differences,
                diagonal_forward_base,
                num_diagonals,
            );

            var diagonal = diagonal_forward_start;
            while (diagonal <= diagonal_forward_end) : (diagonal += 2) {
                // STEP 1: We extend the furthest reaching point in the present
                // diagonal by looking at the diagonals above and below and
                // picking the one whose point is further away from the start.
                if (diagonal == diagonal_forward_start or (diagonal < diagonal_forward_end and forward_points[@intCast(diagonal - 1)] < forward_points[@intCast(diagonal + 1)])) {
                    original_index = forward_points[@intCast(diagonal + 1)];
                } else {
                    original_index = forward_points[@intCast(diagonal - 1)] + 1;
                }
                modified_index = original_index - (diagonal - diagonal_forward_base) - diagonal_forward_offset;

                // Save the current originalIndex so we can test for false
                // overlap in step 3.
                const temp_original_index = original_index;

                // STEP 2: We can continue to extend the furthest reaching
                // point in the present diagonal as long as the elements are
                // equal.
                while (original_index < original_end and modified_index < modified_end and self.elementsAreEqual(original_index + 1, modified_index + 1)) {
                    original_index += 1;
                    modified_index += 1;
                }
                forward_points[@intCast(diagonal)] = @intCast(original_index);

                if (original_index + modified_index > furthest_original_index + furthest_modified_index) {
                    furthest_original_index = original_index;
                    furthest_modified_index = modified_index;
                }

                // STEP 3: If delta is odd (overlap first happens on forward
                // when delta is odd) and diagonal is in the range of reverse
                // diagonals computed for numDifferences-1 (the previous
                // iteration; we haven't computed reverse diagonals for
                // numDifferences yet) then check for overlap.
                if (!delta_is_even and absIsize(diagonal - diagonal_reverse_base) <= (num_differences - 1)) {
                    if (original_index >= reverse_points[@intCast(diagonal)]) {
                        mid_original.* = original_index;
                        mid_modified.* = modified_index;

                        if (temp_original_index <= reverse_points[@intCast(diagonal)] and num_differences <= @as(isize, @intCast(MAX_DIFFERENCES_HISTORY + 1))) {
                            // BINGO! We overlapped, and we have the full trace
                            // in memory!
                            return try self.walkTrace(
                                allocator,
                                .{
                                    .forwardBase = diagonal_forward_base,
                                    .forwardStart = diagonal_forward_start,
                                    .forwardEnd = diagonal_forward_end,
                                    .forwardOffset = diagonal_forward_offset,
                                    .reverseBase = diagonal_reverse_base,
                                    .reverseStart = diagonal_reverse_start,
                                    .reverseEnd = diagonal_reverse_end,
                                    .reverseOffset = diagonal_reverse_offset,
                                },
                                forward_points,
                                reverse_points,
                                original_end,
                                mid_original,
                                modified_end,
                                mid_modified,
                                delta_is_even,
                                quit_early,
                            );
                        }

                        // Either false overlap, or we didn't have enough
                        // memory for the full trace. Just return the recursion
                        // point.
                        return null;
                    }
                }
            }

            // Check to see if we should be quitting early, before moving on
            // to the next iteration.
            const match_length_of_longest = @divTrunc(
                (furthest_original_index - original_start) + (furthest_modified_index - modified_start) - num_differences,
                2,
            );

            if (self.continueProcessingPredicate) |predicate| {
                if (!predicate.call(furthest_original_index, match_length_of_longest)) {
                    // We can't finish, so skip ahead to generating a result
                    // from what we have.
                    quit_early.* = true;

                    // Use the furthest distance we got in the forward direction.
                    mid_original.* = furthest_original_index;
                    mid_modified.* = furthest_modified_index;

                    if (match_length_of_longest > 0 and num_differences <= @as(isize, @intCast(MAX_DIFFERENCES_HISTORY + 1))) {
                        // Enough of the history is in memory to walk it backwards
                        return try self.walkTrace(
                            allocator,
                            .{
                                .forwardBase = diagonal_forward_base,
                                .forwardStart = diagonal_forward_start,
                                .forwardEnd = diagonal_forward_end,
                                .forwardOffset = diagonal_forward_offset,
                                .reverseBase = diagonal_reverse_base,
                                .reverseStart = diagonal_reverse_start,
                                .reverseEnd = diagonal_reverse_end,
                                .reverseOffset = diagonal_reverse_offset,
                            },
                            forward_points,
                            reverse_points,
                            original_end,
                            mid_original,
                            modified_end,
                            mid_modified,
                            delta_is_even,
                            quit_early,
                        );
                    }

                    // We didn't actually remember enough of the history.
                    // Since we are quitting the diff early, we need to shift
                    // back the originalStart and modifiedStart back into the
                    // boundary limits since we decremented their value above
                    // beyond the boundary limit.
                    original_start += 1;
                    modified_start += 1;

                    var changes = Changes.init(allocator);
                    try changes.append(DiffChange.init(
                        original_start,
                        original_end - original_start + 1,
                        modified_start,
                        modified_end - modified_start + 1,
                    ));
                    return changes;
                }
            }

            // Run the algorithm in the reverse direction
            diagonal_reverse_start = clipDiagonalBound(
                diagonal_reverse_base - num_differences,
                num_differences,
                diagonal_reverse_base,
                num_diagonals,
            );
            diagonal_reverse_end = clipDiagonalBound(
                diagonal_reverse_base + num_differences,
                num_differences,
                diagonal_reverse_base,
                num_diagonals,
            );

            diagonal = diagonal_reverse_start;
            while (diagonal <= diagonal_reverse_end) : (diagonal += 2) {
                // STEP 1: We extend the furthest reaching point in the present
                // diagonal by looking at the diagonals above and below and
                // picking the one whose point is further away from the end.
                if (diagonal == diagonal_reverse_start or (diagonal < diagonal_reverse_end and reverse_points[@intCast(diagonal - 1)] >= reverse_points[@intCast(diagonal + 1)])) {
                    original_index = reverse_points[@intCast(diagonal + 1)] - 1;
                } else {
                    original_index = reverse_points[@intCast(diagonal - 1)];
                }
                modified_index = original_index - (diagonal - diagonal_reverse_base) - diagonal_reverse_offset;

                // Save the current originalIndex so we can test for false overlap
                const temp_original_index = original_index;

                // STEP 2: We can continue to extend the furthest reaching
                // point in the present diagonal as long as the elements are
                // equal.
                while (original_index > original_start and modified_index > modified_start and self.elementsAreEqual(original_index, modified_index)) {
                    original_index -= 1;
                    modified_index -= 1;
                }
                reverse_points[@intCast(diagonal)] = @intCast(original_index);

                // STEP 4: If delta is even (overlap first happens on reverse
                // when delta is even) and diagonal is in the range of forward
                // diagonals computed for numDifferences then check for overlap.
                if (delta_is_even and absIsize(diagonal - diagonal_forward_base) <= num_differences) {
                    if (original_index <= forward_points[@intCast(diagonal)]) {
                        mid_original.* = original_index;
                        mid_modified.* = modified_index;

                        if (temp_original_index >= forward_points[@intCast(diagonal)] and num_differences <= @as(isize, @intCast(MAX_DIFFERENCES_HISTORY + 1))) {
                            // BINGO! We overlapped, and we have the full trace
                            // in memory!
                            return try self.walkTrace(
                                allocator,
                                .{
                                    .forwardBase = diagonal_forward_base,
                                    .forwardStart = diagonal_forward_start,
                                    .forwardEnd = diagonal_forward_end,
                                    .forwardOffset = diagonal_forward_offset,
                                    .reverseBase = diagonal_reverse_base,
                                    .reverseStart = diagonal_reverse_start,
                                    .reverseEnd = diagonal_reverse_end,
                                    .reverseOffset = diagonal_reverse_offset,
                                },
                                forward_points,
                                reverse_points,
                                original_end,
                                mid_original,
                                modified_end,
                                mid_modified,
                                delta_is_even,
                                quit_early,
                            );
                        }

                        // Either false overlap, or we didn't have enough
                        // memory for the full trace. Just return the recursion
                        // point.
                        return null;
                    }
                }
            }

            // Save current vectors to history before the next iteration
            if (num_differences <= @as(isize, @intCast(MAX_DIFFERENCES_HISTORY))) {
                // We are allocating space for one extra int, which we fill
                // with the index of the diagonal base index, plus a trailing
                // sentinel so that out-of-range reads in `walkTrace` stay
                // inside the allocation.
                {
                    const length: usize = @intCast(diagonal_forward_end - diagonal_forward_start + 3);
                    const temp = try self.allocator.alloc(i32, length);
                    @memset(temp, 0);
                    temp[0] = @intCast(diagonal_forward_base - diagonal_forward_start + 1);
                    const count: usize = @intCast(diagonal_forward_end - diagonal_forward_start + 1);
                    @memcpy(temp[1 .. 1 + count], forward_points[@intCast(diagonal_forward_start)..][0..count]);
                    try self.forwardHistory.append(temp);
                }
                {
                    const length: usize = @intCast(diagonal_reverse_end - diagonal_reverse_start + 3);
                    const temp = try self.allocator.alloc(i32, length);
                    @memset(temp, 0);
                    temp[0] = @intCast(diagonal_reverse_base - diagonal_reverse_start + 1);
                    const count: usize = @intCast(diagonal_reverse_end - diagonal_reverse_start + 1);
                    @memcpy(temp[1 .. 1 + count], reverse_points[@intCast(diagonal_reverse_start)..][0..count]);
                    try self.reverseHistory.append(temp);
                }
            }
        }

        // If we got here, then we have the full trace in history. We just have
        // to convert it to a change list.
        return try self.walkTrace(
            allocator,
            .{
                .forwardBase = diagonal_forward_base,
                .forwardStart = diagonal_forward_start,
                .forwardEnd = diagonal_forward_end,
                .forwardOffset = diagonal_forward_offset,
                .reverseBase = diagonal_reverse_base,
                .reverseStart = diagonal_reverse_start,
                .reverseEnd = diagonal_reverse_end,
                .reverseOffset = diagonal_reverse_offset,
            },
            forward_points,
            reverse_points,
            original_end,
            mid_original,
            modified_end,
            mid_modified,
            delta_is_even,
            quit_early,
        );
    }

    /// Shifts the given changes to provide a more intuitive diff. While the
    /// first element in a diff matches the first element after the diff, we
    /// shift the diff down.
    fn prettifyChanges(self: *LcsDiff, changes: *Changes) void {
        const original_length: isize = @intCast(self.originalElementsOrHash.len);
        const modified_length: isize = @intCast(self.modifiedElementsOrHash.len);

        // Shift all the changes down first
        var i: isize = 0;
        while (i < @as(isize, @intCast(changes.items.len))) : (i += 1) {
            var change = changes.items[@intCast(i)];
            const original_stop = if (i < @as(isize, @intCast(changes.items.len)) - 1) changes.items[@intCast(i + 1)].originalStart else original_length;
            const modified_stop = if (i < @as(isize, @intCast(changes.items.len)) - 1) changes.items[@intCast(i + 1)].modifiedStart else modified_length;
            const check_original = change.originalLength > 0;
            const check_modified = change.modifiedLength > 0;

            while (change.originalStart + change.originalLength < original_stop and
                change.modifiedStart + change.modifiedLength < modified_stop and
                (!check_original or self.originalElementsAreEqual(change.originalStart, change.originalStart + change.originalLength)) and
                (!check_modified or self.modifiedElementsAreEqual(change.modifiedStart, change.modifiedStart + change.modifiedLength)))
            {
                const start_strict_equal = self.elementsAreStrictEqual(change.originalStart, change.modifiedStart);
                const end_strict_equal = self.elementsAreStrictEqual(change.originalStart + change.originalLength, change.modifiedStart + change.modifiedLength);
                if (end_strict_equal and !start_strict_equal) {
                    // moving the change down would create an equal change, but
                    // the elements are not strict equal
                    break;
                }
                change.originalStart += 1;
                change.modifiedStart += 1;
            }
            changes.items[@intCast(i)] = change;

            var merged_change: ?DiffChange = null;
            if (i < @as(isize, @intCast(changes.items.len)) - 1 and self.changesOverlap(changes.items[@intCast(i)], changes.items[@intCast(i + 1)], &merged_change)) {
                changes.items[@intCast(i)] = merged_change.?;
                _ = changes.orderedRemove(@intCast(i + 1));
                i -= 1;
            }
        }

        // Shift changes back up until we hit empty or whitespace-only lines
        var j: isize = @as(isize, @intCast(changes.items.len)) - 1;
        while (j >= 0) : (j -= 1) {
            var change = changes.items[@intCast(j)];

            var original_stop: isize = 0;
            var modified_stop: isize = 0;
            if (j > 0) {
                const previous_change = changes.items[@intCast(j - 1)];
                original_stop = previous_change.originalStart + previous_change.originalLength;
                modified_stop = previous_change.modifiedStart + previous_change.modifiedLength;
            }

            const check_original = change.originalLength > 0;
            const check_modified = change.modifiedLength > 0;

            var best_delta: isize = 0;
            var best_score = self.boundaryScore(change.originalStart, change.originalLength, change.modifiedStart, change.modifiedLength);

            var delta: isize = 1;
            while (true) : (delta += 1) {
                const original_start = change.originalStart - delta;
                const modified_start = change.modifiedStart - delta;

                if (original_start < original_stop or modified_start < modified_stop) {
                    break;
                }

                if (check_original and !self.originalElementsAreEqual(original_start, original_start + change.originalLength)) {
                    break;
                }

                if (check_modified and !self.modifiedElementsAreEqual(modified_start, modified_start + change.modifiedLength)) {
                    break;
                }

                const touching_previous_change = original_start == original_stop and modified_start == modified_stop;
                const score = (if (touching_previous_change) @as(isize, 5) else 0) +
                    self.boundaryScore(original_start, change.originalLength, modified_start, change.modifiedLength);

                if (score > best_score) {
                    best_score = score;
                    best_delta = delta;
                }
            }

            change.originalStart -= best_delta;
            change.modifiedStart -= best_delta;
            changes.items[@intCast(j)] = change;

            var merged_change: ?DiffChange = null;
            if (j > 0 and self.changesOverlap(changes.items[@intCast(j - 1)], changes.items[@intCast(j)], &merged_change)) {
                changes.items[@intCast(j - 1)] = merged_change.?;
                _ = changes.orderedRemove(@intCast(j));
                j += 1;
            }
        }

        // There could be multiple longest common substrings. Give preference
        // to the ones containing longer lines.
        if (self.hasStrings) {
            var index: usize = 1;
            while (index < changes.items.len) : (index += 1) {
                const a_change = &changes.items[index - 1];
                const b_change = &changes.items[index];
                const matched_length = b_change.originalStart - a_change.originalStart - a_change.originalLength;
                const a_original_start = a_change.originalStart;
                const b_original_end = b_change.originalStart + b_change.originalLength;
                const ab_original_length = b_original_end - a_original_start;
                const a_modified_start = a_change.modifiedStart;
                const b_modified_end = b_change.modifiedStart + b_change.modifiedLength;
                const ab_modified_length = b_modified_end - a_modified_start;
                // Avoid wasting a lot of time with these searches
                if (matched_length < 5 and ab_original_length < 20 and ab_modified_length < 20) {
                    if (self.findBetterContiguousSequence(a_original_start, ab_original_length, a_modified_start, ab_modified_length, matched_length)) |found| {
                        const original_match_start = found[0];
                        const modified_match_start = found[1];
                        if (original_match_start != a_change.originalStart + a_change.originalLength or
                            modified_match_start != a_change.modifiedStart + a_change.modifiedLength)
                        {
                            // switch to another sequence that has a better score
                            a_change.originalLength = original_match_start - a_change.originalStart;
                            a_change.modifiedLength = modified_match_start - a_change.modifiedStart;
                            b_change.originalStart = original_match_start + matched_length;
                            b_change.modifiedStart = modified_match_start + matched_length;
                            b_change.originalLength = b_original_end - b_change.originalStart;
                            b_change.modifiedLength = b_modified_end - b_change.modifiedStart;
                        }
                    }
                }
            }
        }
    }

    fn findBetterContiguousSequence(
        self: *const LcsDiff,
        original_start: isize,
        original_length: isize,
        modified_start: isize,
        modified_length: isize,
        desired_length: isize,
    ) ?[2]isize {
        if (original_length < desired_length or modified_length < desired_length) {
            return null;
        }
        const original_max = original_start + original_length - desired_length + 1;
        const modified_max = modified_start + modified_length - desired_length + 1;
        var best_score: isize = 0;
        var best_original_start: isize = 0;
        var best_modified_start: isize = 0;
        var i = original_start;
        while (i < original_max) : (i += 1) {
            var j = modified_start;
            while (j < modified_max) : (j += 1) {
                const score = self.contiguousSequenceScore(i, j, desired_length);
                if (score > 0 and score > best_score) {
                    best_score = score;
                    best_original_start = i;
                    best_modified_start = j;
                }
            }
        }
        if (best_score > 0) {
            return [2]isize{ best_original_start, best_modified_start };
        }
        return null;
    }

    fn contiguousSequenceScore(self: *const LcsDiff, original_start: isize, modified_start: isize, length: isize) isize {
        var score: isize = 0;
        var l: isize = 0;
        while (l < length) : (l += 1) {
            if (!self.elementsAreEqual(original_start + l, modified_start + l)) {
                return 0;
            }
            score += @intCast(self.originalStringElements[@intCast(original_start + l)].len);
        }
        return score;
    }

    fn originalIsBoundary(self: *const LcsDiff, index: isize) bool {
        if (index <= 0 or index >= @as(isize, @intCast(self.originalElementsOrHash.len)) - 1) {
            return true;
        }
        return self.hasStrings and isWhitespaceOnly(self.originalStringElements[@intCast(index)]);
    }

    fn originalRegionIsBoundary(self: *const LcsDiff, original_start: isize, original_length: isize) bool {
        if (self.originalIsBoundary(original_start) or self.originalIsBoundary(original_start - 1)) {
            return true;
        }
        if (original_length > 0) {
            const original_end = original_start + original_length;
            if (self.originalIsBoundary(original_end - 1) or self.originalIsBoundary(original_end)) {
                return true;
            }
        }
        return false;
    }

    fn modifiedIsBoundary(self: *const LcsDiff, index: isize) bool {
        if (index <= 0 or index >= @as(isize, @intCast(self.modifiedElementsOrHash.len)) - 1) {
            return true;
        }
        return self.hasStrings and isWhitespaceOnly(self.modifiedStringElements[@intCast(index)]);
    }

    fn modifiedRegionIsBoundary(self: *const LcsDiff, modified_start: isize, modified_length: isize) bool {
        if (self.modifiedIsBoundary(modified_start) or self.modifiedIsBoundary(modified_start - 1)) {
            return true;
        }
        if (modified_length > 0) {
            const modified_end = modified_start + modified_length;
            if (self.modifiedIsBoundary(modified_end - 1) or self.modifiedIsBoundary(modified_end)) {
                return true;
            }
        }
        return false;
    }

    fn boundaryScore(self: *const LcsDiff, original_start: isize, original_length: isize, modified_start: isize, modified_length: isize) isize {
        const original_score: isize = if (self.originalRegionIsBoundary(original_start, original_length)) 1 else 0;
        const modified_score: isize = if (self.modifiedRegionIsBoundary(modified_start, modified_length)) 1 else 0;
        return original_score + modified_score;
    }

    /// Concatenates the two input change lists and returns the resulting list.
    fn concatenateChanges(self: *const LcsDiff, allocator: Allocator, left: Changes, right: Changes) !Changes {
        if (left.items.len == 0 or right.items.len == 0) {
            return if (right.items.len > 0) right else left;
        }

        var merged_change: ?DiffChange = null;
        if (self.changesOverlap(left.items[left.items.len - 1], right.items[0], &merged_change)) {
            // Since we break the problem down recursively, it is possible that
            // we might recurse in the middle of a change thereby splitting it
            // into two changes. Here in the combining stage, we detect and
            // fuse those changes back together.
            var result = Changes.init(allocator);
            try result.ensureTotalCapacity(left.items.len + right.items.len - 1);
            try result.appendSlice(left.items[0 .. left.items.len - 1]);
            try result.append(merged_change.?);
            try result.appendSlice(right.items[1..]);
            return result;
        }

        var result = Changes.init(allocator);
        try result.ensureTotalCapacity(left.items.len + right.items.len);
        try result.appendSlice(left.items);
        try result.appendSlice(right.items);
        return result;
    }

    /// Returns true if the two changes overlap and can be merged into a single
    /// change.
    fn changesOverlap(self: *const LcsDiff, left: DiffChange, right: DiffChange, merged_change: *?DiffChange) bool {
        _ = self;
        std.debug.assert(left.originalStart <= right.originalStart);
        std.debug.assert(left.modifiedStart <= right.modifiedStart);

        if (left.originalStart + left.originalLength >= right.originalStart or left.modifiedStart + left.modifiedLength >= right.modifiedStart) {
            const original_start = left.originalStart;
            var original_length = left.originalLength;
            const modified_start = left.modifiedStart;
            var modified_length = left.modifiedLength;

            if (left.originalStart + left.originalLength >= right.originalStart) {
                original_length = right.originalStart + right.originalLength - left.originalStart;
            }
            if (left.modifiedStart + left.modifiedLength >= right.modifiedStart) {
                modified_length = right.modifiedStart + right.modifiedLength - left.modifiedStart;
            }

            merged_change.* = DiffChange.init(original_start, original_length, modified_start, modified_length);
            return true;
        }

        merged_change.* = null;
        return false;
    }
};

fn absIsize(value: isize) isize {
    return if (value < 0) -value else value;
}

/// Clips a diagonal index to the range of valid diagonals. This also decides
/// whether or not the diagonal index, if it exceeds the boundary, should be
/// clipped to the boundary or clipped one inside the boundary depending on the
/// even/odd status of the boundary and `numDifferences`.
fn clipDiagonalBound(diagonal: isize, num_differences: isize, diagonal_base_index: isize, num_diagonals: isize) isize {
    if (diagonal >= 0 and diagonal < num_diagonals) {
        // Nothing to clip, its in range
        return diagonal;
    }

    // diagonalsBelow: the number of diagonals below the reference diagonal.
    // diagonalsAbove: the number of diagonals above the reference diagonal.
    const diagonals_below = diagonal_base_index;
    const diagonals_above = num_diagonals - diagonal_base_index - 1;
    const diff_even = @mod(num_differences, 2) == 0;

    if (diagonal < 0) {
        const lower_bound_even = @mod(diagonals_below, 2) == 0;
        return if (diff_even == lower_bound_even) 0 else 1;
    }

    const upper_bound_even = @mod(diagonals_above, 2) == 0;
    return if (diff_even == upper_bound_even) num_diagonals - 1 else num_diagonals - 2;
}

/// Computes the Levenshtein distance between two strings.
///
/// Upstream uses a bit-parallel Myers variant; this port computes the same
/// value with the classic dynamic programming recurrence, which is easier to
/// verify and behaves identically for the sizes involved.
pub fn computeLevenshteinDistance(allocator: Allocator, first_string: []const u8, second_string: []const u8) !usize {
    var first = first_string;
    var second = second_string;
    if (first.len < second.len) {
        const temp = second;
        second = first;
        first = temp;
    }
    if (second.len == 0) {
        return first.len;
    }

    var previous = try allocator.alloc(usize, second.len + 1);
    defer allocator.free(previous);
    var current = try allocator.alloc(usize, second.len + 1);
    defer allocator.free(current);

    for (previous, 0..) |*entry, j| {
        entry.* = j;
    }

    for (first, 0..) |first_character, i| {
        current[0] = i + 1;
        for (second, 0..) |second_character, j| {
            const substitution_cost: usize = if (first_character == second_character) 0 else 1;
            current[j + 1] = @min(
                @min(current[j] + 1, previous[j + 1] + 1),
                previous[j] + substitution_cost,
            );
        }
        const swap = previous;
        previous = current;
        current = swap;
    }

    return previous[second.len];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestSequence = struct {
    elements: []const i32,

    fn sequence(self: *TestSequence) ISequence {
        return .{
            .context = self,
            .getElementsFn = struct {
                fn get(context: *anyopaque) Elements {
                    const self_: *TestSequence = @ptrCast(@alignCast(context));
                    return .{ .ints = self_.elements };
                }
            }.get,
        };
    }
};

fn diffInts(allocator: Allocator, original: []const i32, modified: []const i32, pretty: bool) ![]DiffChange {
    var original_sequence = TestSequence{ .elements = original };
    var modified_sequence = TestSequence{ .elements = modified };
    var diff = try LcsDiff.init(allocator, original_sequence.sequence(), modified_sequence.sequence(), null);
    defer diff.deinit();
    var result = try diff.computeDiff(pretty);
    defer result.deinit(allocator);
    return try allocator.dupe(DiffChange, result.changes);
}

test "LcsDiff identical sequences" {
    const allocator = std.testing.allocator;
    const original = [_]i32{ 1, 2, 3, 4, 5 };
    const changes = try diffInts(allocator, &original, &original, true);
    defer allocator.free(changes);
    try std.testing.expectEqual(@as(usize, 0), changes.len);
}

test "LcsDiff single insertion and deletion" {
    const allocator = std.testing.allocator;

    {
        const original = [_]i32{ 1, 2, 3 };
        const modified = [_]i32{ 1, 2, 3, 4 };
        const changes = try diffInts(allocator, &original, &modified, true);
        defer allocator.free(changes);
        try std.testing.expectEqual(@as(usize, 1), changes.len);
        try std.testing.expect(changes[0].eql(DiffChange.init(3, 0, 3, 1)));
    }

    {
        const original = [_]i32{ 1, 2, 3, 4 };
        const modified = [_]i32{ 1, 2, 3 };
        const changes = try diffInts(allocator, &original, &modified, true);
        defer allocator.free(changes);
        try std.testing.expectEqual(@as(usize, 1), changes.len);
        try std.testing.expect(changes[0].eql(DiffChange.init(3, 1, 3, 0)));
    }
}

test "LcsDiff replacement" {
    const allocator = std.testing.allocator;
    const original = [_]i32{ 1, 2, 3, 4, 5 };
    const modified = [_]i32{ 1, 2, 9, 4, 5 };
    const changes = try diffInts(allocator, &original, &modified, true);
    defer allocator.free(changes);
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expect(changes[0].eql(DiffChange.init(2, 1, 2, 1)));
}

test "LcsDiff empty sequences" {
    const allocator = std.testing.allocator;

    const empty = [_]i32{};
    const changes = try diffInts(allocator, &empty, &empty, true);
    defer allocator.free(changes);
    try std.testing.expectEqual(@as(usize, 0), changes.len);

    const some = [_]i32{ 1, 2 };
    const insert_all = try diffInts(allocator, &empty, &some, true);
    defer allocator.free(insert_all);
    try std.testing.expectEqual(@as(usize, 1), insert_all.len);
    try std.testing.expect(insert_all[0].eql(DiffChange.init(0, 0, 0, 2)));

    const delete_all = try diffInts(allocator, &some, &empty, true);
    defer allocator.free(delete_all);
    try std.testing.expectEqual(@as(usize, 1), delete_all.len);
    try std.testing.expect(delete_all[0].eql(DiffChange.init(0, 2, 0, 0)));
}

test "LcsDiff disjoint changes" {
    const allocator = std.testing.allocator;
    const original = [_]i32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const modified = [_]i32{ 0, 1, 9, 3, 4, 5, 5, 7, 8, 9 };
    const changes = try diffInts(allocator, &original, &modified, false);
    defer allocator.free(changes);
    try std.testing.expectEqual(@as(usize, 2), changes.len);
    try std.testing.expect(changes[0].eql(DiffChange.init(2, 1, 2, 1)));
    try std.testing.expect(changes[1].eql(DiffChange.init(6, 1, 6, 1)));
}

test "LcsDiff does not report equal elements as changed" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var iteration: usize = 0;
    while (iteration < 200) : (iteration += 1) {
        const original_length = random.intRangeAtMost(usize, 0, 40);
        const modified_length = random.intRangeAtMost(usize, 0, 40);
        const original = try allocator.alloc(i32, original_length);
        defer allocator.free(original);
        const modified = try allocator.alloc(i32, modified_length);
        defer allocator.free(modified);
        for (original) |*value| {
            value.* = random.intRangeAtMost(i32, 0, 3);
        }
        for (modified) |*value| {
            value.* = random.intRangeAtMost(i32, 0, 3);
        }

        const changes = try diffInts(allocator, original, modified, true);
        defer allocator.free(changes);

        // Every element outside the reported changes must be equal in both
        // sequences and the amounts of skipped elements must line up.
        var original_index: isize = 0;
        var modified_index: isize = 0;
        for (changes) |change| {
            try std.testing.expect(change.originalStart >= original_index);
            try std.testing.expect(change.modifiedStart >= modified_index);
            const skipped = change.originalStart - original_index;
            try std.testing.expectEqual(change.modifiedStart - modified_index, skipped);
            for (0..@intCast(skipped)) |offset| {
                const o: usize = @intCast(original_index + @as(isize, @intCast(offset)));
                const m: usize = @intCast(modified_index + @as(isize, @intCast(offset)));
                try std.testing.expectEqual(original[o], modified[m]);
            }
            original_index = change.getOriginalEnd();
            modified_index = change.getModifiedEnd();
        }
        const remaining_original: isize = @intCast(original.len);
        const remaining_modified: isize = @intCast(modified.len);
        try std.testing.expectEqual(remaining_original - original_index, remaining_modified - modified_index);
        for (0..@intCast(remaining_original - original_index)) |offset| {
            const o: usize = @intCast(original_index + @as(isize, @intCast(offset)));
            const m: usize = @intCast(modified_index + @as(isize, @intCast(offset)));
            try std.testing.expectEqual(original[o], modified[m]);
        }
    }
}

fn lcsLength(allocator: Allocator, original: []const i32, modified: []const i32) !usize {
    const width = modified.len + 1;
    const table = try allocator.alloc(usize, (original.len + 1) * width);
    defer allocator.free(table);
    @memset(table, 0);
    for (original, 0..) |original_value, i| {
        for (modified, 0..) |modified_value, j| {
            table[(i + 1) * width + (j + 1)] = if (original_value == modified_value)
                table[i * width + j] + 1
            else
                @max(table[i * width + (j + 1)], table[(i + 1) * width + j]);
        }
    }
    return table[original.len * width + modified.len];
}

test "LcsDiff produces a minimal change list" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();

    var iteration: usize = 0;
    while (iteration < 100) : (iteration += 1) {
        const original_length = random.intRangeAtMost(usize, 0, 30);
        const modified_length = random.intRangeAtMost(usize, 0, 30);
        const original = try allocator.alloc(i32, original_length);
        defer allocator.free(original);
        const modified = try allocator.alloc(i32, modified_length);
        defer allocator.free(modified);
        // A tiny alphabet forces many equal elements and lots of history.
        for (original) |*value| {
            value.* = random.intRangeAtMost(i32, 0, 1);
        }
        for (modified) |*value| {
            value.* = random.intRangeAtMost(i32, 0, 1);
        }

        const changes = try diffInts(allocator, original, modified, false);
        defer allocator.free(changes);

        var changed: isize = 0;
        for (changes) |change| {
            try std.testing.expect(change.originalLength >= 0);
            try std.testing.expect(change.modifiedLength >= 0);
            try std.testing.expect(change.originalLength > 0 or change.modifiedLength > 0);
            changed += change.originalLength + change.modifiedLength;
        }

        const lcs = try lcsLength(allocator, original, modified);
        const expected: isize = @intCast(original.len - lcs + modified.len - lcs);
        try std.testing.expectEqual(expected, changed);
    }
}

test "stringDiff" {
    const allocator = std.testing.allocator;

    const changes = try stringDiff(allocator, "hello world", "hello brave world", true);
    defer allocator.free(changes);
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqual(@as(isize, 6), changes[0].originalStart);
    try std.testing.expectEqual(@as(isize, 0), changes[0].originalLength);
    try std.testing.expectEqual(@as(isize, 6), changes[0].modifiedStart);
    try std.testing.expectEqual(@as(isize, 6), changes[0].modifiedLength);

    // Multi-byte characters: offsets are byte offsets.
    const unicode = try stringDiff(allocator, "ä b", "ä x b", true);
    defer allocator.free(unicode);
    try std.testing.expectEqual(@as(usize, 1), unicode.len);
    // "ä" is two bytes, so the insertion happens after 3 bytes.
    try std.testing.expectEqual(@as(isize, 3), unicode[0].originalStart);
    try std.testing.expectEqual(@as(isize, 3), unicode[0].modifiedStart);

    const identical = try stringDiff(allocator, "same", "same", true);
    defer allocator.free(identical);
    try std.testing.expectEqual(@as(usize, 0), identical.len);
}

test "computeLevenshteinDistance" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(usize, 0), try computeLevenshteinDistance(allocator, "", ""));
    try std.testing.expectEqual(@as(usize, 3), try computeLevenshteinDistance(allocator, "", "abc"));
    try std.testing.expectEqual(@as(usize, 3), try computeLevenshteinDistance(allocator, "abc", ""));
    try std.testing.expectEqual(@as(usize, 0), try computeLevenshteinDistance(allocator, "kitten", "kitten"));
    try std.testing.expectEqual(@as(usize, 3), try computeLevenshteinDistance(allocator, "kitten", "sitting"));
    try std.testing.expectEqual(@as(usize, 1), try computeLevenshteinDistance(allocator, "abc", "abd"));
    try std.testing.expectEqual(@as(usize, 2), try computeLevenshteinDistance(allocator, "abc", "bcd"));
    try std.testing.expectEqual(@as(usize, 5), try computeLevenshteinDistance(allocator, "aaaaa", "bbbbb"));
}

test "diffChangeHelper" {
    const allocator = std.testing.allocator;
    var helper = DiffChangeHelper.init(allocator);
    try helper.markNextChange();
    helper.addOriginalElement(0, 0);
    helper.addModifiedElement(0, 1);
    try helper.markNextChange();
    helper.addOriginalElement(5, 4);
    const changes = try helper.getChanges();
    defer changes.deinit();
    try std.testing.expectEqual(@as(usize, 2), changes.items.len);
    try std.testing.expect(changes.items[0].eql(DiffChange.init(0, 1, 0, 1)));
    try std.testing.expect(changes.items[1].eql(DiffChange.init(5, 1, 4, 0)));

    var reverse_helper = DiffChangeHelper.init(allocator);
    reverse_helper.addOriginalElement(3, 3);
    try reverse_helper.markNextChange();
    reverse_helper.addModifiedElement(6, 6);
    const reversed = try reverse_helper.getReverseChanges();
    defer reversed.deinit();
    try std.testing.expectEqual(@as(usize, 2), reversed.items.len);
    try std.testing.expect(reversed.items[0].eql(DiffChange.init(6, 0, 6, 1)));
    try std.testing.expect(reversed.items[1].eql(DiffChange.init(3, 1, 3, 0)));
}

test "continue processing predicate quits early" {
    const allocator = std.testing.allocator;

    const Predicate = struct {
        fn predicate(_: *anyopaque, _: isize, _: isize) bool {
            return false;
        }
    };

    var context: u8 = 0;
    var original_sequence = TestSequence{ .elements = &[_]i32{ 1, 2, 3, 4, 5, 6, 7, 8 } };
    var modified_sequence = TestSequence{ .elements = &[_]i32{ 8, 7, 6, 5, 4, 3, 2, 1 } };
    var diff = try LcsDiff.init(
        allocator,
        original_sequence.sequence(),
        modified_sequence.sequence(),
        .{ .context = @ptrCast(&context), .predicateFn = Predicate.predicate },
    );
    defer diff.deinit();

    var result = try diff.computeDiff(true);
    defer result.deinit(allocator);
    try std.testing.expect(result.quitEarly);
}
