// Port of `src/vs/editor/contrib/codeAction/browser/codeAction.ts`.
// Promise.all is represented by cancellable native provider continuations.
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../common/types.zig");
const languages = @import("../../../common/languages.zig");
const Kind = @import("../../../../base/common/hierarchicalKind.zig").HierarchicalKind;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Range = @import("../../../common/core/range.zig").Range;
const Registry = @import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(languages.CodeActionProvider);
const cancellation = @import("../../../../base/common/cancellation.zig");
const Disposable = cancellation.IDisposable;
const CodeActionItem = types.CodeActionItem;
const Filter = types.CodeActionFilter;

pub const codeActionCommandId = "editor.action.codeAction";
pub const quickFixCommandId = "editor.action.quickFix";
pub const autoFixCommandId = "editor.action.autoFix";
pub const refactorCommandId = "editor.action.refactor";
pub const refactorPreviewCommandId = "editor.action.refactor.preview";
pub const sourceActionCommandId = "editor.action.sourceAction";
pub const organizeImportsCommandId = "editor.action.organizeImports";
pub const fixAllCommandId = "editor.action.fixAll";

pub const ManagedCodeActionSet = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    all_actions: []CodeActionItem = &.{},
    valid_actions: []CodeActionItem = &.{},
    documentation: []languages.Command = &.{},
    disposables: std.ArrayList(Disposable) = .empty,

    pub fn create(allocator: Allocator) !*ManagedCodeActionSet {
        const self = try allocator.create(ManagedCodeActionSet);
        self.* = .{ .allocator = allocator, .arena = .init(allocator) };
        return self;
    }

    pub fn dispose(self: *ManagedCodeActionSet) void {
        for (self.disposables.items) |disposable| disposable.dispose();
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn hasAutoFix(self: *const ManagedCodeActionSet) bool {
        for (self.valid_actions) |item| if (item.action.is_preferred) if (item.action.kind) |kind| {
            if (types.CodeActionKind.QuickFix.contains(.init(kind))) return true;
        };
        return false;
    }

    pub fn hasAIFix(self: *const ManagedCodeActionSet) bool {
        for (self.valid_actions) |item| if (item.action.is_ai) return true;
        return false;
    }

    pub fn allAIFixes(self: *const ManagedCodeActionSet) bool {
        for (self.valid_actions) |item| if (!item.action.is_ai) return false;
        return true;
    }

    fn lessThan(_: void, lhs: CodeActionItem, rhs: CodeActionItem) bool {
        const a = lhs.action;
        const b = rhs.action;
        if (a.is_ai != b.is_ai) return !a.is_ai;
        if ((a.diagnostics.len > 0) != (b.diagnostics.len > 0)) return a.diagnostics.len > 0;
        return a.is_preferred and !b.is_preferred;
    }
};

pub const Listener = struct { context: *anyopaque, complete: *const fn (*anyopaque, anyerror!*ManagedCodeActionSet) void };

