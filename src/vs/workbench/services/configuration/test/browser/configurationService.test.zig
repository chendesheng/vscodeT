// Port of the workspace-scope cases in
// `src/vs/workbench/services/configuration/test/browser/configurationService.test.ts`.
//
// The terminal harness has no file service, user-data profile, remote agent or
// policy service, so these tests use real temporary settings files and the
// ported `WorkspaceContextService` instead of the browser test services.

const std = @import("std");
const Io = std.Io;
const service_mod = @import("../../browser/configurationService.zig");
const ConfigurationService = service_mod.ConfigurationService;
const workspace_context = @import("../../../workspaces/common/workspaceContextService.zig");
const WorkspaceContextService = workspace_context.WorkspaceContextService;

fn writeFile(tmp: *std.testing.TmpDir, io: Io, path: []const u8, contents: []const u8) !void {
    var file = try tmp.dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

fn absoluteRoot(tmp: *std.testing.TmpDir, io: Io, buffer: *[std.Io.Dir.max_path_bytes]u8) ![]const u8 {
    const len = try tmp.dir.realPath(io, buffer);
    return buffer[0..len];
}

test "ConfigurationService: terminal defaults" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try absoluteRoot(&tmp, io, &buffer);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();

    const service = try ConfigurationService.init(allocator, io, context, .{});
    defer service.deinit();

    try std.testing.expect(service.getBool("explorer.excludeGitIgnore", false));
    const exclude = service.getValue("files.exclude", .{}).?;
    try std.testing.expect(exclude.object.get("**/.git").?.bool);
    try std.testing.expect(exclude.object.get("**/.DS_Store").?.bool);
}

test "ConfigurationService: workspace settings override user settings" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(
        &tmp,
        io,
        "user-settings.json",
        "{\"editor.tabSize\": 2, \"explorer.excludeGitIgnore\": false}",
    );
    try tmp.dir.createDirPath(io, ".vscode");
    try writeFile(&tmp, io, ".vscode/settings.json", "{\"editor.tabSize\": 4}");

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try absoluteRoot(&tmp, io, &buffer);
    var user_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const user_len = try tmp.dir.realPath(io, &user_path_buffer);
    const user_path = try std.fmt.allocPrint(allocator, "{s}/user-settings.json", .{user_path_buffer[0..user_len]});
    defer allocator.free(user_path);

    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const service = try ConfigurationService.init(allocator, io, context, .{
        .user_settings_path = user_path,
    });
    defer service.deinit();

    // Without a resource, folder settings do not apply; only user and
    // workspace scopes are visible. Explorer reads values with a resource.
    try std.testing.expectEqual(@as(i64, 2), service.getValue("editor.tabSize", .{}).?.integer);
    try std.testing.expect(!service.getBool("explorer.excludeGitIgnore", true));

    const file_path = try std.fmt.allocPrint(allocator, "{s}/main.zig", .{root});
    defer allocator.free(file_path);
    const inspected = service.inspect("editor.tabSize", .{ .resource = file_path });
    try std.testing.expectEqual(@as(i64, 2), inspected.user.?.integer);
    try std.testing.expect(inspected.workspace == null);
    try std.testing.expectEqual(@as(i64, 4), inspected.workspace_folder.?.integer);
    try std.testing.expectEqual(@as(i64, 4), inspected.value.?.integer);

    const keys = service.keys();
    try std.testing.expectEqual(@as(usize, 2), keys.user.len);
    try std.testing.expectEqual(@as(usize, 0), keys.workspace.len);
}

test "ConfigurationService: workspace file settings and folder override" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(&tmp, io, "workspace.code-workspace",
        \\{
        \\  "settings": {
        \\    "editor.tabSize": 3,
        \\    "files.eol": "\n"
        \\  }
        \\}
    );
    try tmp.dir.createDirPath(io, ".vscode");
    try writeFile(&tmp, io, ".vscode/settings.json", "{\"editor.tabSize\": 5}");

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try absoluteRoot(&tmp, io, &buffer);
    const workspace_path = try std.fmt.allocPrint(allocator, "{s}/workspace.code-workspace", .{root});
    defer allocator.free(workspace_path);

    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    try context.setConfiguration(workspace_path);

    const service = try ConfigurationService.init(allocator, io, context, .{});
    defer service.deinit();

    try std.testing.expectEqual(@as(i64, 3), service.getValue("editor.tabSize", .{}).?.integer);
    try std.testing.expectEqualStrings("\n", service.getValue("files.eol", .{}).?.string);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/main.zig", .{root});
    defer allocator.free(file_path);
    try std.testing.expectEqual(
        @as(i64, 5),
        service.getValue("editor.tabSize", .{ .resource = file_path }).?.integer,
    );

    const inspected = service.inspect("editor.tabSize", .{ .resource = file_path });
    try std.testing.expectEqual(@as(i64, 3), inspected.workspace.?.integer);
    try std.testing.expectEqual(@as(i64, 5), inspected.workspace_folder.?.integer);
    try std.testing.expectEqual(@as(i64, 5), inspected.value.?.integer);
}

