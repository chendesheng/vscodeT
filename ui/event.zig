//! Keyboard and focus events for the retained tree.
//!
//! The model is DOM-shaped but deliberately smaller: every node carries one
//! listener list, key events run through capture -> target -> bubble, and focus
//! moves use `focus`/`blur` (non-bubbling) plus `focusin`/`focusout`
//! (bubbling). There is no `Event` base class and no per-type `on*` property;
//! a listener is a struct of optional callbacks.
//!
//! This follows the same split as the references:
//! - Lightpanda's `EventTarget`/`EventManager`: a listener list, capture and
//!   bubble passes, `stopPropagation`/`preventDefault`, and focus that sets
//!   `activeElement` before dispatching blur/focus.
//! - TermDOM's browser layer: focusable areas are connected and rendered,
//!   `tabindex` orders sequential navigation (positive first, then document
//!   order), and a removed subtree loses focus silently.
//!
//! We only have terminal input, so only `key_down` exists: a terminal reports
//! bytes, not key releases, and cannot report key repeat.

const std = @import("std");
const dom = @import("dom.zig");

pub const Modifiers = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,

    pub fn eql(a: Modifiers, b: Modifiers) bool {
        return a.shift == b.shift and a.ctrl == b.ctrl and a.alt == b.alt;
    }
};

/// A decoded key. `text` carries a printable run (bulk typing or paste);
/// `char` carries one character, including control-modified characters.
pub const Key = union(enum) {
    text: []const u8,
    char: u21,
    enter,
    backspace,
    delete,
    insert,
    tab,
    backtab,
    escape,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    paste_start,
    paste_end,
};

pub const Phase = enum { capture, target, bubble };

pub const KeyEvent = struct {
    key: Key,
    mods: Modifiers = .{},
    /// The node the event was dispatched to; the focused element or the root.
    target: ?*dom.Node = null,
    /// The node whose listeners are running.
    current_target: ?*dom.Node = null,
    phase: Phase = .target,
    default_prevented: bool = false,
    propagation_stopped: bool = false,
    immediate_stopped: bool = false,

    pub fn preventDefault(self: *KeyEvent) void {
        self.default_prevented = true;
    }

    pub fn stopPropagation(self: *KeyEvent) void {
        self.propagation_stopped = true;
    }

    pub fn stopImmediatePropagation(self: *KeyEvent) void {
        self.propagation_stopped = true;
        self.immediate_stopped = true;
    }
};

pub const FocusEvent = struct {
    target: ?*dom.Node = null,
    current_target: ?*dom.Node = null,
    related_target: ?*dom.Node = null,
    /// `target` for focus/blur; `bubble` for focusin/focusout ancestors.
    phase: Phase = .target,
};

/// A listener callback plus the optional context passed back to it.
///
/// Key listeners run in the capture or bubble pass according to `capture`.
/// Focus callbacks run on the target only for `focus`/`blur`; `focus_in` and
/// `focus_out` additionally run on ancestors. Capture is ignored for focus
/// events in this POC.
pub const Listener = struct {
    context: ?*anyopaque = null,
    capture: bool = false,
    key_down: ?*const fn (context: ?*anyopaque, event: *KeyEvent) void = null,
    focus: ?*const fn (context: ?*anyopaque, event: *FocusEvent) void = null,
    blur: ?*const fn (context: ?*anyopaque, event: *FocusEvent) void = null,
    focus_in: ?*const fn (context: ?*anyopaque, event: *FocusEvent) void = null,
    focus_out: ?*const fn (context: ?*anyopaque, event: *FocusEvent) void = null,

    /// DOM `removeEventListener` identity: same callback, context and phase.
    pub fn eql(a: Listener, b: Listener) bool {
        return a.context == b.context and
            a.capture == b.capture and
            a.key_down == b.key_down and
            a.focus == b.focus and
            a.blur == b.blur and
            a.focus_in == b.focus_in and
            a.focus_out == b.focus_out;
    }
};

pub const FocusDirection = enum { forward, backward };

/// Dispatches a key event to the active element, or to the root when nothing
/// is focused (the browser's body fallback). Returns the event after dispatch,
/// including its final target and whether a listener prevented the default
/// action.
pub fn dispatchKey(document: *dom.Document, key: Key, mods: Modifiers) KeyEvent {
    var event = KeyEvent{ .key = key, .mods = mods };
    const target = activeElement(document) orelse return event;
    event.target = target;

    dispatchCapture(target, &event);
    if (!event.propagation_stopped) dispatchAtTarget(target, &event);
    if (!event.propagation_stopped) dispatchBubble(target, &event);
    if (!event.default_prevented) runDefaultAction(document, &event);
    return event;
}

fn dispatchCapture(node: *dom.Node, event: *KeyEvent) void {
    if (node.parent) |parent| {
        dispatchCapture(parent, event);
        if (event.propagation_stopped) return;
    }
    if (node == event.target) return;
    event.current_target = node;
    event.phase = .capture;
    invokeKeyListeners(node, event, true);
}

