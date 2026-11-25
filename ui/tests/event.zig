const std = @import("std");
const ui = @import("ui");
const dom = ui.dom;
const Phase = ui.event.Phase;
const KeyEvent = ui.event.KeyEvent;
const FocusEvent = ui.event.FocusEvent;
const MouseKind = ui.event.MouseKind;
const MouseEvent = ui.event.MouseEvent;
const Listener = ui.event.Listener;
const commonInclusiveAncestor = ui.event.commonInclusiveAncestor;
const canFocus = ui.event.canFocus;

const TestLog = struct {
    nodes: [32]?*dom.Node = @splat(null),
    phases: [32]Phase = @splat(.target),
    count: usize = 0,

    fn onKey(context: ?*anyopaque, event: *KeyEvent) void {
        const self: *TestLog = @ptrCast(@alignCast(context orelse return));
        if (self.count == self.nodes.len) return;
        self.nodes[self.count] = event.current_target;
        self.phases[self.count] = event.phase;
        self.count += 1;
    }
};

test "event: key dispatch runs capture, target and bubble" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const parent = try doc.createElement(.div);
    const child = try doc.createElement(.div);
    child.asElement().focusable = true;
    _ = try root.appendChild(parent);
    _ = try parent.appendChild(child);
    doc.setRoot(root);
    try std.testing.expect(doc.focus(child));

    var root_capture = TestLog{};
    var root_bubble = TestLog{};
    var parent_capture = TestLog{};
    var parent_bubble = TestLog{};
    var target_log = TestLog{};

    try root.addEventListener(.{ .context = &root_capture, .capture = true, .key_down = TestLog.onKey });
    try root.addEventListener(.{ .context = &root_bubble, .key_down = TestLog.onKey });
    try parent.addEventListener(.{ .context = &parent_capture, .capture = true, .key_down = TestLog.onKey });
    try parent.addEventListener(.{ .context = &parent_bubble, .key_down = TestLog.onKey });
    try child.addEventListener(.{ .context = &target_log, .key_down = TestLog.onKey });

    const dispatched = doc.dispatchKey(.enter, .{});
    try std.testing.expectEqual(child, dispatched.target.?);
    try std.testing.expect(!dispatched.default_prevented);

    try std.testing.expectEqual(root, root_capture.nodes[0].?);
    try std.testing.expectEqual(Phase.capture, root_capture.phases[0]);
    try std.testing.expectEqual(parent, parent_capture.nodes[0].?);
    try std.testing.expectEqual(Phase.capture, parent_capture.phases[0]);
    try std.testing.expectEqual(child, target_log.nodes[0].?);
    try std.testing.expectEqual(Phase.target, target_log.phases[0]);
    try std.testing.expectEqual(parent, parent_bubble.nodes[0].?);
    try std.testing.expectEqual(Phase.bubble, parent_bubble.phases[0]);
    try std.testing.expectEqual(root, root_bubble.nodes[0].?);
    try std.testing.expectEqual(Phase.bubble, root_bubble.phases[0]);
    try std.testing.expectEqual(@as(usize, 1), target_log.count);
}

test "event: dispatchEvent forwards a decoded event and resets flags" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const child = try doc.createElement(.div);
    child.asElement().focusable = true;
    _ = try root.appendChild(child);
    doc.setRoot(root);
    try std.testing.expect(doc.focus(child));

    var log = TestLog{};
    try child.addEventListener(.{ .context = &log, .key_down = TestLog.onKey });

    var event = KeyEvent{
        .key = .{ .char = 'x' },
        .default_prevented = true,
        .propagation_stopped = true,
    };
    doc.dispatchEvent(&event);

    try std.testing.expectEqual(child, event.target.?);
    try std.testing.expectEqual(@as(usize, 1), log.count);
    try std.testing.expect(!event.default_prevented);
    try std.testing.expect(!event.propagation_stopped);
}

test "event: stopPropagation and preventDefault" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const first = try doc.createElement(.div);
    const second = try doc.createElement(.div);
    first.asElement().focusable = true;
    second.asElement().focusable = true;
    _ = try root.appendChild(first);
    _ = try root.appendChild(second);
    doc.setRoot(root);
    try std.testing.expect(doc.focus(first));

    var root_log = TestLog{};
    try root.addEventListener(.{ .context = &root_log, .key_down = TestLog.onKey });

    _ = doc.dispatchKey(.tab, .{});
    try std.testing.expectEqual(second, doc.activeElement().?);

    // preventDefault on the target keeps Tab from moving focus.
    const Blocker = struct {
        fn onKey(_: ?*anyopaque, event: *KeyEvent) void {
            if (event.key == .tab) event.preventDefault();
        }
    };
    try second.addEventListener(.{ .key_down = Blocker.onKey });
    const prevented = doc.dispatchKey(.tab, .{});
    try std.testing.expect(prevented.default_prevented);
    try std.testing.expectEqual(second, doc.activeElement().?);

    // stopPropagation at the target keeps the root listener from running.
    const Stopper = struct {
        fn onKey(_: ?*anyopaque, event: *KeyEvent) void {
            event.stopPropagation();
        }
    };
    try second.addEventListener(.{ .key_down = Stopper.onKey });
    root_log.count = 0;
    _ = doc.dispatchKey(.enter, .{});
    try std.testing.expectEqual(@as(usize, 0), root_log.count);
}

