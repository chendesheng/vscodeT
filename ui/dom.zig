//! A small DOM-like retained tree for the terminal UI.
//!
//! The link layout follows Lightpanda's Zig DOM (see docs/terminal-ui.md):
//! `first_child.?.prev` is the last child, so `lastChild` and `nextSibling` are
//! O(1); detached nodes have null links. Lightpanda uses a contiguous
//! prototype chain because it needs JS/WebIDL interop. We do not, so the node
//! payload is a tagged union instead.
//!
//! Nodes and their strings are owned by a document arena. The POC builds a
//! fresh tree per surface; a later retained tree will add a freelist.

const std = @import("std");
const css = @import("css.zig");
const event = @import("event.zig");
const style_mod = @import("style.zig");

pub const Style = style_mod.Style;
pub const HoverStyle = style_mod.HoverStyle;
pub const Rect = style_mod.Rect;
pub const Key = event.Key;
pub const KeyEvent = event.KeyEvent;
pub const MouseButton = event.MouseButton;
pub const MouseEvent = event.MouseEvent;
pub const MouseKind = event.MouseKind;
pub const Modifiers = event.Modifiers;
pub const FocusEvent = event.FocusEvent;
pub const Listener = event.Listener;
pub const FocusDirection = event.FocusDirection;

pub const Tag = enum { div, span, generic };

pub const Text = struct {
    data: []const u8,
    /// Paint properties carried by the text run (the CSS-class analogue). The
    /// editor's class cache sets `paint_ref` to share one object across runs.
    paint: style_mod.PaintStyle = .{},
    paint_ref: ?*const style_mod.PaintStyle = null,
    /// Text-flow overrides extracted from the last `setStyle`.
    flow: style_mod.TextFlow = .{},
    rect: Rect = .{},
};

pub const Element = struct {
    tag: Tag,
    attributes: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Class IDs indexing `Document.class_styles`; order is cascade order.
    classes: std.ArrayListUnmanaged(u16) = .empty,
    /// Authored inline declaration. Class declarations resolve first, then
    /// this declaration wins.
    style: Style = .{},
    /// Paint-only overrides applied while this element is in the hover chain
    /// (the pointer target or one of its ancestors). `null` opts the element
    /// out of hover. Kept separate from `Style` so layout boxes never copy it
    /// and hover cannot invalidate layout. Set it with `Node.setHoverStyle`.
    hover_style: ?HoverStyle = null,
    rect: Rect = .{},
    /// Participates in keyboard focus. Natively focusable tags are not
    /// implicit here; the code that builds the node opts in.
    focusable: bool = false,
    /// Sequential focus order. Positive values are visited first in ascending
    /// order; `0` uses tree order; negative values are focusable but skipped
    /// by Tab, as in HTML.
    tab_index: i32 = 0,
    /// CSS `pointer-events` analogue: a transparent container that lays out
    /// children but is not itself a hit-test target.
    pointer_events: bool = true,
};

pub const MutationKind = enum { tree, style, text };

