// Port of the registry behavior of
// `src/vs/workbench/services/outline/browser/outlineService.ts`.
//
// Terminal adaptation: `createOutline` is synchronous because the terminal has
// no language server/extension host. A future asynchronous provider can create
// its outline first and fire `IOutline.on_did_change`; the breadcrumbs model
// subscribes to that event.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lifecycle = @import("../../../../base/common/lifecycle.zig");
const IDisposable = lifecycle.IDisposable;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const outline_mod = @import("outline.zig");
const OutlineEditor = outline_mod.OutlineEditor;
const OutlineTarget = outline_mod.OutlineTarget;
const IOutline = outline_mod.IOutline;
const IOutlineCreator = outline_mod.IOutlineCreator;

pub const CreatorEntry = struct {
    creator: IOutlineCreator,
    active: bool = true,
};

pub const OutlineService = struct {
    allocator: Allocator,
    creators: std.array_list.Managed(CreatorEntry),
    on_did_change: Emitter(void),

    const Registration = struct {
        service: *OutlineService,
        index: usize,
    };

    pub fn init(allocator: Allocator) OutlineService {
        return .{
            .allocator = allocator,
            .creators = std.array_list.Managed(CreatorEntry).init(allocator),
            .on_did_change = Emitter(void).init(allocator),
        };
    }

    pub fn deinit(self: *OutlineService) void {
        self.on_did_change.deinit();
        self.creators.deinit();
    }

    pub fn notifyOutlineChanged(self: *OutlineService) void {
        self.on_did_change.fire({}) catch {};
    }

    pub fn canCreateOutline(self: *const OutlineService, editor: OutlineEditor) bool {
        for (self.creators.items) |entry| {
            if (!entry.active) continue;
            if (entry.creator.matches(entry.creator.context, editor)) return true;
        }
        return false;
    }

    pub fn createOutline(
        self: *OutlineService,
        editor: OutlineEditor,
        target: OutlineTarget,
    ) !?*IOutline {
        for (self.creators.items) |entry| {
            if (!entry.active) continue;
            if (!entry.creator.matches(entry.creator.context, editor)) continue;
            return entry.creator.create_outline(entry.creator.context, editor, target);
        }
        return null;
    }

    /// Registers a creator and returns a disposable that deactivates exactly
    /// that creator. Entries stay in the list so a later unregistration never
    /// removes a different provider.
    pub fn registerOutlineCreator(self: *OutlineService, creator: IOutlineCreator) !IDisposable {
        try self.creators.append(.{ .creator = creator });
        const registration = try self.allocator.create(Registration);
        registration.* = .{ .service = self, .index = self.creators.items.len - 1 };
        self.notifyOutlineChanged();
        return .{ .context = registration, .disposeFn = disposeRegistration };
    }

    fn disposeRegistration(context: *anyopaque) void {
        const registration: *Registration = @ptrCast(@alignCast(context));
        const service = registration.service;
        if (registration.index < service.creators.items.len) {
            service.creators.items[registration.index].active = false;
        }
        service.allocator.destroy(registration);
        service.notifyOutlineChanged();
    }
};

test "OutlineService: matching, creation and unregistration" {
    const allocator = std.testing.allocator;
    var service = OutlineService.init(allocator);
    defer service.deinit();

    const Fake = struct {
        fn matches(_: *anyopaque, editor: OutlineEditor) bool {
            return editor.resource != null;
        }
        fn create(_: *anyopaque, editor: OutlineEditor, target: OutlineTarget) !?*IOutline {
            _ = editor;
            _ = target;
            return error.NotImplemented;
        }
    };
    const creator = IOutlineCreator{
        .context = &service,
        .matches = Fake.matches,
        .create_outline = Fake.create,
    };

    const editor = OutlineEditor{ .context = &service, .resource = "/tmp/a.zig", .language_id = "zig" };
    try std.testing.expect(!service.canCreateOutline(editor));
    const registration = try service.registerOutlineCreator(creator);
    try std.testing.expect(service.canCreateOutline(editor));
    registration.dispose();
    try std.testing.expect(!service.canCreateOutline(editor));
}