const FocusLog = struct {
    focus_count: usize = 0,
    blur_count: usize = 0,
    focus_in_count: usize = 0,
    focus_out_count: usize = 0,
    last_related: ?*dom.Node = null,

    fn listener(self: *FocusLog) Listener {
        return .{
            .context = self,
            .focus = onFocus,
            .blur = onBlur,
            .focus_in = onFocusIn,
            .focus_out = onFocusOut,
        };
    }

    fn onFocus(context: ?*anyopaque, event: *FocusEvent) void {
        const self: *FocusLog = @ptrCast(@alignCast(context orelse return));
        self.focus_count += 1;
        self.last_related = event.related_target;
    }

    fn onBlur(context: ?*anyopaque, event: *FocusEvent) void {
        const self: *FocusLog = @ptrCast(@alignCast(context orelse return));
        self.blur_count += 1;
        self.last_related = event.related_target;
    }

    fn onFocusIn(context: ?*anyopaque, event: *FocusEvent) void {
        const self: *FocusLog = @ptrCast(@alignCast(context orelse return));
        self.focus_in_count += 1;
        self.last_related = event.related_target;
    }

    fn onFocusOut(context: ?*anyopaque, event: *FocusEvent) void {
        const self: *FocusLog = @ptrCast(@alignCast(context orelse return));
        self.focus_out_count += 1;
        self.last_related = event.related_target;
    }
};

test "event: focus moves fire blur/focusout then focus/focusin" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const first = try doc.createElement(.div);
    const second = try doc.createElement(.div);
    first.asElement().focusable = true;
    second.asElement().focusable = true;
    _ = try root.appendChild(first);
    _ = try root.appendChild(second);
    doc.setRoot(root);

    var root_log = FocusLog{};
    var first_log = FocusLog{};
    var second_log = FocusLog{};
    try root.addEventListener(root_log.listener());
    try first.addEventListener(first_log.listener());
    try second.addEventListener(second_log.listener());

    try std.testing.expect(doc.activeElement() == root);
    try std.testing.expect(doc.focus(first));
    try std.testing.expectEqual(first, doc.activeElement().?);
    try std.testing.expectEqual(@as(usize, 1), first_log.focus_count);
    try std.testing.expectEqual(@as(usize, 1), first_log.focus_in_count);
    try std.testing.expectEqual(@as(usize, 0), first_log.blur_count);
    try std.testing.expectEqual(@as(usize, 1), root_log.focus_in_count);
    try std.testing.expect(first_log.last_related == null);

    // Focusing the active element is a no-op.
    try std.testing.expect(doc.focus(first));
    try std.testing.expectEqual(@as(usize, 1), first_log.focus_count);

    try std.testing.expect(doc.focus(second));
    try std.testing.expectEqual(second, doc.activeElement().?);
    try std.testing.expectEqual(@as(usize, 1), first_log.blur_count);
    try std.testing.expectEqual(@as(usize, 1), first_log.focus_out_count);
    try std.testing.expectEqual(second, first_log.last_related.?);
    try std.testing.expectEqual(@as(usize, 1), second_log.focus_count);
    try std.testing.expectEqual(first, second_log.last_related.?);
    try std.testing.expectEqual(@as(usize, 2), root_log.focus_in_count);
    try std.testing.expectEqual(@as(usize, 1), root_log.focus_out_count);

    doc.blur();
    try std.testing.expect(doc.activeElement() == root);
    try std.testing.expectEqual(@as(usize, 1), second_log.blur_count);
    try std.testing.expectEqual(@as(usize, 1), second_log.focus_out_count);
    try std.testing.expect(second_log.last_related == null);
    try std.testing.expectEqual(@as(usize, 2), root_log.focus_out_count);
}

test "event: focus requires a connected, rendered, focusable element" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const plain = try doc.createElement(.div);
    const hidden = try doc.createElement(.div);
    hidden.setStyle(.{ .display = .none });
    hidden.asElement().focusable = true;
    _ = try root.appendChild(plain);
    _ = try root.appendChild(hidden);
    doc.setRoot(root);

    try std.testing.expect(!doc.focus(plain));
    try std.testing.expect(!doc.focus(hidden));

    const detached = try doc.createElement(.div);
    detached.asElement().focusable = true;
    try std.testing.expect(!doc.focus(detached));

    // A negative tab index is programmatically focusable, just not a tab stop.
    plain.asElement().focusable = true;
    plain.asElement().tab_index = -1;
    try std.testing.expect(doc.focus(plain));
    try std.testing.expectEqual(plain, doc.activeElement().?);
    // It is the only focusable element and not a tab stop, so Tab finds none.
    try std.testing.expect(!doc.moveFocus(.forward));
    try std.testing.expectEqual(plain, doc.activeElement().?);
}