/// WebKit-style invalidation: the DOM reports a mutation, and the attached
/// layout context decides which boxes need rebuilding or layout. The document
/// itself stores no layout state.
pub const MutationObserver = struct {
    context: *anyopaque,
    on_mutation: *const fn (context: *anyopaque, node: *Node, kind: MutationKind) void,

    pub fn notify(self: MutationObserver, node: *Node, kind: MutationKind) void {
        self.on_mutation(self.context, node, kind);
    }
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    root: ?*Node = null,
    /// The element that owns keyboard focus. Read it through `activeElement`,
    /// which falls back to the root like a browser's body.
    active_element: ?*Node = null,
    /// The element last hit by pointer motion. `Node.isHovered` derives the
    /// CSS-like hover chain from it. Cleared when the node leaves the tree.
    hover_target: ?*Node = null,
    /// Sequential focus navigation starting point: the element a press last
    /// landed on. When nothing is focused, Tab continues in tree order from
    /// this position instead of restarting at the first tab stop. Cleared when
    /// the node leaves the tree or `clear` resets the document.
    focus_start: ?*Node = null,
    /// Incremented when `clear` resets the arena and invalidates every node
    /// pointer. Widgets that retain a node across frames compare it with the
    /// value captured in `build` before dereferencing the node.
    generation: u64 = 1,
    /// Monotonic identity assigned to each node when it is created or reused
    /// from the free list. Widgets that retain a node pointer compare it with
    /// `Node.serial` to reject a recycled node reusing the same address.
    next_node_serial: u64 = 1,
    cols: usize,
    rows: usize,
    tab_size: usize,
    measure_width: *const fn (u21) u2,
    observer: ?MutationObserver = null,
    /// Array-backed class stylesheet. Class IDs are indices into this table;
    /// `clear()` keeps it (like a webpage's stylesheets), `deinit` frees it.
    class_styles: css.StyleTable = .{},
    /// Retired nodes available for reuse. The document arena has no per-node
    /// free; the retained editor view recycles nodes explicitly so long
    /// sessions do not grow without bound between document resets.
    free_nodes: std.ArrayListUnmanaged(*Node) = .empty,

    pub const Options = struct {
        cols: usize,
        rows: usize,
        tab_size: usize = 4,
        measure_width: *const fn (u21) u2 = defaultMeasureWidth,
    };

    pub fn setObserver(self: *Document, observer: ?MutationObserver) void {
        self.observer = observer;
    }

    pub fn notifyMutation(self: *Document, node: *Node, kind: MutationKind) void {
        if (self.observer) |observer| observer.notify(node, kind);
    }

    /// Appends a class style and returns its class ID.
    pub fn addStyle(self: *Document, style: Style) !u16 {
        const id = try self.class_styles.addStyle(self.allocator, style);
        self.invalidateClassStyles();
        return id;
    }

    /// Copies a class sheet into the document and returns its base class ID.
    /// Re-registering the same range updates it in place, which is how a
    /// themed sheet is refreshed.
    pub fn registerSheet(self: *Document, sheet: css.Sheet) !u16 {
        const base = try self.class_styles.register(self.allocator, sheet);
        self.invalidateClassStyles();
        return base;
    }

    /// The declaration registered for a class ID, or null when unregistered.
    pub fn classStyle(self: *const Document, id: u16) ?*const Style {
        return self.class_styles.get(id);
    }

    /// Merges class declarations in list order into one declaration.
    pub fn mergedClassStyle(self: *const Document, classes: anytype) Style {
        return css.mergeClasses(&self.class_styles, classes);
    }

    /// The computed style of a node, resolving declarations from the root
    /// down. This walks ancestors and is intended for DOM-side checks and
    /// tests, not for box derivation (which threads the parent computed style).
    pub fn computedStyle(self: *const Document, node: *const Node) style_mod.ComputedStyle {
        const parent_style = if (node.parent) |parent| self.computedStyle(parent) else style_mod.ComputedStyle{};
        return switch (node.kind) {
            .element => |*element| css.resolveElementStyle(
                parent_style,
                &self.class_styles,
                element.classes.items,
                element.style,
                defaultDisplay(element.tag),
            ),
            .text => parent_style,
        };
    }

    fn invalidateClassStyles(self: *Document) void {
        if (self.root) |root| self.notifyMutation(root, .style);
    }

    pub fn init(allocator: std.mem.Allocator, options: Options) !Document {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .cols = @max(options.cols, 1),
            .rows = @max(options.rows, 1),
            .tab_size = @max(options.tab_size, 1),
            .measure_width = options.measure_width,
        };
    }

    pub fn deinit(self: *Document) void {
        self.class_styles.deinit(self.allocator);
        self.free_nodes.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Drops every node, listener and focus pointer while keeping the viewport
    /// settings and the arena's capacity. Callers must not use any node pointer
    /// handed out before the call; build a new tree and `setRoot` it.
    ///
    /// This is what lets a view rebuild its tree per frame without allocating a
    /// new document (and without losing the renderer's previous frame diff).
    pub fn clear(self: *Document) void {
        self.free_nodes.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.root = null;
        self.active_element = null;
        self.hover_target = null;
        self.focus_start = null;
        self.generation +%= 1;
    }

    /// Retires `node` and its subtree into the free list. The caller must not
    /// use any pointer into that subtree afterwards.
    pub fn destroy(self: *Document, node: *Node) void {
        self.clearHoverWithin(node);
        if (node.parent) |parent| _ = parent.detachChild(node, true);
        self.recycleNode(node);
        event.clearDetachedFocus(self);
    }

    /// Unlinks and recycles every child of `node`, emitting one tree mutation.
    pub fn destroyChildren(self: *Document, node: *Node) void {
        if (self.hover_target) |target| {
            if (target != node and isAncestorOf(node, target)) self.hover_target = null;
        }
        var child = node.first_child;
        node.first_child = null;
        while (child) |current| {
            const next = current.next;
            current.parent = null;
            current.next = null;
            current.prev = null;
            self.recycleNode(current);
            child = next;
        }
        self.notifyMutation(node, .tree);
        event.clearDetachedFocus(self);
    }

    /// Clears the hover target when it lies inside `subtree` (inclusive),
    /// before the subtree is unlinked or recycled. A dangling hover target
    /// would otherwise let a reused node inherit hover state.
    fn clearHoverWithin(self: *Document, subtree: *Node) void {
        const target = self.hover_target orelse return;
        if (isAncestorOf(subtree, target)) self.hover_target = null;
    }

    /// Clears hover after the root changed, when the target is no longer
    /// connected to the new tree.
    fn clearDetachedHover(self: *Document) void {
        const target = self.hover_target orelse return;
        const root = self.root orelse {
            self.hover_target = null;
            return;
        };
        if (!isAncestorOf(root, target)) self.hover_target = null;
    }

    fn recycleNode(self: *Document, node: *Node) void {
        var child = node.first_child;
        node.first_child = null;
        while (child) |current| {
            const next = current.next;
            current.parent = null;
            current.next = null;
            current.prev = null;
            self.recycleNode(current);
            child = next;
        }
        node.parent = null;
        node.next = null;
        node.prev = null;
        node.listeners.clearRetainingCapacity();
        node.recycled = true;
        node.serial = 0;
        self.free_nodes.append(self.allocator, node) catch {};
    }

    fn takeNodeSerial(self: *Document) u64 {
        const serial = self.next_node_serial;
        self.next_node_serial +%= 1;
        if (self.next_node_serial == 0) self.next_node_serial = 1;
        return serial;
    }

    pub fn createElement(self: *Document, tag: Tag) !*Node {
        if (self.free_nodes.pop()) |node| {
            node.kind = .{ .element = .{ .tag = tag } };
            node.parent = null;
            node.first_child = null;
            node.next = null;
            node.prev = null;
            node.document = self;
            node.listeners.clearRetainingCapacity();
            node.recycled = false;
            node.serial = self.takeNodeSerial();
            return node;
        }
        const allocator = self.arena.allocator();
        const node = try allocator.create(Node);
        node.* = .{
            .kind = .{ .element = .{ .tag = tag } },
            .document = self,
            .serial = self.takeNodeSerial(),
        };
        return node;
    }

    pub fn createText(self: *Document, data: []const u8) !*Node {
        const owned = try self.arena.allocator().dupe(u8, data);
        return self.createTextOwned(owned);
    }

    /// Creates a text node that borrows `data`. The caller guarantees the
    /// slice stays valid until the node is destroyed or re-pointed.
    pub fn createTextBorrowed(self: *Document, data: []const u8) !*Node {
        return self.createTextOwned(data);
    }

    fn createTextOwned(self: *Document, data: []const u8) !*Node {
        if (self.free_nodes.pop()) |node| {
            node.kind = .{ .text = .{ .data = data } };
            node.parent = null;
            node.first_child = null;
            node.next = null;
            node.prev = null;
            node.document = self;
            node.listeners.clearRetainingCapacity();
            node.recycled = false;
            node.serial = self.takeNodeSerial();
            return node;
        }
        const allocator = self.arena.allocator();
        const node = try allocator.create(Node);
        node.* = .{
            .kind = .{ .text = .{ .data = data } },
            .document = self,
            .serial = self.takeNodeSerial(),
        };
        return node;
    }

    pub fn setRoot(self: *Document, root: *Node) void {
        root.parent = null;
        self.root = root;
        event.clearDetachedFocus(self);
        self.clearDetachedHover();
        self.notifyMutation(root, .tree);
    }

    /// The element last hit by pointer motion, or null when the pointer is not
    /// over the document tree. `Node.isHovered` derives the hover chain (the
    /// target and its ancestors) from it.
    pub fn hoverTarget(self: *const Document) ?*Node {
        return self.hover_target;
    }

    /// Sets the pointer target. Returns whether it changed. This only changes
    /// paint state: it never dirties or re-runs layout. A host that repaints
    /// the tree later must do so itself.
    pub fn setHoverTarget(self: *Document, target: ?*Node) bool {
        if (self.hover_target == target) return false;
        self.hover_target = target;
        return true;
    }

    /// Clears the pointer target. Returns whether it changed.
    pub fn clearHover(self: *Document) bool {
        return self.setHoverTarget(null);
    }

    /// The focused element, or the root when nothing is focused. Browsers
    /// return the body in the same situation; our root viewport is that
    /// fallback. Use `focusedElement` when "nothing focused" must be distinct.
    pub fn activeElement(self: *const Document) ?*Node {
        return event.activeElement(self);
    }

    /// The focused element, or null when focus is on the document root/body.
    pub fn focusedElement(self: *const Document) ?*Node {
        return self.active_element;
    }

    /// Moves keyboard focus. Returns false when the node is not a connected,
    /// rendered, `focusable` element.
    pub fn focus(self: *Document, node: *Node) bool {
        return event.focus(self, node);
    }

    /// Clears keyboard focus, firing blur/focusout on the active element.
    pub fn blur(self: *Document) void {
        event.blur(self);
    }

    /// Moves focus to the next or previous tab stop.
    pub fn moveFocus(self: *Document, direction: FocusDirection) bool {
        return event.moveFocus(self, direction);
    }

    /// Dispatches a synthetic key event. The target is `activeElement()`.
    pub fn dispatchKey(self: *Document, key: Key, mods: Modifiers) KeyEvent {
        return event.dispatchKey(self, key, mods);
    }

    /// Dispatches an existing event object, resetting its propagation flags.
    pub fn dispatchEvent(self: *Document, key_event: *KeyEvent) void {
        event.dispatchEvent(self, key_event);
    }

    /// Dispatches a mouse event at an already hit-tested target. A non-canceled
    /// press focuses the nearest focusable ancestor, or blurs.
    pub fn dispatchMouse(self: *Document, target: *Node, mouse_event: *MouseEvent) void {
        event.dispatchMouse(self, target, mouse_event);
    }

    pub fn measureText(self: *const Document, text: []const u8) usize {
        var width: usize = 0;
        var offset: usize = 0;
        while (offset < text.len) {
            const decoded = decodeAt(text, offset);
            if (decoded.cp == '\t') {
                const next = nextTabStop(width, self.tab_size);
                width = next;
            } else {
                width += self.measure_width(decoded.cp);
            }
            offset += decoded.len;
        }
        return width;
    }
};

