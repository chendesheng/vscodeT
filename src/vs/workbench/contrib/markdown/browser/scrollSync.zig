//! Port of
//! `vscode/extensions/markdown-language-features/preview-src/scroll-sync.ts`.
//!
//! Upstream reads DOM rectangles in CSS pixels and `window.scrollY`. The
//! terminal preview stores `Element` geometry in cell rows and passes its
//! current scroll row as `scroll_y`, so the same arithmetic is preserved.

const std = @import("std");
const preview = @import("./markdownPreviewDocument.zig");
const Document = preview.Document;
const Element = preview.Element;

pub const Found = struct {
    previous: ?*const Element,
    next: ?*const Element = null,
};

pub fn getElementsForSourceLine(document: *Document, target_line: f64) Found {
    const result = document.source_map.getElementsForSourceLine(target_line);
    return .{ .previous = result.previous, .next = result.next };
}

pub fn getElementsForSourceLineRange(document: *Document, start_line: f64, end_line: f64) []const *const Element {
    const range_start = @floor(start_line);
    const range_end = @max(range_start + 1, @ceil(end_line));
    var result = std.array_list.Managed(*const Element).init(document.arena.allocator());
    const lines = document.elements[0..];
    for (lines, 0..) |*element, index| {
        if (element.line < 0) continue;
        const next = if (index + 1 < lines.len) &lines[index + 1] else null;
        const element_start = element.line;
        const element_end = if (element.source_end_line > element.line)
            element.source_end_line + 1
        else if (next != null and next.?.line > element.line)
            next.?.line
        else
            element.line + 1;
        if (rangesIntersect(range_start, range_end, element_start, element_end)) {
            result.append(element) catch return &.{};
        }
    }
    return result.toOwnedSlice() catch &.{};
}

fn rangesIntersect(start_a: f64, end_a: f64, start_b: f64, end_b: f64) bool {
    return start_a < end_b and start_b < end_a;
}

/// Finds the elements at a viewport-relative page offset. `offset` is the
/// absolute page offset; `scroll_y` is the preview's top row.
pub fn getLineElementsAtPageOffset(document: *const Document, offset: f64, scroll_y: f64) Found {
    const lines = document.elements;
    if (lines.len == 0) return .{ .previous = null };
    const position = offset - scroll_y;
    var lo: isize = -1;
    var hi: isize = @intCast(lines.len - 1);
    while (lo + 1 < hi) {
        const mid: usize = @intCast(@divTrunc(lo + hi, 2));
        const bounds = getElementBounds(&lines[mid], scroll_y);
        if (bounds.top + bounds.height >= position) {
            hi = @intCast(mid);
        } else {
            lo = @intCast(mid);
        }
    }
    const hi_index: usize = @intCast(hi);
    const hi_element = &lines[hi_index];
    const hi_bounds = getElementBounds(hi_element, scroll_y);
    if (hi >= 1 and hi_bounds.top > position) {
        const lo_index: usize = @intCast(lo);
        return .{ .previous = &lines[lo_index], .next = hi_element };
    }
    if (hi > 1 and hi_index + 1 < lines.len and hi_bounds.top + hi_bounds.height > position) {
        return .{ .previous = hi_element, .next = &lines[hi_index + 1] };
    }
    return .{ .previous = hi_element };
}

const Bounds = struct { top: f64, height: f64, padding_top: f64 = 0, padding_bottom: f64 = 0 };

fn getElementBounds(element: *const Element, scroll_y: f64) Bounds {
    return .{ .top = element.top - scroll_y, .height = element.height };
}

fn getContentBounds(element: *const Element, scroll_y: f64) Bounds {
    return .{
        .top = element.content_top - scroll_y,
        .height = element.content_height,
    };
}

/// Returns the absolute scroll row that reveals `line`.
pub fn scrollToRevealSourceLine(document: *Document, line: f64, scroll_y: f64) ?f64 {
    if (line <= 0) return 0;
    if (std.math.isNan(line)) return null;
    const found = getElementsForSourceLine(document, line);
    const previous = found.previous orelse return null;
    const rect = getElementBounds(previous, scroll_y);
    const previous_top = rect.top;
    const source_end = previous.source_end_line;

    if (source_end > previous.line) {
        if (line < source_end) {
            const content = getContentBounds(previous, scroll_y);
            const progress = (line - previous.line) / (source_end - previous.line);
            return scroll_y + content.top + content.height * progress;
        } else if (found.next) |next| {
            if (next.line != previous.line) {
                const progress = (line - source_end) / (next.line - source_end);
                const element_end = scroll_y + previous_top + rect.height;
                const next_top = next.top;
                return element_end + progress * (next_top - element_end);
            }
        }
        return scroll_y + previous_top + rect.height;
    }

    if (found.next) |next| {
        if (next.line != previous.line) {
            const progress = (line - previous.line) / (next.line - previous.line);
            const element_end = scroll_y + previous_top + rect.height;
            const next_top = next.top;
            return element_end + progress * (next_top - element_end);
        }
    }

    const progress = line - @floor(line);
    return scroll_y + previous_top + rect.height * progress;
}