test "event: Tab follows tabindex groups and skips display none" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const two = try doc.createElement(.div);
    const zero = try doc.createElement(.div);
    const group = try doc.createElement(.div);
    const one = try doc.createElement(.div);
    const hidden_group = try doc.createElement(.div);
    hidden_group.setStyle(.{ .display = .none });
    const hidden = try doc.createElement(.div);
    const negative = try doc.createElement(.div);
    const last_zero = try doc.createElement(.div);

    two.asElement().focusable = true;
    two.asElement().tab_index = 2;
    zero.asElement().focusable = true;
    one.asElement().focusable = true;
    one.asElement().tab_index = 1;
    hidden.asElement().focusable = true;
    negative.asElement().focusable = true;
    negative.asElement().tab_index = -5;
    last_zero.asElement().focusable = true;

    _ = try root.appendChild(two);
    _ = try root.appendChild(zero);
    _ = try group.appendChild(one);
    _ = try hidden_group.appendChild(hidden);
    _ = try root.appendChild(group);
    _ = try root.appendChild(hidden_group);
    _ = try root.appendChild(negative);
    _ = try root.appendChild(last_zero);
    doc.setRoot(root);

    // Positive tabindex values first, ascending, then zero in tree order.
    try std.testing.expect(doc.moveFocus(.forward));
    try std.testing.expectEqual(one, doc.activeElement().?);
    try std.testing.expect(doc.moveFocus(.forward));
    try std.testing.expectEqual(two, doc.activeElement().?);
    try std.testing.expect(doc.moveFocus(.forward));
    try std.testing.expectEqual(zero, doc.activeElement().?);
    try std.testing.expect(doc.moveFocus(.forward));
    try std.testing.expectEqual(last_zero, doc.activeElement().?);
    try std.testing.expect(doc.moveFocus(.forward));
    try std.testing.expectEqual(one, doc.activeElement().?);

    try std.testing.expect(doc.moveFocus(.backward));
    try std.testing.expectEqual(last_zero, doc.activeElement().?);
    try std.testing.expect(doc.moveFocus(.backward));
    try std.testing.expectEqual(zero, doc.activeElement().?);

    // A negative tabindex is not a tab stop, so Tab uses DOM order from that
    // element rather than restarting at the first tab stop or using tabindex
    // order. Forward continues at the next tab stop in tree order.
    try std.testing.expect(doc.focus(negative));
    try std.testing.expect(doc.moveFocus(.forward));
    try std.testing.expectEqual(last_zero, doc.activeElement().?);

    // Backward finds the nearest tab stop before the negative element in tree
    // order, which is the nested tabindex=1 element, not the first stop.
    try std.testing.expect(doc.focus(negative));
    try std.testing.expect(doc.moveFocus(.backward));
    try std.testing.expectEqual(one, doc.activeElement().?);
}

test "event: removing a focused subtree clears focus silently" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const branch = try doc.createElement(.div);
    const focused = try doc.createElement(.div);
    focused.asElement().focusable = true;
    _ = try branch.appendChild(focused);
    _ = try root.appendChild(branch);
    doc.setRoot(root);

    var log = FocusLog{};
    try focused.addEventListener(log.listener());

    try std.testing.expect(doc.focus(focused));
    _ = root.removeChild(branch);
    try std.testing.expect(doc.activeElement() == root);
    try std.testing.expectEqual(@as(usize, 0), log.blur_count);
    try std.testing.expectEqual(@as(usize, 0), log.focus_out_count);
}

test "event: listener removal and immediate propagation" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const child = try doc.createElement(.div);
    child.asElement().focusable = true;
    _ = try root.appendChild(child);
    doc.setRoot(root);
    try std.testing.expect(doc.focus(child));

    var first = TestLog{};
    var second = TestLog{};
    const listener = Listener{ .context = &first, .key_down = TestLog.onKey };
    try child.addEventListener(listener);
    try child.addEventListener(.{ .context = &second, .key_down = TestLog.onKey });

    _ = doc.dispatchKey(.enter, .{});
    try std.testing.expectEqual(@as(usize, 1), first.count);
    try std.testing.expectEqual(@as(usize, 1), second.count);
    try std.testing.expect(child.removeEventListener(listener));
    try std.testing.expect(!child.removeEventListener(listener));
    first.count = 0;
    second.count = 0;
    _ = doc.dispatchKey(.enter, .{});
    try std.testing.expectEqual(@as(usize, 0), first.count);
    try std.testing.expectEqual(@as(usize, 1), second.count);

    const Stopper = struct {
        fn onKey(_: ?*anyopaque, event: *KeyEvent) void {
            event.stopImmediatePropagation();
        }
    };
    _ = child.removeEventListener(.{ .context = &second, .key_down = TestLog.onKey });
    try child.addEventListener(.{ .key_down = Stopper.onKey });
    second.count = 0;
    _ = doc.dispatchKey(.enter, .{});
    try std.testing.expectEqual(@as(usize, 0), second.count);
}