pub const Node = struct {
    kind: union(enum) {
        element: Element,
        text: Text,
    },
    parent: ?*Node = null,
    // The first child's `prev` points at the last child.
    first_child: ?*Node = null,
    next: ?*Node = null,
    prev: ?*Node = null,
    document: *Document,
    /// Event listeners in registration order. Removing marks an entry removed
    /// instead of shifting the list, so an in-progress dispatch stays valid.
    /// The backing list is arena-owned and reused when the node is recycled.
    listeners: std.ArrayList(event.ListenerEntry) = .empty,
    /// Set while this node sits in the document's free list. A widget that
    /// retains a node pointer across frames can check this before using it.
    recycled: bool = false,
    /// Identity assigned by the document. Zero while recycled.
    serial: u64 = 0,

    /// Registers a listener. Adding is O(1) amortized; dispatch walks the list
    /// in registration order.
    pub fn addEventListener(self: *Node, listener: Listener) !void {
        try self.listeners.append(
            self.document.arena.allocator(),
            .{ .listener = listener },
        );
    }

    /// Removes the first listener equal to `listener`; returns whether one was
    /// found. The entry stays in the list as a tombstone so a dispatch that is
    /// already walking it remains safe and does not invoke it.
    pub fn removeEventListener(self: *Node, listener: Listener) bool {
        for (self.listeners.items) |*entry| {
            if (entry.removed) continue;
            if (entry.listener.eql(listener)) {
                entry.removed = true;
                return true;
            }
        }
        return false;
    }

    /// Makes this node the active element when it is focusable and connected.
    pub fn focus(self: *Node) bool {
        return self.document.focus(self);
    }

    /// Clears focus when this node is the active element.
    pub fn blur(self: *Node) void {
        if (self.document.active_element == self) self.document.blur();
    }

    /// Whether this node can take focus right now.
    pub fn isFocusable(self: *const Node) bool {
        return event.canFocus(self.document, self);
    }

    pub fn isElement(self: *const Node) bool {
        return switch (self.kind) {
            .element => true,
            .text => false,
        };
    }

    pub fn asElement(self: *Node) *Element {
        return switch (self.kind) {
            .element => |*element| element,
            .text => unreachable,
        };
    }

    pub fn asText(self: *Node) *Text {
        return switch (self.kind) {
            .text => |*text| text,
            .element => unreachable,
        };
    }

    /// Sets the paint-only style applied while this element is hovered, or
    /// clears it with `null`. Text nodes do not take hover styles (hit testing
    /// retargets their cells to the parent element). Hover is applied by the
    /// painter from the live DOM, so this needs no mutation notification and
    /// never invalidates layout.
    pub fn setHoverStyle(self: *Node, value: ?HoverStyle) void {
        switch (self.kind) {
            .element => |*element| element.hover_style = value,
            .text => {},
        }
    }

    /// Whether this node is in the current hover chain: the pointer target
    /// itself or one of its ancestors (CSS `:hover` semantics). Derived from
    /// `Document.hover_target` so it stays correct across reparenting and
    /// node reuse.
    pub fn isHovered(self: *const Node) bool {
        const target = self.document.hover_target orelse return false;
        var current: ?*Node = target;
        while (current) |node| : (current = node.parent) {
            if (node == self) return true;
        }
        return false;
    }

    /// The computed style for this node and its ancestor declarations. Walks
    /// to the root, so prefer box styles inside layout/paint hot paths.
    pub fn computedStyle(self: *const Node) style_mod.ComputedStyle {
        return self.document.computedStyle(self);
    }

    /// The element's computed `display`, including class declarations and its
    /// tag's initial value. `display` is not inherited; an ancestor
    /// `display: none` is checked by walking the chain.
    pub fn declaredDisplay(self: *const Node) style_mod.Display {
        return switch (self.kind) {
            .element => self.computedStyle().display,
            .text => .inline_,
        };
    }

    /// The inherited `visibility`, including class declarations.
    pub fn computedVisibility(self: *const Node) style_mod.Visibility {
        return self.computedStyle().visibility;
    }

    /// Re-points a text node without allocating. Used for retained gutter and
    /// status rows whose text is formatted into stable per-row buffers.
    pub fn setTextBorrowed(self: *Node, data: []const u8) void {
        switch (self.kind) {
            .text => |*text| text.data = data,
            .element => {},
        }
        self.document.notifyMutation(self, .text);
    }

    pub fn setStyle(self: *Node, value: Style) void {
        switch (self.kind) {
            .element => |*element| element.style = value,
            .text => |*text| {
                // Text nodes only paint; layout/text-flow properties are
                // extracted into the small text payload. The browser analogue
                // is a style object resolved to CSS class properties.
                text.paint = style_mod.paintStyleOf(value);
                text.paint_ref = null;
                text.flow = style_mod.textFlowOf(value);
            },
        }
        self.document.notifyMutation(self, .style);
    }

    /// Shares a paint style object with a text node (the editor's class-cache
    /// fast path). No allocation: the cache owns the style.
    pub fn setPaintRef(self: *Node, value: *const style_mod.PaintStyle) void {
        switch (self.kind) {
            .text => |*text| text.paint_ref = value,
            .element => {},
        }
        self.document.notifyMutation(self, .style);
    }

    /// The paint style that applies to this text node. Elements return null;
    /// their paint flow is merged from `element.style` by the painter.
    pub fn paintStyle(self: *const Node) ?*const style_mod.PaintStyle {
        return switch (self.kind) {
            .text => |*text| text.paint_ref orelse &text.paint,
            .element => null,
        };
    }

    /// The flow overrides carried by a text node.
    pub fn textFlow(self: *const Node) style_mod.TextFlow {
        return switch (self.kind) {
            .text => |text| text.flow,
            .element => .{},
        };
    }

    /// Element style. Text nodes carry paint/flow only; use `paintStyle`.
    pub fn style(self: *const Node) *const Style {
        return switch (self.kind) {
            .element => |*element| &element.style,
            .text => unreachable,
        };
    }

    pub fn firstChild(self: *const Node) ?*Node {
        return self.first_child;
    }

    pub fn lastChild(self: *const Node) ?*Node {
        const first = self.first_child orelse return null;
        return first.prev;
    }

    pub fn nextSibling(self: *const Node) ?*Node {
        return self.next;
    }

    pub fn previousSibling(self: *const Node) ?*Node {
        const parent = self.parent orelse return null;
        if (parent.first_child == self) return null;
        return self.prev;
    }

    pub fn appendChild(self: *Node, child: *Node) !*Node {
        if (child == self or isAncestorOf(child, self)) return error.Cycle;
        // A move keeps focus: the node is reattached before anything renders.
        if (child.parent) |parent| _ = parent.detachChild(child, false);

        child.parent = self;
        child.next = null;
        if (self.first_child) |first| {
            const last = first.prev.?;
            last.next = child;
            child.prev = last;
            first.prev = child;
        } else {
            self.first_child = child;
            child.prev = child;
        }
        self.document.notifyMutation(child, .tree);
        return child;
    }

    pub fn insertBefore(self: *Node, child: *Node, reference: ?*Node) !*Node {
        const ref = reference orelse return self.appendChild(child);
        if (ref.parent != self) return error.NotFound;
        if (child == self or isAncestorOf(child, self)) return error.Cycle;
        if (child == ref) return child;
        if (child.parent) |parent| _ = parent.detachChild(child, false);

        child.parent = self;
        child.next = ref;
        child.prev = ref.prev;
        if (self.first_child == ref) {
            self.first_child = child;
        } else {
            ref.prev.?.next = child;
        }
        ref.prev = child;
        self.document.notifyMutation(child, .tree);
        return child;
    }

    pub fn removeChild(self: *Node, child: *Node) *Node {
        return self.detachChild(child, true);
    }

    /// Unlinks `child`. `clear_focus` is false only for the remove/reinsert
    /// pair inside `appendChild`/`insertBefore`, where the node stays in the
    /// document and keeps focus.
    fn detachChild(self: *Node, child: *Node, clear_focus: bool) *Node {
        std.debug.assert(child.parent == self);
        // Focus does not survive leaving the tree, and no blur fires for an
        // element that is already gone (Lightpanda and TermDOM both do this).
        if (clear_focus) event.clearFocusWithin(self.document, child);
        // Hover is pointer-derived paint state; a detached target must not
        // survive into the free list (or a subsequent move/reinsert).
        self.document.clearHoverWithin(child);
        const first = self.first_child.?;
        if (child == first) {
            if (child.next) |next| {
                next.prev = child.prev;
                self.first_child = next;
            } else {
                self.first_child = null;
            }
        } else {
            child.prev.?.next = child.next;
            if (child.next) |next| {
                next.prev = child.prev;
            } else {
                first.prev = child.prev;
            }
        }
        child.parent = null;
        child.next = null;
        child.prev = null;
        self.document.notifyMutation(child, .tree);
        return child;
    }

    pub fn remove(self: *Node) void {
        if (self.parent) |parent| _ = parent.removeChild(self);
    }

    /// Destroys every child through the document's free list. Used by retained
    /// part roots that rebuild their own subtree in place.
    pub fn clearChildren(self: *Node) void {
        self.document.destroyChildren(self);
    }

    pub fn appendText(self: *Node, data: []const u8) !*Node {
        return self.appendChild(try self.document.createText(data));
    }

    pub fn setTextContent(self: *Node, data: []const u8) !void {
        switch (self.kind) {
            .text => |*text| {
                const allocator = self.document.arena.allocator();
                text.data = try allocator.dupe(u8, data);
                self.document.notifyMutation(self, .text);
            },
            .element => {
                while (self.first_child) |child| _ = self.removeChild(child);
                if (data.len != 0) _ = try self.appendText(data);
                self.document.notifyMutation(self, .tree);
            },
        }
    }

    pub fn textContentAlloc(self: *Node, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try appendTextContent(self, allocator, &out);
        return out.toOwnedSlice(allocator);
    }

    fn appendTextContent(node: *Node, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        switch (node.kind) {
            .text => |text| try out.appendSlice(allocator, text.data),
            .element => {
                var child = node.first_child;
                while (child) |current| : (child = current.next) {
                    try appendTextContent(current, allocator, out);
                }
            },
        }
    }

    pub fn setAttribute(self: *Node, name: []const u8, value: []const u8) !void {
        const allocator = self.document.arena.allocator();
        const element = self.asElement();
        const key = try allocator.dupe(u8, name);
        const val = try allocator.dupe(u8, value);
        try element.attributes.put(allocator, key, val);
        self.document.notifyMutation(self, .style);
    }

    pub fn getAttribute(self: *const Node, name: []const u8) ?[]const u8 {
        return switch (self.kind) {
            .element => |element| element.attributes.get(name),
            .text => null,
        };
    }

    pub fn removeAttribute(self: *Node, name: []const u8) void {
        switch (self.kind) {
            .element => |*element| _ = element.attributes.remove(name),
            .text => {},
        }
        self.document.notifyMutation(self, .style);
    }

    pub fn setPointerEvents(self: *Node, enabled: bool) void {
        if (self.kind != .element) return;
        self.asElement().pointer_events = enabled;
    }

    /// Replaces the element's class list. Class names are enum values (or
    /// plain integers) indexing the document's stylesheet.
    pub fn setClasses(self: *Node, classes: anytype) !void {
        switch (self.kind) {
            .element => |*element| {
                const allocator = self.document.arena.allocator();
                element.classes.clearRetainingCapacity();
                if (comptime isTuplePointer(@TypeOf(classes))) {
                    inline for (classes.*) |class| try appendClassId(element, allocator, class);
                } else {
                    for (classes) |class| try appendClassId(element, allocator, class);
                }
            },
            .text => return,
        }
        self.document.notifyMutation(self, .style);
    }

    pub fn addClass(self: *Node, class: anytype) !void {
        const id = css.classId(class);
        switch (self.kind) {
            .element => |*element| {
                if (hasClassId(element, id)) return;
                try element.classes.append(self.document.arena.allocator(), id);
            },
            .text => return,
        }
        self.document.notifyMutation(self, .style);
    }

    pub fn hasClass(self: *const Node, class: anytype) bool {
        const id = css.classId(class);
        return switch (self.kind) {
            .element => |element| hasClassId(&element, id),
            .text => false,
        };
    }

    pub fn removeClass(self: *Node, class: anytype) void {
        const id = css.classId(class);
        switch (self.kind) {
            .element => |*element| {
                var i: usize = 0;
                while (i < element.classes.items.len) {
                    if (element.classes.items[i] == id) {
                        _ = element.classes.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
            },
            .text => return,
        }
        self.document.notifyMutation(self, .style);
    }

    pub fn toggleClass(self: *Node, class: anytype) !void {
        const id = css.classId(class);
        if (self.hasClass(id)) {
            self.removeClass(id);
        } else {
            try self.addClass(id);
        }
    }
};

fn appendClassId(element: *Element, allocator: std.mem.Allocator, class: anytype) !void {
    const id = css.classId(class);
    if (hasClassId(element, id)) return;
    try element.classes.append(allocator, id);
}

fn isTuplePointer(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (pointer.size != .one) return false;
            switch (@typeInfo(pointer.child)) {
                .@"struct" => |inner| return inner.is_tuple,
                else => return false,
            }
        },
        else => return false,
    }
}

