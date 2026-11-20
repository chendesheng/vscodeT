// Port of the baseline subset of
// `src/vs/workbench/api/browser/mainThreadLanguageFeatures.ts`.
//
// Ported features: hover, completion, definition, declaration,
// implementation, type definition, references, document symbols, code actions
// and document/range/on-type formatting. The actor stores providers by handle
// in `LanguageFeaturesService`, converts the extension-host DTOs into editor
// types and forwards provider calls back to `ExtHostLanguageFeatures`.
//
// Terminal adaptation: provider calls are synchronous with a bounded timeout
// because the TUI editor has no asynchronous provider boundary. Workspace
// edits from code actions are retained as raw DTO JSON until a bulk-edit
// service exists; there is no TUI code-action surface yet.

const std = @import("std");
const Allocator = std.mem.Allocator;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const protocol = @import("../common/extHost.protocol.zig");
const proxyIdentifier = @import("../../services/extensions/common/proxyIdentifier.zig");
const cancellation = @import("../../../base/common/cancellation.zig");
const CancellationToken = cancellation.CancellationToken;
const lifecycle = @import("../../../base/common/lifecycle.zig");
const IDisposable = lifecycle.IDisposable;
const TextModel = @import("../../../editor/common/model/textModel.zig").TextModel;
const Position = @import("../../../editor/common/core/position.zig").Position;
const Range = @import("../../../editor/common/core/range.zig").Range;
const languages = @import("../../../editor/common/languages.zig");
const completion = @import("../../../editor/common/languages/completion.zig");
const selector_mod = @import("../../../editor/common/languageSelector.zig");
const std_uri = @import("../../../base/common/stdUri.zig");
const position_converter = @import("../common/positionConverter.zig");
const features_mod = @import("../../../editor/common/services/languageFeaturesService.zig");

pub const ProviderError = error{
    RequestFailed,
    InvalidResult,
    Timeout,
    ServerUnavailable,
};

pub const HostProxy = struct {
    context: *anyopaque,
    request: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        method: []const u8,
        args: []const rpc.Arg,
        token: ?CancellationToken,
        timeout_ms: u32,
    ) anyerror!std.json.Value,
    notify: *const fn (context: *anyopaque, method: []const u8, args: []const rpc.Arg) anyerror!void,
};

const timeout_hover_ms: u32 = 750;
const timeout_default_ms: u32 = 1500;
const timeout_format_ms: u32 = 2000;

const Registration = struct {
    owner: *MainThreadLanguageFeatures,
    handle: u32,
    arena: std.heap.ArenaAllocator,
    disposable: ?IDisposable = null,
    hover_arena: ?*std.heap.ArenaAllocator = null,
};

const HoverState = struct {
    registration: *Registration,
    arena: *std.heap.ArenaAllocator,
};
const CompletionState = struct {
    registration: *Registration,
    trigger_characters: []const []const u8,
    supports_resolve: bool,
};
const LocationState = struct { registration: *Registration };
const ReferenceState = struct { registration: *Registration };
const DocumentSymbolState = struct {
    registration: *Registration,
    display_name: []const u8,
};
const CodeActionState = struct {
    registration: *Registration,
    display_name: []const u8,
    extension_id: []const u8,
    provided_kinds: []const []const u8,
};
const FormattingState = struct {
    registration: *Registration,
    extension_id: []const u8,
    display_name: []const u8,
    supports_ranges: bool = false,
    trigger_characters: []const []const u8 = &.{},
};