const Request = struct {
    allocator: Allocator,
    result: *ManagedCodeActionSet,
    registry: *Registry,
    model: *TextModel,
    range: Range,
    trigger: types.CodeActionTrigger,
    token: cancellation.CancellationTokenSource,
    listener: Listener,
    slots: []Slot = &.{},
    remaining: usize = 0,
    starting: bool = true,
    finished: bool = false,
    canceled: bool = false,
    cancel_notify: bool = false,
    parent_listener: ?Disposable = null,
    registry_listener: ?usize = null,
    content_listener: ?usize = null,
    failure: ?anyerror = null,

    const Slot = struct {
        owner: *Request,
        registration_time: u64,
        provider: languages.CodeActionProvider,
        actions: []const languages.CodeAction = &.{},
        documentation: ?languages.Command = null,
        pending: ?Disposable = null,
        done: bool = false,

        fn ready(context: *anyopaque, reply: anyerror!languages.CodeActionList) void {
            const slot: *Slot = @ptrCast(@alignCast(context));
            const self = slot.owner;
            if (slot.done) return;
            slot.done = true;
            slot.pending = null;
            if (reply) |list| {
                if (self.canceled) {
                    if (list.disposable) |d| d.dispose();
                    return;
                }
                self.acceptList(slot, list) catch |err| {
                    self.failure = err;
                };
            } else |err| {
                if (err == error.CancellationError) {
                    self.cancel(true);
                    return;
                }
            }
            self.remaining -= 1;
            if (!self.starting and !self.canceled and self.remaining == 0) self.finish();
        }
    };

    fn acceptList(self: *Request, slot: *Slot, list: languages.CodeActionList) !void {
        const a = self.result.arena.allocator();
        if (list.disposable) |disposable| self.result.disposables.append(a, disposable) catch |err| {
            disposable.dispose();
            return err;
        };
        var filtered: std.ArrayList(languages.CodeAction) = .empty;
        for (list.actions) |action| if (types.filtersAction(self.trigger.filter, action)) try filtered.append(a, action);
        slot.actions = filtered.items;
        // Registration storage can be destroyed during an asynchronous call.
        if (self.registry.hasRegistration(slot.registration_time)) {
            if (getDocumentation(slot.provider, slot.actions, self.trigger.filter.include)) |doc| {
                slot.documentation = .{ .id = try a.dupe(u8, doc.id), .title = try a.dupe(u8, doc.title), .arguments = if (doc.arguments) |arguments| try cloneJson(a, arguments) else null };
            }
        }
    }

    fn start(self: *Request, parent: cancellation.CancellationToken) !?Disposable {
        const a = self.result.arena.allocator();
        var provider_filter = self.trigger.filter;
        if (self.trigger.type == .Auto) {
            const excludes = try a.alloc(Kind, provider_filter.excludes.len + 1);
            @memcpy(excludes[0..provider_filter.excludes.len], provider_filter.excludes);
            excludes[excludes.len - 1] = types.CodeActionKind.Notebook;
            provider_filter.excludes = excludes;
        }
        const providers = try self.registry.orderedWithSelectors(a, self.model, false);
        var slots: std.ArrayList(Slot) = .empty;
        for (providers) |entry| {
            if (entry.provider.provided_kinds) |kinds| {
                var matches = false;
                for (kinds) |kind| if (types.mayIncludeActionsOfKind(provider_filter, .init(kind))) {
                    matches = true;
                    break;
                };
                if (!matches) continue;
            }
            try slots.append(a, .{ .owner = self, .provider = entry.provider, .registration_time = entry.registration_time });
        }
        self.slots = slots.items;
        self.remaining = self.slots.len;
        const token = try self.token.token();
        self.content_listener = try self.model.onDidChangeContentWithContextId(self, onModelChanged);
        self.registry_listener = try self.registry.on_did_change.listen(self, onRegistryChanged);
        self.parent_listener = try parent.onCancellationRequested(.{ .context = self, .callbackFn = onParentCanceled });
        const context: languages.CodeActionContext = .{
            .only = if (self.trigger.filter.include) |value| value.value else null,
            .trigger_kind = @backingInt(self.trigger.type),
        };
        for (self.slots) |*slot| {
            if (self.canceled) break;
            if (!self.registry.hasRegistration(slot.registration_time)) {
                Slot.ready(slot, .{});
                continue;
            }
            const provider = slot.provider;
            if (provider.request_code_actions) |request| {
                const pending = request(provider.context, a, self.model, self.range, context, token, .{ .context = slot, .complete = Slot.ready }) catch |err| blk: {
                    Slot.ready(slot, err);
                    break :blk null;
                };
                if (self.canceled) {
                    if (pending) |handle| handle.dispose();
                } else if (!slot.done) {
                    slot.pending = pending;
                    if (pending == null) Slot.ready(slot, .{});
                }
            } else Slot.ready(slot, provider.provide_code_actions(provider.context, a, self.model, self.range, context, token));
        }
        self.starting = false;
        if (self.canceled) {
            self.finishCanceled();
            return null;
        }
        if (self.remaining == 0) {
            self.finish();
            return null;
        }
        return Disposable.from(Request, self, dispose);
    }

    fn onModelChanged(_: @import("../../../common/textModelEvents.zig").InternalModelContentChangeEvent, self: *Request) !void {
        self.cancel(true);
    }

    fn onRegistryChanged(_: usize, self: *Request) !void {
        const allocator = self.allocator;
        const providers = self.registry.orderedWithSelectors(allocator, self.model, false) catch {
            self.cancel(true);
            return;
        };
        defer allocator.free(providers);
        if (providers.len != self.slots.len) {
            self.cancel(true);
            return;
        }
        for (providers, self.slots) |provider, slot| if (provider.registration_time != slot.registration_time) {
            self.cancel(true);
            return;
        };
    }

    fn onParentCanceled(context: *anyopaque) void {
        const self: *Request = @ptrCast(@alignCast(context));
        self.cancel(true);
    }

    fn dispose(self: *Request) void {
        self.cancel(false);
    }

    fn cancel(self: *Request, notify: bool) void {
        if (self.canceled or self.finished) return;
        self.canceled = true;
        self.cancel_notify = notify;
        self.token.cancel();
        for (self.slots) |*slot| {
            if (slot.pending) |pending| pending.dispose();
            slot.pending = null;
        }
        if (!self.starting) self.finishCanceled();
    }

    fn unregister(self: *Request) void {
        if (self.content_listener) |listener| self.model.removeDidChangeContentListener(listener);
        if (self.registry_listener) |listener| self.registry.on_did_change.unlisten(listener);
        if (self.parent_listener) |listener| listener.dispose();
        self.content_listener = null;
        self.registry_listener = null;
        self.parent_listener = null;
        self.token.deinit();
    }

    fn finishCanceled(self: *Request) void {
        self.unregister();
        self.result.dispose();
        const listener = self.listener;
        const notify = self.cancel_notify;
        self.allocator.destroy(self);
        if (notify) listener.complete(listener.context, error.CancellationError);
    }

    fn collect(self: *Request) !void {
        if (self.failure) |failure| return failure;
        const a = self.result.arena.allocator();
        var items: std.ArrayList(CodeActionItem) = .empty;
        var docs: std.ArrayList(languages.Command) = .empty;
        for (self.slots) |slot| {
            for (slot.actions) |action| try items.append(a, .{ .action = action, .provider = slot.provider, .registration_time = slot.registration_time });
            if (slot.documentation) |doc| try docs.append(a, doc);
        }
        std.mem.sort(CodeActionItem, items.items, {}, ManagedCodeActionSet.lessThan);
        var valid: std.ArrayList(CodeActionItem) = .empty;
        for (items.items) |item| if (item.action.disabled == null) try valid.append(a, item);
        self.result.all_actions = items.items;
        self.result.valid_actions = valid.items;
        self.result.documentation = docs.items;
    }

    fn finish(self: *Request) void {
        self.finished = true;
        const value: anyerror!*ManagedCodeActionSet = if (self.collect()) self.result else |err| blk: {
            self.result.dispose();
            break :blk err;
        };
        const listener = self.listener;
        self.unregister();
        self.allocator.destroy(self);
        listener.complete(listener.context, value);
    }
};

