//! Port of
//! `vscode/extensions/markdown-language-features/src/util/sourceLineMap.ts`.
//!
//! The browser version reads `data-line` attributes from DOM nodes. The
//! terminal preview stores the same source line on every rendered block, so
//! `SourceLineMap` is shared and `updateSourceLineAttributes` is a duck-typed
//! port used by the tests and by any future diff-update path.

const std = @import("std");

/// Preserves element order while sharing a forward scan across nondecreasing
/// source-line queries.
pub fn SourceLineMap(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Result = struct {
            previous: *const T,
            next: ?*const T = null,
        };

        elements: []const T,
        previous_line: f64 = -std.math.inf(f64),
        index: usize = 0,

        pub fn init(elements: []const T) Self {
            std.debug.assert(elements.len > 0);
            return .{ .elements = elements };
        }

        pub fn getElementsForSourceLine(self: *Self, target_line: f64) Result {
            const line_number = @floor(target_line);
            // `!(a >= b)` also resets for NaN, matching the upstream guard.
            if (!(line_number >= self.previous_line)) self.index = 0;
            self.previous_line = line_number;

            var previous_index = @max(0, self.index -| 1);
            while (self.index < self.elements.len) : (self.index += 1) {
                const entry = &self.elements[self.index];
                const entry_line: f64 = entry.line;
                if (entry_line == line_number) {
                    return .{ .previous = entry };
                } else if (entry_line > line_number) {
                    return .{ .previous = &self.elements[previous_index], .next = entry };
                }
                previous_index = self.index;
            }
            return .{ .previous = &self.elements[previous_index] };
        }
    };
}

/// Port of `updateSourceLineAttributes` for DOM-like nodes. The methods are
/// resolved structurally; the preview itself no longer performs DOM morphing.
pub fn updateSourceLineAttributes(from: anytype, to: @TypeOf(from)) void {
    const from_line = from.getAttribute("data-line");
    const to_line = to.getAttribute("data-line");
    if (to_line != null and from_line != null and !std.mem.eql(u8, from_line.?, to_line.?)) {
        from.setAttribute("data-line", to_line.?);
    }
    const from_lines = from.querySelectorAll("[data-line]");
    const to_lines = to.querySelectorAll("[data-line]");
    if (from_lines.len != to_lines.len) return;
    for (from_lines, 0..) |*from_child, index| {
        if (index >= to_lines.len) break;
        const to_child = &to_lines[index];
        const line = to_child.getAttribute("data-line");
        if (line == null) continue;
        const current = from_child.getAttribute("data-line");
        if (current == null or !std.mem.eql(u8, current.?, line.?)) {
            from_child.setAttribute("data-line", line.?);
        }
    }
}