pub const MainThreadLanguageFeatures = struct {
    allocator: Allocator,
    features: *features_mod.LanguageFeaturesService,
    proxy: HostProxy,
    registrations: std.AutoHashMap(u32, *Registration),

    pub fn init(allocator: Allocator, features: *features_mod.LanguageFeaturesService, proxy: HostProxy) MainThreadLanguageFeatures {
        return .{
            .allocator = allocator,
            .features = features,
            .proxy = proxy,
            .registrations = std.AutoHashMap(u32, *Registration).init(allocator),
        };
    }

    pub fn deinit(self: *MainThreadLanguageFeatures) void {
        var iterator = self.registrations.valueIterator();
        while (iterator.next()) |registration_ptr| self.destroyRegistration(registration_ptr.*);
        self.registrations.deinit();
    }

    fn destroyRegistration(self: *MainThreadLanguageFeatures, registration: *Registration) void {
        if (registration.disposable) |disposable| disposable.dispose();
        if (registration.hover_arena) |arena| {
            arena.deinit();
            self.allocator.destroy(arena);
        }
        registration.arena.deinit();
        self.allocator.destroy(registration);
    }

    fn createRegistration(self: *MainThreadLanguageFeatures, arena: Allocator, handle: u32) !*Registration {
        if (self.registrations.contains(handle)) return error.DuplicateHandle;
        const registration = try self.allocator.create(Registration);
        errdefer self.allocator.destroy(registration);
        registration.* = .{
            .owner = self,
            .handle = handle,
            .arena = std.heap.ArenaAllocator.init(self.allocator),
        };
        errdefer registration.arena.deinit();
        _ = arena;
        try self.registrations.put(handle, registration);
        return registration;
    }

    pub fn invoke(
        self: *MainThreadLanguageFeatures,
        method: []const u8,
        args: []const rpc.Arg,
        token: ?CancellationToken,
        arena: Allocator,
    ) !rpc.HandlerReply {
        _ = token;
        if (std.mem.eql(u8, method, "$unregister")) {
            const handle = handleArg(args) orelse return error.InvalidArguments;
            if (self.registrations.fetchRemove(handle)) |entry| self.destroyRegistration(entry.value);
            return .empty;
        }
        if (std.mem.eql(u8, method, "$registerHoverProvider")) return self.registerHover(args, arena);
        if (std.mem.eql(u8, method, "$registerCompletionsProvider")) return self.registerCompletion(args, arena);
        if (std.mem.eql(u8, method, "$registerDefinitionSupport")) return self.registerLocationProvider(args, arena, .definition);
        if (std.mem.eql(u8, method, "$registerDeclarationSupport")) return self.registerLocationProvider(args, arena, .declaration);
        if (std.mem.eql(u8, method, "$registerImplementationSupport")) return self.registerLocationProvider(args, arena, .implementation);
        if (std.mem.eql(u8, method, "$registerTypeDefinitionSupport")) return self.registerLocationProvider(args, arena, .type_definition);
        if (std.mem.eql(u8, method, "$registerReferenceSupport")) return self.registerReference(args, arena);
        if (std.mem.eql(u8, method, "$registerDocumentSymbolProvider")) return self.registerDocumentSymbol(args, arena);
        if (std.mem.eql(u8, method, "$registerCodeActionSupport")) return self.registerCodeAction(args, arena);
        if (std.mem.eql(u8, method, "$registerDocumentFormattingSupport")) return self.registerDocumentFormatting(args, arena);
        if (std.mem.eql(u8, method, "$registerRangeFormattingSupport")) return self.registerRangeFormatting(args, arena);
        if (std.mem.eql(u8, method, "$registerOnTypeFormattingSupport")) return self.registerOnTypeFormatting(args, arena);

        const kind = methodKind(method);
        if (kind == .request) return .{ .err = .{ .name = "Unsupported", .message = method } };
        return .empty;
    }

    fn registerHover(self: *MainThreadLanguageFeatures, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        const handle = handleArg(args) orelse return error.InvalidArguments;
        const selector_value = jsonArg(args, 1) orelse return error.InvalidArguments;
        const parsed = try parseSelector(arena, selector_value);
        const registration = try self.createRegistration(arena, handle);
        const hover_arena = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(hover_arena);
        hover_arena.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer hover_arena.deinit();
        const state = try registration.arena.allocator().create(HoverState);
        state.* = .{ .registration = registration, .arena = hover_arena };
        registration.hover_arena = hover_arena;
        registration.disposable = try self.features.hover_provider.register(parsed, .{
            .context = state,
            .provide_hover = provideHover,
        });
        return .empty;
    }

    fn registerCompletion(self: *MainThreadLanguageFeatures, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        const handle = handleArg(args) orelse return error.InvalidArguments;
        const selector_value = jsonArg(args, 1) orelse return error.InvalidArguments;
        const parsed = try parseSelector(arena, selector_value);
        const registration = try self.createRegistration(arena, handle);
        const state = try registration.arena.allocator().create(CompletionState);
        const triggers = try stringArray(registration.arena.allocator(), jsonArg(args, 2));
        state.* = .{
            .registration = registration,
            .trigger_characters = triggers,
            .supports_resolve = boolArg(args, 3),
        };
        registration.disposable = try self.features.completion_provider.register(parsed, .{
            .context = state,
            .provide_completion_items = provideCompletion,
            .trigger_characters = triggers,
        });
        return .empty;
    }

    const LocationKind = enum { definition, declaration, implementation, type_definition };

    fn registerLocationProvider(self: *MainThreadLanguageFeatures, args: []const rpc.Arg, arena: Allocator, kind: LocationKind) !rpc.HandlerReply {
        const handle = handleArg(args) orelse return error.InvalidArguments;
        const selector_value = jsonArg(args, 1) orelse return error.InvalidArguments;
        const parsed = try parseSelector(arena, selector_value);
        const registration = try self.createRegistration(arena, handle);
        const state = try registration.arena.allocator().create(LocationState);
        state.* = .{ .registration = registration };
        switch (kind) {
            .definition => registration.disposable = try self.features.definition_provider.register(parsed, .{
                .context = state,
                .provide_definition = provideDefinition,
            }),
            .declaration => registration.disposable = try self.features.declaration_provider.register(parsed, .{
                .context = state,
                .provide_declaration = provideDeclaration,
            }),
            .implementation => registration.disposable = try self.features.implementation_provider.register(parsed, .{
                .context = state,
                .provide_implementation = provideImplementation,
            }),
            .type_definition => registration.disposable = try self.features.type_definition_provider.register(parsed, .{
                .context = state,
                .provide_type_definition = provideTypeDefinition,
            }),
        }
        return .empty;
    }

    fn registerReference(self: *MainThreadLanguageFeatures, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        const handle = handleArg(args) orelse return error.InvalidArguments;
        const selector_value = jsonArg(args, 1) orelse return error.InvalidArguments;
        const parsed = try parseSelector(arena, selector_value);
        const registration = try self.createRegistration(arena, handle);
        const state = try registration.arena.allocator().create(ReferenceState);
        state.* = .{ .registration = registration };
        registration.disposable = try self.features.reference_provider.register(parsed, .{
            .context = state,
            .provide_references = provideReferences,
        });
        return .empty;
    }

    fn registerDocumentSymbol(self: *MainThreadLanguageFeatures, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        const handle = handleArg(args) orelse return error.InvalidArguments;
        const selector_value = jsonArg(args, 1) orelse return error.InvalidArguments;
        const parsed = try parseSelector(arena, selector_value);
        const registration = try self.createRegistration(arena, handle);
        const state = try registration.arena.allocator().create(DocumentSymbolState);
        state.* = .{
            .registration = registration,
            .display_name = try dupString(registration.arena.allocator(), stringArg(args, 2)),
        };
        registration.disposable = try self.features.document_symbol_provider.register(parsed, .{
            .context = state,
            .display_name = state.display_name,
            .provide_document_symbols = provideDocumentSymbols,
        });
        return .empty;
    }

    fn registerCodeAction(self: *MainThreadLanguageFeatures, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        const handle = handleArg(args) orelse return error.InvalidArguments;
        const selector_value = jsonArg(args, 1) orelse return error.InvalidArguments;
        const parsed = try parseSelector(arena, selector_value);
        const registration = try self.createRegistration(arena, handle);
        const state = try registration.arena.allocator().create(CodeActionState);
        state.* = .{
            .registration = registration,
            .display_name = try dupString(registration.arena.allocator(), stringArg(args, 3)),
            .extension_id = try dupString(registration.arena.allocator(), stringArg(args, 4)),
            .provided_kinds = try stringArray(registration.arena.allocator(), metadataKinds(jsonArg(args, 2))),
        };
        registration.disposable = try self.features.code_action_provider.register(parsed, .{
            .context = state,
            .display_name = state.display_name,
            .extension_id = state.extension_id,
            .provided_kinds = state.provided_kinds,
            .provide_code_actions = provideCodeActions,
        });
        return .empty;
    }

    fn registerDocumentFormatting(self: *MainThreadLanguageFeatures, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        return self.registerFormatting(args, arena, .document);
    }

    fn registerRangeFormatting(self: *MainThreadLanguageFeatures, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        return self.registerFormatting(args, arena, .range);
    }

    fn registerOnTypeFormatting(self: *MainThreadLanguageFeatures, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        return self.registerFormatting(args, arena, .on_type);
    }

    const FormattingKind = enum { document, range, on_type };

    fn registerFormatting(self: *MainThreadLanguageFeatures, args: []const rpc.Arg, arena: Allocator, kind: FormattingKind) !rpc.HandlerReply {
        const handle = handleArg(args) orelse return error.InvalidArguments;
        const selector_value = jsonArg(args, 1) orelse return error.InvalidArguments;
        const parsed = try parseSelector(arena, selector_value);
        const registration = try self.createRegistration(arena, handle);
        const state = try registration.arena.allocator().create(FormattingState);
        state.* = .{
            .registration = registration,
            .extension_id = try dupString(registration.arena.allocator(), extensionIdArg(args, 2)),
            .display_name = try dupString(registration.arena.allocator(), stringArg(args, 3)),
            .supports_ranges = boolArg(args, 4),
            .trigger_characters = if (kind == .on_type) try stringArray(registration.arena.allocator(), jsonArg(args, 2)) else &.{},
        };
        switch (kind) {
            .document => registration.disposable = try self.features.document_formatting_edit_provider.register(parsed, .{
                .context = state,
                .extension_id = state.extension_id,
                .display_name = state.display_name,
                .provide_document_formatting_edits = provideDocumentFormatting,
            }),
            .range => registration.disposable = try self.features.document_range_formatting_edit_provider.register(parsed, .{
                .context = state,
                .extension_id = state.extension_id,
                .display_name = state.display_name,
                .provide_document_range_formatting_edits = provideRangeFormatting,
            }),
            .on_type => registration.disposable = try self.features.on_type_formatting_edit_provider.register(parsed, .{
                .context = state,
                .extension_id = state.extension_id,
                .auto_format_trigger_characters = state.trigger_characters,
                .provide_on_type_formatting_edits = provideOnTypeFormatting,
            }),
        }
        return .empty;
    }

    // --- provider implementations

    fn provideHover(context: *anyopaque, model: *TextModel, position: Position, token: CancellationToken, hover_context: ?*const languages.HoverContext) anyerror!?languages.Hover {
        _ = hover_context;
        const state: *HoverState = @ptrCast(@alignCast(context));
        const self = state.registration.owner;
        _ = state.arena.reset(.retain_capacity);
        const scratch = state.arena.allocator();
        var args = std.array_list.Managed(rpc.Arg).init(scratch);
        try args.append(.{ .json = .{ .integer = state.registration.handle } });
        try args.append(.{ .json = try std_uri.jsonComponents(scratch, model.uri()) });
        try args.append(.{ .json = try positionJson(scratch, model, position) });
        try args.append(.{ .json = .{ .object = .empty } });
        const reply = self.call(scratch, "$provideHover", args.items, token, timeout_hover_ms) catch return null;
        if (reply != .object) return null;
        const object = reply.object;
        if (object.get("id")) |id_value| {
            if (id_value == .integer) {
                var release = [_]rpc.Arg{
                    .{ .json = .{ .integer = state.registration.handle } },
                    .{ .json = id_value },
                };
                self.proxy.notify(self.proxy.context, "$releaseHover", &release) catch {};
            }
        }
        const contents_value = object.get("contents") orelse return null;
        var contents = std.array_list.Managed(languages.IMarkdownString).init(scratch);
        try appendHoverContents(&contents, scratch, contents_value);
        if (contents.items.len == 0) return null;
        const owned = try scratch.alloc(languages.IMarkdownString, contents.items.len);
        for (contents.items, 0..) |item, index| owned[index] = .{ .value = try scratch.dupe(u8, item.value) };
        return .{
            .contents = owned,
            .range = if (object.get("range")) |range| rangeFromJson(model, range) else null,
        };
    }

    fn provideCompletion(context: *anyopaque, allocator: Allocator, model: *TextModel, position: Position, trigger: completion.CompletionContext, token: CancellationToken) anyerror!completion.CompletionList {
        const state: *CompletionState = @ptrCast(@alignCast(context));
        const self = state.registration.owner;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var args = std.array_list.Managed(rpc.Arg).init(scratch);
        try args.append(.{ .json = .{ .integer = state.registration.handle } });
        try args.append(.{ .json = try std_uri.jsonComponents(scratch, model.uri()) });
        try args.append(.{ .json = try positionJson(scratch, model, position) });
        var context_json: std.json.ObjectMap = .empty;
        try context_json.put(scratch, "triggerKind", .{ .integer = @backingInt(trigger.trigger_kind) });
        if (trigger.trigger_character) |character| try context_json.put(scratch, "triggerCharacter", .{ .string = try scratch.dupe(u8, character) });
        try args.append(.{ .json = .{ .object = context_json } });
        const reply = self.call(scratch, "$provideCompletionItems", args.items, token, timeout_default_ms) catch return .{};
        if (reply != .object) return .{};
        const object = reply.object;
        if (object.get("x")) |cache| {
            if (cache == .integer) {
                var release = [_]rpc.Arg{
                    .{ .json = .{ .integer = state.registration.handle } },
                    .{ .json = cache },
                };
                self.proxy.notify(self.proxy.context, "$releaseCompletionItems", &release) catch {};
            }
        }
        const items_value = object.get("b") orelse return .{};
        if (items_value != .array) return .{};
        const default_range = object.get("a");
        var items = std.array_list.Managed(completion.CompletionItem).init(allocator);
        for (items_value.array.items) |item_value| {
            if (item_value != .object) continue;
            try items.append(try parseCompletionItem(allocator, item_value.object, default_range, model));
        }
        const owned = try items.toOwnedSlice();
        return .{
            .items = owned,
            .is_incomplete = if (object.get("c")) |value| value == .bool and value.bool else false,
        };
    }

    fn provideDefinition(context: *anyopaque, allocator: Allocator, model: *TextModel, position: Position, token: CancellationToken) anyerror![]languages.LocationLink {
        return provideLocationLinksFor(context, allocator, model, position, token, "$provideDefinition");
    }

    fn provideDeclaration(context: *anyopaque, allocator: Allocator, model: *TextModel, position: Position, token: CancellationToken) anyerror![]languages.LocationLink {
        return provideLocationLinksFor(context, allocator, model, position, token, "$provideDeclaration");
    }

    fn provideImplementation(context: *anyopaque, allocator: Allocator, model: *TextModel, position: Position, token: CancellationToken) anyerror![]languages.LocationLink {
        return provideLocationLinksFor(context, allocator, model, position, token, "$provideImplementation");
    }

    fn provideTypeDefinition(context: *anyopaque, allocator: Allocator, model: *TextModel, position: Position, token: CancellationToken) anyerror![]languages.LocationLink {
        return provideLocationLinksFor(context, allocator, model, position, token, "$provideTypeDefinition");
    }

    fn provideLocationLinksFor(context: *anyopaque, allocator: Allocator, model: *TextModel, position: Position, token: CancellationToken, method: []const u8) anyerror![]languages.LocationLink {
        const state: *LocationState = @ptrCast(@alignCast(context));
        const self = state.registration.owner;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var args = std.array_list.Managed(rpc.Arg).init(scratch);
        try args.append(.{ .json = .{ .integer = state.registration.handle } });
        try args.append(.{ .json = try std_uri.jsonComponents(scratch, model.uri()) });
        try args.append(.{ .json = try positionJson(scratch, model, position) });
        const reply = self.call(scratch, method, args.items, token, timeout_default_ms) catch return &.{};
        if (reply != .array) return &.{};
        var result = std.array_list.Managed(languages.LocationLink).init(allocator);
        for (reply.array.items) |item| {
            if (item != .object) continue;
            const object = item.object;
            const uri_value = object.get("uri") orelse continue;
            const range_value = object.get("range") orelse continue;
            const range = rangeFromJson(model, range_value) orelse continue;
            try result.append(.{
                .origin_selection_range = if (object.get("originSelectionRange")) |value| rangeFromJson(model, value) else null,
                .uri = try resourceKeyFromComponentsJson(allocator, uri_value),
                .range = range,
                .target_selection_range = if (object.get("targetSelectionRange")) |value| rangeFromJson(model, value) orelse range else range,
            });
        }
        return result.toOwnedSlice();
    }

    fn provideReferences(context: *anyopaque, allocator: Allocator, model: *TextModel, position: Position, reference_context: languages.ReferenceContext, token: CancellationToken) anyerror![]languages.Location {
        const state: *ReferenceState = @ptrCast(@alignCast(context));
        const self = state.registration.owner;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var args = std.array_list.Managed(rpc.Arg).init(scratch);
        try args.append(.{ .json = .{ .integer = state.registration.handle } });
        try args.append(.{ .json = try std_uri.jsonComponents(scratch, model.uri()) });
        try args.append(.{ .json = try positionJson(scratch, model, position) });
        var context_json: std.json.ObjectMap = .empty;
        try context_json.put(scratch, "includeDeclaration", .{ .bool = reference_context.include_declaration });
        try args.append(.{ .json = .{ .object = context_json } });
        const reply = self.call(scratch, "$provideReferences", args.items, token, timeout_default_ms) catch return &.{};
        if (reply != .array) return &.{};
        var result = std.array_list.Managed(languages.Location).init(allocator);
        for (reply.array.items) |item| {
            if (item != .object) continue;
            const object = item.object;
            const uri_value = object.get("uri") orelse continue;
            const range_value = object.get("range") orelse continue;
            const range = rangeFromJson(model, range_value) orelse continue;
            try result.append(.{
                .uri = try resourceKeyFromComponentsJson(allocator, uri_value),
                .range = range,
            });
        }
        return result.toOwnedSlice();
    }

    fn provideDocumentSymbols(context: *anyopaque, allocator: Allocator, model: *TextModel, token: CancellationToken) anyerror![]languages.DocumentSymbol {
        const state: *DocumentSymbolState = @ptrCast(@alignCast(context));
        const self = state.registration.owner;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var args = std.array_list.Managed(rpc.Arg).init(scratch);
        try args.append(.{ .json = .{ .integer = state.registration.handle } });
        try args.append(.{ .json = try std_uri.jsonComponents(scratch, model.uri()) });
        const reply = self.call(scratch, "$provideDocumentSymbols", args.items, token, timeout_format_ms) catch return &.{};
        if (reply != .array) return &.{};
        var result = std.array_list.Managed(languages.DocumentSymbol).init(allocator);
        for (reply.array.items) |item| {
            if (item != .object) continue;
            try result.append(try parseDocumentSymbol(allocator, item.object, model));
        }
        return result.toOwnedSlice();
    }

    fn provideCodeActions(context: *anyopaque, allocator: Allocator, model: *TextModel, range: Range, action_context: languages.CodeActionContext, token: CancellationToken) anyerror!languages.CodeActionList {
        const state: *CodeActionState = @ptrCast(@alignCast(context));
        const self = state.registration.owner;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var args = std.array_list.Managed(rpc.Arg).init(scratch);
        try args.append(.{ .json = .{ .integer = state.registration.handle } });
        try args.append(.{ .json = try std_uri.jsonComponents(scratch, model.uri()) });
        try args.append(.{ .json = try rangeJson(scratch, model, range) });
        var context_json: std.json.ObjectMap = .empty;
        if (action_context.only) |only| try context_json.put(scratch, "only", .{ .string = try scratch.dupe(u8, only) });
        try context_json.put(scratch, "trigger", .{ .integer = action_context.trigger_kind });
        try args.append(.{ .json = .{ .object = context_json } });
        const reply = self.call(scratch, "$provideCodeActions", args.items, token, timeout_default_ms) catch return .{};
        if (reply != .object) return .{};
        if (reply.object.get("cacheId")) |cache| {
            if (cache == .integer) {
                var release = [_]rpc.Arg{
                    .{ .json = .{ .integer = state.registration.handle } },
                    .{ .json = cache },
                };
                self.proxy.notify(self.proxy.context, "$releaseCodeActions", &release) catch {};
            }
        }
        const actions_value = reply.object.get("actions") orelse return .{};
        if (actions_value != .array) return .{};
        var result = std.array_list.Managed(languages.CodeAction).init(allocator);
        for (actions_value.array.items) |item| {
            if (item != .object) continue;
            const object = item.object;
            try result.append(.{
                .title = try dupJsonString(allocator, object.get("title")),
                .kind = try optionalJsonString(allocator, object.get("kind")),
                .is_preferred = boolValue(object.get("isPreferred")),
                .disabled = try optionalJsonString(allocator, object.get("disabled")),
                .edit_json = if (object.get("edit")) |edit| try rpc.cloneJsonValue(allocator, edit) else null,
            });
        }
        return .{ .actions = try result.toOwnedSlice() };
    }

    fn provideDocumentFormatting(context: *anyopaque, allocator: Allocator, model: *TextModel, options: languages.FormattingOptions, token: CancellationToken) anyerror![]languages.TextEdit {
        const state: *FormattingState = @ptrCast(@alignCast(context));
        return state.registration.owner.provideFormattingEdits(state.registration, allocator, model, null, null, options, token);
    }

    fn provideRangeFormatting(context: *anyopaque, allocator: Allocator, model: *TextModel, range: Range, options: languages.FormattingOptions, token: CancellationToken) anyerror![]languages.TextEdit {
        const state: *FormattingState = @ptrCast(@alignCast(context));
        return state.registration.owner.provideFormattingEdits(state.registration, allocator, model, range, null, options, token);
    }

    fn provideOnTypeFormatting(context: *anyopaque, allocator: Allocator, model: *TextModel, position: Position, ch: []const u8, options: languages.FormattingOptions, token: CancellationToken) anyerror![]languages.TextEdit {
        const state: *FormattingState = @ptrCast(@alignCast(context));
        return state.registration.owner.provideFormattingEdits(state.registration, allocator, model, null, .{ .position = position, .ch = ch }, options, token);
    }

    const OnTypeContext = struct { position: Position, ch: []const u8 };

    fn provideFormattingEdits(self: *MainThreadLanguageFeatures, registration: *Registration, allocator: Allocator, model: *TextModel, range: ?Range, on_type: ?OnTypeContext, options: languages.FormattingOptions, token: CancellationToken) anyerror![]languages.TextEdit {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        var args = std.array_list.Managed(rpc.Arg).init(scratch);
        try args.append(.{ .json = .{ .integer = registration.handle } });
        try args.append(.{ .json = try std_uri.jsonComponents(scratch, model.uri()) });
        const method = if (on_type != null) "$provideOnTypeFormattingEdits" else if (range != null) "$provideDocumentRangeFormattingEdits" else "$provideDocumentFormattingEdits";
        if (range) |value| try args.append(.{ .json = try rangeJson(scratch, model, value) });
        if (on_type) |value| {
            try args.append(.{ .json = try positionJson(scratch, model, value.position) });
            try args.append(.{ .json = .{ .string = try scratch.dupe(u8, value.ch) } });
        }
        var options_json: std.json.ObjectMap = .empty;
        try options_json.put(scratch, "tabSize", .{ .integer = @intCast(options.tab_size) });
        try options_json.put(scratch, "insertSpaces", .{ .bool = options.insert_spaces });
        try args.append(.{ .json = .{ .object = options_json } });
        const reply = self.call(scratch, method, args.items, token, timeout_format_ms) catch return &.{};
        if (reply != .array) return &.{};
        var result = std.array_list.Managed(languages.TextEdit).init(allocator);
        for (reply.array.items) |item| {
            if (item != .object) continue;
            const object = item.object;
            const range_value = object.get("range") orelse continue;
            const text_value = object.get("text") orelse continue;
            if (text_value != .string) continue;
            try result.append(.{
                .range = rangeFromJson(model, range_value) orelse continue,
                .text = try allocator.dupe(u8, text_value.string),
            });
        }
        return result.toOwnedSlice();
    }

    fn call(self: *MainThreadLanguageFeatures, allocator: Allocator, method: []const u8, args: []const rpc.Arg, token: CancellationToken, timeout_ms: u32) !std.json.Value {
        return self.proxy.request(self.proxy.context, allocator, method, args, token, timeout_ms);
    }
};

