// Port of `src/vs/workbench/contrib/scm/browser/scmViewService.ts`.
// Active-repository selection follows the latest active editor or focused
// repository, with pinning overriding both. The native editor service and
// SCM registry deliver events in place of upstream derived observables.
// Repository visibility, sorting and persisted selection are separate gaps.
const std = @import("std");
const scm = @import("../common/scm.zig");
const editor_service = @import("../../../services/editor/common/editorService.zig");
const EditorInput = @import("../../../common/editor/editorInput.zig").EditorInput;
const events = @import("../../../../base/common/event.zig");
const uri_util = @import("../../../../base/common/stdUri.zig");

pub const SCMViewService = struct {
    allocator: std.mem.Allocator,
    scm_service: scm.ISCMService,
    editor_service: editor_service.IEditorService,
    focused_repository: ?*scm.ISCMRepository = null,
    active_editor_repository: ?*scm.ISCMRepository = null,
    latest_repository: ?*scm.ISCMRepository = null,
    pinned_repository: ?*scm.ISCMRepository = null,
    active_repository: ?scm.ActiveRepository = null,
    on_did_change_active_repository: events.Emitter(?scm.ActiveRepository),
    on_did_focus_repository: events.Emitter(?*scm.ISCMRepository),
    subscriptions: [3]?events.SignalSubscription = @splat(null),

    pub fn create(allocator: std.mem.Allocator, service: scm.ISCMService, editors: editor_service.IEditorService) !*SCMViewService {
        const self = try allocator.create(SCMViewService);
        self.* = .{
            .allocator = allocator,
            .scm_service = service,
            .editor_service = editors,
            .on_did_change_active_repository = .init(allocator),
            .on_did_focus_repository = .init(allocator),
        };
        errdefer self.destroy();
        self.subscriptions[0] = try service.on_did_add_repository.listenDisposable(self, onDidAddRepository);
        self.subscriptions[1] = try service.on_did_remove_repository.listenDisposable(self, onDidRemoveRepository);
        self.subscriptions[2] = try editors.on_did_active_editor_change.listenDisposable(self, onDidActiveEditorChange);
        for (service.repositories()) |repository| {
            try onDidAddRepository(service.getRepository(repository.id).?, self);
        }
        try onDidActiveEditorChange(editors.activeEditor(), self);
        return self;
    }

    pub fn destroy(self: *SCMViewService) void {
        for (self.subscriptions) |subscription| if (subscription) |value| value.dispose();
        self.on_did_focus_repository.deinit();
        self.on_did_change_active_repository.deinit();
        self.allocator.destroy(self);
    }

    fn firstRepository(self: *SCMViewService) ?*scm.ISCMRepository {
        for (self.scm_service.repositories()) |repository| {
            if (!repository.provider.is_hidden) return self.scm_service.getRepository(repository.id);
        }
        return null;
    }

    fn onDidAddRepository(repository: *scm.ISCMRepository, self: *SCMViewService) !void {
        if (self.focused_repository == null and !repository.provider.is_hidden) self.focus(repository);
    }

    fn onDidRemoveRepository(repository: *scm.ISCMRepository, self: *SCMViewService) !void {
        if (self.active_editor_repository == repository) self.active_editor_repository = null;
        if (self.pinned_repository == repository) self.pinned_repository = null;
        if (self.latest_repository == repository) self.latest_repository = self.focused_repository;
        if (self.focused_repository == repository) {
            self.focused_repository = null;
            if (self.firstRepository()) |first| {
                self.focus(first);
            } else {
                self.latest_repository = null;
                try self.on_did_focus_repository.fire(null);
            }
        }
        if (self.latest_repository == repository) self.latest_repository = self.firstRepository();
        self.updateActiveRepository();
    }

    fn onDidActiveEditorChange(input: ?*EditorInput, self: *SCMViewService) !void {
        const resource = if (input) |editor| editor.resource orelse return else return;
        // Native file inputs carry the path directly; resource editor inputs
        // carry the serialized URI. Only file resources belong to an SCM
        // provider with a native filesystem root.
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const path = if (std.fs.path.isAbsolute(resource)) resource else blk: {
            const uri = std.Uri.parse(resource) catch return;
            if (!std.mem.eql(u8, uri.scheme, "file")) return;
            break :blk try uri_util.fsPath(uri, scratch.allocator());
        };
        const repository = self.scm_service.getRepositoryByPath(path) orelse return;
        self.active_editor_repository = repository;
        self.latest_repository = repository;
        self.updateActiveRepository();
    }

    pub fn focus(self: *SCMViewService, repository: *scm.ISCMRepository) void {
        if (repository.provider.is_hidden or self.scm_service.getRepository(repository.id) != repository) return;
        self.focused_repository = repository;
        self.latest_repository = repository;
        self.on_did_focus_repository.fire(repository) catch {};
        self.updateActiveRepository();
    }

    pub fn pinActiveRepository(self: *SCMViewService, repository: ?*scm.ISCMRepository) void {
        if (repository) |value| {
            if (self.scm_service.getRepository(value.id) != value) return;
        }
        self.pinned_repository = repository;
        self.updateActiveRepository();
    }

    fn updateActiveRepository(self: *SCMViewService) void {
        const repository = self.pinned_repository orelse self.latest_repository;
        const next: ?scm.ActiveRepository = if (repository) |value| .{ .repository = value, .pinned = self.pinned_repository != null } else null;
        if (std.meta.eql(self.active_repository, next)) return;
        self.active_repository = next;
        self.on_did_change_active_repository.fire(next) catch {};
    }

    pub fn interface(self: *SCMViewService) scm.ISCMViewService {
        return .{
            .context = self,
            .active_repository_fn = struct {
                fn get(context: *anyopaque) ?scm.ActiveRepository {
                    const service: *SCMViewService = @ptrCast(@alignCast(context));
                    return service.active_repository;
                }
            }.get,
            .focused_repository_fn = struct {
                fn get(context: *anyopaque) ?*scm.ISCMRepository {
                    const service: *SCMViewService = @ptrCast(@alignCast(context));
                    return service.focused_repository;
                }
            }.get,
            .focus_fn = struct {
                fn run(context: *anyopaque, repository: *scm.ISCMRepository) void {
                    const service: *SCMViewService = @ptrCast(@alignCast(context));
                    service.focus(repository);
                }
            }.run,
            .pin_active_repository_fn = struct {
                fn run(context: *anyopaque, repository: ?*scm.ISCMRepository) void {
                    const service: *SCMViewService = @ptrCast(@alignCast(context));
                    service.pinActiveRepository(repository);
                }
            }.run,
            .on_did_change_active_repository = &self.on_did_change_active_repository,
            .on_did_focus_repository = &self.on_did_focus_repository,
        };
    }
};
