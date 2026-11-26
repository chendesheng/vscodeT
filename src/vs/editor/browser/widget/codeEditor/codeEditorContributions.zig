// Port of `src/vs/editor/browser/widget/codeEditor/codeEditorContributions.ts`.
// Native contribution instances use typed factories at the composition boundary.
// Borrowed registrations permit migration of existing view-bound adapters; owned
// instances are disposed by the CodeEditorWidget, independently of its model.
const std = @import("std");
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const extensions = @import("../../editorExtensions.zig");
const Instantiation = extensions.EditorContributionInstantiation;
const Description = extensions.IEditorContributionDescription;
const dispatch = @import("../../../../base/common/windowDispatch.zig");
const time = @import("../../../../base/common/timeCompat.zig");

/// The terminal serializes the currently ported contribution mementos with
/// their upstream IDs; the registry, not the code editor, invokes each
/// instantiated contribution's state hooks. Folding's model memento is
/// supplied by the existing built-in folding controller.
pub const State = struct {
    @"editor.contrib.folding": ?@import("../../../contrib/folding/browser/folding.zig").FoldingStateMemento = null,
    @"editor.contrib.findController": ?@import("../../../contrib/find/browser/findWidget.zig").FindWidgetViewState = null,
    @"editor.contrib.wordHighlighter": ?bool = null,
};