fn methodKind(method: []const u8) protocol.MethodKind {
    for (protocol.MainThreadLanguageFeatures.methods) |candidate| {
        if (std.mem.eql(u8, candidate.name, method)) return candidate.kind;
    }
    return .notification;
}

fn handleArg(args: []const rpc.Arg) ?u32 {
    if (args.len == 0 or args[0] != .json or args[0].json != .integer) return null;
    if (args[0].json.integer < 0) return null;
    return @intCast(args[0].json.integer);
}

fn jsonArg(args: []const rpc.Arg, index: usize) ?std.json.Value {
    if (index >= args.len or args[index] != .json) return null;
    return args[index].json;
}

fn stringArg(args: []const rpc.Arg, index: usize) []const u8 {
    const value = jsonArg(args, index) orelse return "";
    if (value != .string) return "";
    return value.string;
}

fn boolArg(args: []const rpc.Arg, index: usize) bool {
    const value = jsonArg(args, index) orelse return false;
    return value == .bool and value.bool;
}

fn extensionIdArg(args: []const rpc.Arg, index: usize) []const u8 {
    const value = jsonArg(args, index) orelse return "";
    if (value == .string) return value.string;
    if (value == .object) {
        if (value.object.get("value")) |id| if (id == .string) return id.string;
    }
    return "";
}