pub fn getCodeActions(allocator: Allocator, registry: *Registry, model: *TextModel, range: Range, trigger: types.CodeActionTrigger, token: cancellation.CancellationToken, listener: Listener) !?Disposable {
    try token.throwIfCancellationRequested();
    const result = try ManagedCodeActionSet.create(allocator);
    errdefer result.dispose();
    const request = try allocator.create(Request);
    errdefer allocator.destroy(request);
    const owned_trigger = try copyTrigger(result.arena.allocator(), trigger);
    request.* = .{ .allocator = allocator, .result = result, .registry = registry, .model = model, .range = range, .trigger = owned_trigger, .listener = listener, .token = try cancellation.CancellationTokenSource.init(allocator) };
    errdefer request.unregister();
    return request.start(token);
}

pub fn copyTrigger(a: Allocator, trigger: types.CodeActionTrigger) !types.CodeActionTrigger {
    var owned = trigger;
    if (trigger.filter.include) |kind| owned.filter.include = .init(try a.dupe(u8, kind.value));
    const excludes = try a.alloc(Kind, trigger.filter.excludes.len);
    for (excludes, trigger.filter.excludes) |*target, kind| target.* = .init(try a.dupe(u8, kind.value));
    owned.filter.excludes = excludes;
    if (trigger.context) |context| owned.context.?.not_available_message = try a.dupe(u8, context.not_available_message);
    return owned;
}

fn getDocumentation(provider: languages.CodeActionProvider, actions: []const languages.CodeAction, only: ?Kind) ?languages.Command {
    if (only) |kind| {
        var best: ?languages.CodeActionDocumentation = null;
        for (provider.documentation) |entry| {
            const candidate = Kind.init(entry.kind);
            if (candidate.contains(kind) and (best == null or Kind.init(best.?.kind).contains(candidate))) best = entry;
        }
        if (best) |entry| return entry.command;
    }
    for (actions) |action| if (action.kind) |kind| {
        for (provider.documentation) |entry| if (Kind.init(entry.kind).contains(.init(kind))) return entry.command;
    };
    return null;
}

fn cloneJson(a: Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .array => |array| blk: {
            var result = std.json.Array.init(a);
            for (array.items) |item| try result.append(try cloneJson(a, item));
            break :blk .{ .array = result };
        },
        .object => |object| blk: {
            var result: std.json.ObjectMap = .empty;
            var iterator = object.iterator();
            while (iterator.next()) |entry| try result.put(a, try a.dupe(u8, entry.key_ptr.*), try cloneJson(a, entry.value_ptr.*));
            break :blk .{ .object = result };
        },
        else => value,
    };
}
