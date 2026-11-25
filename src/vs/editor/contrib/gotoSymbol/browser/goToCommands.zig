// Portable action metadata for
// `src/vs/editor/contrib/gotoSymbol/browser/goToCommands.ts`.
//
// The terminal workbench has no `IInstantiationService`/`ICodeEditorService`
// action target, so the contribution exposes the upstream action IDs, labels,
// preconditions, keybindings, titles and no-result messages as descriptors.
// The native host supplies resource opening and the active editor;
// the contribution owns provider results, picker lifetime and commands.
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

    /// Portable provider dispatch of SymbolNavigationAction's concrete subclasses.
    pub fn getLocationLinks(action: *const ActionDescriptor, arena: std.mem.Allocator, features: *@import("../../../common/services/languageFeaturesService.zig").LanguageFeaturesService, model: *@import("../../../common/model/textModel.zig").TextModel, position: @import("../../../common/core/position.zig").Position) ![]@import("../../../common/languages.zig").LocationLink {
        const symbols = @import("goToSymbol.zig");
        const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
        return switch (action.kind) {
            .definition => try symbols.getDefinitionsAtPosition(arena, &features.definition_provider, model, position, false, CancellationToken.None),
            .declaration => try symbols.getDeclarationsAtPosition(arena, &features.declaration_provider, model, position, false, CancellationToken.None),
            .type_definition => try symbols.getTypeDefinitionsAtPosition(arena, &features.type_definition_provider, model, position, false, CancellationToken.None),
            .implementation => try symbols.getImplementationsAtPosition(arena, &features.implementation_provider, model, position, false, CancellationToken.None),
            .references => try symbols.getReferencesAtPosition(arena, &features.reference_provider, model, position, action.compact_references, false, CancellationToken.None),
        };
    }
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

const platform_actions = @import("../../../../platform/actions/common/actions.zig");
const ServicesAccessor = @import("../../../../platform/instantiation/common/instantiation.zig").ServicesAccessor;
const QuickInputService = @import("../../../../platform/quickinput/browser/quickInputService.zig").QuickInputService;
const QuickPick = @import("../../../../platform/quickinput/browser/quickInput.zig").QuickPick;
const QuickPickItem = @import("../../../../platform/quickinput/common/quickInput.zig").QuickPickItem;
const Editor = @import("../../../browser/widget/codeEditor/codeEditorWidgetTerminal.zig").Editor;
const LanguageFeaturesService = @import("../../../common/services/languageFeaturesService.zig").LanguageFeaturesService;
const Position = @import("../../../common/core/position.zig").Position;
const references_model = @import("referencesModel.zig");
const ReferencesModel = references_model.ReferencesModel;
const std_uri = @import("../../../../base/common/stdUri.zig");
const strings = @import("../../../../base/common/strings.zig");
const Allocator = std.mem.Allocator;

