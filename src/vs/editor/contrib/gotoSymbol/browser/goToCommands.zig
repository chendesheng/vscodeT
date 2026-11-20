// Portable action metadata for
// `src/vs/editor/contrib/gotoSymbol/browser/goToCommands.ts`.
//
// The terminal workbench has no `IInstantiationService`/`ICodeEditorService`
// action target, so the contribution exposes the upstream action IDs, labels,
// preconditions, keybindings, titles and no-result messages as descriptors.
// `Workbench` supplies the run target and registers the commands.
const std = @import("std");
const editorExtensions = @import("../../../browser/editorExtensions.zig");

pub const Kind = enum {
    definition,
    declaration,
    type_definition,
    implementation,
    references,
};

pub const ActionDescriptor = struct {
    kind: Kind,
    id: []const u8,
    label: []const u8,
    description: []const u8 = "",
    precondition: ?[]const u8 = null,
    keybinding: ?editorExtensions.Keybinding = null,
    title: []const u8,
    no_result_template: []const u8,
    no_result_generic: []const u8,
    always_show_list: bool = false,
    compact_references: bool = true,
};

pub const definition = ActionDescriptor{
    .kind = .definition,
    .id = "editor.action.revealDefinition",
    .label = "Go to Definition",
    .description = "Go to the definition of the symbol at the cursor.",
    .precondition = "editorHasDefinitionProvider",
    .keybinding = .{ .key = "F12", .weight = .editor_contrib },
    .title = "Definitions",
    .no_result_template = "No definition found for '{s}'",
    .no_result_generic = "No definition found",
};

pub const declaration = ActionDescriptor{
    .kind = .declaration,
    .id = "editor.action.revealDeclaration",
    .label = "Go to Declaration",
    .description = "Go to the declaration of the symbol at the cursor.",
    .precondition = "editorHasDeclarationProvider",
    .title = "Declarations",
    .no_result_template = "No declaration found for '{s}'",
    .no_result_generic = "No declaration found",
};

pub const type_definition = ActionDescriptor{
    .kind = .type_definition,
    .id = "editor.action.goToTypeDefinition",
    .label = "Go to Type Definition",
    .description = "Go to the type definition of the symbol at the cursor.",
    .precondition = "editorHasTypeDefinitionProvider",
    .title = "Type Definitions",
    .no_result_template = "No type definition found for '{s}'",
    .no_result_generic = "No type definition found",
};

pub const implementation = ActionDescriptor{
    .kind = .implementation,
    .id = "editor.action.goToImplementation",
    .label = "Go to Implementations",
    .description = "Go to the implementations of the symbol at the cursor.",
    .precondition = "editorHasImplementationProvider",
    .keybinding = .{ .key = "F12", .ctrl = true, .weight = .editor_contrib },
    .title = "Implementations",
    .no_result_template = "No implementation found for '{s}'",
    .no_result_generic = "No implementation found",
};

pub const go_to_references = ActionDescriptor{
    .kind = .references,
    .id = "editor.action.goToReferences",
    .label = "Go to References",
    .description = "Go to the references of the symbol at the cursor.",
    .precondition = "editorHasReferenceProvider",
    .keybinding = .{ .key = "F12", .shift = true, .weight = .editor_contrib },
    .title = "References",
    .no_result_template = "No references found for '{s}'",
    .no_result_generic = "No references found",
    .compact_references = true,
};

pub const peek_references = ActionDescriptor{
    .kind = .references,
    .id = "editor.action.referenceSearch.trigger",
    .label = "Peek References",
    .description = "Show the references of the symbol at the cursor.",
    .precondition = "editorHasReferenceProvider",
    .title = "References",
    .no_result_template = "No references found for '{s}'",
    .no_result_generic = "No references found",
    .always_show_list = true,
    .compact_references = false,
};

pub const find_references = ActionDescriptor{
    .kind = .references,
    .id = "editor.action.findReferences",
    .label = "Find All References",
    .description = "Find all references of the symbol at the cursor.",
    .precondition = "editorHasReferenceProvider",
    .title = "References",
    .no_result_template = "No references found for '{s}'",
    .no_result_generic = "No references found",
    .always_show_list = true,
    .compact_references = false,
};

pub const actions = [_]ActionDescriptor{
    definition,
    declaration,
    type_definition,
    implementation,
    go_to_references,
    peek_references,
    find_references,
};

pub fn find(id: []const u8) ?*const ActionDescriptor {
    for (&actions) |*action| {
        if (std.mem.eql(u8, action.id, id)) return action;
    }
    return null;
}

test "goToCommands: descriptors keep upstream ids and keybindings" {
    try std.testing.expectEqualStrings("editor.action.revealDefinition", definition.id);
    try std.testing.expectEqualStrings("F12", definition.keybinding.?.key);
    try std.testing.expect(definition.keybinding.?.ctrl == false);
    try std.testing.expect(implementation.keybinding.?.ctrl);
    try std.testing.expect(go_to_references.keybinding.?.shift);
    try std.testing.expect(peek_references.always_show_list);
    try std.testing.expect(!peek_references.compact_references);
    try std.testing.expect(find("editor.action.findReferences") != null);
    try std.testing.expect(find("missing.action") == null);
}