fn boolValue(value: ?std.json.Value) bool {
    if (value) |item| return item == .bool and item.bool;
    return false;
}

fn dupString(allocator: Allocator, value: []const u8) ![]const u8 {
    return allocator.dupe(u8, value);
}

fn dupJsonString(allocator: Allocator, value: ?std.json.Value) ![]const u8 {
    if (value) |item| if (item == .string) return allocator.dupe(u8, item.string);
    return allocator.dupe(u8, "");
}

fn optionalJsonString(allocator: Allocator, value: ?std.json.Value) !?[]const u8 {
    if (value) |item| if (item == .string) return try allocator.dupe(u8, item.string);
    return null;
}

fn stringArray(allocator: Allocator, value: ?std.json.Value) ![]const []const u8 {
    const item = value orelse return &.{};
    if (item != .array) return &.{};
    const result = try allocator.alloc([]const u8, item.array.items.len);
    for (item.array.items, 0..) |entry, index| {
        result[index] = if (entry == .string) try allocator.dupe(u8, entry.string) else "";
    }
    return result;
}

fn metadataKinds(value: ?std.json.Value) ?std.json.Value {
    const item = value orelse return null;
    if (item != .object) return null;
    return item.object.get("providedKinds");
}

fn positionJson(arena: Allocator, model: *TextModel, position: Position) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "lineNumber", .{ .integer = @intCast(position.lineNumber) });
    try object.put(arena, "column", .{ .integer = @intCast(utf16ColumnForModel(model, position.lineNumber, position.column)) });
    return .{ .object = object };
}

