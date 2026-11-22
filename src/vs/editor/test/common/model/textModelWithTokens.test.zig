// Port of the indent-guide suite from
// `src/vs/editor/test/common/model/textModelWithTokens.test.ts`.
//
// The upstream file also covers bracket-pair tokenization; those suites live
// next to the bracket-pair model part (`bracketPairColorizer/`). This file
// keeps the upstream basename so the remaining suites can be added here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const TestModel = @import("../port/testSupport.zig").TestModel;
const GuidesTextModelPart = @import("../../../common/model/guidesTextModelPart.zig").GuidesTextModelPart;

const ExpectedGuide = struct {
    guides: usize,
    start: usize,
    end: usize,
    indent: usize,
    text: []const u8,
};

fn assertIndentGuides(allocator: Allocator, expected: []const ExpectedGuide, indent_size: usize) !void {
    var text = ArrayList(u8).init(allocator);
    defer text.deinit();
    for (expected, 0..) |line, index| {
        if (index > 0) try text.append('\n');
        try text.appendSlice(line.text);
    }

    const language_id = "testLang";
    var test_model = try TestModel.init(allocator, text.items, language_id);
    defer test_model.deinit();
    test_model.model.updateOptions(.{
        .tabSize = null,
        .indentSize = .{ .number = @intCast(indent_size) },
        .insertSpaces = null,
        .trimAutoWhitespace = null,
        .bracketColorizationOptions = null,
    });

    var guides = GuidesTextModelPart.init(test_model.model, test_model.languageService);
    defer guides.dispose();

    const line_count = test_model.model.getLineCount();
    const actual_indents = try guides.getLinesIndentGuides(allocator, 1, line_count);
    defer allocator.free(actual_indents);

    for (expected, 0..) |line, index| {
        const line_number = index + 1;
        const active = try guides.getActiveIndentGuide(line_number, 1, line_count);
        try std.testing.expectEqual(line.guides, actual_indents[index]);
        try std.testing.expectEqual(line.start, active.startLineNumber);
        try std.testing.expectEqual(line.end, active.endLineNumber);
        try std.testing.expectEqual(line.indent, active.indent);

        var content = try test_model.model.getLineContent(line_number);
        defer content.deinit();
        try std.testing.expectEqualStrings(line.text, content.items);
    }
}

test "getLineIndentGuide one level 2" {
    try assertIndentGuides(std.testing.allocator, &.{
        .{ .guides = 0, .start = 2, .end = 4, .indent = 1, .text = "A" },
        .{ .guides = 1, .start = 2, .end = 4, .indent = 1, .text = "  A" },
        .{ .guides = 1, .start = 2, .end = 4, .indent = 1, .text = "  A" },
        .{ .guides = 1, .start = 2, .end = 4, .indent = 1, .text = "  A" },
    }, 2);
}

test "getLineIndentGuide two levels" {
    try assertIndentGuides(std.testing.allocator, &.{
        .{ .guides = 0, .start = 2, .end = 5, .indent = 1, .text = "A" },
        .{ .guides = 1, .start = 2, .end = 5, .indent = 1, .text = "  A" },
        .{ .guides = 1, .start = 4, .end = 5, .indent = 2, .text = "  A" },
        .{ .guides = 2, .start = 4, .end = 5, .indent = 2, .text = "    A" },
        .{ .guides = 2, .start = 4, .end = 5, .indent = 2, .text = "    A" },
    }, 2);
}

test "getLineIndentGuide three levels" {
    try assertIndentGuides(std.testing.allocator, &.{
        .{ .guides = 0, .start = 2, .end = 4, .indent = 1, .text = "A" },
        .{ .guides = 1, .start = 3, .end = 4, .indent = 2, .text = "  A" },
        .{ .guides = 2, .start = 4, .end = 4, .indent = 3, .text = "    A" },
        .{ .guides = 3, .start = 4, .end = 4, .indent = 3, .text = "      A" },
        .{ .guides = 0, .start = 5, .end = 5, .indent = 0, .text = "A" },
    }, 2);
}

