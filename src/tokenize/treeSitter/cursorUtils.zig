const ts = @import("tree-sitter");
const Node = ts.Node;
const Tree = ts.Tree;
const TreeCursor = ts.TreeCursor;

pub fn gotoNextSibling(newCursor: *TreeCursor, oldCursor: *TreeCursor) bool {
    const n = newCursor.gotoNextSibling();
    const o = oldCursor.gotoNextSibling();
    if (n != o) {
        unreachable;
    }
    return n and o;
}

pub fn gotoParent(newCursor: *TreeCursor, oldCursor: *TreeCursor) bool {
    const n = newCursor.gotoParent();
    const o = oldCursor.gotoParent();
    if (n != o) {
        unreachable;
    }
    return n and o;
}

pub fn gotoNthChild(newCursor: *TreeCursor, oldCursor: *TreeCursor, index: usize) bool {
    const n = newCursor.gotoFirstChild();
    const o = oldCursor.gotoFirstChild();
    if (n != o) {
        unreachable;
    }
    if (index == 0) {
        return n and o;
    }
    for (1..index + 1) |_| {
        const nn = newCursor.gotoNextSibling();
        const oo = oldCursor.gotoNextSibling();
        if (nn != oo) {
            unreachable;
        }
        if (!nn or !oo) {
            return false;
        }
    }
    return n and o;
}

pub fn nextSiblingOrParentSibling(newCursor: *TreeCursor, oldCursor: *TreeCursor) bool {
    while (true) {
        if (newCursor.node().nextSibling()) {
            return gotoNextSibling(newCursor, oldCursor);
        }
        if (newCursor.node().parent()) {
            gotoParent(newCursor, oldCursor);
        }
        if (newCursor.node().nextSibling() == null and newCursor.node().parent() == null) {
            break;
        }
    }
    return false;
}

pub fn getClosestPreviousNodes(cursor: *TreeCursor, tree: *Tree) ?Node {
    // Go up parents until the end of the parent is before the start of the current.
    const findPrev = tree.walk();
    findPrev.resetTo(cursor);

    const startingNode = cursor.node();
    while (true) {
        if (findPrev.node().previousSibling() and ((findPrev.node().endByte() - findPrev.node().startByte()) != 0)) {
            findPrev.gotoPreviousSibling();
        } else {
            while (!findPrev.node().previousSibling() and findPrev.node().parent()) {
                findPrev.gotoParent();
            }
            findPrev.gotoPreviousSibling();
        }
        if (!((findPrev.node().endByte() > startingNode.startByte()) //
            and (findPrev.node().parent() != null or findPrev.node().prevSibling() != null) //
            and (findPrev.node().id != startingNode.id)))
        {
            break;
        }
    }

    if ((findPrev.node().id != startingNode.id) and findPrev.node().endByte() <= startingNode.startByte()) {
        return findPrev.node();
    }
    return null;
}
