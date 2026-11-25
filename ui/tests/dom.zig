const std = @import("std");
const ui = @import("ui");
const MouseEvent = ui.dom.MouseEvent;
const Document = ui.dom.Document;
const Node = ui.dom.Node;

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

test "Document: destroying the focused root clears the fallback before node reuse" {
    var doc = try Document.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    root.asElement().focusable = true;
    doc.setRoot(root);
    var press = MouseEvent{ .kind = .down, .button = .left };
    doc.dispatchMouse(root, &press);
    var key = doc.dispatchKey(.enter, .{});
    try std.testing.expectEqual(root, key.target.?);

    doc.destroy(root);
    const replacement = try doc.createElement(.div);
    try std.testing.expect(doc.focusedElement() == null);
    try std.testing.expect(doc.focus_start == null);
    try std.testing.expect(doc.activeElement() == null);
    doc.dispatchEvent(&key);
    try std.testing.expect(key.target == null);
    doc.setRoot(replacement);
    try std.testing.expectEqual(replacement, doc.dispatchKey(.enter, .{}).target.?);
}

test "Node: moving a focused subtree keeps focus only within the connected tree" {
    var doc = try Document.init(std.testing.allocator, .{ .cols = 10, .rows = 2 });
    defer doc.deinit();

    const root = try doc.createElement(.div);
    doc.setRoot(root);
    const attached = try root.appendChild(try doc.createElement(.div));
    const detached = try doc.createElement(.div);
    const marker = try detached.appendChild(try doc.createElement(.div));
    const branch = try doc.createElement(.div);
    const control = try branch.appendChild(try doc.createElement(.div));
    control.asElement().focusable = true;
    const readonly: *const Node = control;

    for ([_]?*Node{ null, marker }) |reference| {
        _ = try root.appendChild(branch);
        var press = MouseEvent{ .kind = .down, .button = .left };
        doc.dispatchMouse(control, &press);
        _ = try attached.appendChild(branch);
        try std.testing.expect(readonly.isFocusable());
        try std.testing.expectEqual(control, doc.focusedElement().?);
        try std.testing.expectEqual(control, doc.focus_start.?);

        _ = try detached.insertBefore(branch, reference);
        try std.testing.expect(!readonly.isFocusable());
        try std.testing.expect(doc.focusedElement() == null);
        try std.testing.expect(doc.focus_start == null);
        try std.testing.expectEqual(root, doc.dispatchKey(.enter, .{}).target.?);
    }
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