test "event: moving a focused node keeps focus" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const first = try doc.createElement(.div);
    const second = try doc.createElement(.div);
    const item = try doc.createElement(.div);
    item.asElement().focusable = true;
    _ = try first.appendChild(item);
    _ = try root.appendChild(first);
    _ = try root.appendChild(second);
    doc.setRoot(root);

    try std.testing.expect(doc.focus(item));
    _ = try second.appendChild(item);
    try std.testing.expectEqual(item, doc.activeElement().?);
    try std.testing.expectEqual(second, item.parent.?);
}

const MouseLog = struct {
    kinds: [16]MouseKind = @splat(.down),
    nodes: [16]?*dom.Node = @splat(null),
    phases: [16]Phase = @splat(.target),
    count: usize = 0,

    fn record(self: *MouseLog, event: *MouseEvent) void {
        if (self.count == self.kinds.len) return;
        self.kinds[self.count] = event.kind;
        self.nodes[self.count] = event.current_target;
        self.phases[self.count] = event.phase;
        self.count += 1;
    }

    fn onDown(context: ?*anyopaque, event: *MouseEvent) void {
        const self: *MouseLog = @ptrCast(@alignCast(context orelse return));
        self.record(event);
    }

    fn onClick(context: ?*anyopaque, event: *MouseEvent) void {
        const self: *MouseLog = @ptrCast(@alignCast(context orelse return));
        self.record(event);
    }

    fn onWheel(context: ?*anyopaque, event: *MouseEvent) void {
        const self: *MouseLog = @ptrCast(@alignCast(context orelse return));
        self.record(event);
    }
};

test "event: mouse dispatch runs capture, target and bubble" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const parent = try doc.createElement(.div);
    const child = try doc.createElement(.div);
    parent.asElement().focusable = true;
    _ = try root.appendChild(parent);
    _ = try parent.appendChild(child);
    doc.setRoot(root);

    var root_capture = MouseLog{};
    var root_bubble = MouseLog{};
    var target_log = MouseLog{};
    try root.addEventListener(.{ .context = &root_capture, .capture = true, .mouse_down = MouseLog.onDown });
    try root.addEventListener(.{ .context = &root_bubble, .mouse_down = MouseLog.onDown });
    try child.addEventListener(.{ .context = &target_log, .mouse_down = MouseLog.onDown });

    var down = MouseEvent{ .kind = .down, .x = 2, .y = 1, .button = .left };
    doc.dispatchMouse(child, &down);

    try std.testing.expectEqual(child, down.target.?);
    try std.testing.expect(!down.default_prevented);
    try std.testing.expectEqual(root, root_capture.nodes[0].?);
    try std.testing.expectEqual(Phase.capture, root_capture.phases[0]);
    try std.testing.expectEqual(child, target_log.nodes[0].?);
    try std.testing.expectEqual(Phase.target, target_log.phases[0]);
    try std.testing.expectEqual(root, root_bubble.nodes[0].?);
    try std.testing.expectEqual(Phase.bubble, root_bubble.phases[0]);
    // A press focuses the nearest focusable ancestor.
    try std.testing.expectEqual(parent, doc.activeElement().?);
}

test "event: mouse default focus can be canceled and blur is the fallback" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const focusable = try doc.createElement(.div);
    const plain = try doc.createElement(.div);
    focusable.asElement().focusable = true;
    _ = try root.appendChild(focusable);
    _ = try root.appendChild(plain);
    doc.setRoot(root);

    const Blocker = struct {
        fn onDown(_: ?*anyopaque, event: *MouseEvent) void {
            event.preventDefault();
        }
    };
    var down = MouseEvent{ .kind = .down, .x = 1, .y = 1 };
    doc.dispatchMouse(plain, &down);
    try std.testing.expectEqual(root, doc.activeElement().?);

    try std.testing.expect(doc.focus(focusable));
    try plain.addEventListener(.{ .mouse_down = Blocker.onDown });
    doc.dispatchMouse(plain, &down);
    try std.testing.expectEqual(focusable, doc.activeElement().?);

    // An uncanceled press on plain content blurs.
    try std.testing.expect(plain.removeEventListener(.{ .mouse_down = Blocker.onDown }));
    doc.dispatchMouse(plain, &down);
    try std.testing.expectEqual(root, doc.activeElement().?);

    // Wheel is cancelable and never changes focus.
    var root_log = MouseLog{};
    try root.addEventListener(.{ .context = &root_log, .wheel = MouseLog.onWheel });
    var wheel = MouseEvent{ .kind = .wheel, .x = 1, .y = 1, .delta_y = 3 };
    doc.dispatchMouse(plain, &wheel);
    try std.testing.expectEqual(@as(usize, 1), root_log.count);
    try std.testing.expectEqual(MouseKind.wheel, root_log.kinds[0]);
    try std.testing.expectEqual(@as(i32, 0), wheel.delta_x);

    const WheelBlocker = struct {
        fn onWheel(_: ?*anyopaque, event: *MouseEvent) void {
            event.preventDefault();
        }
    };
    try plain.addEventListener(.{ .wheel = WheelBlocker.onWheel });
    doc.dispatchMouse(plain, &wheel);
    try std.testing.expect(wheel.default_prevented);
}

