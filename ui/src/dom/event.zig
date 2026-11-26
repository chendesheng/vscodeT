//! Keyboard, mouse and focus events for the retained tree.
//!
//! The model is DOM-shaped but deliberately smaller: every node carries one
//! listener list, key and mouse events run through capture -> target -> bubble,
//! and focus moves use `focus`/`blur` (non-bubbling) plus `focusin`/`focusout`
//! (bubbling). There is no `Event` base class and no per-type `on*` property;
//! a listener is a struct of optional callbacks.
//!
//! This follows the same split as the references:
//! - Lightpanda's `EventTarget`/`EventManager`: a listener list, capture and
//!   bubble passes, `stopPropagation`/`preventDefault`, and focus that sets
//!   `activeElement` before dispatching blur/focus.
//! - TermDOM's browser layer: focusable areas are connected and rendered,
//!   `tabindex` orders sequential navigation (positive first, then document
//!   order), and a removed subtree loses focus silently. A mouse press focuses
//!   the nearest focusable ancestor (or blurs), and mouse coordinates are
//!   terminal cells.
//!
//! We only have terminal input, so only `key_down` exists: a terminal reports
//! bytes, not key releases, and cannot report key repeat. Mouse motion is the
//! all-motion report a terminal sends in mode 1003: button-held motion drives
//! drags, and idle motion updates the document's hover target. The painter
//! applies `Element.hover_style` to that element and its ancestors. Style
//! declarations do cascade, but there is no selector engine, no transition and
//! no implicit enter/leave synthesis; the host decides what motion means
//! beyond the hover chain.

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
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
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
    /// `target` for focus/blur; `capture`/`bubble` for focusin/focusout.
    phase: Phase = .target,
    /// Focus events are not cancelable, but focusin/focusout bubble and can be
    /// stopped like any other bubbling event.
    propagation_stopped: bool = false,
    immediate_stopped: bool = false,

    pub fn stopPropagation(self: *FocusEvent) void {
        self.propagation_stopped = true;
    }

    pub fn stopImmediatePropagation(self: *FocusEvent) void {
        self.propagation_stopped = true;
        self.immediate_stopped = true;
    }
};

/// The button a mouse event names. A SGR release names the button that was
/// released, not `none`, and motion names the button held during the drag.
pub const MouseButton = enum { none, left, middle, right };

pub const MouseKind = enum { down, move, up, click, wheel };

/// A mouse event in terminal-cell coordinates, both zero-based.
pub const MouseEvent = struct {
    kind: MouseKind = .down,
    x: usize = 0,
    y: usize = 0,
    button: MouseButton = .none,
    mods: Modifiers = .{},
    /// Wheel distance in lines (TermDOM reports three lines per notch). Positive
    /// scrolls down or right.
    delta_x: i32 = 0,
    delta_y: i32 = 0,
    /// The node hit by the pointer.
    target: ?*dom.Node = null,
    /// The node whose listeners are running.
    current_target: ?*dom.Node = null,
    phase: Phase = .target,
    default_prevented: bool = false,
    propagation_stopped: bool = false,
    immediate_stopped: bool = false,

    pub fn preventDefault(self: *MouseEvent) void {
        self.default_prevented = true;
    }

    pub fn stopPropagation(self: *MouseEvent) void {
        self.propagation_stopped = true;
    }

    pub fn stopImmediatePropagation(self: *MouseEvent) void {
        self.propagation_stopped = true;
        self.immediate_stopped = true;
    }
};