fn rangeJson(arena: Allocator, model: *TextModel, range: Range) !std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(arena, "startLineNumber", .{ .integer = @intCast(range.startLineNumber) });
    try object.put(arena, "startColumn", .{ .integer = @intCast(utf16ColumnForModel(model, range.startLineNumber, range.startColumn)) });
    try object.put(arena, "endLineNumber", .{ .integer = @intCast(range.endLineNumber) });
    try object.put(arena, "endColumn", .{ .integer = @intCast(utf16ColumnForModel(model, range.endLineNumber, range.endColumn)) });
    return .{ .object = object };
}

fn rangeFromJson(model: *TextModel, value: std.json.Value) ?Range {
    if (value != .object) return null;
    const object = value.object;
    const start_line = intField(object, "startLineNumber") orelse return null;
    const start_column = intField(object, "startColumn") orelse return null;
    const end_line = intField(object, "endLineNumber") orelse return null;
    const end_column = intField(object, "endColumn") orelse return null;
    return Range.init(
        start_line,
        columnForModel(model, start_line, start_column),
        end_line,
        columnForModel(model, end_line, end_column),
    );
}

fn utf16ColumnForModel(model: *TextModel, line_number: usize, column: usize) usize {
    if (line_number < 1 or line_number > model.getLineCount()) return column;
    var line = model.getLineContent(line_number) catch return column;
    defer line.deinit();
    return position_converter.utf16OffsetForColumn(line.items, column);
}

