// Port of `src/vs/editor/browser/widget/multiDiffEditor/virtualizedItemManager.ts`.
// Typed item/template bindings use explicit ownership and synchronous change
// notifications in place of JavaScript observable references and GC.
const std = @import("std");
const Allocator = std.mem.Allocator;
const scroll = @import("compressedVirtualizedScrollView.zig");
const OffsetRange = @import("../../../common/core/ranges/offsetRange.zig").OffsetRange;
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const IVirtualizedItemBindingContext = struct {
    initialSize: usize,
    render_context: ?scroll.ICompressedVirtualizedScrollItemContext,
    context: *anyopaque,
    on_did_change: *const fn (*anyopaque) anyerror!void,

    pub fn runWithScrollAnchor(self: @This(), offset: scroll.ItemOffset, update: scroll.Update) !void {
        try (self.render_context orelse return error.MissingRenderContext).runWithScrollAnchor(offset, update);
    }
    pub fn notifyChanged(self: @This()) !void {
        try self.on_did_change(self.context);
    }
};

/// A concrete template owns one typed binding at a time. Clear its current
/// reference before issuing the change notification: listeners may bind again
/// synchronously, and must not have their new binding cleared by the old one.
pub fn VirtualizedItemTemplate(comptime Item: type, comptime Binding: type) type {
    return struct {
        const Self = @This();
        currentBinding: ?*Binding = null,
        on_did_change_binding: Emitter(void),

        pub fn init(allocator: Allocator) Self {
            return .{ .on_did_change_binding = .init(allocator) };
        }
        pub fn bind(self: *Self, owner: anytype, item: *Item, context: IVirtualizedItemBindingContext) !*Binding {
            if (self.currentBinding != null) return error.TemplateAlreadyBound;
            const binding = try owner.createBinding(item, context);
            errdefer binding.destroy();
            if (binding.item != item) return error.WrongBindingItem;
            self.currentBinding = binding;
            self.on_did_change_binding.fire({}) catch {};
            return binding;
        }
        pub fn unbind(self: *Self, binding: *Binding) !void {
            if (self.currentBinding != binding) return error.BindingDoesNotOwnTemplate;
            self.currentBinding = null;
            binding.destroy();
            try self.on_did_change_binding.fire({});
        }
        pub fn deinit(self: *Self) void {
            if (self.currentBinding) |binding| self.unbind(binding) catch {};
            self.on_did_change_binding.deinit();
        }
    };
}