pub const CodeEditorContributions = struct {
    instances: std.StringArrayHashMapUnmanaged(Instance) = .empty,
    pending: std.StringArrayHashMapUnmanaged(Description) = .empty,
    finished_instantiation: [@backingInt(Instantiation.lazy) + 1]bool = @splat(false),
    after_first_render: dispatch.Task = .{},
    before_first_interaction: dispatch.Task = .{},
    eventually: dispatch.Task = .{},

    const Instance = struct {
        value: *anyopaque,
        lifetime: IDisposable = .none,
        save_view_state: ?*const fn (*anyopaque, *State) void = null,
        restore_view_state: ?*const fn (*anyopaque, State) void = null,
    };

    pub fn register(self: *CodeEditorContributions, allocator: std.mem.Allocator, comptime T: type, value: *T, lifetime: IDisposable) !void {
        if (self.instances.contains(T.ID)) return error.DuplicateEditorContribution;
        var instance: Instance = .{ .value = value, .lifetime = lifetime };
        if (comptime @hasField(State, T.ID) and @hasDecl(T, "saveViewState") and @hasDecl(T, "restoreViewState")) {
            instance.save_view_state = struct {
                fn run(context: *anyopaque, state: *State) void {
                    const contribution: *T = @ptrCast(@alignCast(context));
                    @field(state.*, T.ID) = contribution.saveViewState();
                }
            }.run;
            instance.restore_view_state = struct {
                fn run(context: *anyopaque, state: State) void {
                    const contribution: *T = @ptrCast(@alignCast(context));
                    contribution.restoreViewState(@field(state, T.ID));
                }
            }.run;
        }
        try self.instances.put(allocator, T.ID, instance);
    }

    pub fn registerFactory(self: *CodeEditorContributions, allocator: std.mem.Allocator, description: Description) !void {
        if (self.instances.contains(description.id) or self.pending.contains(description.id)) return error.DuplicateEditorContribution;
        try self.pending.put(allocator, description.id, description);
        if (description.instantiation == .eager or self.finished_instantiation[@backingInt(description.instantiation)]) {
            _ = self.instantiateById(description.id);
        }
    }

    /// Detach a model/view-bound factory before its native context dies. The
    /// stable widget can bind the descriptor again on the next model.
    pub fn unregisterFactory(self: *CodeEditorContributions, id: []const u8, context: *anyopaque) void {
        const pending = self.pending.get(id) orelse return;
        if (pending.context == context) _ = self.pending.orderedRemove(id);
    }

    pub fn getInstantiated(self: *const CodeEditorContributions, comptime T: type) ?*T {
        const instance = self.instances.get(T.ID) orelse return null;
        return @ptrCast(@alignCast(instance.value));
    }

    pub fn get(self: *CodeEditorContributions, comptime T: type) ?*T {
        _ = self.instantiateById(T.ID);
        return self.getInstantiated(T);
    }

    pub fn saveViewState(self: *CodeEditorContributions) State {
        var state: State = .{};
        for (self.instances.values()) |instance| {
            if (instance.save_view_state) |save| save(instance.value, &state);
        }
        return state;
    }

    pub fn restoreViewState(self: *CodeEditorContributions, state: State) void {
        for (self.instances.values()) |instance| {
            if (instance.restore_view_state) |restore| restore(instance.value, state);
        }
    }

    pub fn attachWindow(self: *CodeEditorContributions, queue: *dispatch.Queue) void {
        if (self.after_first_render.queue == queue) return;
        self.cancelScheduled();
        self.after_first_render = .{ .queue = queue, .context = self, .run = afterFirstRender, .idle = true };
        self.before_first_interaction = .{ .queue = queue, .context = self, .run = beforeFirstInteraction, .idle = true };
        self.eventually = .{ .queue = queue, .context = self, .run = onEventually, .idle = true };
        if (!self.isFinished(.after_first_render)) self.after_first_render.schedule(std.math.maxInt(i64));
        if (!self.isFinished(.before_first_interaction)) self.before_first_interaction.schedule(std.math.maxInt(i64));
        if (!self.isFinished(.eventually)) self.eventually.schedule(time.milliTimestamp() + 5000);
    }

    pub fn onAfterModelAttached(self: *CodeEditorContributions) void {
        if (self.isFinished(.after_first_render)) return;
        const deadline = time.milliTimestamp() + 50;
        // Keep an earlier idle/deadline request; a new model must never
        // postpone the first-render instantiation.
        if (self.after_first_render.at == null or self.after_first_render.at.? > deadline) self.after_first_render.schedule(deadline);
    }

    pub fn onBeforeInteractionEvent(self: *CodeEditorContributions) void {
        self.before_first_interaction.schedule(null);
        _ = self.instantiateSome(.before_first_interaction);
    }

    fn isFinished(self: *const CodeEditorContributions, kind: Instantiation) bool {
        return self.finished_instantiation[@backingInt(kind)];
    }

    fn instantiateById(self: *CodeEditorContributions, id: []const u8) bool {
        const pending = self.pending.fetchOrderedRemove(id) orelse return false;
        const description = pending.value;
        description.instantiate(description.context) catch |err| {
            std.log.scoped(.editor_contributions).warn("Failed to instantiate {s}: {s}", .{ description.id, @errorName(err) });
            return false;
        };
        return true;
    }

    fn instantiateSome(self: *CodeEditorContributions, kind: Instantiation) bool {
        const index = @backingInt(kind);
        if (self.finished_instantiation[index]) return false;
        self.finished_instantiation[index] = true;
        var created = false;
        while (true) {
            var iterator = self.pending.iterator();
            var id: ?[]const u8 = null;
            while (iterator.next()) |entry| {
                if (entry.value_ptr.instantiation == kind) {
                    id = entry.key_ptr.*;
                    break;
                }
            }
            created = self.instantiateById(id orelse break) or created;
        }
        return created;
    }

    fn afterFirstRender(context: *anyopaque, _: i64, _: bool) bool {
        const self: *CodeEditorContributions = @ptrCast(@alignCast(context));
        return self.instantiateSome(.after_first_render);
    }

    fn beforeFirstInteraction(context: *anyopaque, _: i64, _: bool) bool {
        const self: *CodeEditorContributions = @ptrCast(@alignCast(context));
        return self.instantiateSome(.before_first_interaction);
    }

    fn onEventually(context: *anyopaque, _: i64, _: bool) bool {
        const self: *CodeEditorContributions = @ptrCast(@alignCast(context));
        return self.instantiateSome(.eventually);
    }

    fn cancelScheduled(self: *CodeEditorContributions) void {
        self.after_first_render.schedule(null);
        self.before_first_interaction.schedule(null);
        self.eventually.schedule(null);
    }

    /// Existing native adapters remove borrowed registrations before releasing
    /// their models. Owned instances remain until the widget is disposed.
    pub fn unregister(self: *CodeEditorContributions, comptime T: type, value: *T) void {
        const instance = self.instances.get(T.ID) orelse return;
        if (instance.value == @as(*anyopaque, @ptrCast(value)) and instance.lifetime.isNone()) _ = self.instances.orderedRemove(T.ID);
    }

    pub fn deinit(self: *CodeEditorContributions, allocator: std.mem.Allocator) void {
        self.cancelScheduled();
        self.pending.deinit(allocator);
        // Remove first: disposal can synchronously access the editor registry.
        while (self.instances.count() != 0) {
            var iterator = self.instances.iterator();
            const entry = iterator.next().?;
            const instance = self.instances.fetchOrderedRemove(entry.key_ptr.*).?.value;
            instance.lifetime.dispose();
        }
        self.instances.deinit(allocator);
    }
};