fn columnForModel(model: *TextModel, line_number: usize, offset: usize) usize {
    if (line_number < 1 or line_number > model.getLineCount()) return offset;
    var line = model.getLineContent(line_number) catch return offset;
    defer line.deinit();
    return position_converter.columnForUtf16Offset(line.items, offset);
}

fn intField(object: std.json.ObjectMap, name: []const u8) ?usize {
    const value = object.get(name) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

fn resourceKeyFromComponentsJson(allocator: Allocator, value: std.json.Value) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const components = try std_uri.componentsFromJson(value, arena.allocator());
    return try std_uri.resourceKeyFromComponents(allocator, components);
}

fn appendHoverContents(result: *std.array_list.Managed(languages.IMarkdownString), allocator: Allocator, value: std.json.Value) !void {
    switch (value) {
        .string => |text| try result.append(.{ .value = try allocator.dupe(u8, text) }),
        .object => |object| {
            if (object.get("value")) |content| {
                if (content == .string) try result.append(.{ .value = try allocator.dupe(u8, content.string) });
            }
        },
        .array => |array| {
            for (array.items) |item| try appendHoverContents(result, allocator, item);
        },
        else => {},
    }
}

fn parseCompletionItem(allocator: Allocator, object: std.json.ObjectMap, default_range: ?std.json.Value, model: *TextModel) !completion.CompletionItem {
    const label_value = object.get("a") orelse std.json.Value{ .string = "" };
    var label: []const u8 = "";
    var detail: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    if (label_value == .string) {
        label = try allocator.dupe(u8, label_value.string);
    } else if (label_value == .object) {
        label = try dupJsonString(allocator, label_value.object.get("label"));
        detail = try optionalJsonString(allocator, label_value.object.get("detail"));
        description = try optionalJsonString(allocator, label_value.object.get("description"));
    }
    const insert_text = if (object.get("h")) |value| if (value == .string) try allocator.dupe(u8, value.string) else label else label;
    const kind_value = object.get("b");
    const parsed_kind: ?completion.CompletionItemKind = if (kind_value) |value| if (value == .integer) std.enums.fromInt(completion.CompletionItemKind, @as(u32, @intCast(value.integer))) else null else null;
    const kind: completion.CompletionItemKind = parsed_kind orelse .Text;

    var additional = std.array_list.Managed(completion.TextEdit).init(allocator);
    if (object.get("l")) |value| {
        if (value == .array) {
            for (value.array.items) |edit| {
                if (edit != .object) continue;
                const range_value = edit.object.get("range") orelse continue;
                const text_value = edit.object.get("text") orelse continue;
                if (text_value != .string) continue;
                try additional.append(.{
                    .range = rangeFromJson(model, range_value) orelse continue,
                    .new_text = try allocator.dupe(u8, text_value.string),
                });
            }
        }
    }

    var commit = std.array_list.Managed([]const u8).init(allocator);
    if (object.get("k")) |value| {
        if (value == .string) {
            for (value.string) |ch| {
                const single = try allocator.alloc(u8, 1);
                single[0] = ch;
                try commit.append(single);
            }
        }
    }

    var tags: u32 = 0;
    if (object.get("m")) |value| {
        if (value == .array) {
            for (value.array.items) |tag| {
                if (tag == .integer) tags |= @as(u32, 1) << @intCast(tag.integer);
            }
        }
    }

    const range = if (object.get("j")) |value| completionRange(value, model) orelse defaultCompletionRange(default_range, model) else defaultCompletionRange(default_range, model);
    return .{
        .label = label,
        .kind = kind,
        .detail = detail orelse (try optionalJsonString(allocator, object.get("c"))),
        .documentation = try documentationText(allocator, object.get("d")),
        .sort_text = try optionalJsonString(allocator, object.get("e")),
        .filter_text = try optionalJsonString(allocator, object.get("f")),
        .insert_text = insert_text,
        .insert_text_rules = if (object.get("i")) |value| if (value == .integer) @intCast(value.integer) else 0 else 0,
        .range = range,
        .additional_text_edits = try additional.toOwnedSlice(),
        .commit_characters = try commit.toOwnedSlice(),
        .preselect = boolValue(object.get("g")),
        .tags = tags,
    };
}

