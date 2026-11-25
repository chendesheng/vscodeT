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
    event.target = activeElement(document);
    event.current_target = null;
    event.phase = .target;
    event.default_prevented = false;
    event.propagation_stopped = false;
    event.immediate_stopped = false;

    const target = event.target orelse return;
    dispatchCapture(target, event);
    if (!event.propagation_stopped) dispatchAtTarget(target, event);
    if (!event.propagation_stopped) dispatchBubble(target, event);
    if (!event.default_prevented) runDefaultAction(document, event);
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
    const root = document.root orelse return false;
    const current = document.active_element;
    const start_node = current orelse document.focus_start;
    const start = findFocusStart(document, start_node);

    var search = FocusSearch{
        .document = document,
        .forward = direction == .forward,
        .active = current,
        .start = start,
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

fn findFocusStart(document: *dom.Document, target: ?*dom.Node) ?FocusStart {
    const wanted = target orelse return null;
    const root = document.root orelse return null;
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
        if (self.start) |start| {
            if (!start.is_stop) return self.dom_chosen orelse self.edge;
        }
        return self.chosen orelse self.edge;
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