fn hasClassId(element: *const Element, id: u16) bool {
    for (element.classes.items) |item| {
        if (item == id) return true;
    }
    return false;
}

/// HTML-ish initial display for the small tag set.
pub fn defaultDisplay(tag: Tag) style_mod.Display {
    return switch (tag) {
        .div, .generic => .block,
        .span => .inline_,
    };
}

pub const ChildIterator = struct {
    next_node: ?*Node,

    pub fn next(self: *ChildIterator) ?*Node {
        const node = self.next_node orelse return null;
        self.next_node = node.next;
        return node;
    }
};

pub fn children(node: *const Node) ChildIterator {
    return .{ .next_node = node.first_child };
}

fn isAncestorOf(ancestor: *Node, node: *Node) bool {
    var current: ?*Node = node;
    while (current) |n| {
        if (n == ancestor) return true;
        current = n.parent;
    }
    return false;
}

pub fn defaultMeasureWidth(cp: u21) u2 {
    _ = cp;
    return 1;
}

const Decoded = struct { cp: u21, len: usize };

pub fn decodeAt(text: []const u8, offset: usize) Decoded {
    if (offset >= text.len) return .{ .cp = 0, .len = 0 };
    const len = std.unicode.utf8ByteSequenceLength(text[offset]) catch return .{ .cp = text[offset], .len = 1 };
    if (offset + len > text.len) return .{ .cp = text[offset], .len = 1 };
    const cp = std.unicode.utf8Decode(text[offset .. offset + len]) catch return .{ .cp = text[offset], .len = 1 };
    return .{ .cp = cp, .len = len };
}