pub fn VirtualizedItemManager(comptime Item: type, comptime Binding: type, comptime Template: type) type {
    return struct {
        const Self = @This();
        pub const Delegate = struct {
            context: *anyopaque,
            get_id: *const fn (*anyopaque, *Item) []const u8,
            get_template_id: *const fn (*anyopaque, *Item) []const u8,
            get_unbound_size: *const fn (*anyopaque, *Item) usize,
            on_unbound_change: *const fn (*anyopaque, *Item) *Emitter(void),
            create_template: *const fn (*anyopaque, []const u8) anyerror!*Template,
            on_did_bind: ?*const fn (*anyopaque, *Binding) anyerror!void = null,
            on_will_unbind: ?*const fn (*anyopaque, *Binding) void = null,
            on_unexpected_error: ?*const fn (*anyopaque, anyerror) void = null,
        };
        const TemplatePool = struct {
            id: []u8,
            unused: std.ArrayList(*Template) = .empty,
            used: std.ArrayList(*Template) = .empty,
        };
        allocator: Allocator,
        delegate: Delegate,
        view: *scroll.CompressedVirtualizedScrollView,
        items: []*ManagedVirtualizedItem = &.{},
        trailing_item: ?scroll.ICompressedVirtualizedScrollItem = null,
        pools: std.ArrayList(*TemplatePool) = .empty,

        pub const ManagedVirtualizedItem = struct {
            manager: *Self,
            item: *Item,
            change: Emitter(void),
            unbound_listener: ?usize = null,
            template: ?*Template = null,
            pool: ?*TemplatePool = null,
            is_hidden: bool = false,
            did_render_fail: bool = false,
            last_render: ?Render = null,
            clearing: bool = false,
            const Render = struct {
                range: OffsetRange,
                offset: usize,
                width: usize,
                viewport: OffsetRange,
                context: ?scroll.ICompressedVirtualizedScrollItemContext,
            };

            fn create(manager: *Self, item: *Item) !*@This() {
                const self = try manager.allocator.create(@This());
                errdefer manager.allocator.destroy(self);
                self.* = .{ .manager = manager, .item = item, .change = .init(manager.allocator) };
                errdefer self.change.deinit();
                self.unbound_listener = try manager.delegate.on_unbound_change(manager.delegate.context, item).listen(self, onUnboundChanged);
                return self;
            }
            fn destroy(self: *@This()) void {
                if (self.unbound_listener) |listener| self.manager.delegate.on_unbound_change(self.manager.delegate.context, self.item).unlisten(listener);
                self.clearBinding() catch |err| self.manager.reportError(err);
                self.change.deinit();
                self.manager.allocator.destroy(self);
            }
            pub fn binding(self: *const @This()) ?*Binding {
                return if (self.template) |template| template.virtualized_template.currentBinding else null;
            }
            pub fn size(self: *const @This()) usize {
                return if (self.binding()) |bound| bound.size() else self.manager.delegate.get_unbound_size(self.manager.delegate.context, self.item);
            }
            pub fn maxScroll(self: *const @This()) usize {
                return if (self.binding()) |bound| bound.maxScroll() else 0;
            }
            fn onUnboundChanged(_: void, self: *@This()) !void {
                if (!self.clearing) try self.change.fire({});
            }
            fn notifyBindingChanged(context: *anyopaque) !void {
                const self: *@This() = @ptrCast(@alignCast(context));
                if (self.clearing) return;
                if (self.is_hidden) {
                    if (self.binding()) |bound| {
                        if (!bound.shouldKeepAlive()) try self.clearBinding();
                    }
                }
                try self.change.fire({});
            }
            pub fn render(self: *@This(), range: OffsetRange, offset: usize, width: usize, viewport: OffsetRange, render_context: ?scroll.ICompressedVirtualizedScrollItemContext) void {
                self.last_render = .{ .range = range, .offset = offset, .width = width, .viewport = viewport, .context = render_context };
                self.is_hidden = false;
                if (self.did_render_fail) return;
                self.renderInternal(self.last_render.?) catch |err| {
                    self.did_render_fail = true;
                    self.manager.reportError(err);
                };
            }
            fn renderInternal(self: *@This(), args: Render) !void {
                const old_size = self.size();
                const old_max_scroll = self.maxScroll();
                if (self.binding() == null) {
                    const reference = try self.manager.acquire(self.item);
                    errdefer self.manager.release(reference.pool, reference.template);
                    const bound = try reference.template.virtualized_template.bind(reference.template, self.item, .{
                        .initialSize = old_size,
                        .render_context = args.context,
                        .context = self,
                        .on_did_change = notifyBindingChanged,
                    });
                    errdefer reference.template.virtualized_template.unbind(bound) catch {};
                    if (self.manager.delegate.on_did_bind) |callback| try callback(self.manager.delegate.context, bound);
                    self.template = reference.template;
                    self.pool = reference.pool;
                }
                const bound = self.binding() orelse return error.MissingBinding;
                try bound.render(args.range, args.offset, args.width, args.viewport);
                if (old_size != self.size() or old_max_scroll != self.maxScroll()) try self.change.fire({});
            }
            pub fn hide(self: *@This()) void {
                self.is_hidden = true;
                if (self.binding()) |bound| {
                    bound.hide();
                    if (!bound.shouldKeepAlive()) self.clearBinding() catch |err| self.manager.reportError(err);
                }
            }
            pub fn rebind(self: *@This()) !void {
                if (self.binding() == null or self.last_render == null) return;
                const args = self.last_render.?;
                try self.clearBinding();
                self.did_render_fail = false;
                self.render(args.range, args.offset, args.width, args.viewport, args.context);
            }
            fn clearBinding(self: *@This()) !void {
                const template = self.template orelse return;
                const bound = self.binding() orelse return;
                const pool = self.pool.?;
                self.clearing = true;
                defer self.clearing = false;
                const old_size = self.size();
                const old_max_scroll = self.maxScroll();
                if (self.manager.delegate.on_will_unbind) |callback| callback(self.manager.delegate.context, bound);
                self.template = null;
                self.pool = null;
                bound.hide();
                const result = template.virtualized_template.unbind(bound);
                self.manager.release(pool, template);
                try result;
                if (self.size() != old_size or old_max_scroll != 0) try self.change.fire({});
            }
            pub fn interface(self: *@This()) scroll.ICompressedVirtualizedScrollItem {
                const Adapter = struct {
                    fn size(context: *anyopaque) usize {
                        const actual: *ManagedVirtualizedItem = @ptrCast(@alignCast(context));
                        return actual.size();
                    }
                    fn maxScroll(context: *anyopaque) usize {
                        const actual: *ManagedVirtualizedItem = @ptrCast(@alignCast(context));
                        return actual.maxScroll();
                    }
                    fn render(context: *anyopaque, range: OffsetRange, offset: usize, width: usize, viewport: OffsetRange, scroll_context: scroll.ICompressedVirtualizedScrollItemContext) !void {
                        const actual: *ManagedVirtualizedItem = @ptrCast(@alignCast(context));
                        actual.render(range, offset, width, viewport, scroll_context);
                    }
                    fn hide(context: *anyopaque) void {
                        const actual: *ManagedVirtualizedItem = @ptrCast(@alignCast(context));
                        actual.hide();
                    }
                };
                return .{ .context = self, .size = Adapter.size, .max_scroll = Adapter.maxScroll, .on_did_change = &self.change, .render = Adapter.render, .hide = Adapter.hide };
            }
        };

        pub fn create(allocator: Allocator, delegate: Delegate, view: *scroll.CompressedVirtualizedScrollView) !*Self {
            const self = try allocator.create(Self);
            self.* = .{ .allocator = allocator, .delegate = delegate, .view = view };
            return self;
        }

        /// Upstream's mapObservableArrayCached retains items by delegate ID.
        /// The scroll view detaches old item listeners before we free them.
        pub fn setItems(self: *Self, items: []const *Item) !void {
            const next = try self.allocator.alloc(*ManagedVirtualizedItem, items.len);
            var transferred = false;
            errdefer if (!transferred) self.allocator.free(next);
            const reused = try self.allocator.alloc(bool, items.len);
            defer self.allocator.free(reused);
            const interfaces = try self.allocator.alloc(scroll.ICompressedVirtualizedScrollItem, items.len + @as(usize, if (self.trailing_item != null) 1 else 0));
            defer self.allocator.free(interfaces);
            var initialized: usize = 0;
            errdefer if (!transferred) for (next[0..initialized], reused[0..initialized]) |item, was_reused| {
                if (!was_reused) item.destroy();
            };
            for (items, 0..) |item, i| {
                const id = self.delegate.get_id(self.delegate.context, item);
                for (next[0..i]) |previous| {
                    if (std.mem.eql(u8, id, self.delegate.get_id(self.delegate.context, previous.item))) return error.DuplicateVirtualizedItemId;
                }
                const existing = for (self.items) |previous| {
                    if (std.mem.eql(u8, id, self.delegate.get_id(self.delegate.context, previous.item))) break previous;
                } else null;
                next[i] = existing orelse try ManagedVirtualizedItem.create(self, item);
                reused[i] = existing != null;
                initialized += 1;
                interfaces[i] = next[i].interface();
            }
            if (self.trailing_item) |padding| interfaces[items.len] = padding;
            self.view.beginUpdate();
            self.view.setItems(interfaces) catch |err| {
                self.view.endUpdate() catch {};
                return err;
            };
            for (self.items) |previous| {
                for (next) |item| {
                    if (item == previous) break;
                } else previous.destroy();
            }
            self.allocator.free(self.items);
            self.items = next;
            transferred = true;
            try self.view.endUpdate();
        }

        pub fn destroy(self: *Self) void {
            self.view.detachItems();
            for (self.items) |item| item.destroy();
            for (self.pools.items) |pool| {
                for (pool.used.items) |template| template.destroy();
                for (pool.unused.items) |template| template.destroy();
                pool.used.deinit(self.allocator);
                pool.unused.deinit(self.allocator);
                self.allocator.free(pool.id);
                self.allocator.destroy(pool);
            }
            self.pools.deinit(self.allocator);
            self.allocator.free(self.items);
            self.allocator.destroy(self);
        }

        fn reportError(self: *Self, err: anyerror) void {
            if (self.delegate.on_unexpected_error) |callback| callback(self.delegate.context, err) else std.log.warn("Virtualized item: {s}", .{@errorName(err)});
        }
        fn acquire(self: *Self, item: *Item) !struct { pool: *TemplatePool, template: *Template } {
            const id = self.delegate.get_template_id(self.delegate.context, item);
            const pool = for (self.pools.items) |pool| {
                if (std.mem.eql(u8, pool.id, id)) break pool;
            } else blk: {
                const pool = try self.allocator.create(TemplatePool);
                errdefer self.allocator.destroy(pool);
                pool.* = .{ .id = try self.allocator.dupe(u8, id) };
                errdefer self.allocator.free(pool.id);
                try self.pools.append(self.allocator, pool);
                break :blk pool;
            };
            try pool.used.ensureUnusedCapacity(self.allocator, 1);
            const template = if (pool.unused.items.len != 0) pool.unused.orderedRemove(0) else try self.delegate.create_template(self.delegate.context, id);
            if (template.virtualized_template.currentBinding != null) {
                template.destroy();
                return error.TemplateAlreadyBound;
            }
            pool.used.appendAssumeCapacity(template);
            return .{ .pool = pool, .template = template };
        }
        fn release(self: *Self, pool: *TemplatePool, template: *Template) void {
            const index = for (pool.used.items, 0..) |candidate, i| {
                if (candidate == template) break i;
            } else return;
            _ = pool.used.swapRemove(index);
            if (template.virtualized_template.currentBinding != null or pool.unused.items.len >= 5) {
                template.destroy();
                return;
            }
            pool.unused.append(self.allocator, template) catch template.destroy();
        }
    };
}