/// Returns a fractional 0-based source line for an absolute page offset.
pub fn getEditorLineNumberForPageOffset(document: *const Document, offset: f64, scroll_y: f64) ?f64 {
    const found = getLineElementsAtPageOffset(document, offset, scroll_y);
    const previous = found.previous orelse return null;
    if (previous.line < 0) return 0;
    const previous_bounds = getElementBounds(previous, scroll_y);
    const offset_from_previous = offset - scroll_y - previous_bounds.top;

    if (previous.source_end_line > previous.line) {
        const content = getContentBounds(previous, scroll_y);
        const offset_from_content = offset - scroll_y - content.top;
        if (offset_from_content >= 0 and offset_from_content <= content.height) {
            const progress = offset_from_content / content.height;
            return previous.line + progress * (previous.source_end_line - previous.line);
        } else if (found.next) |next| {
            if (offset_from_content > content.height) {
                const gap_offset = offset_from_content - content.height;
                const next_bounds = getElementBounds(next, scroll_y);
                const content_end = content.top + content.height;
                const gap_height = next_bounds.top - content_end;
                const progress = if (gap_height == 0) 0 else gap_offset / gap_height;
                return previous.source_end_line + progress * (next.line - previous.source_end_line);
            }
        }
    }

    if (found.next) |next| {
        const next_bounds = getElementBounds(next, scroll_y);
        const denominator = next_bounds.top - previous_bounds.top;
        const progress = if (denominator == 0) 0 else offset_from_previous / denominator;
        return previous.line + progress * (next.line - previous.line);
    }
    const progress = if (previous_bounds.height == 0) 0 else offset_from_previous / previous_bounds.height;
    return previous.line + progress;
}

pub fn getLineElementForFragment(document: *Document, fragment: []const u8) ?*const Element {
    return document.anchorElement(fragment);
}

test "scrollSync: source line mapping uses block boundaries" {
    var content = try @import("../../../../editor/common/markdown/markdownTerminalRenderer.zig").parseDocument(
        std.testing.allocator,
        "# one\n\ntwo\n\n### three",
        .{},
    );
    defer content.deinit();
    var document = try preview.build(std.testing.allocator, &content, 40, .{});
    defer document.deinit();

    const first = getElementsForSourceLine(&document, 0);
    try std.testing.expect(first.previous != null);
    try std.testing.expectEqual(@as(f64, 0), first.previous.?.line);
    const later = getElementsForSourceLine(&document, 3);
    try std.testing.expect(later.previous.?.line <= 3);
}

test "scrollSync: anchors and multi-line code blocks map" {
    var content = try @import("../../../../editor/common/markdown/markdownTerminalRenderer.zig").parseDocument(
        std.testing.allocator,
        "# One\n\n```zig\nconst a = 1;\nconst b = 2;\n```\n\n## Two",
        .{},
    );
    defer content.deinit();
    var document = try preview.build(std.testing.allocator, &content, 40, .{});
    defer document.deinit();

    const two = getLineElementForFragment(&document, "two");
    try std.testing.expect(two != null);
    try std.testing.expectEqual(@as(f64, 7), two.?.line);

    const code = getElementsForSourceLine(&document, 3);
    try std.testing.expect(code.previous != null);
    try std.testing.expect(code.previous.?.code);
    const target = scrollToRevealSourceLine(&document, 4, 0);
    try std.testing.expect(target != null);
    try std.testing.expect(target.? > 0);
}

test "scrollSync: page offset maps back to a fractional line" {
    var content = try @import("../../../../editor/common/markdown/markdownTerminalRenderer.zig").parseDocument(
        std.testing.allocator,
        "# one\n\nparagraph\n\n## two",
        .{},
    );
    defer content.deinit();
    var document = try preview.build(std.testing.allocator, &content, 40, .{});
    defer document.deinit();

    const line = getEditorLineNumberForPageOffset(&document, 0, 0);
    try std.testing.expect(line != null);
    try std.testing.expectEqual(@as(f64, 0), line.?);
    const target = scrollToRevealSourceLine(&document, 4, 0);
    try std.testing.expect(target != null);
}