fn documentationText(allocator: Allocator, value: ?std.json.Value) !?[]const u8 {
    if (value) |item| {
        if (item == .string) return try allocator.dupe(u8, item.string);
        if (item == .object) {
            if (item.object.get("value")) |content| if (content == .string) return try allocator.dupe(u8, content.string);
        }
    }
    return null;
}

fn completionRange(value: std.json.Value, model: *TextModel) ?Range {
    if (value != .object) return null;
    if (value.object.get("replace")) |replace| return rangeFromJson(model, replace);
    return rangeFromJson(model, value);
}

fn defaultCompletionRange(value: ?std.json.Value, model: *TextModel) ?Range {
    if (value) |item| {
        if (item != .object) return null;
        if (item.object.get("replace")) |replace| return rangeFromJson(model, replace);
        if (item.object.get("insert")) |insert| return rangeFromJson(model, insert);
    }
    return null;
}

fn parseDocumentSymbol(allocator: Allocator, object: std.json.ObjectMap, model: *TextModel) !languages.DocumentSymbol {
    var children = std.array_list.Managed(languages.DocumentSymbol).init(allocator);
    if (object.get("children")) |value| {
        if (value == .array) {
            for (value.array.items) |child| {
                if (child == .object) try children.append(try parseDocumentSymbol(allocator, child.object, model));
            }
        }
    }
    var tags = std.array_list.Managed(u32).init(allocator);
    if (object.get("tags")) |value| {
        if (value == .array) {
            for (value.array.items) |tag| if (tag == .integer) try tags.append(@intCast(tag.integer));
        }
    }
    return .{
        .name = try dupJsonString(allocator, object.get("name")),
        .detail = try dupJsonString(allocator, object.get("detail")),
        .kind = if (object.get("kind")) |value| if (value == .integer) @intCast(value.integer) else 0 else 0,
        .tags = try tags.toOwnedSlice(),
        .container_name = try optionalJsonString(allocator, object.get("containerName")),
        .range = if (object.get("range")) |value| rangeFromJson(model, value) orelse Range.init(1, 1, 1, 1) else Range.init(1, 1, 1, 1),
        .selection_range = if (object.get("selectionRange")) |value| rangeFromJson(model, value) orelse Range.init(1, 1, 1, 1) else Range.init(1, 1, 1, 1),
        .children = try children.toOwnedSlice(),
    };
}