/// A listener callback plus the optional context passed back to it.
///
/// Key, mouse and focusin/focusout listeners run in the capture or bubble pass
/// according to `capture`; a mouse listener runs only for its own event kind.
/// Focus callbacks run on the target only for `focus`/`blur`; `focus_in` and
/// `focus_out` additionally capture and bubble through ancestors.
pub const Listener = struct {
    context: ?*anyopaque = null,
    capture: bool = false,
    key_down: ?*const fn (context: ?*anyopaque, event: *KeyEvent) void = null,
    mouse_down: ?*const fn (context: ?*anyopaque, event: *MouseEvent) void = null,
    mouse_move: ?*const fn (context: ?*anyopaque, event: *MouseEvent) void = null,
    mouse_up: ?*const fn (context: ?*anyopaque, event: *MouseEvent) void = null,
    click: ?*const fn (context: ?*anyopaque, event: *MouseEvent) void = null,
    wheel: ?*const fn (context: ?*anyopaque, event: *MouseEvent) void = null,
    focus: ?*const fn (context: ?*anyopaque, event: *FocusEvent) void = null,
    blur: ?*const fn (context: ?*anyopaque, event: *FocusEvent) void = null,
    focus_in: ?*const fn (context: ?*anyopaque, event: *FocusEvent) void = null,
    focus_out: ?*const fn (context: ?*anyopaque, event: *FocusEvent) void = null,

    /// DOM `removeEventListener` identity: same callback, context and phase.
    pub fn eql(a: Listener, b: Listener) bool {
        return a.context == b.context and
            a.capture == b.capture and
            a.key_down == b.key_down and
            a.mouse_down == b.mouse_down and
            a.mouse_move == b.mouse_move and
            a.mouse_up == b.mouse_up and
            a.click == b.click and
            a.wheel == b.wheel and
            a.focus == b.focus and
            a.blur == b.blur and
            a.focus_in == b.focus_in and
            a.focus_out == b.focus_out;
    }
};

/// One entry in a node's listener list. Removing a listener marks the entry
/// removed instead of shifting the list, so a dispatch in progress keeps valid
/// indices while handlers add or remove listeners. Entries are arena-owned with
/// the node's backing list, which is reused when the node is recycled.
pub const ListenerEntry = struct {
    listener: Listener,
    removed: bool = false,
};

/// Iterates the entries that were present when the dispatch reached the node.
/// Entries appended during dispatch are not visited; removed entries are
/// skipped. The node's serial guards against a recycled node reusing the slot.
pub const ListenerIterator = struct {
    node: *dom.Node,
    index: usize = 0,
    end: usize,
    serial: u64,

    pub fn init(node: *dom.Node) ListenerIterator {
        return .{
            .node = node,
            .end = node.listeners.items.len,
            .serial = node.serial,
        };
    }

    pub fn next(self: *ListenerIterator) ?Listener {
        while (self.index < self.end and self.index < self.node.listeners.items.len) {
            const entry = self.node.listeners.items[self.index];
            self.index += 1;
            if (self.node.serial != self.serial) return null;
            if (!entry.removed) return entry.listener;
        }
        return null;
    }
};

pub const FocusDirection = enum { forward, backward };

/// Dispatches a key event to the active element, or to the root when nothing
/// is focused (the browser's body fallback). Returns the event after dispatch,
/// including its final target and whether a listener prevented the default
/// action.
pub fn dispatchKey(document: *dom.Document, key: Key, mods: Modifiers) KeyEvent {
    var event = KeyEvent{ .key = key, .mods = mods };
    dispatchEvent(document, &event);
    return event;
}

/// Dispatches an already constructed key event, as `dispatchKey` does. This is
/// how a host forwards a decoded terminal event and can inspect the flags the
/// listeners set. The propagation flags are reset before the dispatch.
pub fn dispatchEvent(document: *dom.Document, event: *KeyEvent) void {
    _ = dispatchEventInFocusScope(document, event, null);
}

/// The same event dispatch, with a native focus-scope boundary. Like WebKit's
/// focus controller, a scope without a next stop yields to its outer owner
/// before wrapping. TermDOM likewise lets focus leave a completed sequence.
pub fn dispatchEventInFocusScope(document: *dom.Document, event: *KeyEvent, scope: ?*dom.Node) bool {
    event.target = activeElement(document);
    event.current_target = null;
    event.phase = .target;
    event.default_prevented = false;
    event.propagation_stopped = false;
    event.immediate_stopped = false;

    const target = event.target orelse return false;
    if (scope) |root| {
        if (!isWithinScope(target, root)) return false;
    }
    dispatchCapture(target, event);
    if (!event.propagation_stopped) dispatchAtTarget(target, event);
    if (!event.propagation_stopped) dispatchBubble(target, event);
    const default_handled = if (!event.default_prevented) runDefaultAction(document, event, scope) else false;
    return event.default_prevented or event.propagation_stopped or default_handled;
}

