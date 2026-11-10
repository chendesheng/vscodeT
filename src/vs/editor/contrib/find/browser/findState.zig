// Port of `src/vs/editor/contrib/find/browser/findState.ts`.
//
// The generic filters type upstream has no consumer in the editor find
// contribution; it is omitted here. Search scopes are copied and owned by the
// state so callers can pass transient selections.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Range = @import("../../../common/core/range.zig").Range;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

/// Upstream `findModel.ts` exports this; `findState` imports it. Keep the
/// constant here so the two modules do not import each other.
pub const MATCHES_LIMIT: usize = 19999;

pub const FindOptionOverride = enum {
    not_set,
    set_true,
    set_false,
};

pub const FindReplaceStateChangedEvent = struct {
    move_cursor: bool = false,
    update_history: bool = false,

    search_string: bool = false,
    replace_string: bool = false,
    is_revealed: bool = false,
    is_replace_revealed: bool = false,
    is_regex: bool = false,
    whole_word: bool = false,
    match_case: bool = false,
    preserve_case: bool = false,
    search_scope: bool = false,
    matches_position: bool = false,
    matches_count: bool = false,
    current_match: bool = false,
    loop: bool = false,
    is_searching: bool = false,
};

pub const SearchScope = union(enum) {
    /// Leave the current scope untouched.
    unset,
    /// Clear the scope.
    none,
    ranges: []const Range,
};

pub const NewState = struct {
    search_string: ?[]const u8 = null,
    replace_string: ?[]const u8 = null,
    is_revealed: ?bool = null,
    is_replace_revealed: ?bool = null,
    is_regex: ?bool = null,
    is_regex_override: FindOptionOverride = .not_set,
    whole_word: ?bool = null,
    whole_word_override: FindOptionOverride = .not_set,
    match_case: ?bool = null,
    match_case_override: FindOptionOverride = .not_set,
    preserve_case: ?bool = null,
    preserve_case_override: FindOptionOverride = .not_set,
    search_scope: SearchScope = .unset,
    loop: ?bool = null,
    is_searching: ?bool = null,
};

fn effectiveOptionValue(override: FindOptionOverride, value: bool) bool {
    return switch (override) {
        .set_true => true,
        .set_false => false,
        .not_set => value,
    };
}

