// Port of the tab order and horizontal SplitPaneContainer from
// `src/vs/workbench/contrib/terminal/browser/terminalGroup.ts`.
// The bottom panel measures splits in terminal cells.

const std = @import("std");
const ui = @import("ui");
const Allocator = std.mem.Allocator;
const TerminalInstance = @import("./terminalInstance.zig").TerminalInstance;

pub const TerminalGroup = struct {
    allocator: Allocator,
    instances: std.array_list.Managed(*TerminalInstance),
    active: usize = 0,
    on_did_change_active_instance: @import("../../../../base/common/event.zig").Emitter(?*TerminalInstance),
    on_did_change_instances: @import("../../../../base/common/event.zig").Emitter(void),

    pub fn init(allocator: Allocator) TerminalGroup {
        return .{
            .allocator = allocator,
            .instances = std.array_list.Managed(*TerminalInstance).init(allocator),
            .on_did_change_active_instance = .init(allocator),
            .on_did_change_instances = .init(allocator),
        };
    }

    pub fn deinit(self: *TerminalGroup) void {
        for (self.instances.items) |instance| instance.deinit();
        self.instances.deinit();
        self.on_did_change_active_instance.deinit();
        self.on_did_change_instances.deinit();
    }

    pub fn add(self: *TerminalGroup, instance: *TerminalInstance) !void {
        const previous_instance = self.activeInstance();
        try self.instances.append(instance);
        instance.panel_group_id = instance.id;
        instance.panel_group_active = true;
        instance.split_weight = 1;
        _ = self.setActiveFrom(self.instances.items.len - 1, previous_instance);
        self.on_did_change_instances.fire({}) catch {};
    }

    pub fn split(self: *TerminalGroup, parent: usize, instance: *TerminalInstance) !void {
        const previous_instance = self.activeInstance();
        try self.instances.insert(parent + 1, instance);
        instance.panel_group_id = self.instances.items[parent].panel_group_id;
        self.resetPaneSizes(parent);
        _ = self.setActiveFrom(parent + 1, previous_instance);
        self.on_did_change_instances.fire({}) catch {};
    }

    pub fn detach(self: *TerminalGroup, index: usize) ?*TerminalInstance {
        if (index >= self.instances.items.len) return null;
        const previous_instance = self.activeInstance();
        const instance = self.instances.orderedRemove(index);
        if (self.instances.items.len == 0) {
            self.active = 0;
        } else if (index < self.active) {
            self.active -= 1;
        } else if (index == self.active) {
            self.active = @min(index, self.instances.items.len - 1);
            if (self.active > 0 and self.instances.items[self.active - 1].panel_group_id == instance.panel_group_id and
                self.instances.items[self.active].panel_group_id != instance.panel_group_id)
            {
                self.active -= 1;
            }
        }
        if (self.at(self.active)) |active| {
            if (active.panel_group_id == instance.panel_group_id) _ = self.setActiveFrom(self.active, self.activeInstance());
        }
        instance.tab_selected = false;
        _ = instance.setFocused(false);
        if (previous_instance != self.activeInstance()) self.on_did_change_active_instance.fire(self.activeInstance()) catch {};
        self.on_did_change_instances.fire({}) catch {};
        return instance;
    }

    pub fn remove(self: *TerminalGroup, index: usize) void {
        if (self.detach(index)) |instance| instance.deinit();
    }

    pub const GroupRange = struct { first: usize, end: usize };

    pub fn groupRange(self: *const TerminalGroup, index: usize) GroupRange {
        const items = self.instances.items;
        const id = items[index].panel_group_id;
        var first = index;
        var end = index + 1;
        while (first > 0 and items[first - 1].panel_group_id == id) first -= 1;
        while (end < items.len and items[end].panel_group_id == id) end += 1;
        return .{ .first = first, .end = end };
    }

    pub fn groupCount(self: *const TerminalGroup) usize {
        var count_groups: usize = 0;
        var index: usize = 0;
        while (index < self.count()) {
            count_groups += 1;
            index = self.groupRange(index).end;
        }
        return count_groups;
    }

    pub fn paneRect(self: *const TerminalGroup, content: ui.Rect, index: usize) ui.Rect {
        const group = self.groupRange(index);
        const count_panes = group.end - group.first;
        const width = ui.cell.snap(content.w);
        if (count_panes == 1) return content;
        const separators = @min(count_panes - 1, width / 2);
        const available = width - separators;
        const pane = index - group.first;
        var total: f64 = 0;
        var before: f64 = 0;
        for (self.instances.items[group.first..group.end], group.first..) |instance, i| {
            total += instance.split_weight;
            if (i < index) before += instance.split_weight;
        }
        const width_float: f64 = @floatFromInt(available);
        const start: usize = @intFromFloat(width_float * before / total);
        const end: usize = if (index + 1 == group.end) available else @intFromFloat(width_float * (before + self.instances.items[index].split_weight) / total);
        return .{
            .x = content.x + @as(f64, @floatFromInt(start + @min(pane, separators))),
            .y = content.y,
            .w = @floatFromInt(end - start),
            .h = content.h,
        };
    }

    pub fn resetPaneSizes(self: *TerminalGroup, index: usize) void {
        const group = self.groupRange(index);
        for (self.instances.items[group.first..group.end]) |instance| instance.split_weight = 1;
    }

    pub fn resizePaneBoundary(self: *TerminalGroup, content: ui.Rect, right_index: usize, x: usize) void {
        if (right_index == 0 or right_index >= self.count()) return;
        if (self.groupRange(right_index).first == right_index) return;
        const left = self.paneRect(content, right_index - 1);
        const right = self.paneRect(content, right_index);
        const start = ui.cell.snap(left.x);
        const end = ui.cell.snap(right.right());
        if (end - start < 5) return;
        const boundary = std.math.clamp(x, start + 2, end - 3);
        const instances = self.instances.items;
        const left_instance = instances[right_index - 1];
        const right_instance = instances[right_index];
        const total_weight = left_instance.split_weight + right_instance.split_weight;
        const available: f64 = @floatFromInt(end - start - 1);
        left_instance.split_weight = total_weight * @as(f64, @floatFromInt(boundary - start)) / available;
        right_instance.split_weight = total_weight - left_instance.split_weight;
    }

    pub fn moveGroup(self: *TerminalGroup, source: usize, target: ?usize) void {
        const items = self.instances.items;
        const source_group = self.groupRange(source);
        const target_group = if (target) |index| self.groupRange(index) else GroupRange{ .first = items.len, .end = items.len };
        if (source_group.first == target_group.first) return;
        const previous_instance = self.activeInstance();
        const instance = items[source];
        if (target_group.first < source_group.first) {
            std.mem.rotate(*TerminalInstance, items[target_group.first..source_group.end], source_group.first - target_group.first);
        } else {
            std.mem.rotate(*TerminalInstance, items[source_group.first..target_group.end], source_group.end - source_group.first);
        }
        for (items, 0..) |candidate, index| {
            if (candidate == instance) {
                _ = self.setActiveFrom(index, previous_instance);
                break;
            }
        }
    }

    pub fn unsplitInstance(self: *TerminalGroup, index: usize) !void {
        if (index >= self.count()) return;
        const range = self.groupRange(index);
        if (range.end - range.first < 2) return;
        const instance = self.detach(index).?;
        // Detaching leaves room to append a standalone group.
        try self.add(instance);
    }

    pub fn joinInstances(self: *TerminalGroup, selected: []const *TerminalInstance) !void {
        if (selected.len < 2) return;
        const initial_range = self.groupRange(self.indexOf(selected[0]).?);
        if (initial_range.end - initial_range.first == selected.len) {
            for (selected) |instance| {
                if (instance.panel_group_id != selected[0].panel_group_id) break;
            } else return;
        }

        // Upstream prefers to reuse the first standalone group in the
        // selection. Otherwise it leaves the existing groups in place and
        // appends a new group for the selected panes.
        var target: ?*TerminalInstance = null;
        for (selected) |instance| {
            const group = self.groupRange(self.indexOf(instance).?);
            if (group.end - group.first == 1) {
                target = instance;
                break;
            }
        }
        if (target == null) {
            const first = self.detach(self.indexOf(selected[0]).?).?;
            try self.add(first);
            target = first;
        }
        for (selected) |instance| {
            if (instance == target.?) continue;
            _ = self.detach(self.indexOf(instance).?);
            const parent = self.groupRange(self.indexOf(target.?).?).end - 1;
            try self.split(parent, instance);
        }
        self.clearTabSelection();
        _ = self.setActive(self.indexOf(selected[0]).?);
    }

    fn indexOf(self: *const TerminalGroup, instance: *TerminalInstance) ?usize {
        for (self.instances.items, 0..) |candidate, index| {
            if (candidate == instance) return index;
        }
        return null;
    }

    pub fn clearTabSelection(self: *TerminalGroup) void {
        for (self.instances.items) |instance| instance.tab_selected = false;
    }

    pub fn selectTab(self: *TerminalGroup, index: usize, anchor: ?usize, toggle: bool) void {
        const instance = self.at(index) orelse return;
        if (!toggle) self.clearTabSelection();
        if (anchor) |start| {
            for (self.instances.items[@min(start, index) .. @max(start, index) + 1]) |candidate| candidate.tab_selected = true;
        } else {
            instance.tab_selected = !instance.tab_selected;
        }
        _ = self.setActive(index);
    }

    pub fn count(self: *const TerminalGroup) usize {
        return self.instances.items.len;
    }

    pub fn at(self: *const TerminalGroup, index: usize) ?*TerminalInstance {
        if (index >= self.instances.items.len) return null;
        return self.instances.items[index];
    }

    pub fn activeInstance(self: *const TerminalGroup) ?*TerminalInstance {
        return self.at(self.active);
    }

    pub fn setActive(self: *TerminalGroup, index: usize) bool {
        return self.setActiveFrom(index, self.activeInstance());
    }

    fn setActiveFrom(self: *TerminalGroup, index: usize, previous_instance: ?*TerminalInstance) bool {
        if (index >= self.instances.items.len) return false;
        self.active = index;
        const range = self.groupRange(index);
        for (self.instances.items[range.first..range.end], range.first..) |instance, i| {
            instance.panel_group_active = i == index;
        }
        if (previous_instance != self.activeInstance()) self.on_did_change_active_instance.fire(self.activeInstance()) catch {};
        return true;
    }

    pub fn next(self: *TerminalGroup) void {
        if (self.count() == 0) return;
        const current = self.groupRange(self.active);
        if (current.end == self.count() and current.first == 0) return;
        self.activateGroupContaining(current.end % self.count());
    }

    pub fn previous(self: *TerminalGroup) void {
        if (self.count() == 0) return;
        const first = self.groupRange(self.active).first;
        if (first == 0 and self.groupRange(self.active).end == self.count()) return;
        self.activateGroupContaining(if (first == 0) self.count() - 1 else first - 1);
    }

    fn activateGroupContaining(self: *TerminalGroup, index: usize) void {
        const range = self.groupRange(index);
        for (self.instances.items[range.first..range.end], range.first..) |instance, i| {
            if (instance.panel_group_active) {
                _ = self.setActive(i);
                return;
            }
        }
        _ = self.setActive(range.first);
    }

    pub fn focusPane(self: *TerminalGroup, next_pane: bool) bool {
        if (self.count() == 0) return false;
        const current = self.groupRange(self.active);
        if (current.end - current.first < 2) return false;
        const next_index = if (next_pane)
            (if (self.active + 1 == current.end) current.first else self.active + 1)
        else
            (if (self.active == current.first) current.end - 1 else self.active - 1);
        return self.setActive(next_index);
    }
};
