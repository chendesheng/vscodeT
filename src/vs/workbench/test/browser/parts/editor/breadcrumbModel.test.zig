// Port of the adapted cases in
// `src/vs/workbench/test/browser/parts/editor/breadcrumbModel.test.ts`.
//
// Upstream resolves `URI`s through the workspace, label and URI-identity
// services. The terminal model works on canonical path strings, so the cases
// cover the workspace-relative/absolute decision, the multi-root root label,
// `filePath` modes and the breadcrumbs data source. Home/contributed-label
// cases are not portable because `ILabelService` is not part of this port.

const std = @import("std");
const WorkspaceContextService = @import("../../../../services/workspaces/common/workspaceContextService.zig").WorkspaceContextService;
const OutlineService = @import("../../../../services/outline/browser/outlineService.zig").OutlineService;
const outline_mod = @import("../../../../services/outline/browser/outline.zig");
const OutlineEditor = outline_mod.OutlineEditor;
const OutlineTarget = outline_mod.OutlineTarget;
const IOutline = outline_mod.IOutline;
const FileKind = @import("../../../../../platform/files/common/files.zig").FileKind;
const model_mod = @import("../../../../browser/parts/editor/breadcrumbsModel.zig");
const BreadcrumbsModel = model_mod.BreadcrumbsModel;

test "BreadcrumbsModel: files inside a single-root workspace" {
    const allocator = std.testing.allocator;
    const workspace = try WorkspaceContextService.initWithFolders(allocator, "w", &.{"/repo"});
    defer workspace.deinit();

    const model = try BreadcrumbsModel.init(allocator, "/repo/src/a.ts", workspace, .{}, null, null);
    defer model.deinit();

    const elements = model.getElements();
    try std.testing.expectEqual(@as(usize, 2), elements.len);
    try std.testing.expectEqual(FileKind.FOLDER, elements[0].file.kind);
    try std.testing.expectEqual(FileKind.FILE, elements[1].file.kind);
    try std.testing.expect(std.mem.endsWith(u8, elements[0].file.path, "/src"));
    try std.testing.expect(std.mem.endsWith(u8, elements[1].file.path, "/a.ts"));
    try std.testing.expect(model.isRelative());
}

test "BreadcrumbsModel: files outside the workspace keep absolute segments" {
    const allocator = std.testing.allocator;
    const workspace = try WorkspaceContextService.initWithFolders(allocator, "w", &.{"/repo"});
    defer workspace.deinit();

    const model = try BreadcrumbsModel.init(allocator, "/outside/file.ts", workspace, .{}, null, null);
    defer model.deinit();

    const elements = model.getElements();
    try std.testing.expectEqual(@as(usize, 2), elements.len);
    try std.testing.expectEqual(FileKind.FOLDER, elements[0].file.kind);
    try std.testing.expectEqual(FileKind.FILE, elements[1].file.kind);
    try std.testing.expectEqualStrings("/outside", elements[0].file.path);
    try std.testing.expectEqualStrings("/outside/file.ts", elements[1].file.path);
    try std.testing.expect(!model.isRelative());
}

test "BreadcrumbsModel: filePath off and last" {
    const allocator = std.testing.allocator;
    const workspace = try WorkspaceContextService.initWithFolders(allocator, "w", &.{"/repo"});
    defer workspace.deinit();

    const model = try BreadcrumbsModel.init(allocator, "/repo/a/b.ts", workspace, .{ .file_path = .last }, null, null);
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 1), model.getElements().len);
    try std.testing.expectEqualStrings("/repo/a/b.ts", model.getElements()[0].file.path);

    try model.setSettings(.{ .file_path = .off });
    try std.testing.expectEqual(@as(usize, 0), model.getElements().len);
}

test "BreadcrumbsModel: multi-root workspace keeps the root label" {
    const allocator = std.testing.allocator;
    const workspace = try WorkspaceContextService.initWithFolders(allocator, "w", &.{ "/repo/a", "/repo/b" });
    defer workspace.deinit();

    const model = try BreadcrumbsModel.init(allocator, "/repo/a/file.ts", workspace, .{}, null, null);
    defer model.deinit();
    const elements = model.getElements();
    try std.testing.expectEqual(@as(usize, 2), elements.len);
    try std.testing.expectEqual(FileKind.ROOT_FOLDER, elements[0].file.kind);
    try std.testing.expectEqualStrings("a", elements[0].file.label.?);
}

test "BreadcrumbsModel: symbols from an outline provider" {
    const allocator = std.testing.allocator;
    const workspace = try WorkspaceContextService.initWithFolders(allocator, "w", &.{"/repo"});
    defer workspace.deinit();

    var service = OutlineService.init(allocator);
    defer service.deinit();

    const Fake = struct {
        var labels = [_][]const u8{ "parseAuthority", "port" };
        var elements: [2]outline_mod.OutlineElement = undefined;
        var outline: IOutline = undefined;

        fn matches(_: *anyopaque, _: OutlineEditor) bool {
            return true;
        }
        fn create(_: *anyopaque, _: OutlineEditor, _: OutlineTarget) !?*IOutline {
            return &outline;
        }
        fn getElements(_: *anyopaque) []const outline_mod.OutlineElement {
            return &elements;
        }
        fn reveal(_: *anyopaque, _: *anyopaque, _: outline_mod.RevealOptions) !void {}
        fn dispose(_: *anyopaque) void {}
    };
    var fake_instance: Fake = .{};
    Fake.elements[0] = .{ .element = @ptrCast(@constCast(&Fake.labels[0])), .label = Fake.labels[0] };
    Fake.elements[1] = .{ .element = @ptrCast(@constCast(&Fake.labels[1])), .label = Fake.labels[1] };
    Fake.outline = .{
        .context = @ptrCast(&fake_instance),
        .uri = "/repo/file.ts",
        .outline_kind = "test",
        .config = .{ .breadcrumbs_data_source = .{
            .context = @ptrCast(&fake_instance),
            .get_breadcrumb_elements = Fake.getElements,
        } },
        .on_did_change = null,
        .revealFn = Fake.reveal,
        .disposeFn = Fake.dispose,
    };
    const registration = try service.registerOutlineCreator(.{
        .context = @ptrCast(&fake_instance),
        .matches = Fake.matches,
        .create_outline = Fake.create,
    });
    defer registration.dispose();

    const editor = OutlineEditor{ .context = @ptrCast(&fake_instance), .resource = "/repo/file.ts", .language_id = "javascript" };
    const model = try BreadcrumbsModel.init(allocator, "/repo/file.ts", workspace, .{}, &service, editor);
    defer model.deinit();

    const elements = model.getElements();
    try std.testing.expectEqual(@as(usize, 3), elements.len);
    try std.testing.expectEqualStrings("parseAuthority", elements[1].outline.label);
    try std.testing.expectEqualStrings("port", elements[2].outline.label);

    try model.setSettings(.{ .symbol_path = .last });
    try std.testing.expectEqual(@as(usize, 2), model.getElements().len);
    try std.testing.expectEqualStrings("port", model.getElements()[1].outline.label);
}