fn dispatchAtTarget(target: *dom.Node, event: *KeyEvent) void {
    event.current_target = target;
    event.phase = .target;
    // DOM dispatch invokes the target's listeners once, in registration order
    // and regardless of `capture`. `stopPropagation` on the target therefore
    // does not silence the remaining target listeners; only immediate
    // propagation does.
    for (target.listeners.items) |listener| {
        if (event.immediate_stopped) return;
        if (listener.key_down) |handler| handler(listener.context, event);
    }
}

fn dispatchBubble(target: *dom.Node, event: *KeyEvent) void {
    var current = target.parent;
    while (current) |node| : (current = node.parent) {
        if (event.propagation_stopped) return;
        event.current_target = node;
        event.phase = .bubble;
        invokeKeyListeners(node, event, false);
    }
}

fn invokeKeyListeners(node: *dom.Node, event: *KeyEvent, capture: bool) void {
    for (node.listeners.items) |listener| {
        if (event.immediate_stopped) return;
        if (listener.capture != capture) continue;
        if (listener.key_down) |handler| handler(listener.context, event);
    }
}

fn runDefaultAction(document: *dom.Document, event: *KeyEvent) void {
    if (event.mods.ctrl or event.mods.alt) return;
    switch (event.key) {
        .tab => {
            const direction: FocusDirection = if (event.mods.shift) .backward else .forward;
            _ = moveFocus(document, direction);
        },
        .backtab => _ = moveFocus(document, .backward),
        else => {},
    }
}

/// The focused element, or the root when nothing is focused. Browsers return
/// the body in the same situation; our root viewport is that fallback.
pub fn activeElement(document: *const dom.Document) ?*dom.Node {
    return document.active_element orelse document.root;
}

/// Moves focus to `node`. Only connected, rendered, `focusable` elements take
/// focus. An already focused node is a no-op; failure leaves focus untouched.
pub fn focus(document: *dom.Document, node: *dom.Node) bool {
    if (document.active_element == node) return true;
    if (!canFocus(document, node)) return false;

    const previous = document.active_element;
    document.active_element = node;

    if (previous) |old| {
        dispatchFocusEvent(old, .blur, .{ .related_target = node });
        dispatchFocusEvent(old, .focus_out, .{ .related_target = node });
    }
    dispatchFocusEvent(node, .focus, .{ .related_target = previous });
    dispatchFocusEvent(node, .focus_in, .{ .related_target = previous });
    return true;
}

/// Clears focus from the active element, if any.
pub fn blur(document: *dom.Document) void {
    const previous = document.active_element orelse return;
    document.active_element = null;
    dispatchFocusEvent(previous, .blur, .{});
    dispatchFocusEvent(previous, .focus_out, .{});
}

/// Clears focus when the active element is inside a subtree that is about to
/// be removed. Like the references, no blur fires for an element that is
/// already leaving the tree.
pub fn clearFocusWithin(document: *dom.Document, subtree: *dom.Node) void {
    const active = document.active_element orelse return;
    if (!isInclusiveAncestor(subtree, active)) return;
    document.active_element = null;
}

/// Clears focus after the root changed, when the active element is no longer
/// connected to the new tree.
pub fn clearDetachedFocus(document: *dom.Document) void {
    const active = document.active_element orelse return;
    if (isConnected(document, active)) return;
    document.active_element = null;
}

/// A focusable area: connected, `focusable`, rendered, and visible. A negative
/// `tab_index` stays programmatically focusable but is skipped by Tab.
pub fn canFocus(document: *const dom.Document, node: *dom.Node) bool {
    if (!node.isElement()) return false;
    if (!node.asElement().focusable) return false;
    if (!isConnected(document, node)) return false;

    var current: ?*dom.Node = node;
    while (current) |candidate| : (current = candidate.parent) {
        if (candidate.style().display == .none) return false;
    }
    return node.style().visibility == .visible;
}

/// Moves focus to the next/previous tab stop, in sequential focus navigation
/// order. Positive `tab_index` values come first in ascending order, then
/// `tab_index == 0` in tree order, tying on tree order within a group. Negative
/// values are focusable but not tab stops. Navigation wraps around.
pub fn moveFocus(document: *dom.Document, direction: FocusDirection) bool {
    const root = document.root orelse return false;
    const current = document.active_element;
    const current_stop = findFocusStop(document, current);

    var search = FocusSearch{
        .document = document,
        .forward = direction == .forward,
        .current = current,
        .current_stop = current_stop,
    };
    search.walk(root);

    const target = search.chosen orelse search.edge orelse return false;
    if (target == current) return true;
    return focus(document, target);
}

const FocusStop = struct {
    tab_index: i32,
    order: usize,
};