test "getLineIndentGuide decreasing indent" {
    try assertIndentGuides(std.testing.allocator, &.{
        .{ .guides = 2, .start = 1, .end = 1, .indent = 2, .text = "    A" },
        .{ .guides = 1, .start = 1, .end = 1, .indent = 2, .text = "  A" },
        .{ .guides = 0, .start = 1, .end = 2, .indent = 1, .text = "A" },
    }, 2);
}

test "getLineIndentGuide Java" {
    try assertIndentGuides(std.testing.allocator, &.{
        .{ .guides = 0, .start = 2, .end = 9, .indent = 1, .text = "class A {" },
        .{ .guides = 1, .start = 3, .end = 4, .indent = 2, .text = "  void foo() {" },
        .{ .guides = 2, .start = 3, .end = 4, .indent = 2, .text = "    console.log(1);" },
        .{ .guides = 2, .start = 3, .end = 4, .indent = 2, .text = "    console.log(2);" },
        .{ .guides = 1, .start = 3, .end = 4, .indent = 2, .text = "  }" },
        .{ .guides = 1, .start = 2, .end = 9, .indent = 1, .text = "" },
        .{ .guides = 1, .start = 8, .end = 8, .indent = 2, .text = "  void bar() {" },
        .{ .guides = 2, .start = 8, .end = 8, .indent = 2, .text = "    console.log(3);" },
        .{ .guides = 1, .start = 8, .end = 8, .indent = 2, .text = "  }" },
        .{ .guides = 0, .start = 2, .end = 9, .indent = 1, .text = "}" },
        .{ .guides = 0, .start = 12, .end = 12, .indent = 1, .text = "interface B {" },
        .{ .guides = 1, .start = 12, .end = 12, .indent = 1, .text = "  void bar();" },
        .{ .guides = 0, .start = 12, .end = 12, .indent = 1, .text = "}" },
    }, 2);
}

test "getLineIndentGuide Javadoc" {
    try assertIndentGuides(std.testing.allocator, &.{
        .{ .guides = 0, .start = 2, .end = 3, .indent = 1, .text = "/**" },
        .{ .guides = 1, .start = 2, .end = 3, .indent = 1, .text = " * Comment" },
        .{ .guides = 1, .start = 2, .end = 3, .indent = 1, .text = " */" },
        .{ .guides = 0, .start = 5, .end = 6, .indent = 1, .text = "class A {" },
        .{ .guides = 1, .start = 5, .end = 6, .indent = 1, .text = "  void foo() {" },
        .{ .guides = 1, .start = 5, .end = 6, .indent = 1, .text = "  }" },
        .{ .guides = 0, .start = 5, .end = 6, .indent = 1, .text = "}" },
    }, 2);
}

test "getLineIndentGuide Whitespace" {
    try assertIndentGuides(std.testing.allocator, &.{
        .{ .guides = 0, .start = 2, .end = 7, .indent = 1, .text = "class A {" },
        .{ .guides = 1, .start = 2, .end = 7, .indent = 1, .text = "" },
        .{ .guides = 1, .start = 4, .end = 5, .indent = 2, .text = "  void foo() {" },
        .{ .guides = 2, .start = 4, .end = 5, .indent = 2, .text = "    " },
        .{ .guides = 2, .start = 4, .end = 5, .indent = 2, .text = "    return 1;" },
        .{ .guides = 1, .start = 4, .end = 5, .indent = 2, .text = "  }" },
        .{ .guides = 1, .start = 2, .end = 7, .indent = 1, .text = "      " },
        .{ .guides = 0, .start = 2, .end = 7, .indent = 1, .text = "}" },
    }, 2);
}