pub fn nextTabStop(column: usize, tab_size: usize) usize {
    const size = @max(tab_size, 1);
    return column + size - column % size;
}

test "Node links: append, insert, remove, last child" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const a = try doc.createText("a");
    const b = try doc.createText("b");
    const c = try doc.createText("c");

    _ = try root.appendChild(a);
    _ = try root.appendChild(c);
    _ = try root.insertBefore(b, c);

    try std.testing.expectEqual(a, root.firstChild().?);
    try std.testing.expectEqual(c, root.lastChild().?);
    try std.testing.expectEqual(b, a.nextSibling().?);
    try std.testing.expectEqual(a, b.previousSibling().?);
    try std.testing.expectEqual(c, b.nextSibling().?);

    _ = root.removeChild(b);
    try std.testing.expectEqual(c, a.nextSibling().?);
    try std.testing.expectEqual(a, c.previousSibling().?);
    try std.testing.expectEqual(c, root.lastChild().?);
    try std.testing.expect(b.parent == null);

    _ = root.removeChild(c);
    try std.testing.expectEqual(a, root.lastChild().?);

    _ = root.removeChild(a);
    try std.testing.expect(root.firstChild() == null);
    try std.testing.expect(root.lastChild() == null);
}

test "Node: moving a child reparents it" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const one = try doc.createElement(.div);
    const two = try doc.createElement(.div);
    const child = try doc.createText("x");

    _ = try one.appendChild(child);
    _ = try two.appendChild(child);
    try std.testing.expectEqual(two, child.parent.?);
    try std.testing.expect(one.firstChild() == null);
}