test "event: click listeners run only for click and common ancestors are found" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const left = try doc.createElement(.div);
    const right = try doc.createElement(.div);
    _ = try root.appendChild(left);
    _ = try root.appendChild(right);
    doc.setRoot(root);

    var log = MouseLog{};
    try root.addEventListener(.{ .context = &log, .click = MouseLog.onClick });

    var down = MouseEvent{ .kind = .down, .x = 1, .y = 1 };
    doc.dispatchMouse(left, &down);
    try std.testing.expectEqual(@as(usize, 0), log.count);

    var click = MouseEvent{ .kind = .click, .x = 1, .y = 1, .button = .left };
    doc.dispatchMouse(root, &click);
    try std.testing.expectEqual(@as(usize, 1), log.count);
    try std.testing.expectEqual(MouseKind.click, log.kinds[0]);

    try std.testing.expectEqual(root, commonInclusiveAncestor(left, right).?);
    try std.testing.expectEqual(left, commonInclusiveAncestor(left, left).?);
    try std.testing.expectEqual(root, commonInclusiveAncestor(left, root).?);
}

test "event: motion updates the hover target, other mouse events do not" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const child = try doc.createElement(.div);
    _ = try root.appendChild(child);
    doc.setRoot(root);

    var move = MouseEvent{ .kind = .move, .x = 1, .y = 1 };
    doc.dispatchMouse(child, &move);
    try std.testing.expectEqual(child, doc.hoverTarget().?);

    // A press or wheel at another target leaves the hover chain alone: only
    // motion moves the pointer.
    var down = MouseEvent{ .kind = .down, .x = 1, .y = 1, .button = .left };
    doc.dispatchMouse(root, &down);
    try std.testing.expectEqual(child, doc.hoverTarget().?);

    var wheel = MouseEvent{ .kind = .wheel, .x = 1, .y = 1, .delta_y = 1 };
    doc.dispatchMouse(root, &wheel);
    try std.testing.expectEqual(child, doc.hoverTarget().?);

    var leave = MouseEvent{ .kind = .move, .x = 9, .y = 4 };
    doc.dispatchMouse(root, &leave);
    try std.testing.expectEqual(root, doc.hoverTarget().?);
    try std.testing.expect(root.isHovered());
    try std.testing.expect(!child.isHovered());
}

test "event: class display none makes an element unfocusable" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const Class = enum(u16) { hidden };
    _ = try doc.registerSheet(.{ .styles = &.{.{ .display = .none }} });

    const root = try doc.createElement(.div);
    doc.setRoot(root);
    const child = try doc.createElement(.div);
    child.asElement().focusable = true;
    try child.addClass(Class.hidden);
    _ = try root.appendChild(child);

    try std.testing.expect(!doc.focus(child));
    try std.testing.expect(!canFocus(&doc, child));
}

test "event: removing listeners during focus and key dispatch is safe" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const child = try doc.createElement(.div);
    child.asElement().focusable = true;
    _ = try root.appendChild(child);
    doc.setRoot(root);

    const Remover = struct {
        node: *dom.Node,
        listener: Listener = .{},
        focus_in: usize = 0,
        key: usize = 0,

        fn onFocusIn(context: ?*anyopaque, _: *FocusEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse return));
            self.focus_in += 1;
            _ = self.node.removeEventListener(self.listener);
        }

        fn onKey(context: ?*anyopaque, _: *KeyEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse return));
            self.key += 1;
            _ = self.node.removeEventListener(self.listener);
        }
    };

    const Counter = struct {
        focus_in: usize = 0,
        key: usize = 0,

        fn onFocusIn(context: ?*anyopaque, _: *FocusEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse return));
            self.focus_in += 1;
        }

        fn onKey(context: ?*anyopaque, _: *KeyEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse return));
            self.key += 1;
        }
    };

    var remover = Remover{ .node = child };
    var counter = Counter{};
    remover.listener = .{ .context = &remover, .focus_in = Remover.onFocusIn };
    try child.addEventListener(remover.listener);
    try child.addEventListener(.{ .context = &counter, .focus_in = Counter.onFocusIn });

    try std.testing.expect(doc.focus(child));
    try std.testing.expectEqual(@as(usize, 1), remover.focus_in);
    try std.testing.expectEqual(@as(usize, 1), counter.focus_in);

    remover.listener = .{ .context = &remover, .key_down = Remover.onKey };
    try child.addEventListener(remover.listener);
    try child.addEventListener(.{ .context = &counter, .key_down = Counter.onKey });
    _ = doc.dispatchKey(.enter, .{});
    try std.testing.expectEqual(@as(usize, 1), remover.key);
    try std.testing.expectEqual(@as(usize, 1), counter.key);
}