fn parseSelector(arena: Allocator, value: std.json.Value) !selector_mod.Selector {
    switch (value) {
        .string => |language| return .{ .language = language },
        .array => |array| {
            const items = try arena.alloc(selector_mod.Selector, array.items.len);
            for (array.items, 0..) |item, index| items[index] = try parseSelector(arena, item);
            return .{ .list = items };
        },
        .object => |object| {
            var filter: selector_mod.Filter = .{};
            if (object.get("language")) |language| if (language == .string) {
                filter.language = language.string;
            };
            if (object.get("scheme")) |scheme| if (scheme == .string) {
                filter.scheme = scheme.string;
            };
            if (object.get("notebookType")) |notebook| if (notebook == .string) {
                filter.notebook_type = notebook.string;
            };
            if (object.get("exclusive")) |exclusive| filter.exclusive = exclusive == .bool and exclusive.bool;
            if (object.get("isBuiltin")) |builtin| filter.is_builtin = builtin == .bool and builtin.bool;
            if (object.get("pattern")) |pattern_value| {
                if (pattern_value == .string) {
                    filter.pattern = .{ .string = pattern_value.string };
                } else if (pattern_value == .object) {
                    const text = if (pattern_value.object.get("pattern")) |pattern_text| if (pattern_text == .string) pattern_text.string else "" else "";
                    const base_value = pattern_value.object.get("baseUri");
                    const base = if (base_value) |base_json| blk: {
                        const components = std_uri.componentsFromJson(base_json, arena) catch break :blk "";
                        break :blk components.path;
                    } else "";
                    filter.pattern = .{ .relative = .{ .base = base, .pattern = text } };
                }
            }
            return .{ .filter = filter };
        },
        else => return .{ .language = "" },
    }
}
