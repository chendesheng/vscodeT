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
const style_mod = @import("style.zig");

pub const Style = style_mod.Style;
pub const Rect = style_mod.Rect;

pub const Tag = enum { div, span, generic };

pub const Text = struct {
    data: []const u8,
    style: Style = .{},
    rect: Rect = .{},
};

pub const Element = struct {
    tag: Tag,
    attributes: std.StringHashMapUnmanaged([]const u8) = .empty,
    classes: std.ArrayList([]const u8) = .empty,
    style: Style = .{},
    rect: Rect = .{},
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
    cols: usize,
    rows: usize,
    tab_size: usize,
    measure_width: *const fn (u21) u2,
    observer: ?MutationObserver = null,

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
        self.arena.deinit();
    }

    pub fn createElement(self: *Document, tag: Tag) !*Node {
        const allocator = self.arena.allocator();
        const node = try allocator.create(Node);
        node.* = .{
            .kind = .{ .element = .{ .tag = tag } },
            .document = self,
        };
        return node;
    }

    pub fn createText(self: *Document, data: []const u8) !*Node {
        const allocator = self.arena.allocator();
        const node = try allocator.create(Node);
        node.* = .{
            .kind = .{ .text = .{ .data = try allocator.dupe(u8, data) } },
            .document = self,
        };
        return node;
    }

    pub fn setRoot(self: *Document, root: *Node) void {
        root.parent = null;
        self.root = root;
        self.notifyMutation(root, .tree);
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

    pub fn setStyle(self: *Node, value: Style) void {
        switch (self.kind) {
            .element => |*element| element.style = value,
            .text => |*text| text.style = value,
        }
        self.document.notifyMutation(self, .style);
    }

    pub fn style(self: *const Node) *const Style {
        return switch (self.kind) {
            .element => |*element| &element.style,
            .text => |*text| &text.style,
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
        if (child.parent) |parent| _ = parent.removeChild(child);

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
        if (child.parent) |parent| _ = parent.removeChild(child);

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
        std.debug.assert(child.parent == self);
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

    pub fn addClass(self: *Node, class: []const u8) !void {
        if (self.hasClass(class)) return;
        const allocator = self.document.arena.allocator();
        const element = self.asElement();
        try element.classes.append(allocator, try allocator.dupe(u8, class));
        self.document.notifyMutation(self, .style);
    }

    pub fn hasClass(self: *const Node, class: []const u8) bool {
        return switch (self.kind) {
            .element => |element| blk: {
                for (element.classes.items) |item| {
                    if (std.mem.eql(u8, item, class)) break :blk true;
                }
                break :blk false;
            },
            .text => false,
        };
    }

    pub fn removeClass(self: *Node, class: []const u8) void {
        switch (self.kind) {
            .element => |*element| {
                var i: usize = 0;
                while (i < element.classes.items.len) {
                    if (std.mem.eql(u8, element.classes.items[i], class)) {
                        _ = element.classes.orderedRemove(i);
                    } else {
                        i += 1;
                    }
                }
            },
            .text => {},
        }
        self.document.notifyMutation(self, .style);
    }

    pub fn toggleClass(self: *Node, class: []const u8) !void {
        if (self.hasClass(class)) {
            self.removeClass(class);
        } else {
            try self.addClass(class);
        }
    }
};

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
    try root.addClass("a");
    try std.testing.expect(root.hasClass("a"));
    try root.toggleClass("a");
    try std.testing.expect(!root.hasClass("a"));

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