test "event: focus is cleared during blur and a redirect aborts the pending target" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const a = try doc.createElement(.div);
    const b = try doc.createElement(.div);
    const c = try doc.createElement(.div);
    a.asElement().focusable = true;
    b.asElement().focusable = true;
    c.asElement().focusable = true;
    _ = try root.appendChild(a);
    _ = try root.appendChild(b);
    _ = try root.appendChild(c);
    doc.setRoot(root);

    var a_log = FocusLog{};
    var b_log = FocusLog{};
    var c_log = FocusLog{};
    try a.addEventListener(a_log.listener());
    try b.addEventListener(b_log.listener());
    try c.addEventListener(c_log.listener());

    const Redirect = struct {
        doc: *dom.Document,
        target: *dom.Node,
        seen_active: ?*dom.Node = null,

        fn onBlur(context: ?*anyopaque, _: *FocusEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse return));
            self.seen_active = self.doc.activeElement();
            _ = self.doc.focus(self.target);
        }
    };
    var redirect = Redirect{ .doc = &doc, .target = c };
    try a.addEventListener(.{ .context = &redirect, .blur = Redirect.onBlur });

    try std.testing.expect(doc.focus(a));
    a_log = .{};
    b_log = .{};
    c_log = .{};

    // The blur handler focuses c. B must not receive focus/focusin, and the
    // active element during blur is the root/body fallback.
    try std.testing.expect(!doc.focus(b));
    try std.testing.expectEqual(c, doc.activeElement().?);
    try std.testing.expect(redirect.seen_active == root);
    try std.testing.expectEqual(@as(usize, 1), a_log.blur_count);
    try std.testing.expectEqual(@as(usize, 1), a_log.focus_out_count);
    try std.testing.expectEqual(@as(usize, 0), b_log.focus_count);
    try std.testing.expectEqual(@as(usize, 0), b_log.focus_in_count);
    try std.testing.expectEqual(@as(usize, 1), c_log.focus_count);
    try std.testing.expectEqual(@as(usize, 1), c_log.focus_in_count);
}

test "event: focus and focusin handlers can redirect focus" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const a = try doc.createElement(.div);
    const b = try doc.createElement(.div);
    const c = try doc.createElement(.div);
    a.asElement().focusable = true;
    b.asElement().focusable = true;
    c.asElement().focusable = true;
    _ = try root.appendChild(a);
    _ = try root.appendChild(b);
    _ = try root.appendChild(c);
    doc.setRoot(root);

    var b_log = FocusLog{};
    var c_log = FocusLog{};
    try b.addEventListener(b_log.listener());
    try c.addEventListener(c_log.listener());

    const Redirect = struct {
        doc: *dom.Document,
        target: *dom.Node,

        fn onFocus(context: ?*anyopaque, _: *FocusEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse return));
            _ = self.doc.focus(self.target);
        }
    };
    var redirect = Redirect{ .doc = &doc, .target = c };
    try b.addEventListener(.{ .context = &redirect, .focus = Redirect.onFocus });

    try std.testing.expect(doc.focus(a));
    b_log = .{};
    c_log = .{};

    // B receives focus, redirects to c, then loses focus; focusin is not
    // delivered for the aborted transition.
    try std.testing.expect(!doc.focus(b));
    try std.testing.expectEqual(c, doc.activeElement().?);
    try std.testing.expectEqual(@as(usize, 1), b_log.focus_count);
    try std.testing.expectEqual(@as(usize, 1), b_log.blur_count);
    try std.testing.expectEqual(@as(usize, 1), b_log.focus_out_count);
    try std.testing.expectEqual(@as(usize, 0), b_log.focus_in_count);
    try std.testing.expectEqual(@as(usize, 1), c_log.focus_count);
    try std.testing.expectEqual(@as(usize, 1), c_log.focus_in_count);

    try std.testing.expect(b.removeEventListener(.{ .context = &redirect, .focus = Redirect.onFocus }));
    try b.addEventListener(.{ .context = &redirect, .focus_in = Redirect.onFocus });
    try std.testing.expect(!doc.focus(b));
    try std.testing.expectEqual(c, doc.focusedElement().?);
}