fn findFocusStop(document: *dom.Document, target: ?*dom.Node) ?FocusStop {
    const wanted = target orelse return null;
    const root = document.root orelse return null;
    var order: usize = 0;
    return findFocusStopWalk(document, root, wanted, &order);
}

fn findFocusStopWalk(
    document: *dom.Document,
    node: *dom.Node,
    wanted: *dom.Node,
    order: *usize,
) ?FocusStop {
    if (node.isElement()) {
        const element = node.asElement();
        const current_order = order.*;
        order.* += 1;
        if (node == wanted) {
            if (element.tab_index >= 0 and canFocus(document, node)) {
                return .{ .tab_index = element.tab_index, .order = current_order };
            }
        }
    }
    if (node.isElement() and node.style().display == .none) return null;

    var child = node.first_child;
    while (child) |current| : (child = current.next) {
        if (findFocusStopWalk(document, current, wanted, order)) |found| return found;
    }
    return null;
}

const FocusSearch = struct {
    document: *dom.Document,
    forward: bool,
    current: ?*dom.Node,
    current_stop: ?FocusStop = null,
    order: usize = 0,
    edge: ?*dom.Node = null,
    edge_stop: FocusStop = .{ .tab_index = 0, .order = 0 },
    chosen: ?*dom.Node = null,
    chosen_stop: FocusStop = .{ .tab_index = 0, .order = 0 },

    fn walk(self: *FocusSearch, node: *dom.Node) void {
        if (node.isElement()) {
            const element = node.asElement();
            const stop = FocusStop{ .tab_index = element.tab_index, .order = self.order };
            self.order += 1;

            if (element.tab_index >= 0 and canFocus(self.document, node)) {
                if (self.edge == null or self.beforeEdge(stop)) {
                    self.edge = node;
                    self.edge_stop = stop;
                }
                if (self.current_stop) |current_stop| {
                    if (node != self.current and self.pastCurrent(stop, current_stop)) {
                        if (self.chosen == null or self.beforeChosen(stop)) {
                            self.chosen = node;
                            self.chosen_stop = stop;
                        }
                    }
                }
            }
        }
        if (node.isElement() and node.style().display == .none) return;

        var child = node.first_child;
        while (child) |current| : (child = current.next) self.walk(current);
    }

    fn beforeEdge(self: *const FocusSearch, candidate: FocusStop) bool {
        if (self.forward) {
            return focusOrderBefore(candidate, self.edge_stop);
        }
        return focusOrderBefore(self.edge_stop, candidate);
    }

    fn pastCurrent(self: *const FocusSearch, candidate: FocusStop, current: FocusStop) bool {
        if (self.forward) {
            return focusOrderBefore(current, candidate);
        }
        return focusOrderBefore(candidate, current);
    }

    fn beforeChosen(self: *const FocusSearch, candidate: FocusStop) bool {
        if (self.forward) {
            return focusOrderBefore(candidate, self.chosen_stop);
        }
        return focusOrderBefore(self.chosen_stop, candidate);
    }
};

/// Sequential focus navigation order: positive tabindex first (ascending),
/// then tabindex 0, ties broken by tree order.
fn focusOrderBefore(a: FocusStop, b: FocusStop) bool {
    const a_positive = a.tab_index > 0;
    const b_positive = b.tab_index > 0;

    if (a_positive != b_positive) return a_positive;
    if (a_positive and a.tab_index != b.tab_index) return a.tab_index < b.tab_index;
    return a.order < b.order;
}

const FocusKind = enum { focus, blur, focus_in, focus_out };

const FocusEventOptions = struct {
    related_target: ?*dom.Node = null,
};

fn dispatchFocusEvent(target: *dom.Node, kind: FocusKind, options: FocusEventOptions) void {
    var event = FocusEvent{
        .target = target,
        .related_target = options.related_target,
    };

    const bubbles = kind == .focus_in or kind == .focus_out;
    var current: ?*dom.Node = target;
    while (current) |node| : (current = if (bubbles) node.parent else null) {
        event.current_target = node;
        event.phase = if (node == target) .target else .bubble;

        for (node.listeners.items) |listener| {
            const handler = switch (kind) {
                .focus => listener.focus,
                .blur => listener.blur,
                .focus_in => listener.focus_in,
                .focus_out => listener.focus_out,
            } orelse continue;
            handler(listener.context, &event);
        }
    }
}

fn isConnected(document: *const dom.Document, node: *dom.Node) bool {
    const root = document.root orelse return false;
    return isInclusiveAncestor(root, node);
}

fn isInclusiveAncestor(ancestor: *dom.Node, node: *dom.Node) bool {
    var current: ?*dom.Node = node;
    while (current) |candidate| : (current = candidate.parent) {
        if (candidate == ancestor) return true;
    }
    return false;
}

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

    // A negative tabindex is not a tab stop: Tab restarts at the first stop.
    try std.testing.expect(doc.focus(negative));
    try std.testing.expect(doc.moveFocus(.forward));
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