test "ConfigurationService: reload emits a change event" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".vscode");
    try writeFile(&tmp, io, ".vscode/settings.json", "{\"editor.tabSize\": 2}");

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try absoluteRoot(&tmp, io, &buffer);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const service = try ConfigurationService.init(allocator, io, context, .{});
    defer service.deinit();

    const file_path = try std.fmt.allocPrint(allocator, "{s}/main.zig", .{root});
    defer allocator.free(file_path);

    var changes: usize = 0;
    try service.onDidChangeConfiguration(&changes, struct {
        fn changed(_: service_mod.Change, count: *usize) anyerror!void {
            count.* += 1;
        }
    }.changed);

    try writeFile(&tmp, io, ".vscode/settings.json", "{\"editor.tabSize\": 6}");
    try service.reload();

    try std.testing.expectEqual(@as(usize, 1), changes);
    try std.testing.expectEqual(
        @as(i64, 6),
        service.getValue("editor.tabSize", .{ .resource = file_path }).?.integer,
    );
}

test "ConfigurationService: settings files accept comments and trailing commas" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".vscode");
    try writeFile(&tmp, io, ".vscode/settings.json",
        \\{
        \\  // editor settings
        \\  "editor.tabSize": 8,
        \\}
    );

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try absoluteRoot(&tmp, io, &buffer);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const service = try ConfigurationService.init(allocator, io, context, .{});
    defer service.deinit();

    const file_path = try std.fmt.allocPrint(allocator, "{s}/main.zig", .{root});
    defer allocator.free(file_path);
    try std.testing.expectEqual(
        @as(i64, 8),
        service.getValue("editor.tabSize", .{ .resource = file_path }).?.integer,
    );
}

test "ConfigurationService: language overrides from workspace settings" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(&tmp, io, "user-settings.json", "{\"editor.tabSize\": 2}");
    try tmp.dir.createDirPath(io, ".vscode");
    try writeFile(&tmp, io, ".vscode/settings.json", "{\"[typescript]\": {\"editor.tabSize\": 4}}");

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try absoluteRoot(&tmp, io, &buffer);
    var user_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const user_len = try tmp.dir.realPath(io, &user_buffer);
    const user_path = try std.fmt.allocPrint(allocator, "{s}/user-settings.json", .{user_buffer[0..user_len]});
    defer allocator.free(user_path);

    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const service = try ConfigurationService.init(allocator, io, context, .{ .user_settings_path = user_path });
    defer service.deinit();

    const resource = try std.fmt.allocPrint(allocator, "{s}/main.zig", .{root});
    defer allocator.free(resource);
    try std.testing.expectEqual(@as(i64, 2), service.getValue("editor.tabSize", .{ .resource = resource }).?.integer);
    try std.testing.expectEqual(@as(i64, 4), service.getValue("editor.tabSize", .{ .resource = resource, .override_identifier = "typescript" }).?.integer);
    try std.testing.expectEqual(@as(i64, 2), service.getValue("editor.tabSize", .{ .resource = resource, .override_identifier = "python" }).?.integer);
    try std.testing.expectEqual(@as(i64, 4), service.inspect("editor.tabSize", .{ .resource = resource, .override_identifier = "typescript" }).value.?.integer);
}

test "ConfigurationService: untrusted workspaces ignore restricted workspace values" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".vscode");
    try writeFile(&tmp, io, ".vscode/settings.json", "{\"restricted.setting\": 8}");

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try absoluteRoot(&tmp, io, &buffer);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const service = try ConfigurationService.init(allocator, io, context, .{});
    defer service.deinit();
    try service.registry.registerConfiguration("test", &.{.{
        .key = "restricted.setting",
        .value_type = "number",
        .default = std.json.Value{ .integer = 4 },
        .restricted = true,
    }});
    try service.reload();

    const resource = try std.fmt.allocPrint(allocator, "{s}/main.zig", .{root});
    defer allocator.free(resource);
    try std.testing.expectEqual(@as(i64, 8), service.getValue("restricted.setting", .{ .resource = resource }).?.integer);
    service.trusted = false;
    try std.testing.expectEqual(@as(i64, 4), service.getValue("restricted.setting", .{ .resource = resource }).?.integer);
}