test "Document: clear drops the tree and focus but keeps capacity" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const child = try doc.createElement(.div);
    child.asElement().focusable = true;
    _ = try root.appendChild(child);
    doc.setRoot(root);
    try std.testing.expect(doc.focus(child));
    try std.testing.expectEqual(child, doc.activeElement().?);

    doc.clear();
    try std.testing.expect(doc.root == null);
    try std.testing.expect(doc.active_element == null);

    const next_root = try doc.createElement(.div);
    doc.setRoot(next_root);
    try std.testing.expectEqual(next_root, doc.root.?);
    try std.testing.expect(doc.activeElement() != null);
}

test "Node: text content and attributes" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    _ = try root.appendChild(try doc.createText("hello "));
    const span = try doc.createElement(.span);
    _ = try span.appendChild(try doc.createText("world"));
    _ = try root.appendChild(span);

    const text = try root.textContentAlloc(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello world", text);

    try root.setAttribute("id", "root");
    try std.testing.expectEqualStrings("root", root.getAttribute("id").?);
    const TestClass = enum(u16) { a };
    try root.addClass(TestClass.a);
    try std.testing.expect(root.hasClass(TestClass.a));
    try root.toggleClass(TestClass.a);
    try std.testing.expect(!root.hasClass(TestClass.a));

    try root.setTextContent("plain");
    const plain = try root.textContentAlloc(allocator);
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("plain", plain);
    try std.testing.expect(!root.firstChild().?.isElement());
}

