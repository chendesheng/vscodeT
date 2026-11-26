// Port of the baseline subset of
// `src/vs/workbench/api/browser/mainThreadLanguageFeatures.ts`.
//
// Ported features: hover, completion, definition, declaration,
// implementation, type definition, references, document symbols, single- and
// multi-document highlights, CodeLens, code actions
// and document/range/on-type formatting. The actor stores providers by handle
// in `LanguageFeaturesService`, converts the extension-host DTOs into editor
// types and forwards provider calls back to `ExtHostLanguageFeatures`.
//
// Terminal adaptation: existing synchronous providers have bounded timeouts;
// Hover, CodeLens and document highlight providers use cancellable RPC continuations. Workspace
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
const parseSelector = @import("../common/extHostTypeConverters.zig").parseSelector;
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
    request_async: ?*const fn (context: *anyopaque, method: []const u8, args: []const rpc.Arg, callback: rpc.ReplyCallback) anyerror!IDisposable = null,
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
    code_lens_state: ?*CodeLensState = null,
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
const CodeLensState = struct {
    registration: *Registration,
    event_handle: ?u32 = null,
    changed: @import("../../../base/common/event.zig").Emitter(void),
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

const code_lens_model = @import("../../../editor/contrib/codelens/browser/codelens.zig");
const EditorDocument = @import("../../../editor/browser/widget/codeEditor/codeEditorWidgetTerminal.zig").EditorDocument;
const CommandRegistry = @import("../../browser/commands.zig").CommandRegistry;
const WindowDispatch = @import("../../../base/common/windowDispatch.zig");

/// Async command result ownership: the provider cache stays alive for the
/// upstream 100 ms grace period after delivering the CodeLens DTOs.
const CodeLensCommandRequest = struct {
    owner: *MainThreadLanguageFeatures,
    document: *EditorDocument,
    commands: *CommandRegistry,
    execution: code_lens_model.Execution,
    cleanup: WindowDispatch.Task,
    channel: ?*rpc.RpcProtocol = null,
    request_id: u32 = 0,

    fn start(context: *anyopaque, channel: *rpc.RpcProtocol, request_id: u32) void {
        const self: *CodeLensCommandRequest = @ptrCast(@alignCast(context));
        self.channel = channel;
        self.request_id = request_id;
        self.run() catch |err| onComplete(self, err);
    }

    fn run(self: *CodeLensCommandRequest) !void {
        const providers = try self.owner.features.code_lens_provider.ordered(self.owner.allocator, self.document.model, false);
        defer self.owner.allocator.free(providers);
        const command = self.commands.get("_executeCodeLensProvider") orelse return error.CommandNotFound;
        const args: code_lens_model.ExecuteCodeLensProviderArgs = .{ .execution = &self.execution, .providers = providers };
        try command.executeWithArgument(@import("../../../platform/commands/common/commands.zig").CommandArgument.from(code_lens_model.ExecuteCodeLensProviderArgs, &args));
    }

    fn onComplete(context: *anyopaque, result: anyerror![]const languages.CodeLens) void {
        const self: *CodeLensCommandRequest = @ptrCast(@alignCast(context));
        if (self.channel) |channel| {
            var scratch = std.heap.ArenaAllocator.init(self.owner.allocator);
            defer scratch.deinit();
            const value = self.serialize(scratch.allocator(), result) catch |err| {
                channel.sendReply(self.request_id, .{ .err = .{ .name = @errorName(err), .message = @errorName(err) } });
                self.channel = null;
                self.cleanup.schedule(@import("../../../base/common/timeCompat.zig").milliTimestamp() + 100);
                return;
            };
            channel.sendReply(self.request_id, .{ .json = value });
            self.channel = null;
        }
        self.cleanup.schedule(@import("../../../base/common/timeCompat.zig").milliTimestamp() + 100);
    }

    fn serialize(self: *CodeLensCommandRequest, a: Allocator, result: anyerror![]const languages.CodeLens) !std.json.Value {
        var rows = std.json.Array.init(a);
        for (try result) |lens| {
            var item: std.json.ObjectMap = .empty;
            try item.put(a, "range", try rangeJson(a, self.document.model, lens.range));
            if (lens.command) |command| {
                var dto: std.json.ObjectMap = .empty;
                try dto.put(a, "id", .{ .string = command.id });
                try dto.put(a, "title", .{ .string = command.title });
                if (command.arguments) |args| try dto.put(a, "arguments", args);
                try item.put(a, "command", .{ .object = dto });
            }
            try rows.append(.{ .object = item });
        }
        return .{ .array = rows };
    }

    fn onCleanup(context: *anyopaque, _: i64, _: bool) bool {
        const self: *CodeLensCommandRequest = @ptrCast(@alignCast(context));
        self.dispose();
        return false;
    }

    fn dispose(self: *CodeLensCommandRequest) void {
        self.cleanup.schedule(null);
        for (self.owner.code_lens_commands.items, 0..) |candidate, index| {
            if (candidate != self) continue;
            _ = self.owner.code_lens_commands.swapRemove(index);
            break;
        }
        self.execution.deinit();
        self.document.release();
        self.owner.allocator.destroy(self);
    }

    fn cancel(self: *CodeLensCommandRequest) void {
        if (self.channel) |channel| channel.sendReply(self.request_id, .{ .err = .{ .name = "Canceled", .message = "CodeLens provider disposed" } });
        self.dispose();
    }
};

pub const InlineProvider = struct { handle: u32, supports_events: bool };

const occurrence_model = @import("../../../editor/contrib/wordHighlighter/browser/wordHighlighter.zig");
const resolver = @import("../../../editor/common/services/resolverService.zig");

// registerModelAndPositionCommand retains the resolved model throughout the
// asynchronous provider execution, including an unmounted resource.
const DocumentHighlightCommandRequest = struct {
    owner: *MainThreadLanguageFeatures,
    commands: *CommandRegistry,
    resolver_service: resolver.ITextModelService,
    resource_string: []const u8,
    input_position: Position, // upstream UTF-16 columns
    document: ?*EditorDocument,
    reference: ?resolver.ModelReference = null,
    resolving: ?resolver.ModelReferenceRequest = null,
    pending: ?*occurrence_model.OccurrenceRequest = null,
    channel: ?*rpc.RpcProtocol = null,
    request_id: u32 = 0,
    starting: bool = false,
    finished: bool = false,

    fn start(context: *anyopaque, channel: *rpc.RpcProtocol, request_id: u32) void {
        const self: *DocumentHighlightCommandRequest = @ptrCast(@alignCast(context));
        self.channel = channel;
        self.request_id = request_id;
        if (self.document) |document| {
            self.run(document.model);
        } else {
            const uri = std.Uri.parse(self.resource_string) catch |err| return self.fail(err);
            self.resolving = self.resolver_service.createModelReference(uri, .{ .context = self, .complete = modelReady }) catch |err| return self.fail(err);
        }
    }

    fn modelReady(context: *anyopaque, result: resolver.ModelReferenceResult) void {
        const self: *DocumentHighlightCommandRequest = @ptrCast(@alignCast(context));
        self.resolving = null;
        switch (result) {
            .failure => |err| self.fail(err),
            .resolved => |reference| {
                self.reference = reference;
                self.run(reference.object.textEditorModel);
            },
        }
    }

    fn currentModel(self: *DocumentHighlightCommandRequest) *TextModel {
        return if (self.document) |document| document.model else self.reference.?.object.textEditorModel;
    }

    fn run(self: *DocumentHighlightCommandRequest, model: *TextModel) void {
        const command = self.commands.get("_executeDocumentHighlights") orelse return self.fail(error.CommandNotFound);
        const position = Position.init(self.input_position.lineNumber, columnForModel(model, self.input_position.lineNumber, self.input_position.column));
        const args: occurrence_model.ExecuteDocumentHighlightsArgs = .{
            .allocator = self.owner.allocator,
            .registry = &self.owner.features.document_highlight_provider,
            .model = model,
            .position = position,
            .listener = .{ .context = self, .complete = ready },
            .pending = &self.pending,
        };
        self.starting = true;
        command.executeWithArgument(@import("../../../platform/commands/common/commands.zig").CommandArgument.from(occurrence_model.ExecuteDocumentHighlightsArgs, &args)) catch |err| self.fail(err);
        self.starting = false;
        if (self.finished) self.dispose();
    }

    fn ready(context: *anyopaque, result: *occurrence_model.OccurrenceResult) void {
        const self: *DocumentHighlightCommandRequest = @ptrCast(@alignCast(context));
        self.pending = null;
        defer result.dispose();
        const model = self.currentModel();
        var scratch = std.heap.ArenaAllocator.init(self.owner.allocator);
        defer scratch.deinit();
        const highlights = result.get(model.uri()) orelse return self.reply(.empty);
        const a = scratch.allocator();
        var items = std.json.Array.init(a);
        for (highlights) |highlight| {
            var dto: std.json.ObjectMap = .empty;
            dto.put(a, "range", rangeJson(a, model, highlight.range) catch |err| return self.fail(err)) catch |err| return self.fail(err);
            if (highlight.kind) |kind| dto.put(a, "kind", .{ .integer = @backingInt(kind) }) catch |err| return self.fail(err);
            items.append(.{ .object = dto }) catch |err| return self.fail(err);
        }
        self.reply(.{ .json = .{ .array = items } });
    }

    fn fail(self: *DocumentHighlightCommandRequest, err: anyerror) void {
        self.reply(.{ .err = .{ .name = @errorName(err), .message = @errorName(err) } });
    }

    fn reply(self: *DocumentHighlightCommandRequest, value: rpc.HandlerReply) void {
        if (self.finished) return;
        self.finished = true;
        if (self.channel) |channel| channel.sendReply(self.request_id, value);
        self.channel = null;
        if (!self.starting) self.dispose();
    }

    fn dispose(self: *DocumentHighlightCommandRequest) void {
        if (self.resolving) |request| request.cancel();
        if (self.pending) |request| request.cancel();
        if (self.reference) |*reference| reference.dispose();
        if (self.document) |document| document.release();
        const owner = self.owner;
        for (owner.highlight_commands.items, 0..) |candidate, index| {
            if (candidate != self) continue;
            _ = owner.highlight_commands.swapRemove(index);
            break;
        }
        owner.allocator.free(self.resource_string);
        owner.allocator.destroy(self);
    }
};

pub const MainThreadLanguageFeatures = struct {
    allocator: Allocator,
    features: *features_mod.LanguageFeaturesService,
    proxy: HostProxy,
    registrations: std.AutoHashMap(u32, *Registration),
    code_lens_events: std.AutoHashMap(u32, *CodeLensState),
    code_lens_commands: std.ArrayList(*CodeLensCommandRequest) = .empty,
    highlight_commands: std.ArrayList(*DocumentHighlightCommandRequest) = .empty,
    inline_providers: @import("../../../editor/common/languageFeatureRegistry.zig").LanguageFeatureRegistry(InlineProvider),

    pub fn init(allocator: Allocator, features: *features_mod.LanguageFeaturesService, proxy: HostProxy) MainThreadLanguageFeatures {
        return .{
            .allocator = allocator,
            .features = features,
            .proxy = proxy,
            .inline_providers = .init(allocator),
            .registrations = std.AutoHashMap(u32, *Registration).init(allocator),
            .code_lens_events = std.AutoHashMap(u32, *CodeLensState).init(allocator),
        };
    }

    pub fn deinit(self: *MainThreadLanguageFeatures) void {
        while (self.highlight_commands.items.len != 0) self.highlight_commands.items[self.highlight_commands.items.len - 1].dispose();
        self.highlight_commands.deinit(self.allocator);
        while (self.code_lens_commands.items.len != 0) self.code_lens_commands.items[self.code_lens_commands.items.len - 1].dispose();
        var iterator = self.registrations.valueIterator();
        while (iterator.next()) |registration_ptr| self.destroyRegistration(registration_ptr.*);
        self.registrations.deinit();
        self.code_lens_commands.deinit(self.allocator);
        self.code_lens_events.deinit();
        self.inline_providers.deinit();
    }

    pub fn executeCodeLensCommand(self: *MainThreadLanguageFeatures, document: *EditorDocument, resolve_count: ?usize, commands: *CommandRegistry, queue: *WindowDispatch.Queue) !rpc.HandlerReply {
        const request = try self.allocator.create(CodeLensCommandRequest);
        errdefer self.allocator.destroy(request);
        document.retain();
        errdefer document.release();
        request.* = .{
            .owner = self,
            .document = document,
            .commands = commands,
            .execution = .{ .allocator = self.allocator, .model = document.model, .resolve_count = resolve_count, .context = request, .complete = CodeLensCommandRequest.onComplete },
            .cleanup = .{ .queue = queue, .context = request, .run = CodeLensCommandRequest.onCleanup },
        };
        try self.code_lens_commands.append(self.allocator, request);
        return .{ .deferred = .{ .context = request, .start = CodeLensCommandRequest.start } };
    }

    pub fn executeDocumentHighlightCommand(self: *MainThreadLanguageFeatures, resource: std.Uri, position: Position, document: ?*EditorDocument, resolver_service: resolver.ITextModelService, commands: *CommandRegistry) !rpc.HandlerReply {
        const request = try self.allocator.create(DocumentHighlightCommandRequest);
        errdefer self.allocator.destroy(request);
        const resource_string = try std_uri.encodedResource(self.allocator, resource);
        errdefer self.allocator.free(resource_string);
        if (document) |loaded| loaded.retain();
        errdefer if (document) |loaded| loaded.release();
        request.* = .{ .owner = self, .commands = commands, .resolver_service = resolver_service, .resource_string = resource_string, .input_position = position, .document = document };
        try self.highlight_commands.append(self.allocator, request);
        return .{ .deferred = .{ .context = request, .start = DocumentHighlightCommandRequest.start } };
    }

    fn destroyRegistration(self: *MainThreadLanguageFeatures, registration: *Registration) void {
        if (registration.code_lens_state != null) {
            var index = self.code_lens_commands.items.len;
            while (index != 0) {
                index -= 1;
                const request = self.code_lens_commands.items[index];
                if (!request.execution.finished) request.cancel();
            }
        }
        if (registration.disposable) |disposable| disposable.dispose();
        if (registration.code_lens_state) |state| {
            if (state.event_handle) |handle| _ = self.code_lens_events.remove(handle);
            state.changed.deinit();
        }
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
            if (self.code_lens_events.fetchRemove(handle)) |entry| entry.value.event_handle = null;
            return .empty;
        }
        if (std.mem.eql(u8, method, "$registerInlineCompletionsSupport")) {
            const handle = handleArg(args) orelse return error.InvalidArguments;
            const selector = try parseSelector(arena, jsonArg(args, 1) orelse return error.InvalidArguments);
            const registration = try self.createRegistration(arena, handle);
            registration.disposable = try self.inline_providers.register(selector, .{ .handle = handle, .supports_events = boolArg(args, 2) });
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
        if (std.mem.eql(u8, method, "$registerDocumentHighlightProvider")) return self.registerDocumentHighlights(args, arena, false);
        if (std.mem.eql(u8, method, "$registerMultiDocumentHighlightProvider")) return self.registerDocumentHighlights(args, arena, true);
        if (std.mem.eql(u8, method, "$registerCodeLensSupport")) return self.registerCodeLens(args, arena);
        if (std.mem.eql(u8, method, "$emitCodeLensEvent")) {
            const handle = handleArg(args) orelse return error.InvalidArguments;
            if (self.code_lens_events.get(handle)) |state| try state.changed.fire({});
            return .empty;
        }
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
            .request_hover = requestHover,
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

    fn registerDocumentHighlights(self: *MainThreadLanguageFeatures, args: []const rpc.Arg, arena: Allocator, multi: bool) !rpc.HandlerReply {
        const handle = handleArg(args) orelse return error.InvalidArguments;
        const selector = try parseSelector(arena, jsonArg(args, 1) orelse return error.InvalidArguments);
        const registration = try self.createRegistration(arena, handle);
        errdefer {
            _ = self.registrations.remove(handle);
            self.destroyRegistration(registration);
        }
        registration.disposable = if (multi)
            try self.features.multi_document_highlight_provider.register(selector, .{
                .context = registration,
                .provide_multi_document_highlights = provideMultiDocumentHighlights,
                .request_multi_document_highlights = requestMultiDocumentHighlights,
            })
        else
            try self.features.document_highlight_provider.register(selector, .{
                .context = registration,
                .provide_document_highlights = provideDocumentHighlights,
                .request_document_highlights = requestDocumentHighlights,
            });
        return .empty;
    }

    fn registerCodeLens(self: *MainThreadLanguageFeatures, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        const handle = handleArg(args) orelse return error.InvalidArguments;
        const selector = try parseSelector(arena, jsonArg(args, 1) orelse return error.InvalidArguments);
        const registration = try self.createRegistration(arena, handle);
        errdefer {
            _ = self.registrations.remove(handle);
            self.destroyRegistration(registration);
        }
        const state = try registration.arena.allocator().create(CodeLensState);
        state.* = .{ .registration = registration, .changed = @import("../../../base/common/event.zig").Emitter(void).init(self.allocator) };
        registration.code_lens_state = state;
        if (jsonArg(args, 2)) |event| if (event == .integer and event.integer >= 0 and event.integer <= std.math.maxInt(u32)) {
            const event_handle: u32 = @intCast(event.integer);
            try self.code_lens_events.put(event_handle, state);
            state.event_handle = event_handle;
        };
        registration.disposable = try self.features.code_lens_provider.register(selector, .{
            .context = state,
            .on_did_change = if (state.event_handle != null) &state.changed else null,
            .provide_code_lenses = provideCodeLenses,
            .request_code_lenses = requestCodeLenses,
            .resolve_code_lens = resolveCodeLens,
            .request_resolve_code_lens = requestResolveCodeLens,
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

    fn hoverArgs(allocator: Allocator, handle: u32, model: *TextModel, position: Position) ![4]rpc.Arg {
        return .{
            .{ .json = .{ .integer = handle } },
            .{ .json = try std_uri.jsonComponents(allocator, model.uri()) },
            .{ .json = try positionJson(allocator, model, position) },
            .{ .json = .{ .object = .empty } },
        };
    }

    fn parseHoverReply(allocator: Allocator, proxy: HostProxy, handle: u32, model: *TextModel, reply: std.json.Value) !?languages.Hover {
        if (reply != .object) return null;
        const object = reply.object;
        // The terminal currently renders the complete result without IDE
        // verbosity controls. Release the cached extension-host hover after
        // copying its DTO, rather than retaining unowned provider handles.
        if (object.get("id")) |id_value| if (id_value == .integer) {
            const release = [_]rpc.Arg{ .{ .json = .{ .integer = handle } }, .{ .json = id_value } };
            proxy.notify(proxy.context, "$releaseHover", &release) catch {};
        };
        const contents_value = object.get("contents") orelse return null;
        var contents = std.array_list.Managed(languages.IMarkdownString).init(allocator);
        try appendHoverContents(&contents, allocator, contents_value);
        if (contents.items.len == 0) return null;
        return .{
            .contents = try contents.toOwnedSlice(),
            .range = if (object.get("range")) |range| rangeFromJson(model, range) else null,
            .can_increase_verbosity = optionalBool(object.get("canIncreaseVerbosity")),
            .can_decrease_verbosity = optionalBool(object.get("canDecreaseVerbosity")),
        };
    }

    fn provideHover(context: *anyopaque, model: *TextModel, position: Position, token: CancellationToken, hover_context: ?*const languages.HoverContext) anyerror!?languages.Hover {
        _ = hover_context;
        const state: *HoverState = @ptrCast(@alignCast(context));
        const self = state.registration.owner;
        _ = state.arena.reset(.retain_capacity);
        const scratch = state.arena.allocator();
        const args = try hoverArgs(scratch, state.registration.handle, model, position);
        const reply = self.call(scratch, "$provideHover", &args, token, timeout_hover_ms) catch return null;
        return parseHoverReply(scratch, self.proxy, state.registration.handle, model, reply);
    }

    const HoverAsyncRequest = struct {
        allocator: Allocator,
        proxy: HostProxy,
        handle: u32,
        model: *TextModel,
        callback: languages.HoverCallback,

        fn ready(context: *anyopaque, reply: rpc.Reply) void {
            const self: *HoverAsyncRequest = @ptrCast(@alignCast(context));
            self.callback.complete(self.callback.context, switch (reply) {
                .json => |value| parseHoverReply(self.allocator, self.proxy, self.handle, self.model, value),
                .err => error.RequestFailed,
                else => null,
            });
        }
    };

    fn requestHover(context: *anyopaque, allocator: Allocator, model: *TextModel, position: Position, token: CancellationToken, hover_context: ?*const languages.HoverContext, callback: languages.HoverCallback) !?IDisposable {
        const state: *HoverState = @ptrCast(@alignCast(context));
        try token.throwIfCancellationRequested();
        const proxy = state.registration.owner.proxy;
        if (proxy.request_async) |request| {
            var scratch = std.heap.ArenaAllocator.init(state.registration.owner.allocator);
            defer scratch.deinit();
            const pending = try allocator.create(HoverAsyncRequest);
            pending.* = .{ .allocator = allocator, .proxy = proxy, .handle = state.registration.handle, .model = model, .callback = callback };
            const args = try hoverArgs(scratch.allocator(), state.registration.handle, model, position);
            return try request(proxy.context, "$provideHover", &args, .{ .context = pending, .callback = HoverAsyncRequest.ready });
        }
        callback.complete(callback.context, provideHover(context, model, position, token, hover_context));
        return null;
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

    const CodeLensRelease = struct {
        proxy: HostProxy,
        handle: u32,
        cache_id: i64,
        fn dispose(context: *anyopaque) void {
            const self: *CodeLensRelease = @ptrCast(@alignCast(context));
            self.proxy.notify(self.proxy.context, "$releaseCodeLenses", &.{ .{ .json = .{ .integer = self.handle } }, .{ .json = .{ .integer = self.cache_id } } }) catch {};
        }
    };

    fn parseCodeLens(allocator: Allocator, model: *TextModel, value: std.json.Value) !?languages.CodeLens {
        if (value != .object) return null;
        const range = rangeFromJson(model, value.object.get("range") orelse return null) orelse return null;
        var command: ?languages.Command = null;
        if (value.object.get("command")) |cmd| if (cmd == .object) {
            command = .{
                .id = try dupJsonString(allocator, cmd.object.get("id")),
                .title = try dupJsonString(allocator, cmd.object.get("title")),
                .arguments = if (cmd.object.get("arguments")) |arguments| try rpc.cloneJsonValue(allocator, arguments) else null,
            };
        };
        return .{ .range = range, .command = command, .provider_data = try rpc.cloneJsonValue(allocator, value) };
    }

    fn parseCodeLensList(state: *CodeLensState, allocator: Allocator, model: *TextModel, value: std.json.Value) !?languages.CodeLensList {
        if (value != .object) return null;
        var release: ?IDisposable = null;
        if (value.object.get("cacheId")) |cache| if (cache == .integer) {
            const context = try allocator.create(CodeLensRelease);
            context.* = .{ .proxy = state.registration.owner.proxy, .handle = state.registration.handle, .cache_id = cache.integer };
            release = .{ .context = context, .disposeFn = CodeLensRelease.dispose };
        };
        errdefer if (release) |disposable| disposable.dispose();
        var result: std.ArrayList(languages.CodeLens) = .empty;
        const lenses = value.object.get("lenses") orelse return .{ .disposable = release };
        if (lenses != .array) return .{ .disposable = release };
        for (lenses.array.items) |item| if (try parseCodeLens(allocator, model, item)) |lens| try result.append(allocator, lens);
        return .{ .lenses = try result.toOwnedSlice(allocator), .disposable = release };
    }

    fn highlightArgs(arena: Allocator, handle: u32, model: *TextModel, position: Position, others: ?[]const *TextModel) ![]rpc.Arg {
        const args = try arena.alloc(rpc.Arg, if (others == null) 3 else 4);
        args[0] = .{ .json = .{ .integer = handle } };
        args[1] = .{ .json = try std_uri.jsonComponents(arena, model.uri()) };
        args[2] = .{ .json = try positionJson(arena, model, position) };
        if (others) |models| {
            var values = std.json.Array.init(arena);
            for (models) |other| try values.append(try std_uri.jsonComponents(arena, other.uri()));
            args[3] = .{ .json = .{ .array = values } };
        }
        return args;
    }

    fn parseDocumentHighlights(allocator: Allocator, model: *TextModel, value: std.json.Value) !?[]const languages.DocumentHighlight {
        if (value != .array) return null;
        var highlights: std.ArrayList(languages.DocumentHighlight) = .empty;
        errdefer highlights.deinit(allocator);
        for (value.array.items) |item| {
            if (item != .object) continue;
            const range = rangeFromJson(model, item.object.get("range") orelse continue) orelse continue;
            const kind = intField(item.object, "kind");
            try highlights.append(allocator, .{ .range = range, .kind = if (kind) |k| std.enums.fromInt(languages.DocumentHighlightKind, k) else null });
        }
        return try highlights.toOwnedSlice(allocator);
    }

    fn parseMultiDocumentHighlights(allocator: Allocator, primary: *TextModel, others: []const *TextModel, value: std.json.Value) !?[]const languages.MultiDocumentHighlight {
        if (value != .array) return null;
        const Accumulator = struct { model: *TextModel, highlights: std.ArrayList(languages.DocumentHighlight) = .empty };
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var models: std.StringHashMapUnmanaged(*TextModel) = .empty;
        try models.put(a, try std_uri.resourceKey(a, primary.uri()), primary);
        for (others) |model| try models.put(a, try std_uri.resourceKey(a, model.uri()), model);
        var entries: std.StringArrayHashMapUnmanaged(Accumulator) = .empty;
        for (value.array.items) |item| {
            if (item != .object) continue;
            const key = resourceKeyFromComponentsJson(a, item.object.get("uri") orelse continue) catch continue;
            const model = models.get(key) orelse continue;
            const highlights = try parseDocumentHighlights(a, model, item.object.get("highlights") orelse continue) orelse continue;
            const entry = try entries.getOrPut(a, key);
            if (!entry.found_existing) entry.value_ptr.* = .{ .model = model };
            // The upstream DTO can contain repeated URIs; concatenate their
            // ranges in provider order before returning the ResourceMap.
            try entry.value_ptr.highlights.appendSlice(a, highlights);
        }
        const result = try allocator.alloc(languages.MultiDocumentHighlight, entries.count());
        for (result, entries.values()) |*entry, accumulated| entry.* = .{
            .uri = accumulated.model.uri(),
            .highlights = try allocator.dupe(languages.DocumentHighlight, accumulated.highlights.items),
        };
        return result;
    }

    const HighlightRequest = struct {
        allocator: Allocator,
        model: *TextModel,
        callback: union(enum) {
            single: languages.DocumentHighlightCallback,
            multi: struct { others: []const *TextModel, callback: languages.MultiDocumentHighlightCallback },
        },

        fn ready(context: *anyopaque, reply: rpc.Reply) void {
            const self: *HighlightRequest = @ptrCast(@alignCast(context));
            switch (self.callback) {
                .single => |cb| cb.complete(cb.context, switch (reply) {
                    .json => |value| parseDocumentHighlights(self.allocator, self.model, value),
                    .err => error.RequestFailed,
                    else => null,
                }),
                .multi => |multi| multi.callback.complete(multi.callback.context, switch (reply) {
                    .json => |value| parseMultiDocumentHighlights(self.allocator, self.model, multi.others, value),
                    .err => error.RequestFailed,
                    else => null,
                }),
            }
        }
    };

    fn provideDocumentHighlights(context: *anyopaque, allocator: Allocator, model: *TextModel, position: Position, token: CancellationToken) !?[]const languages.DocumentHighlight {
        const registration: *Registration = @ptrCast(@alignCast(context));
        var scratch = std.heap.ArenaAllocator.init(registration.owner.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const args = try highlightArgs(a, registration.handle, model, position, null);
        const value = try registration.owner.call(a, "$provideDocumentHighlights", args, token, timeout_format_ms);
        return parseDocumentHighlights(allocator, model, value);
    }

    fn provideMultiDocumentHighlights(context: *anyopaque, allocator: Allocator, model: *TextModel, position: Position, others: []const *TextModel, token: CancellationToken) !?[]const languages.MultiDocumentHighlight {
        const registration: *Registration = @ptrCast(@alignCast(context));
        var scratch = std.heap.ArenaAllocator.init(registration.owner.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const args = try highlightArgs(a, registration.handle, model, position, others);
        const value = try registration.owner.call(a, "$provideMultiDocumentHighlights", args, token, timeout_format_ms);
        return parseMultiDocumentHighlights(allocator, model, others, value);
    }

    fn requestDocumentHighlights(context: *anyopaque, allocator: Allocator, model: *TextModel, position: Position, token: CancellationToken, callback: languages.DocumentHighlightCallback) !?IDisposable {
        const registration: *Registration = @ptrCast(@alignCast(context));
        try token.throwIfCancellationRequested();
        const proxy = registration.owner.proxy;
        if (proxy.request_async) |request| {
            var scratch = std.heap.ArenaAllocator.init(registration.owner.allocator);
            defer scratch.deinit();
            const pending = try allocator.create(HighlightRequest);
            pending.* = .{ .allocator = allocator, .model = model, .callback = .{ .single = callback } };
            const args = try highlightArgs(scratch.allocator(), registration.handle, model, position, null);
            return try request(proxy.context, "$provideDocumentHighlights", args, .{ .context = pending, .callback = HighlightRequest.ready });
        }
        callback.complete(callback.context, provideDocumentHighlights(context, allocator, model, position, token));
        return null;
    }

    fn requestMultiDocumentHighlights(context: *anyopaque, allocator: Allocator, model: *TextModel, position: Position, others: []const *TextModel, token: CancellationToken, callback: languages.MultiDocumentHighlightCallback) !?IDisposable {
        const registration: *Registration = @ptrCast(@alignCast(context));
        try token.throwIfCancellationRequested();
        const proxy = registration.owner.proxy;
        if (proxy.request_async) |request| {
            var scratch = std.heap.ArenaAllocator.init(registration.owner.allocator);
            defer scratch.deinit();
            const pending = try allocator.create(HighlightRequest);
            pending.* = .{ .allocator = allocator, .model = model, .callback = .{ .multi = .{ .others = others, .callback = callback } } };
            const args = try highlightArgs(scratch.allocator(), registration.handle, model, position, others);
            return try request(proxy.context, "$provideMultiDocumentHighlights", args, .{ .context = pending, .callback = HighlightRequest.ready });
        }
        callback.complete(callback.context, provideMultiDocumentHighlights(context, allocator, model, position, others, token));
        return null;
    }

    fn provideCodeLenses(context: *anyopaque, allocator: Allocator, model: *TextModel, token: CancellationToken) !?languages.CodeLensList {
        const state: *CodeLensState = @ptrCast(@alignCast(context));
        const self = state.registration.owner;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const args = [_]rpc.Arg{ .{ .json = .{ .integer = state.registration.handle } }, .{ .json = try std_uri.jsonComponents(a, model.uri()) } };
        const value = try self.call(a, "$provideCodeLenses", &args, token, timeout_format_ms);
        return parseCodeLensList(state, allocator, model, value);
    }

    const CodeLensRequest = struct {
        state: *CodeLensState,
        allocator: Allocator,
        model: *TextModel,
        callback: union(enum) { provide: languages.CodeLensCallback, resolve: languages.CodeLensResolveCallback },

        fn ready(context: *anyopaque, reply: rpc.Reply) void {
            const self: *CodeLensRequest = @ptrCast(@alignCast(context));
            switch (self.callback) {
                .provide => |cb| cb.complete(cb.context, if (reply == .json) parseCodeLensList(self.state, self.allocator, self.model, reply.json) catch null else null),
                .resolve => |cb| cb.complete(cb.context, if (reply == .json) parseCodeLens(self.allocator, self.model, reply.json) catch null else null),
            }
        }
    };

    fn requestCodeLenses(context: *anyopaque, allocator: Allocator, model: *TextModel, callback: languages.CodeLensCallback) !?IDisposable {
        const state: *CodeLensState = @ptrCast(@alignCast(context));
        const proxy = state.registration.owner.proxy;
        if (proxy.request_async) |request| {
            var scratch = std.heap.ArenaAllocator.init(state.registration.owner.allocator);
            defer scratch.deinit();
            const pending = try allocator.create(CodeLensRequest);
            pending.* = .{ .state = state, .allocator = allocator, .model = model, .callback = .{ .provide = callback } };
            const args = [_]rpc.Arg{ .{ .json = .{ .integer = state.registration.handle } }, .{ .json = try std_uri.jsonComponents(scratch.allocator(), model.uri()) } };
            return try request(proxy.context, "$provideCodeLenses", &args, .{ .context = pending, .callback = CodeLensRequest.ready });
        }
        callback.complete(callback.context, provideCodeLenses(context, allocator, model, CancellationToken.None) catch null);
        return null;
    }

    fn resolveArgs(allocator: Allocator, state: *CodeLensState, model: *TextModel, symbol: languages.CodeLens) ![2]rpc.Arg {
        var dto = try rpc.cloneJsonValue(allocator, symbol.provider_data orelse return error.InvalidCodeLens);
        if (dto != .object) return error.InvalidCodeLens;
        try dto.object.put(allocator, "range", try rangeJson(allocator, model, symbol.range));
        return .{ .{ .json = .{ .integer = state.registration.handle } }, .{ .json = dto } };
    }

    fn resolveCodeLens(context: *anyopaque, allocator: Allocator, model: *TextModel, symbol: languages.CodeLens, token: CancellationToken) !?languages.CodeLens {
        const state: *CodeLensState = @ptrCast(@alignCast(context));
        const self = state.registration.owner;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const args = try resolveArgs(a, state, model, symbol);
        const value = try self.call(a, "$resolveCodeLens", &args, token, timeout_format_ms);
        return parseCodeLens(allocator, model, value);
    }

    fn requestResolveCodeLens(context: *anyopaque, allocator: Allocator, model: *TextModel, symbol: languages.CodeLens, callback: languages.CodeLensResolveCallback) !?IDisposable {
        const state: *CodeLensState = @ptrCast(@alignCast(context));
        const proxy = state.registration.owner.proxy;
        if (proxy.request_async) |request| {
            var scratch = std.heap.ArenaAllocator.init(state.registration.owner.allocator);
            defer scratch.deinit();
            const pending = try allocator.create(CodeLensRequest);
            pending.* = .{ .state = state, .allocator = allocator, .model = model, .callback = .{ .resolve = callback } };
            const args = try resolveArgs(scratch.allocator(), state, model, symbol);
            return try request(proxy.context, "$resolveCodeLens", &args, .{ .context = pending, .callback = CodeLensRequest.ready });
        }
        callback.complete(callback.context, resolveCodeLens(context, allocator, model, symbol, CancellationToken.None) catch null);
        return null;
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

pub fn positionJson(arena: Allocator, model: *TextModel, position: Position) !std.json.Value {
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

pub fn rangeFromJson(model: *TextModel, value: std.json.Value) ?Range {
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

fn optionalBool(value: ?std.json.Value) ?bool {
    const item = value orelse return null;
    return if (item == .bool) item.bool else null;
}

fn appendHoverContents(result: *std.array_list.Managed(languages.IMarkdownString), allocator: Allocator, value: std.json.Value) !void {
    switch (value) {
        .string => |text| try result.append(.{ .value = try allocator.dupe(u8, text) }),
        .object => |object| {
            if (object.get("value")) |content| {
                if (content == .string) try result.append(.{
                    .value = try allocator.dupe(u8, content.string),
                    .is_trusted = optionalBool(object.get("isTrusted")),
                    .support_theme_icons = optionalBool(object.get("supportThemeIcons")),
                    .support_html = optionalBool(object.get("supportHtml")),
                });
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