test "ConfigurationService: application and machine settings ignore workspace values" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(&tmp, io, "user-settings.json", "{\"application.setting\": 2, \"machine.setting\": 2}");
    try tmp.dir.createDirPath(io, ".vscode");
    try writeFile(&tmp, io, ".vscode/settings.json", "{\"application.setting\": 8, \"machine.setting\": 8}");

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try absoluteRoot(&tmp, io, &buffer);
    var user_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const user_len = try tmp.dir.realPath(io, &user_buffer);
    const user_path = try std.fmt.allocPrint(allocator, "{s}/user-settings.json", .{user_buffer[0..user_len]});
    defer allocator.free(user_path);

    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const service = try ConfigurationService.init(allocator, io, context, .{ .user_settings_path = user_path });
    defer service.deinit();
    try service.registry.registerConfiguration("test", &.{
        .{
            .key = "application.setting",
            .value_type = "number",
            .default = std.json.Value{ .integer = 4 },
            .scope = .APPLICATION,
        },
        .{
            .key = "machine.setting",
            .value_type = "number",
            .default = std.json.Value{ .integer = 4 },
            .scope = .MACHINE_OVERRIDABLE,
        },
    });

    try std.testing.expectEqual(@import("../../../../../platform/configuration/common/configuration.zig").ConfigurationScope.APPLICATION, service.registry.getConfigurationProperties().get("application.setting").?.scope);
    try std.testing.expectEqual(@as(i64, 2), service.user.getValue("application.setting").?.integer);
    const resource = try std.fmt.allocPrint(allocator, "{s}/main.zig", .{root});
    defer allocator.free(resource);
    try std.testing.expectEqual(@as(i64, 2), service.getValue("application.setting", .{ .resource = resource }).?.integer);
    try std.testing.expectEqual(@as(i64, 2), service.inspect("application.setting", .{ .resource = resource }).value.?.integer);
    try std.testing.expect(service.inspect("application.setting", .{ .resource = resource }).workspace == null);
    try std.testing.expectEqual(@as(i64, 2), service.getValue("machine.setting", .{ .resource = resource }).?.integer);
    try std.testing.expect(service.inspect("machine.setting", .{ .resource = resource }).workspace == null);
}

test "ConfigurationService: untrusted workspaces ignore unregistered workspace values" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(&tmp, io, "user-settings.json", "{\"unregistered.setting\": \"userValue\"}");
    try tmp.dir.createDirPath(io, ".vscode");
    try writeFile(&tmp, io, ".vscode/settings.json", "{\"unregistered.setting\": \"workspaceValue\"}");

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try absoluteRoot(&tmp, io, &buffer);
    var user_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const user_len = try tmp.dir.realPath(io, &user_buffer);
    const user_path = try std.fmt.allocPrint(allocator, "{s}/user-settings.json", .{user_buffer[0..user_len]});
    defer allocator.free(user_path);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const service = try ConfigurationService.init(allocator, io, context, .{ .user_settings_path = user_path });
    defer service.deinit();

    const resource = try std.fmt.allocPrint(allocator, "{s}/main.zig", .{root});
    defer allocator.free(resource);
    try std.testing.expectEqualStrings("workspaceValue", service.getValue("unregistered.setting", .{ .resource = resource }).?.string);
    const Listener = struct {
        fn onChange(_: @import("../../../../../platform/configuration/common/configuration.zig").Change, count: *usize) anyerror!void {
            count.* += 1;
        }
    };
    var changes: usize = 0;
    try service.onDidChangeConfiguration(&changes, Listener.onChange);
    try service.updateWorkspaceTrust(false);
    try std.testing.expectEqualStrings("userValue", service.getValue("unregistered.setting", .{ .resource = resource }).?.string);
    try std.testing.expect(changes > 0);

    try service.registry.registerConfiguration("test", &.{.{ .key = "unregistered.setting", .value_type = "string", .default = std.json.Value{ .string = "default" } }});
    try std.testing.expectEqualStrings("workspaceValue", service.getValue("unregistered.setting", .{ .resource = resource }).?.string);
}