test "Node: cycle is rejected" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const parent = try doc.createElement(.div);
    const child = try doc.createElement(.div);
    _ = try parent.appendChild(child);
    try std.testing.expectError(error.Cycle, child.appendChild(parent));
}

test "Document: hover target covers the inclusive ancestor chain" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const parent = try doc.createElement(.div);
    const child = try doc.createElement(.div);
    const sibling = try doc.createElement(.div);
    _ = try root.appendChild(parent);
    _ = try parent.appendChild(child);
    _ = try root.appendChild(sibling);
    doc.setRoot(root);

    try std.testing.expect(doc.setHoverTarget(child));
    try std.testing.expectEqual(child, doc.hoverTarget().?);
    try std.testing.expect(child.isHovered());
    try std.testing.expect(parent.isHovered());
    try std.testing.expect(root.isHovered());
    try std.testing.expect(!sibling.isHovered());

    // Re-setting the same target is a no-op.
    try std.testing.expect(!doc.setHoverTarget(child));

    try std.testing.expect(doc.clearHover());
    try std.testing.expect(doc.hoverTarget() == null);
    try std.testing.expect(!child.isHovered());
    try std.testing.expect(!parent.isHovered());
}

test "Document: detaching the hovered subtree clears the target" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const parent = try doc.createElement(.div);
    const child = try doc.createElement(.div);
    _ = try root.appendChild(parent);
    _ = try parent.appendChild(child);
    doc.setRoot(root);

    try std.testing.expect(doc.setHoverTarget(child));
    _ = parent.removeChild(child);
    try std.testing.expect(doc.hoverTarget() == null);
    try std.testing.expect(!child.isHovered());

    // Detaching a sibling leaves the target alone.
    const other = try doc.createElement(.div);
    _ = try root.appendChild(other);
    try std.testing.expect(doc.setHoverTarget(parent));
    _ = root.removeChild(other);
    try std.testing.expectEqual(parent, doc.hoverTarget().?);
}

