// Port of the baseline subset of
// `src/vs/workbench/api/browser/mainThreadLanguageFeatures.ts`.
//
// Ported features: hover, completion, definition, declaration,
// implementation, type definition, references, document/workspace symbols, single- and
// multi-document highlights, folding/selection ranges, CodeLens, code actions
// and document/range/on-type formatting. The actor stores providers by handle
// in `LanguageFeaturesService`, converts the extension-host DTOs into editor
// types and forwards provider calls back to `ExtHostLanguageFeatures`.
//
// Terminal adaptation: existing synchronous providers have bounded timeouts;
// Hover, CodeLens, document highlights and code-action providers use
// cancellable RPC continuations. Code-action workspace edits are revived
// into typed bulk-edit operations; their raw DTOs also preserve extension
// command and public provider result conversion.

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
const workspace_symbols = @import("../../contrib/search/common/search.zig");
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
    workspace_symbol_state: ?*WorkspaceSymbolState = null,
    folding_state: ?*FoldingState = null,
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
    provided_kinds: ?[]const []const u8,
    documentation: []const languages.CodeActionDocumentation,
    supports_resolve: bool,
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

const hover_model = @import("../../../editor/contrib/hover/browser/getHover.zig");
const occurrence_model = @import("../../../editor/contrib/wordHighlighter/browser/wordHighlighter.zig");
const resolver = @import("../../../editor/common/services/resolverService.zig");

pub const ModelPositionCommand = enum {
    document_highlights,
    hover,
    hover_recursive,

    pub fn id(self: ModelPositionCommand) []const u8 {
        return switch (self) {
            .document_highlights => "_executeDocumentHighlights",
            .hover => "_executeHoverProvider",
            .hover_recursive => "_executeHoverProvider_recursive",
        };
    }

    pub fn fromId(command: []const u8) ?ModelPositionCommand {
        for (std.enums.values(ModelPositionCommand)) |value| if (std.mem.eql(u8, command, value.id())) return value;
        return null;
    }
};

// registerModelAndPositionCommand retains the resolved model throughout the
// asynchronous provider execution, including an unmounted resource.
const ModelPositionCommandRequest = struct {
    owner: *MainThreadLanguageFeatures,
    commands: *CommandRegistry,
    command: ModelPositionCommand,
    arena: std.heap.ArenaAllocator,
    hover_items: std.json.Array,
    hover_error: ?anyerror = null,
    pending_hover: ?IDisposable = null,
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
        const self: *ModelPositionCommandRequest = @ptrCast(@alignCast(context));
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
        const self: *ModelPositionCommandRequest = @ptrCast(@alignCast(context));
        self.resolving = null;
        switch (result) {
            .failure => |err| self.fail(err),
            .resolved => |reference| {
                self.reference = reference;
                self.run(reference.object.textEditorModel);
            },
        }
    }

    fn currentModel(self: *ModelPositionCommandRequest) *TextModel {
        return if (self.document) |document| document.model else self.reference.?.object.textEditorModel;
    }

    fn run(self: *ModelPositionCommandRequest, model: *TextModel) void {
        const command = self.commands.get(self.command.id()) orelse return self.fail(error.CommandNotFound);
        const position = Position.init(self.input_position.lineNumber, columnForModel(model, self.input_position.lineNumber, self.input_position.column));
        self.starting = true;
        switch (self.command) {
            .document_highlights => {
                const args: occurrence_model.ExecuteDocumentHighlightsArgs = .{
                    .allocator = self.owner.allocator,
                    .registry = &self.owner.features.document_highlight_provider,
                    .model = model,
                    .position = position,
                    .listener = .{ .context = self, .complete = ready },
                    .pending = &self.pending,
                };
                command.executeWithArgument(@import("../../../platform/commands/common/commands.zig").CommandArgument.from(occurrence_model.ExecuteDocumentHighlightsArgs, &args)) catch |err| self.fail(err);
            },
            .hover, .hover_recursive => {
                const args: hover_model.ExecuteHoverProviderArgs = .{
                    .allocator = self.owner.allocator,
                    .registry = &self.owner.features.hover_provider,
                    .model = model,
                    .position = position,
                    .listener = .{ .context = self, .emit = hoverResult, .complete = hoverComplete },
                    .pending = &self.pending_hover,
                };
                command.executeWithArgument(@import("../../../platform/commands/common/commands.zig").CommandArgument.from(hover_model.ExecuteHoverProviderArgs, &args)) catch |err| self.fail(err);
            },
        }
        self.starting = false;
        if (self.finished) self.dispose();
    }

    fn hoverResult(context: *anyopaque, result: hover_model.HoverProviderResult) void {
        const self: *ModelPositionCommandRequest = @ptrCast(@alignCast(context));
        if (self.hover_error != null) return;
        self.appendHover(result.hover) catch |err| {
            self.hover_error = err;
        };
    }

    fn appendHover(self: *ModelPositionCommandRequest, hover: languages.Hover) !void {
        const a = self.arena.allocator();
        var dto: std.json.ObjectMap = .empty;
        try dto.put(a, "range", try rangeJson(a, self.currentModel(), hover.range.?));
        var contents = std.json.Array.init(a);
        for (hover.contents) |content| {
            var item: std.json.ObjectMap = .empty;
            try item.put(a, "value", .{ .string = try a.dupe(u8, content.value) });
            if (content.is_trusted) |flag| try item.put(a, "isTrusted", .{ .bool = flag });
            if (content.support_theme_icons) |flag| try item.put(a, "supportThemeIcons", .{ .bool = flag });
            if (content.support_html) |flag| try item.put(a, "supportHtml", .{ .bool = flag });
            try contents.append(.{ .object = item });
        }
        try dto.put(a, "contents", .{ .array = contents });
        if (hover.can_increase_verbosity) |flag| try dto.put(a, "canIncreaseVerbosity", .{ .bool = flag });
        if (hover.can_decrease_verbosity) |flag| try dto.put(a, "canDecreaseVerbosity", .{ .bool = flag });
        try self.hover_items.append(.{ .object = dto });
    }

    fn hoverComplete(context: *anyopaque) void {
        const self: *ModelPositionCommandRequest = @ptrCast(@alignCast(context));
        self.pending_hover = null;
        if (self.hover_error) |err| return self.fail(err);
        self.reply(.{ .json = .{ .array = self.hover_items } });
    }

    fn ready(context: *anyopaque, result: *occurrence_model.OccurrenceResult) void {
        const self: *ModelPositionCommandRequest = @ptrCast(@alignCast(context));
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

    fn fail(self: *ModelPositionCommandRequest, err: anyerror) void {
        self.reply(.{ .err = .{ .name = @errorName(err), .message = @errorName(err) } });
    }

    fn reply(self: *ModelPositionCommandRequest, value: rpc.HandlerReply) void {
        if (self.finished) return;
        self.finished = true;
        if (self.channel) |channel| channel.sendReply(self.request_id, value);
        self.channel = null;
        if (!self.starting) self.dispose();
    }

    fn dispose(self: *ModelPositionCommandRequest) void {
        if (self.resolving) |request| request.cancel();
        if (self.pending) |request| request.cancel();
        if (self.pending_hover) |request| request.dispose();
        self.arena.deinit();
        if (self.reference) |*reference| reference.dispose();
        if (self.document) |document| document.release();
        const owner = self.owner;
        for (owner.model_position_commands.items, 0..) |candidate, index| {
            if (candidate != self) continue;
            _ = owner.model_position_commands.swapRemove(index);
            break;
        }
        owner.allocator.free(self.resource_string);
        owner.allocator.destroy(self);
    }
};

const code_action_model = @import("../../../editor/contrib/codeAction/browser/codeAction.zig");
const Selection = @import("../../../editor/common/core/selection.zig").Selection;