test "event: target focus runs capture listeners before bubble listeners" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const child = try doc.createElement(.div);
    child.asElement().focusable = true;
    _ = try root.appendChild(child);
    doc.setRoot(root);

    const Recorder = struct {
        order: *std.ArrayListUnmanaged([2]u8),
        allocator: std.mem.Allocator,

        fn push(self: *@This(), value: []const u8) void {
            self.order.append(self.allocator, .{ value[0], value[1] }) catch {};
        }
        fn bubble1(context: ?*anyopaque, _: *FocusEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse return));
            self.push("b1");
        }
        fn capture(context: ?*anyopaque, _: *FocusEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse return));
            self.push("c2");
        }
        fn bubble3(context: ?*anyopaque, _: *FocusEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse return));
            self.push("b3");
        }
        fn stopCapture(context: ?*anyopaque, event: *FocusEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse return));
            self.push("s0");
            event.stopPropagation();
        }
    };

    var order: std.ArrayListUnmanaged([2]u8) = .empty;
    defer order.deinit(allocator);
    var recorder = Recorder{ .order = &order, .allocator = allocator };
    try child.addEventListener(.{ .context = &recorder, .focus = Recorder.bubble1 });
    try child.addEventListener(.{ .context = &recorder, .capture = true, .focus = Recorder.capture });
    try child.addEventListener(.{ .context = &recorder, .focus = Recorder.bubble3 });

    try std.testing.expect(doc.focus(child));
    try std.testing.expectEqualSlices([2]u8, &.{ "c2".*, "b1".*, "b3".* }, order.items);

    order.clearRetainingCapacity();
    _ = doc.blur();
    var stopper = Recorder{ .order = &order, .allocator = allocator };
    try child.addEventListener(.{ .context = &stopper, .capture = true, .focus = Recorder.stopCapture });
    try std.testing.expect(doc.focus(child));
    try std.testing.expectEqualSlices([2]u8, &.{ "c2".*, "s0".* }, order.items);
}

const PhaseLog = struct {
    nodes: [16]?*dom.Node = @splat(null),
    phases: [16]Phase = @splat(.target),
    count: usize = 0,

    fn onFocusIn(context: ?*anyopaque, event: *FocusEvent) void {
        const self: *@This() = @ptrCast(@alignCast(context orelse return));
        if (self.count == self.nodes.len) return;
        self.nodes[self.count] = event.current_target;
        self.phases[self.count] = event.phase;
        self.count += 1;
    }
};

test "event: focusin runs capture, target and bubble and honors stopPropagation" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const parent = try doc.createElement(.div);
    const child = try doc.createElement(.div);
    child.asElement().focusable = true;
    _ = try root.appendChild(parent);
    _ = try parent.appendChild(child);
    doc.setRoot(root);

    var root_capture = PhaseLog{};
    var parent_capture = PhaseLog{};
    var parent_bubble = PhaseLog{};
    var root_bubble = PhaseLog{};
    try root.addEventListener(.{ .context = &root_capture, .capture = true, .focus_in = PhaseLog.onFocusIn });
    try parent.addEventListener(.{ .context = &parent_capture, .capture = true, .focus_in = PhaseLog.onFocusIn });
    try parent.addEventListener(.{ .context = &parent_bubble, .focus_in = PhaseLog.onFocusIn });
    try root.addEventListener(.{ .context = &root_bubble, .focus_in = PhaseLog.onFocusIn });

    var target_log = PhaseLog{};
    try child.addEventListener(.{ .context = &target_log, .focus_in = PhaseLog.onFocusIn });

    try std.testing.expect(doc.focus(child));
    try std.testing.expectEqual(@as(usize, 1), root_capture.count);
    try std.testing.expectEqual(Phase.capture, root_capture.phases[0]);
    try std.testing.expectEqual(@as(usize, 1), parent_capture.count);
    try std.testing.expectEqual(Phase.capture, parent_capture.phases[0]);
    try std.testing.expectEqual(@as(usize, 1), target_log.count);
    try std.testing.expectEqual(Phase.target, target_log.phases[0]);
    try std.testing.expectEqual(@as(usize, 1), parent_bubble.count);
    try std.testing.expectEqual(Phase.bubble, parent_bubble.phases[0]);
    try std.testing.expectEqual(@as(usize, 1), root_bubble.count);
    try std.testing.expectEqual(Phase.bubble, root_bubble.phases[0]);

    // stopPropagation at the target suppresses the ancestors but not the
    // remaining listeners on the target.
    const Stopper = struct {
        fn onFocusIn(_: ?*anyopaque, event: *FocusEvent) void {
            event.stopPropagation();
        }
    };
    try child.addEventListener(.{ .focus_in = Stopper.onFocusIn });
    var after_stop = PhaseLog{};
    try child.addEventListener(.{ .context = &after_stop, .focus_in = PhaseLog.onFocusIn });
    root_bubble.count = 0;
    parent_bubble.count = 0;
    target_log.count = 0;
    try std.testing.expect(doc.focus(child));
    // Already focused: no event at all.
    try std.testing.expectEqual(@as(usize, 0), target_log.count);

    _ = doc.blur();
    try std.testing.expect(doc.focus(child));
    try std.testing.expectEqual(@as(usize, 1), target_log.count);
    try std.testing.expectEqual(@as(usize, 1), after_stop.count);
    try std.testing.expectEqual(@as(usize, 0), parent_bubble.count);
    try std.testing.expectEqual(@as(usize, 0), root_bubble.count);
}