/// Terminal adapter of SymbolNavigationAction.runEditorCommand. The native
/// picker is used instead of the browser peek widget; resource opening is
/// delegated to the window's code editor service boundary.
pub const SymbolNavigationActionHost = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    quick_input: *QuickInputService,
    language_features: *const ?*LanguageFeaturesService,
    host: struct {
        context: *anyopaque,
        active_editor: *const fn (*anyopaque) ?*Editor,
        workspace_root: *const fn (*anyopaque) ?[]const u8,
        find_open_editor: *const fn (*anyopaque, []const u8) ?*Editor,
        open_link: *const fn (*anyopaque, @import("../../../common/languages.zig").LocationLink) anyerror!void,
    },
    pending_references: ?*ReferencesModel = null,

    pub fn deinit(self: *SymbolNavigationActionHost) void {
        if (self.quick_input.handler_context == @as(*anyopaque, self)) self.quick_input.hide();
        self.arena.deinit();
    }

    fn cleanupReferencePicker(context: *anyopaque) void {
        const self: *SymbolNavigationActionHost = @ptrCast(@alignCast(context));
        self.pending_references = null;
    }

    pub fn actionDescriptors(self: *SymbolNavigationActionHost) [actions.len]platform_actions.Action2 {
        var result: [actions.len]platform_actions.Action2 = undefined;
        inline for (actions, 0..) |action, index| result[index] = self.actionDescriptor(action);
        return result;
    }

    fn actionDescriptor(self: *SymbolNavigationActionHost, comptime action: ActionDescriptor) platform_actions.Action2 {
        return .{
            .command = .{ .id = action.id, .title = action.label, .category = "Go", .tooltip = action.description },
            .f1 = true,
            .context = self,
            .run_fn = struct {
                fn run(context: *anyopaque, _: ServicesAccessor) !void {
                    const navigation: *SymbolNavigationActionHost = @ptrCast(@alignCast(context));
                    _ = navigation.runEditorCommand(&action) catch |err| {
                        if (navigation.host.active_editor(navigation.host.context)) |editor| editor.setMessage("Navigation failed: {s}", .{@errorName(err)});
                        return;
                    };
                }
            }.run,
        };
    }

    pub fn runEditorCommand(self: *SymbolNavigationActionHost, action: *const ActionDescriptor) !bool {
        const editor = self.host.active_editor(self.host.context) orelse return false;
        const features = self.language_features.* orelse return false;
        if (self.quick_input.isVisible()) self.quick_input.hide();

        self.pending_references = null;
        _ = self.arena.reset(.retain_capacity);
        const arena = self.arena.allocator();

        const model = editor.model;
        const position = editor.modelCursorPosition();
        const links = try action.getLocationLinks(arena, features, model, position);

        const references = try arena.create(ReferencesModel);
        references.* = try ReferencesModel.init(arena, links, action.title);
        if (references.references.len == 0) {
            self.setNoResultMessage(editor, action.kind, position);
            return false;
        }
        if (references.references.len == 1 and !action.always_show_list) {
            self.navigateToReference(&references.references[0]) catch |err| {
                editor.setMessage("Navigation failed: {s}", .{@errorName(err)});
                return false;
            };
            return true;
        }

        self.pending_references = references;
        self.showReferencePicker(editor, references, action) catch |err| {
            self.pending_references = null;
            editor.setMessage("References failed: {s}", .{@errorName(err)});
            return false;
        };
        return true;
    }

    fn showReferencePicker(
        self: *SymbolNavigationActionHost,
        editor: *Editor,
        references: *ReferencesModel,
        action: *const ActionDescriptor,
    ) !void {
        const arena = self.arena.allocator();
        const current_uri = try std_uri.resourceKey(arena, editor.model.uri());
        const current_reference = references.referenceAt(current_uri, editor.modelCursorPosition());

        var items = std.array_list.Managed(QuickPickItem).init(arena);
        var active_id: ?[]const u8 = null;
        var index: usize = 0;
        for (references.groups) |*group| {
            const path = pathForUri(arena, group.uri);
            const basename = std.fs.path.basename(path);
            const separator_label = try std.fmt.allocPrint(arena, "{s} ({d})", .{ basename, group.children.len });
            try items.append(.{ .separator = .{ .label = separator_label } });

            const root = self.host.workspace_root(self.host.context);
            const description = if (root) |value| @import("../../../../base/common/extpath.zig").relativeToRoot(path, value) orelse path else path;
            for (group.children) |*reference| {
                const id = try std.fmt.allocPrint(arena, "ref:{d}", .{index});
                const label = try self.referenceItemLabel(arena, reference);
                try items.append(.{ .item = .{
                    .id = id,
                    .label = label,
                    .description = description,
                } });
                if (current_reference != null and current_reference.? == reference) active_id = id;
                index += 1;
            }
        }

        self.quick_input.showPick(
            items.items,
            .{ .placeholder = action.title, .active_id = active_id, .cleanup = cleanupReferencePicker, .cleanup_context = self },
            onReferencePick,
            self,
        ) catch |err| {
            self.pending_references = null;
            editor.setMessage("References failed: {s}", .{@errorName(err)});
        };
    }

    fn referenceItemLabel(self: *SymbolNavigationActionHost, allocator: Allocator, reference: *const references_model.OneReference) ![]u8 {
        const path = pathForUri(allocator, reference.uri());
        const basename = std.fs.path.basename(path);
        const range = reference.range();
        var preview: []const u8 = "";
        if (self.host.find_open_editor(self.host.context, path)) |input| {
            const line = input.model.getLineContent(range.startLineNumber) catch null;
            if (line) |value| {
                var owned_line = value;
                defer owned_line.deinit();
                const trimmed = std.mem.trim(u8, owned_line.items, " \t\r");
                preview = try allocator.dupe(u8, strings.safeUtf8Prefix(trimmed, 60));
            }
        }
        if (preview.len > 0) {
            return std.fmt.allocPrint(allocator, "{s}:{d}:{d}  {s}", .{
                basename,
                range.startLineNumber,
                range.startColumn,
                preview,
            });
        }
        return std.fmt.allocPrint(allocator, "{s}:{d}:{d}", .{
            basename,
            range.startLineNumber,
            range.startColumn,
        });
    }

    fn navigateToReference(self: *SymbolNavigationActionHost, reference: *const references_model.OneReference) !void {
        try self.host.open_link(self.host.context, reference.link);
    }

    fn setNoResultMessage(self: *SymbolNavigationActionHost, editor: *Editor, kind: Kind, position: Position) void {
        _ = self;
        const word = editor.model.getWordAtPosition(position);
        if (word) |value| {
            var owned = value;
            defer owned.deinit();
            switch (kind) {
                .definition => editor.setMessage("No definition found for '{s}'", .{owned.word.items}),
                .declaration => editor.setMessage("No declaration found for '{s}'", .{owned.word.items}),
                .type_definition => editor.setMessage("No type definition found for '{s}'", .{owned.word.items}),
                .implementation => editor.setMessage("No implementation found for '{s}'", .{owned.word.items}),
                .references => editor.setMessage("No references found for '{s}'", .{owned.word.items}),
            }
        } else {
            switch (kind) {
                .definition => editor.setMessage("No definition found", .{}),
                .declaration => editor.setMessage("No declaration found", .{}),
                .type_definition => editor.setMessage("No type definition found", .{}),
                .implementation => editor.setMessage("No implementation found", .{}),
                .references => editor.setMessage("No references found", .{}),
            }
        }
    }

    fn onReferencePick(context: *anyopaque, picker: *QuickPick) anyerror!void {
        const self: *SymbolNavigationActionHost = @ptrCast(@alignCast(context));
        const model = self.pending_references orelse return;
        const item = picker.selectedItem() orelse picker.activeItem() orelse return;
        self.pending_references = null;
        const index = itemIndex(item.id, "ref:") orelse return;
        if (index >= model.references.len) return;
        self.navigateToReference(&model.references[index]) catch |err| {
            if (self.host.active_editor(self.host.context)) |editor| editor.setMessage("Navigation failed: {s}", .{@errorName(err)});
        };
    }
};

fn pathForUri(allocator: Allocator, uri: []const u8) []const u8 {
    const parsed = std.Uri.parse(uri) catch return uri;
    if (!std.mem.eql(u8, parsed.scheme, "file")) return uri;
    return std_uri.fsPath(parsed, allocator) catch uri;
}

fn itemIndex(id: []const u8, prefix: []const u8) ?usize {
    if (!std.mem.startsWith(u8, id, prefix)) return null;
    return std.fmt.parseInt(usize, id[prefix.len..], 10) catch null;
}
