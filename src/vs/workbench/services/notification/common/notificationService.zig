// Port of `src/vs/workbench/services/notification/common/notificationService.ts`.
// The terminal host supplies storage explicitly instead of TS decorators.
const std = @import("std");
const notification = @import("../../../../platform/notification/common/notification.zig");
const model_mod = @import("../../../common/notifications.zig");
const Severity = @import("../../../../base/common/severity.zig").Severity;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const actions = @import("../../../../base/common/actions.zig");
const storage_mod = @import("../../../../platform/storage/common/storage.zig");
const Allocator = std.mem.Allocator;
const Storage = storage_mod.InMemoryStorageService;
const Filter = notification.NotificationsFilter;
const Source = notification.INotificationSource;
const SourceFilter = notification.INotificationSourceFilter;
const INotificationHandle = notification.INotificationHandle;

pub const NotificationService = struct {
    const global_filter_key = "notifications.doNotDisturbMode";
    const per_source_filter_key = "notifications.perSourceDoNotDisturbMode";

    allocator: Allocator,
    model: model_mod.NotificationsModel,
    storage: *Storage,
    global_filter_enabled: bool = false,
    source_filters: std.StringHashMapUnmanaged(SourceFilter) = .empty,
    on_did_change_filter: Emitter(void),
    prompts: std.ArrayList(*Prompt) = .empty,

    pub fn create(allocator: Allocator, storage: *Storage) !*NotificationService {
        const self = try allocator.create(NotificationService);
        self.* = .{ .allocator = allocator, .model = .init(allocator), .storage = storage, .on_did_change_filter = .init(allocator) };
        errdefer self.deinit();
        self.global_filter_enabled = storage.getBoolean(global_filter_key, .application, false) orelse false;
        if (storage.get(per_source_filter_key, .application, null)) |raw| {
            if (std.json.parseFromSlice([]SourceFilter, allocator, raw, .{ .ignore_unknown_fields = true })) |parsed| {
                defer parsed.deinit();
                for (parsed.value) |value| try self.storeSource(value);
            } else |_| {}
        }
        try self.updateFilters();
        _ = try self.model.on_did_change_notification.listen(self, onNotification);
        return self;
    }
    pub fn deinit(self: *NotificationService) void {
        // Prompt actions own their callbacks separately from the model.
        // Closing resolves outstanding prompts before the model is destroyed.
        while (self.prompts.items.len != 0) {
            const pending = self.prompts.items[self.prompts.items.len - 1];
            if (pending.handle) |handle| handle.close();
            // A no-op handle never fires onDidClose.
            if (self.prompts.items.len != 0 and self.prompts.items[self.prompts.items.len - 1] == pending) pending.destroy();
        }
        self.prompts.deinit(self.allocator);
        self.model.deinit();
        var values = self.source_filters.valueIterator();
        while (values.next()) |value| {
            self.allocator.free(value.id);
            self.allocator.free(value.label);
        }
        self.source_filters.deinit(self.allocator);
        self.on_did_change_filter.deinit();
        self.allocator.destroy(self);
    }
    fn onNotification(event: model_mod.INotificationChangeEvent, self: *NotificationService) !void {
        if (event.kind != .ADD) return;
        const id = event.item.source_id orelse return;
        const label = event.item.source orelse return;
        if (self.source_filters.get(id)) |existing| {
            if (!std.mem.eql(u8, existing.label, label)) try self.setSourceFilter(.{ .id = id, .label = label, .filter = existing.filter });
        } else try self.setSourceFilter(.{ .id = id, .label = label, .filter = .OFF });
    }
    pub fn setFilter(self: *NotificationService, filter: Filter) !void {
        if (self.global_filter_enabled == (filter == .ERROR)) return;
        self.global_filter_enabled = filter == .ERROR;
        try self.storage.store(global_filter_key, .{ .boolean = self.global_filter_enabled }, .application, .machine);
        try self.updateFilters();
        try self.on_did_change_filter.fire({});
    }
    pub fn setSourceFilter(self: *NotificationService, source: SourceFilter) !void {
        if (self.source_filters.get(source.id)) |existing| {
            if (existing.filter == source.filter and std.mem.eql(u8, existing.label, source.label)) return;
        }
        try self.storeSource(source);
        try self.saveSourceFilters();
        try self.updateFilters();
    }
    fn storeSource(self: *NotificationService, value: SourceFilter) !void {
        const label = try self.allocator.dupe(u8, value.label);
        errdefer self.allocator.free(label);
        if (self.source_filters.getPtr(value.id)) |existing| {
            self.allocator.free(existing.label);
            existing.label = label;
            existing.filter = value.filter;
        } else {
            const id = try self.allocator.dupe(u8, value.id);
            errdefer self.allocator.free(id);
            try self.source_filters.put(self.allocator, id, .{ .id = id, .label = label, .filter = value.filter });
        }
    }
    pub fn getFilter(self: *const NotificationService, source: ?Source) Filter {
        if (source) |value| return if (self.source_filters.get(value.id)) |entry| entry.filter else .OFF;
        return if (self.global_filter_enabled) .ERROR else .OFF;
    }
    pub fn getFilters(self: *NotificationService, allocator: Allocator) ![]SourceFilter {
        const result = try allocator.alloc(SourceFilter, self.source_filters.count());
        var values = self.source_filters.valueIterator();
        var i: usize = 0;
        while (values.next()) |value| : (i += 1) result[i] = value.*;
        return result;
    }
    pub fn removeFilter(self: *NotificationService, id: []const u8) !void {
        if (self.source_filters.fetchRemove(id)) |removed| {
            self.allocator.free(removed.value.id);
            self.allocator.free(removed.value.label);
            try self.saveSourceFilters();
            try self.updateFilters();
        }
    }
    fn saveSourceFilters(self: *NotificationService) !void {
        const filters = try self.getFilters(self.allocator);
        defer self.allocator.free(filters);
        const raw = try std.json.Stringify.valueAlloc(self.allocator, filters, .{});
        defer self.allocator.free(raw);
        try self.storage.store(per_source_filter_key, .{ .string = raw }, .application, .machine);
    }
    fn updateFilters(self: *NotificationService) !void {
        var filters: std.StringHashMapUnmanaged(Filter) = .empty;
        defer filters.deinit(self.allocator);
        var iter = self.source_filters.iterator();
        while (iter.next()) |entry| try filters.put(self.allocator, entry.key_ptr.*, entry.value_ptr.filter);
        try self.model.setFilter(self.getFilter(null), &filters);
    }

    pub fn notify(self: *NotificationService, input: notification.INotification) INotificationHandle {
        return self.model.addNotification(input) catch self.model.no_op.interface();
    }
    pub fn info(self: *NotificationService, message: notification.NotificationMessage) void {
        self.notify(.{ .severity = .Info, .message = message }).release();
    }
    pub fn warn(self: *NotificationService, message: notification.NotificationMessage) void {
        self.notify(.{ .severity = .Warning, .message = message }).release();
    }
    pub fn err(self: *NotificationService, message: notification.NotificationMessage) void {
        self.notify(.{ .severity = .Error, .message = message }).release();
    }
    pub fn status(self: *NotificationService, message: notification.NotificationMessage, options: ?notification.IStatusMessageOptions) notification.IStatusHandle {
        return self.model.showStatusMessage(message, options) catch .{ .context = self, .close_fn = noopStatus };
    }
    fn noopStatus(_: *anyopaque) void {}

    pub fn prompt(self: *NotificationService, severity: Severity, message: notification.NotificationMessage, choices: []const notification.IPromptChoice, options: ?notification.IPromptOptions) INotificationHandle {
        return self.createPrompt(severity, message, choices, options) catch self.model.no_op.interface();
    }
    fn createPrompt(self: *NotificationService, severity: Severity, message: notification.NotificationMessage, choices: []const notification.IPromptChoice, options: ?notification.IPromptOptions) !INotificationHandle {
        const opts = options orelse notification.IPromptOptions{};
        const state = try self.allocator.create(Prompt);
        state.* = .{ .service = self, .arena = .init(self.allocator), .cancel = opts.on_cancel };
        errdefer state.destroy();
        try self.prompts.append(self.allocator, state);
        const a = state.arena.allocator();
        state.choices = try a.alloc(Prompt.Choice, choices.len);
        var primary: std.ArrayList(actions.IAction) = .empty;
        var secondary: std.ArrayList(actions.IAction) = .empty;
        for (choices, 0..) |choice, index| {
            const id = try std.fmt.allocPrint(a, "workbench.dialog.choice.{d}", .{index});
            const label = try a.dupe(u8, choice.label);
            const entry = &state.choices[index];
            entry.* = .{ .prompt = state, .choice = choice, .action = actions.Action.init(a, id, label, null, true, Prompt.Choice.run, entry) };
            state.initialized += 1;
            try (if (choice.is_secondary) &secondary else &primary).append(a, entry.action.interface());
        }
        const handle = self.notify(.{ .severity = severity, .message = message, .actions = .{ .primary = primary.items, .secondary = secondary.items }, .sticky = opts.sticky, .priority = opts.priority, .legacy_extension_link_parsing = opts.legacy_extension_link_parsing });
        if (handle.on_did_close == null) {
            state.destroy();
            return handle;
        }
        state.handle = handle;
        const item: *model_mod.NotificationViewItem = @ptrCast(@alignCast(handle.context));
        if (item.closed) {
            state.destroy();
            return handle;
        }
        _ = handle.on_did_close.?.listen(state, Prompt.onClosed) catch |e| {
            handle.close();
            handle.release();
            return e;
        };
        return handle;
    }
    const Prompt = struct {
        service: *NotificationService,
        arena: std.heap.ArenaAllocator,
        handle: ?INotificationHandle = null,
        cancel: ?notification.PromptCancel = null,
        choices: []Choice = &.{},
        initialized: usize = 0,
        choice_clicked: bool = false,
        closed: bool = false,
        running: usize = 0,

        const Choice = struct {
            prompt: *Prompt,
            choice: notification.IPromptChoice,
            action: actions.Action,
            fn run(context: *anyopaque, _: ?*const anyopaque) !void {
                const self: *Choice = @ptrCast(@alignCast(context));
                const state = self.prompt;
                state.running += 1;
                defer {
                    state.running -= 1;
                    if (state.closed and state.running == 0) state.destroy();
                }
                state.choice_clicked = true;
                self.choice.run();
                if (!self.choice.keep_open and !state.closed) state.handle.?.close();
            }
        };
        fn onClosed(_: void, self: *Prompt) !void {
            self.closed = true;
            if (!self.choice_clicked) if (self.cancel) |cancel| cancel.run();
            if (self.running == 0) self.destroy();
        }
        fn destroy(self: *Prompt) void {
            const service = self.service;
            if (std.mem.indexOfScalar(*Prompt, service.prompts.items, self)) |index| _ = service.prompts.swapRemove(index);
            for (self.choices[0..self.initialized]) |*choice| choice.action.deinit();
            self.arena.deinit();
            service.allocator.destroy(self);
        }
    };

    pub fn interface(self: *NotificationService) notification.INotificationService {
        return .{ .context = self, .notify_fn = notifyImpl, .info_fn = infoImpl, .warn_fn = warnImpl, .error_fn = errorImpl, .status_fn = statusImpl, .prompt_fn = promptImpl };
    }
    fn fromContext(ctx: *anyopaque) *NotificationService {
        return @ptrCast(@alignCast(ctx));
    }
    fn notifyImpl(ctx: *anyopaque, input: notification.INotification) INotificationHandle {
        return fromContext(ctx).notify(input);
    }
    fn infoImpl(ctx: *anyopaque, message: notification.NotificationMessage) void {
        fromContext(ctx).info(message);
    }
    fn warnImpl(ctx: *anyopaque, message: notification.NotificationMessage) void {
        fromContext(ctx).warn(message);
    }
    fn errorImpl(ctx: *anyopaque, message: notification.NotificationMessage) void {
        fromContext(ctx).err(message);
    }
    fn statusImpl(ctx: *anyopaque, message: notification.NotificationMessage, options: ?notification.IStatusMessageOptions) notification.IStatusHandle {
        return fromContext(ctx).status(message, options);
    }
    fn promptImpl(ctx: *anyopaque, severity: Severity, message: notification.NotificationMessage, choices: []const notification.IPromptChoice, options: ?notification.IPromptOptions) INotificationHandle {
        return fromContext(ctx).prompt(severity, message, choices, options);
    }
};