pub const FindReplaceState = struct {
    allocator: Allocator,
    search_string: []const u8 = "",
    replace_string: []const u8 = "",
    is_revealed: bool = false,
    is_replace_revealed: bool = false,

    actual_is_regex: bool = false,
    actual_whole_word: bool = false,
    actual_match_case: bool = false,
    actual_preserve_case: bool = false,
    is_regex_override: FindOptionOverride = .not_set,
    whole_word_override: FindOptionOverride = .not_set,
    match_case_override: FindOptionOverride = .not_set,
    preserve_case_override: FindOptionOverride = .not_set,

    search_scope: ?[]Range = null,
    matches_position: usize = 0,
    matches_count: usize = 0,
    current_match: ?Range = null,
    loop: bool = true,
    is_searching: bool = false,

    on_find_replace_state_change: Emitter(FindReplaceStateChangedEvent),

    pub fn init(allocator: Allocator) FindReplaceState {
        return .{
            .allocator = allocator,
            .on_find_replace_state_change = Emitter(FindReplaceStateChangedEvent).init(allocator),
        };
    }

    pub fn deinit(self: *FindReplaceState) void {
        if (self.search_scope) |scope| self.allocator.free(scope);
        self.search_scope = null;
        self.allocator.free(self.search_string);
        self.allocator.free(self.replace_string);
        self.on_find_replace_state_change.deinit();
    }

    pub fn isRegex(self: *const FindReplaceState) bool {
        return effectiveOptionValue(self.is_regex_override, self.actual_is_regex);
    }

    pub fn wholeWord(self: *const FindReplaceState) bool {
        return effectiveOptionValue(self.whole_word_override, self.actual_whole_word);
    }

    pub fn matchCase(self: *const FindReplaceState) bool {
        return effectiveOptionValue(self.match_case_override, self.actual_match_case);
    }

    pub fn preserveCase(self: *const FindReplaceState) bool {
        return effectiveOptionValue(self.preserve_case_override, self.actual_preserve_case);
    }

    pub fn changeMatchInfo(
        self: *FindReplaceState,
        matches_position: usize,
        matches_count: usize,
        current_match: ?Range,
        update_current_match: bool,
    ) void {
        var event = FindReplaceStateChangedEvent{};

        var position = matches_position;
        if (matches_count == 0) position = 0;
        if (position > matches_count) position = matches_count;

        var something_changed = false;
        if (self.matches_position != position) {
            self.matches_position = position;
            event.matches_position = true;
            something_changed = true;
        }
        if (self.matches_count != matches_count) {
            self.matches_count = matches_count;
            event.matches_count = true;
            something_changed = true;
        }
        if (update_current_match and !Range.equalsRange(self.current_match, current_match)) {
            self.current_match = current_match;
            event.current_match = true;
            something_changed = true;
        }

        if (something_changed) {
            self.on_find_replace_state_change.fire(event) catch {};
        }
    }

    pub fn change(self: *FindReplaceState, new_state: NewState, move_cursor: bool, update_history: bool) void {
        var event = FindReplaceStateChangedEvent{
            .move_cursor = move_cursor,
            .update_history = update_history,
        };

        const old_is_regex = self.isRegex();
        const old_whole_word = self.wholeWord();
        const old_match_case = self.matchCase();
        const old_preserve_case = self.preserveCase();

        if (new_state.search_string) |value| {
            if (!std.mem.eql(u8, self.search_string, value)) {
                const copy = self.allocator.dupe(u8, value) catch return;
                self.allocator.free(self.search_string);
                self.search_string = copy;
                event.search_string = true;
            }
        }
        if (new_state.replace_string) |value| {
            if (!std.mem.eql(u8, self.replace_string, value)) {
                const copy = self.allocator.dupe(u8, value) catch return;
                self.allocator.free(self.replace_string);
                self.replace_string = copy;
                event.replace_string = true;
            }
        }
        if (new_state.is_revealed) |value| {
            if (self.is_revealed != value) {
                self.is_revealed = value;
                event.is_revealed = true;
            }
        }
        if (new_state.is_replace_revealed) |value| {
            if (self.is_replace_revealed != value) {
                self.is_replace_revealed = value;
                event.is_replace_revealed = true;
            }
        }
        if (new_state.is_regex) |value| self.actual_is_regex = value;
        if (new_state.whole_word) |value| self.actual_whole_word = value;
        if (new_state.match_case) |value| self.actual_match_case = value;
        if (new_state.preserve_case) |value| self.actual_preserve_case = value;

        switch (new_state.search_scope) {
            .unset => {},
            .none => {
                if (self.search_scope != null) {
                    self.allocator.free(self.search_scope.?);
                    self.search_scope = null;
                    event.search_scope = true;
                }
            },
            .ranges => |ranges| {
                if (searchScopeChanged(self.search_scope, ranges)) {
                    const copy = self.allocator.dupe(Range, ranges) catch return;
                    if (self.search_scope) |old| self.allocator.free(old);
                    self.search_scope = copy;
                    event.search_scope = true;
                }
            },
        }

        if (new_state.loop) |value| {
            if (self.loop != value) {
                self.loop = value;
                event.loop = true;
            }
        }
        if (new_state.is_searching) |value| {
            if (self.is_searching != value) {
                self.is_searching = value;
                event.is_searching = true;
            }
        }

        self.is_regex_override = new_state.is_regex_override;
        self.whole_word_override = new_state.whole_word_override;
        self.match_case_override = new_state.match_case_override;
        self.preserve_case_override = new_state.preserve_case_override;

        if (old_is_regex != self.isRegex()) {
            event.is_regex = true;
        }
        if (old_whole_word != self.wholeWord()) {
            event.whole_word = true;
        }
        if (old_match_case != self.matchCase()) {
            event.match_case = true;
        }
        if (old_preserve_case != self.preserveCase()) {
            event.preserve_case = true;
        }

        if (event.search_string or event.replace_string or event.is_revealed or
            event.is_replace_revealed or event.is_regex or event.whole_word or
            event.match_case or event.preserve_case or event.search_scope or
            event.loop or event.is_searching)
        {
            self.on_find_replace_state_change.fire(event) catch {};
        }
    }

    pub fn canNavigateBack(self: *const FindReplaceState) bool {
        return self.canNavigateInLoop() or self.matches_position != 1;
    }

    pub fn canNavigateForward(self: *const FindReplaceState) bool {
        return self.canNavigateInLoop() or self.matches_position < self.matches_count;
    }

    fn canNavigateInLoop(self: *const FindReplaceState) bool {
        return self.loop or self.matches_count >= MATCHES_LIMIT;
    }
};

fn searchScopeChanged(old: ?[]const Range, new: []const Range) bool {
    for (new) |new_scope| {
        var found_different = false;
        if (old) |existing| {
            for (existing) |existing_scope| {
                if (!Range.equalsRange(existing_scope, new_scope)) {
                    found_different = true;
                    break;
                }
            }
        }
        if (!found_different) return true;
    }
    return false;
}

test "FindReplaceState: overrides and effective options" {
    const allocator = std.testing.allocator;
    var state = FindReplaceState.init(allocator);
    defer state.deinit();

    try std.testing.expect(!state.isRegex());
    state.change(.{ .is_regex = true }, false, true);
    try std.testing.expect(state.isRegex());

    state.change(.{ .is_regex = false, .is_regex_override = .set_true }, false, true);
    try std.testing.expect(state.isRegex());
    try std.testing.expect(!state.actual_is_regex);

    state.change(.{ .search_string = "one" }, false, true);
    try std.testing.expect(!state.isRegex());
}

test "FindReplaceState: navigation flags follow the match count" {
    const allocator = std.testing.allocator;
    var state = FindReplaceState.init(allocator);
    defer state.deinit();

    state.changeMatchInfo(1, 3, null, false);
    // The default loop allows wrapping back from the first match.
    try std.testing.expect(state.canNavigateBack());
    try std.testing.expect(state.canNavigateForward());

    state.changeMatchInfo(2, 3, null, false);
    try std.testing.expect(state.canNavigateBack());
    try std.testing.expect(state.canNavigateForward());

    state.change(.{ .loop = false }, false, true);
    state.changeMatchInfo(1, 3, null, false);
    try std.testing.expect(!state.canNavigateBack());
}

test "FindReplaceState: search scopes are copied and cleared" {
    const allocator = std.testing.allocator;
    var state = FindReplaceState.init(allocator);
    defer state.deinit();

    const range = Range.init(1, 1, 1, 3);
    state.change(.{ .search_scope = .{ .ranges = &.{range} } }, false, true);
    try std.testing.expectEqual(@as(usize, 1), state.search_scope.?.len);

    state.change(.{ .search_scope = .none }, false, true);
    try std.testing.expect(state.search_scope == null);
}