test "event: focusin path is fixed before dispatch" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const first_parent = try doc.createElement(.div);
    const second_parent = try doc.createElement(.div);
    const child = try doc.createElement(.div);
    child.asElement().focusable = true;
    _ = try first_parent.appendChild(child);
    _ = try root.appendChild(first_parent);
    _ = try root.appendChild(second_parent);
    doc.setRoot(root);

    const Move = struct {
        child: *dom.Node,
        new_parent: *dom.Node,
        fn onFocusIn(context: ?*anyopaque, _: *FocusEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse return));
            _ = self.new_parent.appendChild(self.child) catch {};
        }
    };
    var move = Move{ .child = child, .new_parent = second_parent };
    try child.addEventListener(.{ .context = &move, .focus_in = Move.onFocusIn });

    var first_bubble = PhaseLog{};
    var second_bubble = PhaseLog{};
    try first_parent.addEventListener(.{ .context = &first_bubble, .focus_in = PhaseLog.onFocusIn });
    try second_parent.addEventListener(.{ .context = &second_bubble, .focus_in = PhaseLog.onFocusIn });

    try std.testing.expect(doc.focus(child));
    try std.testing.expectEqual(second_parent, child.parent.?);
    try std.testing.expectEqual(@as(usize, 1), first_bubble.count);
    try std.testing.expectEqual(@as(usize, 0), second_bubble.count);

    doc.blur();
    const container = try first_parent.appendChild(try doc.createElement(.div));
    _ = try container.appendChild(child);
    move.child = container;
    try std.testing.expect(doc.focus(child));
    try std.testing.expectEqual(second_parent, container.parent.?);
    try std.testing.expectEqual(@as(usize, 2), first_bubble.count);
    try std.testing.expectEqual(@as(usize, 0), second_bubble.count);
}

test "event: Tab continues from the last pressed tree position" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 5 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const first = try doc.createElement(.div);
    const spacer = try doc.createElement(.div);
    const last = try doc.createElement(.div);
    first.asElement().focusable = true;
    last.asElement().focusable = true;
    _ = try root.appendChild(first);
    _ = try root.appendChild(spacer);
    _ = try root.appendChild(last);
    doc.setRoot(root);

    // Without a press, Tab starts at the first tab stop.
    try std.testing.expect(doc.moveFocus(.forward));
    try std.testing.expectEqual(first, doc.activeElement().?);

    _ = doc.blur();
    var down = MouseEvent{ .kind = .down, .x = 1, .y = 1, .button = .left };
    doc.dispatchMouse(spacer, &down);
    try std.testing.expect(doc.focusedElement() == null);
    try std.testing.expectEqual(spacer, doc.focus_start.?);
    try std.testing.expect(doc.moveFocus(.forward));
    try std.testing.expectEqual(last, doc.activeElement().?);
}

test "event: hiding the focused element keeps focus, as in the browser" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const child = try doc.createElement(.div);
    child.asElement().focusable = true;
    _ = try root.appendChild(child);
    doc.setRoot(root);

    var keys: usize = 0;
    const Counter = struct {
        fn onKey(context: ?*anyopaque, _: *KeyEvent) void {
            const count: *usize = @ptrCast(@alignCast(context orelse return));
            count.* += 1;
        }
    };
    try child.addEventListener(.{ .context = &keys, .key_down = Counter.onKey });

    try std.testing.expect(doc.focus(child));
    child.setStyle(.{ .display = .none });
    // Chrome keeps the hidden element focused and continues routing keys to
    // it; only removing the node clears focus.
    try std.testing.expectEqual(child, doc.activeElement().?);
    try std.testing.expect(!canFocus(&doc, child));
    _ = doc.dispatchKey(.enter, .{});
    try std.testing.expectEqual(@as(usize, 1), keys);
}

test "event: a blur handler may install the pending target itself" {
    const allocator = std.testing.allocator;
    var doc = try dom.Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const a = try doc.createElement(.div);
    const b = try doc.createElement(.div);
    a.asElement().focusable = true;
    b.asElement().focusable = true;
    _ = try root.appendChild(a);
    _ = try root.appendChild(b);
    doc.setRoot(root);

    var b_log = FocusLog{};
    try b.addEventListener(b_log.listener());

    const Install = struct {
        doc: *dom.Document,
        target: *dom.Node,
        fn onBlur(context: ?*anyopaque, _: *FocusEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context orelse return));
            _ = self.doc.focus(self.target);
        }
    };
    var install = Install{ .doc = &doc, .target = b };
    try a.addEventListener(.{ .context = &install, .blur = Install.onBlur });

    try std.testing.expect(doc.focus(a));
    b_log = .{};
    // The handler already focused b during a's blur, so the outer call
    // succeeds without dispatching focus/focusin a second time.
    try std.testing.expect(doc.focus(b));
    try std.testing.expectEqual(b, doc.activeElement().?);
    try std.testing.expectEqual(@as(usize, 1), b_log.focus_count);
    try std.testing.expectEqual(@as(usize, 1), b_log.focus_in_count);
}