fn isWithinScope(node: *dom.Node, scope: *dom.Node) bool {
    var current: ?*dom.Node = node;
    while (current) |candidate| : (current = candidate.parent) {
        if (candidate == scope) return true;
    }
    return false;
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
    var listeners = ListenerIterator.init(target);
    while (listeners.next()) |listener| {
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
    var listeners = ListenerIterator.init(node);
    while (listeners.next()) |listener| {
        if (event.immediate_stopped) return;
        if (listener.capture != capture) continue;
        if (listener.key_down) |handler| handler(listener.context, event);
    }
}

fn runDefaultAction(document: *dom.Document, event: *KeyEvent, scope: ?*dom.Node) bool {
    if (event.mods.ctrl or event.mods.alt) return false;
    const direction: FocusDirection = switch (event.key) {
        .tab => if (event.mods.shift) .backward else .forward,
        .backtab => .backward,
        else => return false,
    };
    return if (scope) |root| moveFocusWithin(document, root, direction) else moveFocus(document, direction);
}

/// Dispatches a mouse event at `target`, the element hit-tested for the cell.
/// The propagation flags are reset before the dispatch. A non-canceled press
/// focuses the nearest focusable ancestor (or blurs), as TermDOM and browsers
/// do; release, click and wheel have no library default. Motion additionally
/// records `target` as the document's hover target; `Element.hover_style` is
/// applied by the painter.
pub fn dispatchMouse(document: *dom.Document, target: *dom.Node, event: *MouseEvent) void {
    event.target = target;
    event.current_target = null;
    event.phase = .target;
    event.default_prevented = false;
    event.propagation_stopped = false;
    event.immediate_stopped = false;

    // Idle motion moves the pointer target; hover chains are derived from it
    // by `Node.isHovered` and painted from `Element.hover_style`. This is
    // paint state only and never invalidates layout.
    if (event.kind == .move) _ = document.setHoverTarget(target);

    dispatchMouseCapture(target, event);
    if (!event.propagation_stopped) dispatchMouseAtTarget(target, event);
    if (!event.propagation_stopped) dispatchMouseBubble(target, event);
    if (!event.default_prevented) runMouseDefaultAction(document, event);
}

fn dispatchMouseCapture(node: *dom.Node, event: *MouseEvent) void {
    if (node.parent) |parent| {
        dispatchMouseCapture(parent, event);
        if (event.propagation_stopped) return;
    }
    if (node == event.target) return;
    event.current_target = node;
    event.phase = .capture;
    invokeMouseListeners(node, event, true);
}

fn dispatchMouseAtTarget(target: *dom.Node, event: *MouseEvent) void {
    event.current_target = target;
    event.phase = .target;
    var listeners = ListenerIterator.init(target);
    while (listeners.next()) |listener| {
        if (event.immediate_stopped) return;
        invokeMouseListener(listener, event);
    }
}

fn dispatchMouseBubble(target: *dom.Node, event: *MouseEvent) void {
    var current = target.parent;
    while (current) |node| : (current = node.parent) {
        if (event.propagation_stopped) return;
        event.current_target = node;
        event.phase = .bubble;
        invokeMouseListeners(node, event, false);
    }
}

fn invokeMouseListeners(node: *dom.Node, event: *MouseEvent, capture: bool) void {
    var listeners = ListenerIterator.init(node);
    while (listeners.next()) |listener| {
        if (event.immediate_stopped) return;
        if (listener.capture != capture) continue;
        invokeMouseListener(listener, event);
    }
}

fn invokeMouseListener(listener: Listener, event: *MouseEvent) void {
    const handler = switch (event.kind) {
        .down => listener.mouse_down,
        .move => listener.mouse_move,
        .up => listener.mouse_up,
        .click => listener.click,
        .wheel => listener.wheel,
    } orelse return;
    handler(listener.context, event);
}

fn runMouseDefaultAction(document: *dom.Document, event: *MouseEvent) void {
    if (event.kind != .down) return;
    if (focusableAncestor(document, event.target)) |node| {
        _ = focus(document, node);
        // The next Tab starts at the element that was pressed, matching the
        // browser's sequential focus navigation starting point.
        document.focus_start = node;
    } else {
        if (document.active_element != null) blur(document);
        // A press on non-focusable content still sets the starting point; Tab
        // then continues in tree order from that position instead of restarting.
        document.focus_start = event.target;
    }
}

/// The nearest inclusive ancestor that can take focus, or null. A press on
/// text or other non-focusable content blurs, as in a browser.
fn focusableAncestor(document: *const dom.Document, target: ?*dom.Node) ?*dom.Node {
    var current = target;
    while (current) |node| : (current = node.parent) {
        if (canFocus(document, node)) return node;
    }
    return null;
}

/// The nearest common ancestor of two connected nodes, used to pick the click
/// target when a press and its release landed on different elements.
pub fn commonInclusiveAncestor(a: *dom.Node, b: *dom.Node) ?*dom.Node {
    var first: ?*dom.Node = a;
    while (first) |ancestor| : (first = ancestor.parent) {
        var second: ?*dom.Node = b;
        while (second) |candidate| : (second = candidate.parent) {
            if (ancestor == candidate) return ancestor;
        }
    }
    return null;
}

/// The focused element, or the root when nothing is focused. Browsers return
/// the body in the same situation; our root viewport is that fallback.
pub fn activeElement(document: *const dom.Document) ?*dom.Node {
    return document.active_element orelse document.root;
}

/// Moves focus to `node`. Only connected, rendered, `focusable` elements take
/// focus. An already focused node is a no-op.
///
/// This follows the browser focus-update sequence: focus is cleared before the
/// old element's blur/focusout, and the move is abandoned when a blur, focusout
/// or focus handler retargets focus. That keeps `activeElement` and the events
/// observers see consistent with the final focused element.
pub fn focus(document: *dom.Document, node: *dom.Node) bool {
    if (document.active_element == node) return true;
    if (!canFocus(document, node)) return false;

    const previous = document.active_element;
    // The browser's activeElement is the body (our root fallback) while blur
    // and focusout run; the next focused element is only installed afterwards.
    document.active_element = null;
    if (previous) |old| {
        dispatchFocusEvent(old, .blur, .{ .related_target = node });
        dispatchFocusEvent(old, .focus_out, .{ .related_target = node });
        // A handler moved focus (or already installed the requested node);
        // the outer call must not dispatch focus/focusin again.
        if (document.active_element != null) return document.active_element == node;
    }

    if (!canFocus(document, node)) return false;
    document.active_element = node;
    dispatchFocusEvent(node, .focus, .{ .related_target = previous });
    // focusin is delivered only while the node still owns focus. A focus
    // handler may blur it or move focus elsewhere.
    if (document.active_element != node) return false;
    dispatchFocusEvent(node, .focus_in, .{ .related_target = previous });
    return document.active_element == node;
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
/// already leaving the tree. The sequential focus starting point is dropped too
/// when it pointed into the removed subtree.
pub fn clearFocusWithin(document: *dom.Document, subtree: *dom.Node) void {
    if (document.active_element) |active| {
        if (isInclusiveAncestor(subtree, active)) document.active_element = null;
    }
    if (document.focus_start) |start| {
        if (isInclusiveAncestor(subtree, start)) document.focus_start = null;
    }
}

/// Clears focus after the root changed, when the active element is no longer
/// connected to the new tree. A stale sequential focus starting point is
/// dropped the same way.
pub fn clearDetachedFocus(document: *dom.Document) void {
    if (document.active_element) |active| {
        if (!isConnected(document, active)) document.active_element = null;
    }
    if (document.focus_start) |start| {
        if (!isConnected(document, start)) document.focus_start = null;
    }
}

/// A focusable area: connected, `focusable`, rendered, and visible. A negative
/// `tab_index` stays programmatically focusable but is skipped by Tab.
pub fn canFocus(document: *const dom.Document, node: *const dom.Node) bool {
    if (!node.isElement()) return false;
    if (!node.kind.element.focusable) return false;
    if (!isConnected(document, node)) return false;

    var current: ?*const dom.Node = node;
    while (current) |candidate| : (current = candidate.parent) {
        if (candidate.declaredDisplay() == .none) return false;
    }
    return node.computedVisibility() == .visible;
}

/// Moves focus to the next/previous tab stop. Positive `tab_index` values come
/// first in ascending order, then `tab_index == 0` in tree order, tying on tree
/// order within a group. Negative values are focusable but not tab stops.
///
/// When the current element (or the last pressed element) is not itself a tab
/// stop, the HTML algorithm switches to DOM order and picks the nearest tab
/// stop after/before it in tree order. Navigation wraps around.
pub fn moveFocus(document: *dom.Document, direction: FocusDirection) bool {
    return moveFocusInScope(document, document.root orelse return false, direction, true, true);
}

/// Search only the native container's own focus stops, without wrapping at
/// its boundary. A caller can then advance focus to the adjacent container.
pub fn moveFocusWithin(document: *dom.Document, root: *dom.Node, direction: FocusDirection) bool {
    if (!isConnected(document, root)) return false;
    return moveFocusInScope(document, root, direction, false, true);
}

pub fn focusScopeEdge(document: *dom.Document, root: *dom.Node, direction: FocusDirection) bool {
    if (!isConnected(document, root)) return false;
    return moveFocusInScope(document, root, direction, false, false);
}

fn moveFocusInScope(document: *dom.Document, root: *dom.Node, direction: FocusDirection, wrap: bool, use_start: bool) bool {
    const current = document.active_element;
    const start_node = if (use_start) current orelse document.focus_start else null;
    const start = findFocusStart(document, root, start_node);

    var search = FocusSearch{
        .document = document,
        .forward = direction == .forward,
        .active = current,
        .start = start,
        .wrap = wrap,
    };
    search.walk(root, false);

    const target = search.target() orelse return false;
    if (target == current) return true;
    const moved = focus(document, target);
    if (moved) document.focus_start = null;
    return moved;
}

const FocusStop = struct {
    tab_index: i32,
    order: usize,
};

/// The focused/starting element and its position in tree order. `is_stop` is
/// false for a negative tabindex, non-focusable or hidden element; Tab then
/// selects in DOM order instead of tabindex order.
const FocusStart = struct {
    node: *dom.Node,
    tab_index: i32,
    order: usize,
    is_stop: bool,
};

fn findFocusStart(document: *dom.Document, root: *dom.Node, target: ?*dom.Node) ?FocusStart {
    const wanted = target orelse return null;
    var order: usize = 0;
    return findFocusStartWalk(document, root, wanted, &order);
}

fn findFocusStartWalk(
    document: *dom.Document,
    node: *dom.Node,
    wanted: *dom.Node,
    order: *usize,
) ?FocusStart {
    if (node.isElement()) {
        const element = node.asElement();
        const current_order = order.*;
        order.* += 1;
        if (node == wanted) {
            return .{
                .node = node,
                .tab_index = element.tab_index,
                .order = current_order,
                .is_stop = element.tab_index >= 0 and canFocus(document, node),
            };
        }
    }
    // Tree order includes hidden subtrees; candidate filtering happens in the
    // search walk, which carries the hidden state down the tree.
    var child = node.first_child;
    while (child) |current| : (child = current.next) {
        if (findFocusStartWalk(document, current, wanted, order)) |found| return found;
    }
    return null;
}

const FocusSearch = struct {
    document: *dom.Document,
    forward: bool,
    active: ?*dom.Node,
    start: ?FocusStart = null,
    wrap: bool = true,
    order: usize = 0,
    edge: ?*dom.Node = null,
    edge_stop: FocusStop = .{ .tab_index = 0, .order = 0 },
    chosen: ?*dom.Node = null,
    chosen_stop: FocusStop = .{ .tab_index = 0, .order = 0 },
    dom_chosen: ?*dom.Node = null,
    dom_chosen_order: usize = 0,

    fn walk(self: *FocusSearch, node: *dom.Node, inherited_hidden: bool) void {
        var hidden = inherited_hidden;
        if (node.isElement()) {
            const element = node.asElement();
            const current_order = self.order;
            self.order += 1;
            if (node.declaredDisplay() == .none) hidden = true;
            if (!hidden and element.tab_index >= 0 and canFocus(self.document, node)) {
                self.consider(node, element.tab_index, current_order);
            }
        }

        var child = node.first_child;
        while (child) |current| : (child = current.next) self.walk(current, hidden);
    }

    fn consider(self: *FocusSearch, node: *dom.Node, tab_index: i32, order: usize) void {
        const stop = FocusStop{ .tab_index = tab_index, .order = order };
        if (self.edge == null or self.beforeEdge(stop)) {
            self.edge = node;
            self.edge_stop = stop;
        }

        const start = self.start orelse return;
        if (start.is_stop) {
            if (node == self.active) return;
            const start_stop = FocusStop{ .tab_index = start.tab_index, .order = start.order };
            if (self.pastCurrent(stop, start_stop)) {
                if (self.chosen == null or self.beforeChosen(stop)) {
                    self.chosen = node;
                    self.chosen_stop = stop;
                }
            }
        } else {
            if (node == start.node) return;
            const after = if (self.forward) start.order < order else order < start.order;
            if (!after) return;
            if (self.beforeDomChosen(order)) {
                self.dom_chosen = node;
                self.dom_chosen_order = order;
            }
        }
    }

    fn target(self: *const FocusSearch) ?*dom.Node {
        const start = self.start orelse return self.edge;
        const chosen = if (start.is_stop) self.chosen else self.dom_chosen;
        return chosen orelse if (self.wrap) self.edge else null;
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

    fn beforeDomChosen(self: *const FocusSearch, order: usize) bool {
        if (self.dom_chosen == null) return true;
        return if (self.forward) order < self.dom_chosen_order else order > self.dom_chosen_order;
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

    event.current_target = target;
    event.phase = .target;
    switch (kind) {
        // focus/blur fire at the target only and do not capture or bubble.
        .focus, .blur => invokeFocusListeners(target, kind, &event, .target),
        .focus_in, .focus_out => dispatchFocusPath(target, null, kind, &event),
    }
}

/// Capture the ancestor chain in stack frames before running any listener.
/// Each nested dispatch builds its own path, even when handlers move a subtree.
const FocusPath = struct {
    node: *dom.Node,
    serial: u64,
    child: ?*const FocusPath,

    fn dispatch(self: *const FocusPath, kind: FocusKind, event: *FocusEvent) void {
        if (self.child) |child| {
            self.invoke(kind, event, .capture);
            if (event.propagation_stopped) return;
            child.dispatch(kind, event);
            if (event.propagation_stopped) return;
            self.invoke(kind, event, .bubble);
        } else {
            self.invoke(kind, event, .target);
        }
    }

    fn invoke(self: *const FocusPath, kind: FocusKind, event: *FocusEvent, phase: Phase) void {
        if (self.node.serial != self.serial) return;
        event.current_target = self.node;
        invokeFocusListeners(self.node, kind, event, phase);
    }
};

fn dispatchFocusPath(node: *dom.Node, child: ?*const FocusPath, kind: FocusKind, event: *FocusEvent) void {
    const path = FocusPath{ .node = node, .serial = node.serial, .child = child };
    if (node.parent) |parent| {
        dispatchFocusPath(parent, &path, kind, event);
    } else {
        path.dispatch(kind, event);
    }
}

fn invokeFocusListeners(node: *dom.Node, kind: FocusKind, event: *FocusEvent, phase: Phase) void {
    switch (phase) {
        .capture => invokeFocusPass(node, kind, event, .capture, true),
        // At the target, DOM runs capture listeners first (still reporting the
        // target phase), then the non-capture listeners. stopPropagation in the
        // capture group prevents the bubble group.
        .target => {
            invokeFocusPass(node, kind, event, .target, true);
            if (event.propagation_stopped) return;
            invokeFocusPass(node, kind, event, .target, false);
        },
        .bubble => invokeFocusPass(node, kind, event, .bubble, false),
    }
}

fn invokeFocusPass(
    node: *dom.Node,
    kind: FocusKind,
    event: *FocusEvent,
    phase: Phase,
    capture: bool,
) void {
    var listeners = ListenerIterator.init(node);
    while (listeners.next()) |listener| {
        if (event.immediate_stopped) return;
        if (listener.capture != capture) continue;
        const handler = switch (kind) {
            .focus => listener.focus,
            .blur => listener.blur,
            .focus_in => listener.focus_in,
            .focus_out => listener.focus_out,
        } orelse continue;
        event.phase = phase;
        handler(listener.context, event);
    }
}

fn isConnected(document: *const dom.Document, node: *const dom.Node) bool {
    const root = document.root orelse return false;
    return isInclusiveAncestor(root, node);
}

fn isInclusiveAncestor(ancestor: *const dom.Node, node: *const dom.Node) bool {
    var current: ?*const dom.Node = node;
    while (current) |candidate| : (current = candidate.parent) {
        if (candidate == ancestor) return true;
    }
    return false;
}