test "Document: clear, destroy and root changes drop a detached hover target" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    const parent = try doc.createElement(.div);
    const child = try doc.createElement(.div);
    _ = try root.appendChild(parent);
    _ = try parent.appendChild(child);
    doc.setRoot(root);

    try std.testing.expect(doc.setHoverTarget(child));
    doc.destroy(child);
    try std.testing.expect(doc.hoverTarget() == null);

    const next = try doc.createElement(.div);
    _ = try parent.appendChild(next);
    try std.testing.expect(doc.setHoverTarget(next));
    const replacement = try doc.createElement(.div);
    doc.setRoot(replacement);
    try std.testing.expect(doc.hoverTarget() == null);

    _ = try replacement.appendChild(try doc.createText("x"));
    try std.testing.expect(doc.setHoverTarget(replacement));
    doc.clear();
    try std.testing.expect(doc.hoverTarget() == null);
}

test "Document: a recycled node does not keep its hover style" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    doc.setRoot(root);
    const first = try doc.createElement(.div);
    first.setHoverStyle(.{ .background = .{ .r = 1, .g = 2, .b = 3 } });
    try std.testing.expect(first.asElement().hover_style != null);
    doc.destroy(first);

    const second = try doc.createElement(.div);
    try std.testing.expect(second.asElement().hover_style == null);
}

test "Document: class styles survive clear and nodes hold integer IDs" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const Class = enum(u16) { panel, selected };
    const base = try doc.registerSheet(.{ .styles = &.{
        .{ .color = .{ .r = 1, .g = 2, .b = 3 } },
        .{ .bold = true },
    } });
    try std.testing.expectEqual(@as(u16, 0), base);

    const root = try doc.createElement(.div);
    doc.setRoot(root);
    const child = try doc.createElement(.div);
    try child.setClasses(&.{ Class.panel, Class.selected });
    _ = try root.appendChild(child);
    try std.testing.expect(child.hasClass(Class.panel));
    try std.testing.expectEqual(@as(usize, 2), child.asElement().classes.items.len);

    doc.clear();
    // The stylesheet is document state, like a webpage's stylesheet.
    try std.testing.expect(doc.classStyle(@backingInt(Class.selected)) != null);
    try std.testing.expectEqual(@as(?bool, true), doc.classStyle(@backingInt(Class.selected)).?.bold);

    const next = try doc.createElement(.div);
    doc.setRoot(next);
    try next.addClass(Class.selected);
    try std.testing.expect(next.hasClass(Class.selected));
    next.removeClass(Class.selected);
    try std.testing.expect(!next.hasClass(Class.selected));
}

test "Document: a recycled node receives a new serial" {
    const allocator = std.testing.allocator;
    var doc = try Document.init(allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    doc.setRoot(root);
    const child = try doc.createElement(.div);
    _ = try root.appendChild(child);
    const old_serial = child.serial;
    try std.testing.expect(old_serial != 0);

    doc.destroy(child);
    try std.testing.expect(child.recycled);

    const reused = try doc.createElement(.div);
    try std.testing.expectEqual(child, reused);
    try std.testing.expect(!reused.recycled);
    try std.testing.expect(reused.serial != old_serial);
}