test "getLineIndentGuide Tabs" {
    try assertIndentGuides(std.testing.allocator, &.{
        .{ .guides = 0, .start = 2, .end = 7, .indent = 1, .text = "class A {" },
        .{ .guides = 1, .start = 2, .end = 7, .indent = 1, .text = "\t\t" },
        .{ .guides = 1, .start = 4, .end = 5, .indent = 2, .text = "\tvoid foo() {" },
        .{ .guides = 2, .start = 4, .end = 5, .indent = 2, .text = "\t \t//hello" },
        .{ .guides = 2, .start = 4, .end = 5, .indent = 2, .text = "\t    return 2;" },
        .{ .guides = 1, .start = 4, .end = 5, .indent = 2, .text = "  \t}" },
        .{ .guides = 1, .start = 2, .end = 7, .indent = 1, .text = "      " },
        .{ .guides = 0, .start = 2, .end = 7, .indent = 1, .text = "}" },
    }, 4);
}

test "getLineIndentGuide checker.ts" {
    try assertIndentGuides(std.testing.allocator, &.{
        .{ .guides = 0, .start = 1, .end = 1, .indent = 0, .text = "/// <reference path=\"binder.ts\"/>" },
        .{ .guides = 0, .start = 2, .end = 2, .indent = 0, .text = "" },
        .{ .guides = 0, .start = 3, .end = 3, .indent = 0, .text = "/* @internal */" },
        .{ .guides = 0, .start = 5, .end = 16, .indent = 1, .text = "namespace ts {" },
        .{ .guides = 1, .start = 5, .end = 16, .indent = 1, .text = "    let nextSymbolId = 1;" },
        .{ .guides = 1, .start = 5, .end = 16, .indent = 1, .text = "    let nextNodeId = 1;" },
        .{ .guides = 1, .start = 5, .end = 16, .indent = 1, .text = "    let nextMergeId = 1;" },
        .{ .guides = 1, .start = 5, .end = 16, .indent = 1, .text = "    let nextFlowId = 1;" },
        .{ .guides = 1, .start = 5, .end = 16, .indent = 1, .text = "" },
        .{ .guides = 1, .start = 11, .end = 15, .indent = 2, .text = "    export function getNodeId(node: Node): number {" },
        .{ .guides = 2, .start = 12, .end = 13, .indent = 3, .text = "        if (!node.id) {" },
        .{ .guides = 3, .start = 12, .end = 13, .indent = 3, .text = "            node.id = nextNodeId;" },
        .{ .guides = 3, .start = 12, .end = 13, .indent = 3, .text = "            nextNodeId++;" },
        .{ .guides = 2, .start = 12, .end = 13, .indent = 3, .text = "        }" },
        .{ .guides = 2, .start = 11, .end = 15, .indent = 2, .text = "        return node.id;" },
        .{ .guides = 1, .start = 11, .end = 15, .indent = 2, .text = "    }" },
        .{ .guides = 0, .start = 5, .end = 16, .indent = 1, .text = "}" },
    }, 4);
}

test "issue #8425 - Missing indentation lines for first level indentation" {
    try assertIndentGuides(std.testing.allocator, &.{
        .{ .guides = 1, .start = 2, .end = 3, .indent = 2, .text = "\tindent1" },
        .{ .guides = 2, .start = 2, .end = 3, .indent = 2, .text = "\t\tindent2" },
        .{ .guides = 2, .start = 2, .end = 3, .indent = 2, .text = "\t\tindent2" },
        .{ .guides = 1, .start = 2, .end = 3, .indent = 2, .text = "\tindent1" },
    }, 4);
}

test "issue #8952 - Indentation guide lines going through text on .yml file" {
    try assertIndentGuides(std.testing.allocator, &.{
        .{ .guides = 0, .start = 2, .end = 5, .indent = 1, .text = "properties:" },
        .{ .guides = 1, .start = 3, .end = 5, .indent = 2, .text = "    emailAddress:" },
        .{ .guides = 2, .start = 3, .end = 5, .indent = 2, .text = "        - bla" },
        .{ .guides = 2, .start = 5, .end = 5, .indent = 3, .text = "        - length:" },
        .{ .guides = 3, .start = 5, .end = 5, .indent = 3, .text = "            max: 255" },
        .{ .guides = 0, .start = 6, .end = 6, .indent = 0, .text = "getters:" },
    }, 4);
}