test "CodeEditorContributions: upstream instantiation phases and model-bound factory disposal" {
    const TestContribution = struct {
        fn Type(comptime contribution_id: []const u8) type {
            return struct {
                pub const ID = contribution_id;
                calls: usize = 0,
            };
        }
        fn Factory(comptime Contribution: type) type {
            return struct {
                registry: *CodeEditorContributions,
                value: Contribution = .{},
                fn create(context: *anyopaque) !void {
                    const self: *@This() = @ptrCast(@alignCast(context));
                    self.value.calls += 1;
                    try self.registry.register(std.testing.allocator, Contribution, &self.value, .none);
                }
                fn description(self: *@This(), kind: Instantiation) Description {
                    return .{ .id = Contribution.ID, .instantiation = kind, .context = self, .instantiate = create };
                }
            };
        }
    };
    const Eager = TestContribution.Type("test.eager");
    const After = TestContribution.Type("test.after");
    const Before = TestContribution.Type("test.before");
    const Eventually = TestContribution.Type("test.eventually");
    const Lazy = TestContribution.Type("test.lazy");
    const Rebound = TestContribution.Type("test.rebound");
    const allocator = std.testing.allocator;
    var queue: dispatch.Queue = .{ .io = std.testing.io };
    var registry: CodeEditorContributions = .{};
    defer registry.deinit(allocator);
    var eager: TestContribution.Factory(Eager) = .{ .registry = &registry };
    var after: TestContribution.Factory(After) = .{ .registry = &registry };
    var before: TestContribution.Factory(Before) = .{ .registry = &registry };
    var eventually: TestContribution.Factory(Eventually) = .{ .registry = &registry };
    var lazy: TestContribution.Factory(Lazy) = .{ .registry = &registry };
    var rebound: TestContribution.Factory(Rebound) = .{ .registry = &registry };
    try registry.registerFactory(allocator, eager.description(.eager));
    try registry.registerFactory(allocator, after.description(.after_first_render));
    try registry.registerFactory(allocator, before.description(.before_first_interaction));
    try registry.registerFactory(allocator, eventually.description(.eventually));
    try registry.registerFactory(allocator, lazy.description(.lazy));
    try registry.registerFactory(allocator, rebound.description(.after_first_render));
    try std.testing.expect(registry.getInstantiated(Eager) == &eager.value);
    try std.testing.expect(registry.getInstantiated(Lazy) == null);
    try std.testing.expect(registry.getInstantiated(After) == null);
    registry.attachWindow(&queue);
    registry.onAfterModelAttached();
    registry.unregisterFactory(Rebound.ID, &rebound);
    registry.onBeforeInteractionEvent();
    try std.testing.expect(registry.getInstantiated(Before) == &before.value);
    try std.testing.expect(registry.getInstantiated(After) == null);
    try std.testing.expect(queue.dispatch(time.milliTimestamp()));
    try std.testing.expect(registry.getInstantiated(After) == &after.value);
    try std.testing.expect(registry.getInstantiated(Rebound) == null);
    // The widget survives model replacement. A factory attached after its
    // instantiation phase has completed executes as soon as it can bind.
    try registry.registerFactory(allocator, rebound.description(.after_first_render));
    try std.testing.expect(registry.getInstantiated(Rebound) == &rebound.value);
    try std.testing.expect(queue.dispatch(time.milliTimestamp()));
    try std.testing.expect(registry.getInstantiated(Eventually) == &eventually.value);
    try std.testing.expect(registry.getInstantiated(Lazy) == null);
    try std.testing.expect(registry.get(Lazy) == &lazy.value);
    try std.testing.expect(registry.get(Lazy) == &lazy.value);
    try std.testing.expectEqual(@as(usize, 1), lazy.value.calls);
    try std.testing.expectEqual(@as(usize, 1), rebound.value.calls);
    try std.testing.expect(!queue.dispatch(time.milliTimestamp()));
}