/// Native RPC boundary for the registered `_executeCodeActionProvider` action.
/// Results and command caches remain valid for the upstream 100 ms grace
/// period after the public extension API response.
const CodeActionCommandRequest = struct {
    owner: *MainThreadLanguageFeatures,
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    commands: *CommandRegistry,
    resolver_service: resolver.ITextModelService,
    resource: std.Uri,
    input_range: std.json.Value,
    kind: ?[]const u8,
    resolve_count: usize,
    cleanup: WindowDispatch.Task = .{},
    document: ?*EditorDocument = null,
    reference: ?resolver.ModelReference = null,
    resolving: ?resolver.ModelReferenceRequest = null,
    pending: ?IDisposable = null,
    set: ?*code_action_model.ManagedCodeActionSet = null,
    channel: ?*rpc.RpcProtocol = null,
    request_id: u32 = 0,
    finished: bool = false,

    fn start(context: *anyopaque, channel: *rpc.RpcProtocol, id: u32) void {
        const self: *CodeActionCommandRequest = @ptrCast(@alignCast(context));
        self.channel = channel;
        self.request_id = id;
        if (self.document) |document| self.run(document.model) else {
            self.resolving = self.resolver_service.createModelReference(self.resource, .{ .context = self, .complete = modelReady }) catch |err| return self.fail(err);
        }
    }
    fn modelReady(context: *anyopaque, result: resolver.ModelReferenceResult) void {
        const self: *CodeActionCommandRequest = @ptrCast(@alignCast(context));
        self.resolving = null;
        switch (result) {
            .failure => |err| self.fail(err),
            .resolved => |reference| {
                self.reference = reference;
                self.run(reference.object.textEditorModel);
            },
        }
    }
    fn currentModel(self: *CodeActionCommandRequest) *TextModel {
        return if (self.document) |document| document.model else self.reference.?.object.textEditorModel;
    }
    fn run(self: *CodeActionCommandRequest, model: *TextModel) void {
        if (self.input_range != .object) return self.fail(error.InvalidArguments);
        const object = self.input_range.object;
        const selection: ?Selection = if (intField(object, "selectionStartLineNumber")) |line| blk: {
            const column = intField(object, "selectionStartColumn") orelse return self.fail(error.InvalidArguments);
            const end_line = intField(object, "positionLineNumber") orelse return self.fail(error.InvalidArguments);
            const end_column = intField(object, "positionColumn") orelse return self.fail(error.InvalidArguments);
            break :blk Selection.init(line, columnForModel(model, line, column), end_line, columnForModel(model, end_line, end_column));
        } else null;
        const range = if (selection) |value| Range.init(value.startLineNumber, value.startColumn, value.endLineNumber, value.endColumn) else rangeFromJson(model, self.input_range) orelse return self.fail(error.InvalidArguments);
        const command = self.commands.get("_executeCodeActionProvider") orelse return self.fail(error.CommandNotFound);
        const args: code_action_model.ExecuteCodeActionProviderArgs = .{ .allocator = self.allocator, .registry = &self.owner.features.code_action_provider, .model = model, .range = model.validateRange(range), .selection = selection, .kind = self.kind, .resolve_count = self.resolve_count, .listener = .{ .context = self, .complete = ready }, .pending = &self.pending };
        command.executeWithArgument(@import("../../../platform/commands/common/commands.zig").CommandArgument.from(code_action_model.ExecuteCodeActionProviderArgs, &args)) catch |err| self.fail(err);
    }
    fn ready(context: *anyopaque, outcome: anyerror!*code_action_model.ManagedCodeActionSet) void {
        const self: *CodeActionCommandRequest = @ptrCast(@alignCast(context));
        self.pending = null;
        const set = outcome catch |err| return self.fail(err);
        self.set = set;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var array = std.json.Array.init(a);
        for (set.valid_actions) |item| {
            const dto = self.serializeAction(a, item.action) catch |err| return self.fail(err);
            array.append(dto) catch |err| return self.fail(err);
        }
        self.reply(.{ .json = .{ .array = array } });
    }
    fn serializeAction(self: *CodeActionCommandRequest, a: Allocator, action: languages.CodeAction) !std.json.Value {
        var value: std.json.ObjectMap = .empty;
        try value.put(a, "title", .{ .string = action.title });
        if (action.kind) |kind| try value.put(a, "kind", .{ .string = kind });
        if (action.is_preferred) try value.put(a, "isPreferred", .{ .bool = true });
        if (action.is_ai) try value.put(a, "isAI", .{ .bool = true });
        if (action.is_synthetic) try value.put(a, "_isSynthetic", .{ .bool = true });
        if (action.command) |command| {
            var dto: std.json.ObjectMap = .empty;
            try dto.put(a, "id", .{ .string = command.id });
            try dto.put(a, "title", .{ .string = command.title });
            if (command.arguments) |arguments| try dto.put(a, "arguments", arguments);
            try value.put(a, "command", .{ .object = dto });
        }
        if (action.edit_json) |edit| try value.put(a, "edit", edit) else if (action.edit) |edit| try value.put(a, "edit", try self.serializeWorkspaceEdit(a, edit));
        return .{ .object = value };
    }
    fn serializeWorkspaceEdit(self: *CodeActionCommandRequest, a: Allocator, edit: languages.WorkspaceEdit) !std.json.Value {
        var edits = std.json.Array.init(a);
        for (edit.edits) |resource_edit| {
            var dto: std.json.ObjectMap = .empty;
            const metadata = switch (resource_edit) {
                .text => |text| blk: {
                    try dto.put(a, "resource", try std_uri.jsonComponents(a, text.resource));
                    if (text.version_id) |version| try dto.put(a, "versionId", .{ .integer = version });
                    var text_dto: std.json.ObjectMap = .empty;
                    try text_dto.put(a, "text", .{ .string = text.text });
                    if (text.eol) |eol| try text_dto.put(a, "eol", .{ .integer = @backingInt(eol) });
                    if (text.insert_as_snippet) try text_dto.put(a, "insertAsSnippet", .{ .bool = true });
                    if (text.keep_whitespace) try text_dto.put(a, "keepWhitespace", .{ .bool = true });
                    if (text.range) |range| {
                        const range_dto = if (text.column_encoding == .utf16) try rawRangeJson(a, range) else blk_range: {
                            const model = self.currentModel();
                            const key = try std_uri.resourceKey(a, text.resource);
                            const current_key = try std_uri.resourceKey(a, model.uri());
                            if (std.mem.eql(u8, key, current_key)) break :blk_range try rangeJson(a, model, range);
                            var reference = try self.resolver_service.acquireModelReference(text.resource);
                            defer reference.dispose();
                            break :blk_range try rangeJson(a, reference.object.textEditorModel, range);
                        };
                        try text_dto.put(a, "range", range_dto);
                    }
                    try dto.put(a, "textEdit", .{ .object = text_dto });
                    break :blk text.metadata;
                },
                .file => |file| blk: {
                    if (file.old_resource) |resource| try dto.put(a, "oldResource", try std_uri.jsonComponents(a, resource));
                    if (file.new_resource) |resource| try dto.put(a, "newResource", try std_uri.jsonComponents(a, resource));
                    var options: std.json.ObjectMap = .empty;
                    if (file.options.overwrite) |overwrite| try options.put(a, "overwrite", .{ .bool = overwrite });
                    inline for (.{ .{ "ignoreIfNotExists", file.options.ignore_if_not_exists }, .{ "ignoreIfExists", file.options.ignore_if_exists }, .{ "recursive", file.options.recursive }, .{ "copy", file.options.copy }, .{ "folder", file.options.folder }, .{ "skipTrashBin", file.options.skip_trash_bin } }) |pair| {
                        if (pair[1]) try options.put(a, pair[0], .{ .bool = true });
                    }
                    if (file.options.max_size) |size| try options.put(a, "maxSize", .{ .integer = @intCast(size) });
                    if (file.options.contents) |contents| {
                        const encoder = std.base64.standard.Encoder;
                        const encoded = try a.alloc(u8, encoder.calcSize(contents.len));
                        var content: std.json.ObjectMap = .empty;
                        try content.put(a, "type", .{ .string = "base64" });
                        try content.put(a, "value", .{ .string = encoder.encode(encoded, contents) });
                        try options.put(a, "contents", .{ .object = content });
                    }
                    try dto.put(a, "options", .{ .object = options });
                    break :blk file.metadata;
                },
            };
            if (metadata) |value| {
                var meta: std.json.ObjectMap = .empty;
                try meta.put(a, "label", .{ .string = value.label });
                try meta.put(a, "needsConfirmation", .{ .bool = value.needs_confirmation });
                if (value.description) |description| try meta.put(a, "description", .{ .string = description });
                try dto.put(a, "metadata", .{ .object = meta });
            }
            try edits.append(.{ .object = dto });
        }
        var object: std.json.ObjectMap = .empty;
        try object.put(a, "edits", .{ .array = edits });
        return .{ .object = object };
    }
    fn rawRangeJson(a: Allocator, range: Range) !std.json.Value {
        var result: std.json.ObjectMap = .empty;
        try result.put(a, "startLineNumber", .{ .integer = @intCast(range.startLineNumber) });
        try result.put(a, "startColumn", .{ .integer = @intCast(range.startColumn) });
        try result.put(a, "endLineNumber", .{ .integer = @intCast(range.endLineNumber) });
        try result.put(a, "endColumn", .{ .integer = @intCast(range.endColumn) });
        return .{ .object = result };
    }
    fn fail(self: *CodeActionCommandRequest, err: anyerror) void {
        self.reply(.{ .err = .{ .name = @errorName(err), .message = @errorName(err) } });
    }
    fn reply(self: *CodeActionCommandRequest, response: rpc.HandlerReply) void {
        if (self.finished) return;
        self.finished = true;
        if (self.channel) |channel| channel.sendReply(self.request_id, response);
        self.channel = null;
        self.cleanup.schedule(@import("../../../base/common/timeCompat.zig").milliTimestamp() + 100);
    }
    fn onCleanup(context: *anyopaque, _: i64, _: bool) bool {
        const self: *CodeActionCommandRequest = @ptrCast(@alignCast(context));
        self.dispose();
        return false;
    }
    fn dispose(self: *CodeActionCommandRequest) void {
        self.cleanup.schedule(null);
        if (self.resolving) |request| request.cancel();
        if (self.pending) |pending| pending.dispose();
        if (self.set) |set| set.dispose();
        if (self.reference) |*reference| reference.dispose();
        if (self.document) |document| document.release();
        for (self.owner.code_action_commands.items, 0..) |candidate, i| if (candidate == self) {
            _ = self.owner.code_action_commands.swapRemove(i);
            break;
        };
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

pub const MainThreadLanguageFeatures = struct {
    allocator: Allocator,
    features: *features_mod.LanguageFeaturesService,
    proxy: HostProxy,
    workspace_symbol_registry: ?*workspace_symbols.WorkspaceSymbolProviderRegistry = null,
    registrations: std.AutoHashMap(u32, *Registration),
    code_lens_events: std.AutoHashMap(u32, *CodeLensState),
    folding_events: std.AutoHashMap(u32, *FoldingState),
    code_lens_commands: std.ArrayList(*CodeLensCommandRequest) = .empty,
    model_position_commands: std.ArrayList(*ModelPositionCommandRequest) = .empty,
    code_action_commands: std.ArrayList(*CodeActionCommandRequest) = .empty,
    inline_providers: @import("../../../editor/common/languageFeatureRegistry.zig").LanguageFeatureRegistry(InlineProvider),

    pub fn init(allocator: Allocator, features: *features_mod.LanguageFeaturesService, proxy: HostProxy) MainThreadLanguageFeatures {
        return .{
            .allocator = allocator,
            .features = features,
            .proxy = proxy,
            .inline_providers = .init(allocator),
            .registrations = std.AutoHashMap(u32, *Registration).init(allocator),
            .code_lens_events = std.AutoHashMap(u32, *CodeLensState).init(allocator),
            .folding_events = .init(allocator),
        };
    }

    pub fn deinit(self: *MainThreadLanguageFeatures) void {
        while (self.model_position_commands.items.len != 0) self.model_position_commands.items[self.model_position_commands.items.len - 1].dispose();
        self.model_position_commands.deinit(self.allocator);
        while (self.code_action_commands.items.len != 0) self.code_action_commands.items[self.code_action_commands.items.len - 1].dispose();
        self.code_action_commands.deinit(self.allocator);
        while (self.code_lens_commands.items.len != 0) self.code_lens_commands.items[self.code_lens_commands.items.len - 1].dispose();
        var iterator = self.registrations.valueIterator();
        while (iterator.next()) |registration_ptr| self.destroyRegistration(registration_ptr.*);
        self.registrations.deinit();
        self.code_lens_commands.deinit(self.allocator);
        self.code_lens_events.deinit();
        self.folding_events.deinit();
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

    pub fn executeCodeActionCommand(self: *MainThreadLanguageFeatures, resource: std.Uri, range: std.json.Value, kind: ?[]const u8, resolve_count: usize, document: ?*EditorDocument, resolver_service: resolver.ITextModelService, commands: *CommandRegistry, queue: *WindowDispatch.Queue) !rpc.HandlerReply {
        const request = try self.allocator.create(CodeActionCommandRequest);
        errdefer self.allocator.destroy(request);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned_resource = try std_uri.clone(a, resource);
        const owned_range = try rpc.cloneJsonValue(a, range);
        const owned_kind = if (kind) |value| try a.dupe(u8, value) else null;
        if (document) |loaded| loaded.retain();
        errdefer if (document) |loaded| loaded.release();
        request.* = .{ .owner = self, .allocator = self.allocator, .arena = arena, .commands = commands, .resolver_service = resolver_service, .resource = owned_resource, .input_range = owned_range, .kind = owned_kind, .resolve_count = resolve_count, .document = document };
        request.cleanup = .{ .queue = queue, .context = request, .run = CodeActionCommandRequest.onCleanup };
        try self.code_action_commands.append(self.allocator, request);
        return .{ .deferred = .{ .context = request, .start = CodeActionCommandRequest.start } };
    }

    pub fn executeModelPositionCommand(self: *MainThreadLanguageFeatures, command: ModelPositionCommand, resource: std.Uri, position: Position, document: ?*EditorDocument, resolver_service: resolver.ITextModelService, commands: *CommandRegistry) !rpc.HandlerReply {
        const request = try self.allocator.create(ModelPositionCommandRequest);
        errdefer self.allocator.destroy(request);
        const resource_string = try std_uri.encodedResource(self.allocator, resource);
        errdefer self.allocator.free(resource_string);
        if (document) |loaded| loaded.retain();
        errdefer if (document) |loaded| loaded.release();
        request.* = .{ .owner = self, .commands = commands, .command = command, .arena = .init(self.allocator), .hover_items = undefined, .resolver_service = resolver_service, .resource_string = resource_string, .input_position = position, .document = document };
        errdefer request.arena.deinit();
        request.hover_items = .init(request.arena.allocator());
        try self.model_position_commands.append(self.allocator, request);
        return .{ .deferred = .{ .context = request, .start = ModelPositionCommandRequest.start } };
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
        if (registration.workspace_symbol_state) |state| state.releaseLastResult();
        if (registration.folding_state) |state| {
            if (state.event_handle) |handle| _ = self.folding_events.remove(handle);
            state.changed.deinit();
        }
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
            if (self.folding_events.fetchRemove(handle)) |entry| entry.value.event_handle = null;
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
        if (std.mem.eql(u8, method, "$registerFoldingRangeProvider")) return self.registerFoldingRange(args, arena);
        if (std.mem.eql(u8, method, "$emitFoldingRangeEvent")) {
            const handle = handleArg(args) orelse return error.InvalidArguments;
            if (self.folding_events.get(handle)) |state| try state.changed.fire({});
            return .empty;
        }
        if (std.mem.eql(u8, method, "$registerSelectionRangeProvider")) return self.registerSelectionRange(args, arena);
        if (std.mem.eql(u8, method, "$registerNavigateTypeSupport")) return self.registerWorkspaceSymbol(args, arena);
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
            .provide_completion_items_deferred = if (self.proxy.request_async != null) requestCompletion else null,
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
                .requires_window_fiber = self.proxy.request_async != null,
                .provide_definition = provideDefinition,
            }),
            .declaration => registration.disposable = try self.features.declaration_provider.register(parsed, .{
                .context = state,
                .requires_window_fiber = self.proxy.request_async != null,
                .provide_declaration = provideDeclaration,
            }),
            .implementation => registration.disposable = try self.features.implementation_provider.register(parsed, .{
                .context = state,
                .requires_window_fiber = self.proxy.request_async != null,
                .provide_implementation = provideImplementation,
            }),
            .type_definition => registration.disposable = try self.features.type_definition_provider.register(parsed, .{
                .context = state,
                .requires_window_fiber = self.proxy.request_async != null,
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
            .requires_window_fiber = self.proxy.request_async != null,
            .provide_references = provideReferences,
        });
        return .empty;
    }

    fn registerFoldingRange(self: *MainThreadLanguageFeatures, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        const handle = handleArg(args) orelse return error.InvalidArguments;
        const selector_value = jsonArg(args, 1) orelse return error.InvalidArguments;
        const registration = try self.createRegistration(arena, handle);
        errdefer {
            _ = self.registrations.remove(handle);
            self.destroyRegistration(registration);
        }
        const a = registration.arena.allocator();
        const state = try a.create(FoldingState);
        state.* = .{ .registration = registration, .changed = .init(self.allocator) };
        registration.folding_state = state;
        if (jsonArg(args, 3)) |event| {
            if (event == .integer) state.event_handle = std.math.cast(u32, event.integer);
        }
        if (state.event_handle) |event| try self.folding_events.put(event, state);
        const selector = try parseSelector(a, selector_value);
        registration.disposable = try self.features.folding_range_provider.register(selector, .{
            .context = state,
            .id = try a.dupe(u8, extensionIdArg(args, 2)),
            .on_did_change = if (state.event_handle != null) &state.changed else null,
            .provide_folding_ranges = FoldingState.provide,
            .request_folding_ranges = if (self.proxy.request_async != null) FoldingState.request else null,
        });
        return .empty;
    }

    fn registerSelectionRange(self: *MainThreadLanguageFeatures, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        const handle = handleArg(args) orelse return error.InvalidArguments;
        const selector_value = jsonArg(args, 1) orelse return error.InvalidArguments;
        const registration = try self.createRegistration(arena, handle);
        errdefer {
            _ = self.registrations.remove(handle);
            self.destroyRegistration(registration);
        }
        const selector = try parseSelector(registration.arena.allocator(), selector_value);
        registration.disposable = try self.features.selection_range_provider.register(selector, .{
            .context = registration,
            .provide_selection_ranges = provideSelectionRanges,
            .request_selection_ranges = if (self.proxy.request_async != null) requestSelectionRanges else null,
        });
        return .empty;
    }

    fn selectionRangeArgs(allocator: Allocator, registration: *Registration, model: *TextModel, positions: []const Position) ![3]rpc.Arg {
        var values = std.json.Array.init(allocator);
        for (positions) |position| try values.append(try positionJson(allocator, model, position));
        return .{ .{ .json = .{ .integer = registration.handle } }, .{ .json = try std_uri.jsonComponents(allocator, model.uri()) }, .{ .json = .{ .array = values } } };
    }

    fn parseSelectionRangeReply(allocator: Allocator, model: *TextModel, value: std.json.Value) ![]const []const languages.SelectionRange {
        if (value != .array) return &.{};
        const buckets = try allocator.alloc([]const languages.SelectionRange, value.array.items.len);
        for (value.array.items, buckets) |bucket, *dest| {
            if (bucket != .array) return error.InvalidResult;
            var ranges: std.ArrayList(languages.SelectionRange) = .empty;
            for (bucket.array.items) |item| {
                if (item != .object) continue;
                const range = rangeFromJson(model, item.object.get("range") orelse continue) orelse continue;
                try ranges.append(allocator, .{ .range = range });
            }
            dest.* = ranges.items;
        }
        return buckets;
    }

    fn provideSelectionRanges(context: *anyopaque, allocator: Allocator, model: *TextModel, positions: []const Position, token: CancellationToken) ![]const []const languages.SelectionRange {
        const registration: *Registration = @ptrCast(@alignCast(context));
        const args = try selectionRangeArgs(allocator, registration, model, positions);
        const reply = try registration.owner.call(allocator, "$provideSelectionRanges", &args, token, timeout_default_ms);
        return parseSelectionRangeReply(allocator, model, reply);
    }

    const SelectionRangeRequest = struct {
        allocator: Allocator,
        model: *TextModel,
        callback: languages.SelectionRangesCallback,

        fn ready(context: *anyopaque, reply: rpc.Reply) void {
            const self: *SelectionRangeRequest = @ptrCast(@alignCast(context));
            self.callback.complete(self.callback.context, switch (reply) {
                .json => |value| parseSelectionRangeReply(self.allocator, self.model, value),
                .err => error.RequestFailed,
                else => @as([]const []const languages.SelectionRange, &.{}),
            });
        }
    };

    fn requestSelectionRanges(context: *anyopaque, allocator: Allocator, model: *TextModel, positions: []const Position, callback: languages.SelectionRangesCallback) !IDisposable {
        const registration: *Registration = @ptrCast(@alignCast(context));
        const proxy = registration.owner.proxy;
        const request = proxy.request_async orelse return error.RequestFailed;
        const pending = try allocator.create(SelectionRangeRequest);
        pending.* = .{ .allocator = allocator, .model = model, .callback = callback };
        const args = try selectionRangeArgs(allocator, registration, model, positions);
        return request(proxy.context, "$provideSelectionRanges", &args, .{ .context = pending, .callback = SelectionRangeRequest.ready });
    }

    fn registerWorkspaceSymbol(self: *MainThreadLanguageFeatures, args: []const rpc.Arg, arena: Allocator) !rpc.HandlerReply {
        const registry = self.workspace_symbol_registry orelse return .{ .err = .{ .name = "Unavailable", .message = "Workspace symbols" } };
        const handle = handleArg(args) orelse return error.InvalidArguments;
        const registration = try self.createRegistration(arena, handle);
        errdefer {
            _ = self.registrations.remove(handle);
            self.destroyRegistration(registration);
        }
        const state = try registration.arena.allocator().create(WorkspaceSymbolState);
        state.* = .{ .registration = registration };
        registration.workspace_symbol_state = state;
        registration.disposable = try registry.register(.{
            .context = state,
            .provide = WorkspaceSymbolState.provide,
            .resolve = if (boolArg(args, 1)) WorkspaceSymbolState.resolve else null,
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
            .request_document_symbols = if (self.proxy.request_async != null) requestDocumentSymbols else null,
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
        errdefer {
            _ = self.registrations.remove(handle);
            self.destroyRegistration(registration);
        }
        const state = try registration.arena.allocator().create(CodeActionState);
        state.* = .{
            .registration = registration,
            .display_name = try dupString(registration.arena.allocator(), stringArg(args, 3)),
            .extension_id = try dupString(registration.arena.allocator(), stringArg(args, 4)),
            .provided_kinds = if (metadataKinds(jsonArg(args, 2))) |kinds| try stringArray(registration.arena.allocator(), kinds) else null,
            .documentation = try parseCodeActionDocumentation(registration.arena.allocator(), jsonArg(args, 2)),
            .supports_resolve = boolArg(args, 5),
        };
        registration.disposable = try self.features.code_action_provider.register(parsed, .{
            .context = state,
            .display_name = state.display_name,
            .extension_id = state.extension_id,
            .provided_kinds = state.provided_kinds,
            .documentation = state.documentation,
            .provide_code_actions = provideCodeActions,
            .request_code_actions = requestCodeActions,
            .resolve_code_action = if (state.supports_resolve) resolveCodeAction else null,
            .request_resolve_code_action = if (state.supports_resolve) requestResolveCodeAction else null,
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
                .requires_window_fiber = self.proxy.request_async != null,
                .provide_document_formatting_edits = provideDocumentFormatting,
            }),
            .range => registration.disposable = try self.features.document_range_formatting_edit_provider.register(parsed, .{
                .context = state,
                .extension_id = state.extension_id,
                .display_name = state.display_name,
                .requires_window_fiber = self.proxy.request_async != null,
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

    fn hoverArgs(allocator: Allocator, handle: u32, model: *TextModel, position: Position, hover_context: ?*const languages.HoverContext) ![4]rpc.Arg {
        var context: std.json.ObjectMap = .empty;
        if (hover_context) |value| if (value.verbosity_request) |verbosity| {
            if (verbosity.previous_hover.id) |id| {
                var previous: std.json.ObjectMap = .empty;
                try previous.put(allocator, "id", .{ .integer = id });
                var request: std.json.ObjectMap = .empty;
                try request.put(allocator, "verbosityDelta", .{ .integer = verbosity.verbosity_delta });
                try request.put(allocator, "previousHover", .{ .object = previous });
                try context.put(allocator, "verbosityRequest", .{ .object = request });
            }
        };
        return .{
            .{ .json = .{ .integer = handle } },
            .{ .json = try std_uri.jsonComponents(allocator, model.uri()) },
            .{ .json = try positionJson(allocator, model, position) },
            .{ .json = .{ .object = context } },
        };
    }

    fn parseHoverReply(allocator: Allocator, model: *TextModel, reply: std.json.Value) !?languages.Hover {
        if (reply != .object) return null;
        const object = reply.object;
        // Match upstream: the extension host owns a bounded cache of ten
        // original Hover objects. Retain their IDs for verbosity requests;
        // upstream's FinalizationRegistry release is deliberately disabled.
        const id: ?u32 = if (object.get("id")) |value| if (value == .integer and value.integer >= 0 and value.integer <= std.math.maxInt(u32)) @intCast(value.integer) else null else null;
        const contents_value = object.get("contents") orelse return null;
        var contents = std.array_list.Managed(languages.IMarkdownString).init(allocator);
        try appendHoverContents(&contents, allocator, contents_value);
        if (contents.items.len == 0) return null;
        return .{
            .id = id,
            .contents = try contents.toOwnedSlice(),
            .range = if (object.get("range")) |range| rangeFromJson(model, range) else null,
            .can_increase_verbosity = optionalBool(object.get("canIncreaseVerbosity")),
            .can_decrease_verbosity = optionalBool(object.get("canDecreaseVerbosity")),
        };
    }

    fn provideHover(context: *anyopaque, model: *TextModel, position: Position, token: CancellationToken, hover_context: ?*const languages.HoverContext) anyerror!?languages.Hover {
        const state: *HoverState = @ptrCast(@alignCast(context));
        const self = state.registration.owner;
        _ = state.arena.reset(.retain_capacity);
        const scratch = state.arena.allocator();
        const args = try hoverArgs(scratch, state.registration.handle, model, position, hover_context);
        const reply = self.call(scratch, "$provideHover", &args, token, timeout_hover_ms) catch return null;
        return parseHoverReply(scratch, model, reply);
    }

    const HoverAsyncRequest = struct {
        allocator: Allocator,
        model: *TextModel,
        callback: languages.HoverCallback,

        fn ready(context: *anyopaque, reply: rpc.Reply) void {
            const self: *HoverAsyncRequest = @ptrCast(@alignCast(context));
            self.callback.complete(self.callback.context, switch (reply) {
                .json => |value| parseHoverReply(self.allocator, self.model, value),
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
            pending.* = .{ .allocator = allocator, .model = model, .callback = callback };
            const args = try hoverArgs(scratch.allocator(), state.registration.handle, model, position, hover_context);
            return try request(proxy.context, "$provideHover", &args, .{ .context = pending, .callback = HoverAsyncRequest.ready });
        }
        callback.complete(callback.context, provideHover(context, model, position, token, hover_context));
        return null;
    }

    fn completionArgs(scratch: Allocator, handle: u32, model: *TextModel, position: Position, trigger: completion.CompletionContext) ![]rpc.Arg {
        var args = std.array_list.Managed(rpc.Arg).init(scratch);
        try args.append(.{ .json = .{ .integer = handle } });
        try args.append(.{ .json = try std_uri.jsonComponents(scratch, model.uri()) });
        try args.append(.{ .json = try positionJson(scratch, model, position) });
        var context_json: std.json.ObjectMap = .empty;
        try context_json.put(scratch, "triggerKind", .{ .integer = @backingInt(trigger.trigger_kind) });
        if (trigger.trigger_character) |character| try context_json.put(scratch, "triggerCharacter", .{ .string = try scratch.dupe(u8, character) });
        try args.append(.{ .json = .{ .object = context_json } });
        return args.items;
    }

    fn provideCompletion(context: *anyopaque, allocator: Allocator, model: *TextModel, position: Position, trigger: completion.CompletionContext, token: CancellationToken) anyerror!completion.CompletionList {
        const state: *CompletionState = @ptrCast(@alignCast(context));
        const self = state.registration.owner;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const args = try completionArgs(scratch, state.registration.handle, model, position, trigger);
        const reply = self.call(scratch, "$provideCompletionItems", args, token, timeout_default_ms) catch return .{};
        return parseCompletionReply(allocator, self.proxy, state.registration.handle, model, reply);
    }

    fn parseCompletionReply(allocator: Allocator, proxy: HostProxy, handle: u32, model: *TextModel, reply: std.json.Value) !completion.CompletionList {
        if (reply != .object) return .{};
        const object = reply.object;
        if (object.get("x")) |cache| {
            if (cache == .integer) {
                var release = [_]rpc.Arg{
                    .{ .json = .{ .integer = handle } },
                    .{ .json = cache },
                };
                proxy.notify(proxy.context, "$releaseCompletionItems", &release) catch {};
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

    const CompletionAsyncRequest = struct {
        allocator: Allocator,
        model: *TextModel,
        proxy: HostProxy,
        handle: u32,
        pending: ?IDisposable = null,
        callback: ?completion.CompletionRequest.Callback = null,
        result: ?anyerror!completion.CompletionList = null,
        callback_context: *anyopaque = undefined,

        fn onComplete(context: *anyopaque, callback_context: *anyopaque, callback: completion.CompletionRequest.Callback) void {
            const self: *CompletionAsyncRequest = @ptrCast(@alignCast(context));
            self.callback_context = callback_context;
            self.callback = callback;
            if (self.result) |result| callback(callback_context, self, result);
        }

        fn cancel(context: *anyopaque) void {
            const self: *CompletionAsyncRequest = @ptrCast(@alignCast(context));
            if (self.pending) |pending| pending.dispose();
            self.pending = null;
        }

        fn ready(context: *anyopaque, reply: rpc.Reply) void {
            const self: *CompletionAsyncRequest = @ptrCast(@alignCast(context));
            self.pending = null;
            const result: anyerror!completion.CompletionList = switch (reply) {
                .json => |value| parseCompletionReply(self.allocator, self.proxy, self.handle, self.model, value),
                .err => error.RequestFailed,
                else => .{},
            };
            self.result = result;
            if (self.callback) |callback| callback(self.callback_context, self, result);
        }
    };

    fn requestCompletion(context: *anyopaque, allocator: Allocator, model: *TextModel, position: Position, trigger: completion.CompletionContext, token: CancellationToken) !?completion.CompletionRequest {
        const state: *CompletionState = @ptrCast(@alignCast(context));
        try token.throwIfCancellationRequested();
        const proxy = state.registration.owner.proxy;
        const request = proxy.request_async orelse return null;
        var scratch = std.heap.ArenaAllocator.init(state.registration.owner.allocator);
        defer scratch.deinit();
        const handle = state.registration.handle;
        const args = try completionArgs(scratch.allocator(), handle, model, position, trigger);
        const pending = try allocator.create(CompletionAsyncRequest);
        pending.* = .{ .allocator = allocator, .model = model, .proxy = proxy, .handle = handle };
        pending.pending = try request(proxy.context, "$provideCompletionItems", args, .{ .context = pending, .callback = CompletionAsyncRequest.ready });
        return .{ .context = pending, .on_complete = CompletionAsyncRequest.onComplete, .cancel = CompletionAsyncRequest.cancel };
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
        return parseDocumentSymbolsReply(allocator, model, reply);
    }

    fn parseDocumentSymbolsReply(allocator: Allocator, model: *TextModel, reply: std.json.Value) ![]languages.DocumentSymbol {
        if (reply != .array) return &.{};
        var result = std.array_list.Managed(languages.DocumentSymbol).init(allocator);
        for (reply.array.items) |item| {
            if (item != .object) continue;
            try result.append(try parseDocumentSymbol(allocator, item.object, model));
        }
        return result.toOwnedSlice();
    }

    const DocumentSymbolsAsyncRequest = struct {
        allocator: Allocator,
        model: *TextModel,
        callback: languages.DocumentSymbolCallback,

        fn ready(context: *anyopaque, reply: rpc.Reply) void {
            const self: *DocumentSymbolsAsyncRequest = @ptrCast(@alignCast(context));
            const symbols = switch (reply) {
                .json => |value| parseDocumentSymbolsReply(self.allocator, self.model, value) catch &.{},
                else => &.{},
            };
            self.callback.complete(self.callback.context, symbols);
        }
    };

    fn requestDocumentSymbols(context: *anyopaque, allocator: Allocator, model: *TextModel, callback: languages.DocumentSymbolCallback) !?IDisposable {
        const state: *DocumentSymbolState = @ptrCast(@alignCast(context));
        const proxy = state.registration.owner.proxy;
        const request = proxy.request_async orelse return null;
        var scratch = std.heap.ArenaAllocator.init(state.registration.owner.allocator);
        defer scratch.deinit();
        const args = [_]rpc.Arg{
            .{ .json = .{ .integer = state.registration.handle } },
            .{ .json = try std_uri.jsonComponents(scratch.allocator(), model.uri()) },
        };
        const pending = try allocator.create(DocumentSymbolsAsyncRequest);
        pending.* = .{ .allocator = allocator, .model = model, .callback = callback };
        return try request(proxy.context, "$provideDocumentSymbols", &args, .{ .context = pending, .callback = DocumentSymbolsAsyncRequest.ready });
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

    fn codeActionArgs(a: Allocator, handle: u32, model: *TextModel, range: Range, action_context: languages.CodeActionContext) ![4]rpc.Arg {
        var context_json: std.json.ObjectMap = .empty;
        if (action_context.only) |only| try context_json.put(a, "only", .{ .string = only });
        try context_json.put(a, "trigger", .{ .integer = action_context.trigger_kind });
        var range_value = try rangeJson(a, model, range);
        if (action_context.selection) |selection| {
            try range_value.object.put(a, "selectionStartLineNumber", .{ .integer = @intCast(selection.selectionStartLineNumber) });
            try range_value.object.put(a, "selectionStartColumn", .{ .integer = @intCast(utf16ColumnForModel(model, selection.selectionStartLineNumber, selection.selectionStartColumn)) });
            try range_value.object.put(a, "positionLineNumber", .{ .integer = @intCast(selection.positionLineNumber) });
            try range_value.object.put(a, "positionColumn", .{ .integer = @intCast(utf16ColumnForModel(model, selection.positionLineNumber, selection.positionColumn)) });
        }
        return .{
            .{ .json = .{ .integer = handle } },
            .{ .json = try std_uri.jsonComponents(a, model.uri()) },
            .{ .json = range_value },
            .{ .json = .{ .object = context_json } },
        };
    }

    const CodeActionRelease = struct {
        proxy: HostProxy,
        handle: u32,
        cache_id: i64,
        fn dispose(context: *anyopaque) void {
            const self: *CodeActionRelease = @ptrCast(@alignCast(context));
            self.proxy.notify(self.proxy.context, "$releaseCodeActions", &.{ .{ .json = .{ .integer = self.handle } }, .{ .json = .{ .integer = self.cache_id } } }) catch {};
        }
    };

    fn parseActionCommand(a: Allocator, candidate: ?std.json.Value) !?languages.Command {
        const value = candidate orelse return null;
        if (value != .object) return null;
        return .{
            .id = try dupJsonString(a, value.object.get("id")),
            .title = try dupJsonString(a, value.object.get("title")),
            .arguments = if (value.object.get("arguments")) |arguments| try rpc.cloneJsonValue(a, arguments) else null,
        };
    }

    fn parseCodeActionDocumentation(a: Allocator, metadata: ?std.json.Value) ![]const languages.CodeActionDocumentation {
        const value = metadata orelse return &.{};
        if (value != .object) return &.{};
        const docs = value.object.get("documentation") orelse return &.{};
        if (docs != .array) return &.{};
        var result: std.ArrayList(languages.CodeActionDocumentation) = .empty;
        for (docs.array.items) |entry| {
            if (entry != .object) continue;
            const command = (try parseActionCommand(a, entry.object.get("command"))) orelse continue;
            try result.append(a, .{ .kind = try dupJsonString(a, entry.object.get("kind")), .command = command });
        }
        return result.items;
    }

    fn parseCodeActionList(a: Allocator, proxy: HostProxy, handle: u32, model: *TextModel, reply: std.json.Value) !languages.CodeActionList {
        if (reply != .object) return .{};
        var release: ?IDisposable = null;
        if (reply.object.get("cacheId")) |cache| if (cache == .integer) {
            const context = try a.create(CodeActionRelease);
            context.* = .{ .proxy = proxy, .handle = handle, .cache_id = cache.integer };
            release = .{ .context = context, .disposeFn = CodeActionRelease.dispose };
        };
        errdefer if (release) |disposable| disposable.dispose();
        const actions_value = reply.object.get("actions") orelse return .{ .disposable = release };
        if (actions_value != .array) return .{ .disposable = release };
        var result: std.ArrayList(languages.CodeAction) = .empty;
        const markers = @import("../../../platform/markers/common/markers.zig");
        for (actions_value.array.items) |item| {
            if (item != .object) continue;
            const object = item.object;
            var action: languages.CodeAction = .{
                .title = try dupJsonString(a, object.get("title")),
                .kind = try optionalJsonString(a, object.get("kind")),
                .is_preferred = boolValue(object.get("isPreferred")),
                .is_ai = boolValue(object.get("isAI")),
                .is_synthetic = boolValue(object.get("_isSynthetic")),
                .disabled = try optionalJsonString(a, object.get("disabled")),
                .edit_json = if (object.get("edit")) |edit| try rpc.cloneJsonValue(a, edit) else null,
                .edit = if (object.get("edit")) |edit| try @import("mainThreadBulkEdits.zig").reviveWorkspaceEditDto(a, edit) else null,
                .command = try parseActionCommand(a, object.get("command")),
            };
            if (object.get("cacheId")) |cache| {
                if (cache == .array and cache.array.items.len == 2) {
                    const list = cache.array.items[0];
                    const index = cache.array.items[1];
                    if (list == .integer and index == .integer and list.integer >= 0 and index.integer >= 0 and list.integer <= std.math.maxInt(u32) and index.integer <= std.math.maxInt(u32)) {
                        action.cache_id = .{ .list = @intCast(list.integer), .index = @intCast(index.integer) };
                    }
                }
            }
            if (object.get("diagnostics")) |values| if (values == .array) {
                var diagnostics: std.ArrayList(markers.MarkerData) = .empty;
                for (values.array.items) |diagnostic| {
                    if (diagnostic != .object) continue;
                    const range = rangeFromJson(model, diagnostic) orelse continue;
                    try diagnostics.append(a, .{
                        .message = try dupJsonString(a, diagnostic.object.get("message")),
                        .source = try optionalJsonString(a, diagnostic.object.get("source")),
                        .severity = @intCast(@min(intField(diagnostic.object, "severity") orelse markers.MarkerSeverity.Error, std.math.maxInt(u32))),
                        .start_line_number = @intCast(range.startLineNumber),
                        .start_column = @intCast(range.startColumn),
                        .end_line_number = @intCast(range.endLineNumber),
                        .end_column = @intCast(range.endColumn),
                    });
                }
                action.diagnostics = diagnostics.items;
            };
            if (object.get("ranges")) |values| if (values == .array) {
                var ranges: std.ArrayList(Range) = .empty;
                for (values.array.items) |value| if (rangeFromJson(model, value)) |range| try ranges.append(a, range);
                action.ranges = ranges.items;
            };
            try result.append(a, action);
        }
        return .{ .actions = result.items, .disposable = release };
    }

    fn provideCodeActions(context: *anyopaque, allocator: Allocator, model: *TextModel, range: Range, action_context: languages.CodeActionContext, token: CancellationToken) !languages.CodeActionList {
        const state: *CodeActionState = @ptrCast(@alignCast(context));
        const self = state.registration.owner;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const args = try codeActionArgs(arena.allocator(), state.registration.handle, model, range, action_context);
        const reply = try self.call(arena.allocator(), "$provideCodeActions", &args, token, timeout_default_ms);
        return parseCodeActionList(allocator, self.proxy, state.registration.handle, model, reply);
    }

    const CodeActionRequest = struct {
        allocator: Allocator,
        proxy: HostProxy,
        handle: u32,
        model: *TextModel,
        callback: languages.CodeActionCallback,
        fn ready(context: *anyopaque, reply: rpc.Reply) void {
            const self: *CodeActionRequest = @ptrCast(@alignCast(context));
            self.callback.complete(self.callback.context, switch (reply) {
                .json => |value| parseCodeActionList(self.allocator, self.proxy, self.handle, self.model, value),
                .err => error.RequestFailed,
                else => .{},
            });
        }
    };

    fn requestCodeActions(context: *anyopaque, allocator: Allocator, model: *TextModel, range: Range, action_context: languages.CodeActionContext, token: CancellationToken, callback: languages.CodeActionCallback) !?IDisposable {
        const state: *CodeActionState = @ptrCast(@alignCast(context));
        try token.throwIfCancellationRequested();
        const proxy = state.registration.owner.proxy;
        if (proxy.request_async) |request| {
            var scratch = std.heap.ArenaAllocator.init(state.registration.owner.allocator);
            defer scratch.deinit();
            const pending = try allocator.create(CodeActionRequest);
            pending.* = .{ .allocator = allocator, .proxy = proxy, .handle = state.registration.handle, .model = model, .callback = callback };
            const args = try codeActionArgs(scratch.allocator(), state.registration.handle, model, range, action_context);
            return try request(proxy.context, "$provideCodeActions", &args, .{ .context = pending, .callback = CodeActionRequest.ready });
        }
        callback.complete(callback.context, provideCodeActions(context, allocator, model, range, action_context, token));
        return null;
    }

    fn codeActionResolveArgs(a: Allocator, handle: u32, action: languages.CodeAction) ![2]rpc.Arg {
        const cache = action.cache_id orelse return error.InvalidResult;
        var ids = std.json.Array.init(a);
        try ids.append(.{ .integer = cache.list });
        try ids.append(.{ .integer = cache.index });
        return .{ .{ .json = .{ .integer = handle } }, .{ .json = .{ .array = ids } } };
    }

    fn parseResolvedAction(a: Allocator, original: languages.CodeAction, reply: std.json.Value) !?languages.CodeAction {
        if (reply != .object) return null;
        var action = original;
        if (reply.object.get("edit")) |edit| {
            action.edit_json = try rpc.cloneJsonValue(a, edit);
            action.edit = try @import("mainThreadBulkEdits.zig").reviveWorkspaceEditDto(a, edit);
        }
        if (try parseActionCommand(a, reply.object.get("command"))) |command| action.command = command;
        return action;
    }

    fn resolveCodeAction(context: *anyopaque, allocator: Allocator, action: languages.CodeAction, token: CancellationToken) !?languages.CodeAction {
        const state: *CodeActionState = @ptrCast(@alignCast(context));
        const self = state.registration.owner;
        if (action.cache_id == null) return action;
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const args = try codeActionResolveArgs(a, state.registration.handle, action);
        const reply = try self.call(a, "$resolveCodeAction", &args, token, timeout_format_ms);
        return parseResolvedAction(allocator, action, reply);
    }

    const ResolveCodeActionRequest = struct {
        allocator: Allocator,
        action: languages.CodeAction,
        callback: languages.ResolveCodeActionCallback,
        fn ready(context: *anyopaque, reply: rpc.Reply) void {
            const self: *ResolveCodeActionRequest = @ptrCast(@alignCast(context));
            self.callback.complete(self.callback.context, switch (reply) {
                .json => |value| parseResolvedAction(self.allocator, self.action, value),
                .err => error.RequestFailed,
                else => null,
            });
        }
    };

    fn requestResolveCodeAction(context: *anyopaque, allocator: Allocator, action: languages.CodeAction, token: CancellationToken, callback: languages.ResolveCodeActionCallback) !?IDisposable {
        const state: *CodeActionState = @ptrCast(@alignCast(context));
        try token.throwIfCancellationRequested();
        if (action.cache_id == null) {
            callback.complete(callback.context, action);
            return null;
        }
        const proxy = state.registration.owner.proxy;
        if (proxy.request_async) |request| {
            var scratch = std.heap.ArenaAllocator.init(state.registration.owner.allocator);
            defer scratch.deinit();
            const pending = try allocator.create(ResolveCodeActionRequest);
            pending.* = .{ .allocator = allocator, .action = action, .callback = callback };
            const args = try codeActionResolveArgs(scratch.allocator(), state.registration.handle, action);
            return try request(proxy.context, "$resolveCodeAction", &args, .{ .context = pending, .callback = ResolveCodeActionRequest.ready });
        }
        callback.complete(callback.context, resolveCodeAction(context, allocator, action, token));
        return null;
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

const WorkspaceSymbolState = struct {
    registration: *Registration,
    last_result_id: ?i64 = null,

    fn releaseLastResult(self: *WorkspaceSymbolState) void {
        if (self.last_result_id) |id| {
            const proxy = self.registration.owner.proxy;
            proxy.notify(proxy.context, "$releaseWorkspaceSymbols", &.{
                .{ .json = .{ .integer = self.registration.handle } },
                .{ .json = .{ .integer = id } },
            }) catch {};
            self.last_result_id = null;
        }
    }

    const Request = struct {
        state: *WorkspaceSymbolState,
        allocator: Allocator,
        callback: workspace_symbols.WorkspaceSymbolsCallback,

        fn ready(context: *anyopaque, reply: rpc.Reply) void {
            const self: *Request = @ptrCast(@alignCast(context));
            const result = switch (reply) {
                .json => |value| self.parse(value),
                .err => error.RequestFailed,
                else => @as([]const workspace_symbols.IWorkspaceSymbol, &.{}),
            };
            self.callback.complete(self.callback.context, result);
        }

        fn parse(self: *Request, value: std.json.Value) ![]const workspace_symbols.IWorkspaceSymbol {
            if (value != .object) return error.InvalidResult;
            self.state.releaseLastResult();
            if (value.object.get("cacheId")) |id| if (id == .integer) {
                self.state.last_result_id = id.integer;
            };
            const symbols = value.object.get("symbols") orelse return &.{};
            if (symbols != .array) return error.InvalidResult;
            var output: std.ArrayList(workspace_symbols.IWorkspaceSymbol) = .empty;
            for (symbols.array.items) |symbol| {
                const parsed = try parseWorkspaceSymbol(self.allocator, symbol) orelse continue;
                try output.append(self.allocator, parsed);
            }
            return output.items;
        }
    };

    fn provide(context: *anyopaque, allocator: Allocator, query: []const u8, callback: workspace_symbols.WorkspaceSymbolsCallback) !IDisposable {
        const self: *WorkspaceSymbolState = @ptrCast(@alignCast(context));
        const proxy = self.registration.owner.proxy;
        const pending = try allocator.create(Request);
        pending.* = .{ .state = self, .allocator = allocator, .callback = callback };
        const args: []const rpc.Arg = &.{ .{ .json = .{ .integer = self.registration.handle } }, .{ .json = .{ .string = query } } };
        if (proxy.request_async) |request| return request(proxy.context, "$provideWorkspaceSymbols", args, .{ .context = pending, .callback = Request.ready });
        const value = try proxy.request(proxy.context, allocator, "$provideWorkspaceSymbols", args, null, timeout_default_ms);
        callback.complete(callback.context, pending.parse(value));
        return IDisposable.none;
    }

    const ResolveRequest = struct {
        allocator: Allocator,
        callback: workspace_symbols.ResolveWorkspaceSymbolCallback,

        fn ready(context: *anyopaque, reply: rpc.Reply) void {
            const self: *ResolveRequest = @ptrCast(@alignCast(context));
            const result = switch (reply) {
                .json => |value| parseWorkspaceSymbol(self.allocator, value),
                .err => error.RequestFailed,
                else => @as(?workspace_symbols.IWorkspaceSymbol, null),
            };
            self.callback.complete(self.callback.context, result);
        }
    };

    fn resolve(context: *anyopaque, allocator: Allocator, symbol: workspace_symbols.IWorkspaceSymbol, callback: workspace_symbols.ResolveWorkspaceSymbolCallback) !IDisposable {
        const self: *WorkspaceSymbolState = @ptrCast(@alignCast(context));
        const proxy = self.registration.owner.proxy;
        const pending = try allocator.create(ResolveRequest);
        pending.* = .{ .allocator = allocator, .callback = callback };
        var location: std.json.ObjectMap = .empty;
        try location.put(allocator, "uri", try std_uri.jsonComponents(allocator, try std.Uri.parse(symbol.resource)));
        if (symbol.range) |range| {
            var object: std.json.ObjectMap = .empty;
            try object.put(allocator, "startLineNumber", .{ .integer = @intCast(range.startLineNumber) });
            try object.put(allocator, "startColumn", .{ .integer = @intCast(range.startColumn) });
            try object.put(allocator, "endLineNumber", .{ .integer = @intCast(range.endLineNumber) });
            try object.put(allocator, "endColumn", .{ .integer = @intCast(range.endColumn) });
            try location.put(allocator, "range", .{ .object = object });
        }
        var dto: std.json.ObjectMap = .empty;
        try dto.put(allocator, "name", .{ .string = symbol.name });
        try dto.put(allocator, "kind", .{ .integer = symbol.kind });
        try dto.put(allocator, "containerName", .{ .string = symbol.container_name });
        try dto.put(allocator, "location", .{ .object = location });
        if (symbol.cache_id) |cache_id| {
            var array = std.json.Array.init(allocator);
            for (cache_id) |id| try array.append(.{ .integer = id });
            try dto.put(allocator, "cacheId", .{ .array = array });
        }
        const args: []const rpc.Arg = &.{ .{ .json = .{ .integer = self.registration.handle } }, .{ .json = .{ .object = dto } } };
        if (proxy.request_async) |request| return request(proxy.context, "$resolveWorkspaceSymbol", args, .{ .context = pending, .callback = ResolveRequest.ready });
        const value = try proxy.request(proxy.context, allocator, "$resolveWorkspaceSymbol", args, null, timeout_default_ms);
        callback.complete(callback.context, parseWorkspaceSymbol(allocator, value));
        return IDisposable.none;
    }
};

fn parseWorkspaceSymbol(allocator: Allocator, value: std.json.Value) !?workspace_symbols.IWorkspaceSymbol {
    if (value != .object) return null;
    const object = value.object;
    const name = object.get("name") orelse return null;
    const kind = object.get("kind") orelse return null;
    const location = object.get("location") orelse return null;
    if (name != .string or name.string.len == 0 or kind != .integer or location != .object) return null;
    const resource = location.object.get("uri") orelse return null;
    var symbol: workspace_symbols.IWorkspaceSymbol = .{
        .name = try allocator.dupe(u8, name.string),
        .kind = kind.integer,
        .container_name = try dupJsonString(allocator, object.get("containerName")),
        .resource = try std_uri.encodedResourceFromJson(allocator, resource),
    };
    if (location.object.get("range")) |range| if (range == .object) {
        symbol.range = .init(
            intField(range.object, "startLineNumber") orelse return null,
            intField(range.object, "startColumn") orelse return null,
            intField(range.object, "endLineNumber") orelse return null,
            intField(range.object, "endColumn") orelse return null,
        );
    };
    if (object.get("cacheId")) |id| if (id == .array and id.array.items.len == 2 and id.array.items[0] == .integer and id.array.items[1] == .integer) {
        symbol.cache_id = .{ id.array.items[0].integer, id.array.items[1].integer };
    };
    return symbol;
}

const FoldingState = struct {
    registration: *Registration,
    changed: @import("../../../base/common/event.zig").Emitter(void),
    event_handle: ?u32 = null,

    fn args(self: *FoldingState, a: Allocator, model: *TextModel) ![3]rpc.Arg {
        return .{
            .{ .json = .{ .integer = self.registration.handle } },
            .{ .json = try std_uri.jsonComponents(a, model.uri()) },
            .{ .json = .{ .object = .empty } },
        };
    }

    fn parse(a: Allocator, value: std.json.Value) !?[]const languages.FoldingRange {
        if (value == .null) return null;
        if (value != .array) return error.InvalidResult;
        var result: std.ArrayList(languages.FoldingRange) = .empty;
        for (value.array.items) |item| {
            if (item != .object) continue;
            const start = intField(item.object, "start") orelse continue;
            const end = intField(item.object, "end") orelse continue;
            var kind: ?languages.FoldingRangeKind = null;
            if (item.object.get("kind")) |k| {
                const val = if (k == .object) k.object.get("value") orelse .null else k;
                if (val == .string) kind = std.meta.stringToEnum(languages.FoldingRangeKind, val.string);
            }
            try result.append(a, .{ .start = start, .end = end, .kind = kind });
        }
        return result.items;
    }

    fn provide(context: *anyopaque, a: Allocator, model: *TextModel, token: CancellationToken) !?[]const languages.FoldingRange {
        const self: *FoldingState = @ptrCast(@alignCast(context));
        const arguments = try self.args(a, model);
        const reply = try self.registration.owner.call(a, "$provideFoldingRanges", &arguments, token, timeout_default_ms);
        return parse(a, reply);
    }

    const Pending = struct {
        allocator: Allocator,
        callback: languages.FoldingRangesCallback,
        fn ready(context: *anyopaque, reply: rpc.Reply) void {
            const self: *Pending = @ptrCast(@alignCast(context));
            self.callback.complete(self.callback.context, switch (reply) {
                .json => |value| parse(self.allocator, value),
                .err => error.RequestFailed,
                else => @as(?[]const languages.FoldingRange, null),
            });
        }
    };

    fn request(context: *anyopaque, a: Allocator, model: *TextModel, callback: languages.FoldingRangesCallback) !IDisposable {
        const self: *FoldingState = @ptrCast(@alignCast(context));
        const proxy = self.registration.owner.proxy;
        const send = proxy.request_async orelse return error.RequestFailed;
        const pending = try a.create(Pending);
        pending.* = .{ .allocator = a, .callback = callback };
        const arguments = try self.args(a, model);
        return send(proxy.context, "$provideFoldingRanges", &arguments, .{ .context = pending, .callback = Pending.ready });
    }
};