test "issue #11892 - Indent guides look funny" {
    try assertIndentGuides(std.testing.allocator, &.{
        .{ .guides = 0, .start = 2, .end = 7, .indent = 1, .text = "function test(base) {" },
        .{ .guides = 1, .start = 3, .end = 6, .indent = 2, .text = "\tswitch (base) {" },
        .{ .guides = 2, .start = 4, .end = 4, .indent = 3, .text = "\t\tcase 1:" },
        .{ .guides = 3, .start = 4, .end = 4, .indent = 3, .text = "\t\t\treturn 1;" },
        .{ .guides = 2, .start = 6, .end = 6, .indent = 3, .text = "\t\tcase 2:" },
        .{ .guides = 3, .start = 6, .end = 6, .indent = 3, .text = "\t\t\treturn 2;" },
        .{ .guides = 1, .start = 2, .end = 7, .indent = 1, .text = "\t}" },
        .{ .guides = 0, .start = 2, .end = 7, .indent = 1, .text = "}" },
    }, 4);
}

test "issue #12398 - Problem in indent guidelines" {
    try assertIndentGuides(std.testing.allocator, &.{
        .{ .guides = 2, .start = 2, .end = 2, .indent = 3, .text = "\t\t.bla" },
        .{ .guides = 3, .start = 2, .end = 2, .indent = 3, .text = "\t\t\tlabel(for)" },
        .{ .guides = 0, .start = 3, .end = 3, .indent = 0, .text = "include script" },
    }, 4);
}

test "issue #49173" {
    const allocator = std.testing.allocator;
    const source = "class A {\n" ++
        "\tpublic m1(): void {\n" ++
        "\t}\n" ++
        "\tpublic m2(): void {\n" ++
        "\t}\n" ++
        "\tpublic m3(): void {\n" ++
        "\t}\n" ++
        "\tpublic m4(): void {\n" ++
        "\t}\n" ++
        "\tpublic m5(): void {\n" ++
        "\t}\n" ++
        "}";
    var test_model = try TestModel.init(allocator, source, "testLang");
    defer test_model.deinit();

    var guides = GuidesTextModelPart.init(test_model.model, test_model.languageService);
    defer guides.dispose();
    const actual = try guides.getActiveIndentGuide(2, 4, 9);
    try std.testing.expectEqual(@as(usize, 2), actual.startLineNumber);
    try std.testing.expectEqual(@as(usize, 9), actual.endLineNumber);
    try std.testing.expectEqual(@as(usize, 1), actual.indent);
}

test "tweaks - no active" {
    try assertIndentGuides(std.testing.allocator, &.{
        .{ .guides = 0, .start = 1, .end = 1, .indent = 0, .text = "A" },
        .{ .guides = 0, .start = 2, .end = 2, .indent = 0, .text = "A" },
    }, 2);
}

test "tweaks - inside scope" {
    try assertIndentGuides(std.testing.allocator, &.{
        .{ .guides = 0, .start = 2, .end = 2, .indent = 1, .text = "A" },
        .{ .guides = 1, .start = 2, .end = 2, .indent = 1, .text = "  A" },
    }, 2);
}

test "tweaks - scope start" {
    try assertIndentGuides(std.testing.allocator, &.{
        .{ .guides = 0, .start = 2, .end = 2, .indent = 1, .text = "A" },
        .{ .guides = 1, .start = 2, .end = 2, .indent = 1, .text = "  A" },
        .{ .guides = 0, .start = 2, .end = 2, .indent = 1, .text = "A" },
    }, 2);
}

test "tweaks - empty line" {
    try assertIndentGuides(std.testing.allocator, &.{
        .{ .guides = 0, .start = 2, .end = 4, .indent = 1, .text = "A" },
        .{ .guides = 1, .start = 2, .end = 4, .indent = 1, .text = "  A" },
        .{ .guides = 1, .start = 2, .end = 4, .indent = 1, .text = "" },
        .{ .guides = 1, .start = 2, .end = 4, .indent = 1, .text = "  A" },
        .{ .guides = 0, .start = 2, .end = 4, .indent = 1, .text = "A" },
    }, 2);
}
