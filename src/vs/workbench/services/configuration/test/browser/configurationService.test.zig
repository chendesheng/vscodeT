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
    const io = std.testing.io;
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
    const io = std.testing.io;
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
        .user_settings_paths = &.{user_path},
    });
    defer service.deinit();

    // Without a resource, folder settings do not apply; only user and
    // workspace scopes are visible. Explorer reads values with a resource.
    try std.testing.expectEqual(@as(i64, 2), service.getValue("editor.tabSize", .{}).?.integer);
    try std.testing.expect(!service.getBool("explorer.excludeGitIgnore", true));

    const file_path = try std.fmt.allocPrint(allocator, "{s}/main.zig", .{root});
    defer allocator.free(file_path);
    var binding = service_mod.ConfigurationServiceBinding.init(allocator);
    defer binding.deinit();
    try binding.bind(service);
    try std.testing.expectEqual(@as(i64, 2), binding.interface().getValue("editor.tabSize").?.integer);
    try std.testing.expectEqual(@as(i64, 4), binding.interface().getValueWithOverrides("editor.tabSize", .{ .resource = file_path }).?.integer);
    const inspected = service.inspect("editor.tabSize", .{ .resource = file_path });
    try std.testing.expectEqual(@as(i64, 2), inspected.user.?.integer);
    try std.testing.expect(inspected.workspace == null);
    try std.testing.expectEqual(@as(i64, 4), inspected.workspace_folder.?.integer);
    try std.testing.expectEqual(@as(i64, 4), inspected.value.?.integer);

    const keys = service.keys();
    try std.testing.expectEqual(@as(usize, 2), keys.user.len);
    try std.testing.expectEqual(@as(usize, 0), keys.workspace.len);
}

test "ConfigurationService: later user layers override earlier ones" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeFile(&tmp, io, "vscode-user.json",
        \\{
        \\  // VS Code profile layer
        \\  "editor.tabSize": 8,
        \\  "files.eol": "\n",
        \\}
    );
    try writeFile(&tmp, io, "tui-user.json",
        \\{
        \\  "editor.tabSize": 3,
        \\  "editor.insertSpaces": false,
        \\}
    );

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try absoluteRoot(&tmp, io, &buffer);
    const vscode_user = try std.fmt.allocPrint(allocator, "{s}/vscode-user.json", .{root});
    defer allocator.free(vscode_user);
    const tui_user = try std.fmt.allocPrint(allocator, "{s}/tui-user.json", .{root});
    defer allocator.free(tui_user);
    const missing_user = try std.fmt.allocPrint(allocator, "{s}/missing-settings.json", .{root});
    defer allocator.free(missing_user);

    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const service = try ConfigurationService.init(allocator, io, context, .{
        .user_settings_paths = &.{ vscode_user, tui_user, missing_user },
    });
    defer service.deinit();

    // The later TUI layer wins; the earlier layer's other keys survive and a
    // missing file behaves like an empty layer.
    try std.testing.expectEqual(@as(i64, 3), service.getValue("editor.tabSize", .{}).?.integer);
    try std.testing.expect(!service.getValue("editor.insertSpaces", .{}).?.bool);
    try std.testing.expectEqualStrings("\n", service.getValue("files.eol", .{}).?.string);
    const inspected = service.inspect("editor.tabSize", .{});
    try std.testing.expectEqual(@as(i64, 3), inspected.user.?.integer);
}

test "ConfigurationService: workspace file settings and folder override" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
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
    try service.interface().updateResourceValue("editor.tabSize", .{ .integer = 7 }, .{ .resource = file_path }, null);
    try std.testing.expectEqual(@as(i64, 7), service.getValue("editor.tabSize", .{ .resource = file_path }).?.integer);
    try std.testing.expectEqual(@as(i64, 3), service.getValue("editor.tabSize", .{}).?.integer);
    try service.interface().updateResourceValue("files.eol", .{ .string = "\r\n" }, .{ .resource = file_path }, null);
    try std.testing.expectEqualStrings("\r\n", service.getValue("files.eol", .{}).?.string);
    try std.testing.expectEqual(@as(i64, 7), service.getValue("editor.tabSize", .{ .resource = file_path }).?.integer);
}

test "ConfigurationService: reload emits a change event" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
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

test "ConfigurationService: reload reports added removed updated and override keys only" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".vscode");
    try writeFile(&tmp, io, ".vscode/settings.json",
        \\{"files.associations":{"*.foo":"zig"}, "editor.tabSize":2, "editor.insertSpaces":true, "[zig]":{"editor.tabSize":4}}
    );
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try absoluteRoot(&tmp, io, &buffer);
    const context = try WorkspaceContextService.initWithFolders(allocator, "test", &.{root});
    defer context.deinit();
    const service = try ConfigurationService.init(allocator, io, context, .{});
    defer service.deinit();
    const config = @import("../../../../../platform/configuration/common/configuration.zig");
    const Listener = struct {
        count: usize = 0,
        valid: bool = false,
        fn changed(change: service_mod.Change, self: *@This()) !void {
            self.count += 1;
            self.valid = change.keys.len == 3 and
                config.affectsConfiguration(change, "files.associations") and
                config.affectsConfiguration(change, "editor.tabSize") and
                config.affectsConfiguration(change, "files.eol") and
                !config.affectsConfiguration(change, "editor.insertSpaces") and
                config.affectsConfigurationWithOverrides(change, "editor.wordWrap", "zig") and
                !config.affectsConfigurationWithOverrides(change, "editor.wordWrap", "python");
        }
    };
    var listener: Listener = .{};
    try service.onDidChangeConfiguration(&listener, Listener.changed);
    try service.reload();
    try std.testing.expectEqual(@as(usize, 0), listener.count);
    try writeFile(&tmp, io, ".vscode/settings.json",
        \\{"editor.tabSize":6, "editor.insertSpaces":true, "files.eol":"lf", "[zig]":{"editor.tabSize":4,"editor.wordWrap":"on"}}
    );
    try service.reload();
    try std.testing.expectEqual(@as(usize, 1), listener.count);
    try std.testing.expect(listener.valid);
    try service.reload();
    try std.testing.expectEqual(@as(usize, 1), listener.count);
}

test "ConfigurationService: settings files accept comments and trailing commas" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
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
    const io = std.testing.io;
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
    const service = try ConfigurationService.init(allocator, io, context, .{ .user_settings_paths = &.{user_path} });
    defer service.deinit();

    const resource = try std.fmt.allocPrint(allocator, "{s}/main.zig", .{root});
    defer allocator.free(resource);
    try std.testing.expectEqual(@as(i64, 2), service.getValue("editor.tabSize", .{ .resource = resource }).?.integer);
    try std.testing.expectEqual(@as(i64, 4), service.getValue("editor.tabSize", .{ .resource = resource, .override_identifier = "typescript" }).?.integer);
    const first = service.getValue("editor.tabSize", .{ .resource = resource, .override_identifier = "typescript" }).?;
    try std.testing.expectEqual(@as(i64, 2), service.getValue("editor.tabSize", .{ .resource = resource, .override_identifier = "python" }).?.integer);
    try std.testing.expectEqual(first, service.getValue("editor.tabSize", .{ .resource = resource, .override_identifier = "typescript" }).?);
    try std.testing.expectEqual(@as(i64, 4), first.integer);
    const typescript_inspect = service.inspect("editor.tabSize", .{ .resource = resource, .override_identifier = "typescript" });
    try std.testing.expectEqual(@as(i64, 4), typescript_inspect.value.?.integer);
    try std.testing.expectEqual(@as(usize, 1), typescript_inspect.override_identifiers.len);
    try std.testing.expectEqualStrings("typescript", typescript_inspect.override_identifiers[0]);
    try service.interface().updateResourceValue("editor.tabSize", .{ .integer = 6 }, .{ .resource = resource, .override_identifier = "typescript" }, null);
    try std.testing.expectEqual(@as(i64, 6), service.getValue("editor.tabSize", .{ .resource = resource, .override_identifier = "typescript" }).?.integer);
    try std.testing.expectEqual(@as(i64, 2), service.getValue("editor.tabSize", .{ .resource = resource, .override_identifier = "python" }).?.integer);
    try std.testing.expectEqual(@as(i64, 2), service.getValue("editor.tabSize", .{}).?.integer);
}

test "ConfigurationService: untrusted workspaces ignore restricted workspace values" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
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
    const io = std.testing.io;
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
    const service = try ConfigurationService.init(allocator, io, context, .{ .user_settings_paths = &.{user_path} });
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
    const machine_value = service.getValue("machine.setting", .{ .resource = resource }).?;
    try std.testing.expectEqual(machine_value, service.getValue("machine.setting", .{ .resource = resource }).?);
    try std.testing.expectEqual(machine_value, service.inspect("machine.setting", .{ .resource = resource }).value.?);
    try std.testing.expect(service.inspect("machine.setting", .{ .resource = resource }).workspace == null);
}

test "ConfigurationService: untrusted workspaces ignore unregistered workspace values" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
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
    const service = try ConfigurationService.init(allocator, io, context, .{ .user_settings_paths = &.{user_path} });
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

    try service.updateWorkspaceTrust(true);
    try std.testing.expectEqualStrings("workspaceValue", service.getValue("unregistered.setting", .{ .resource = resource }).?.string);
    try std.testing.expectEqual(@as(usize, 2), changes);

    try service.registry.registerConfiguration("test", &.{.{ .key = "unregistered.setting", .value_type = "string", .default = std.json.Value{ .string = "default" } }});
    try std.testing.expectEqualStrings("workspaceValue", service.getValue("unregistered.setting", .{ .resource = resource }).?.string);
}

test "ConfigurationService: queued window updates preserve order and publish after disk completion" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Window = @import("../../../../../base/common/windowDispatch.zig");
    const configuration = @import("../../../../../platform/configuration/common/configuration.zig");
    var scheduler = try @import("ui").WindowIo.init(a, io);
    defer scheduler.deinit();
    var window = Window.Queue{ .io = scheduler.io(), .scheduler = &scheduler };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(&tmp, io, "settings.json", "{}");
    const path = try tmp.dir.realPathFileAlloc(io, "settings.json", a);
    defer a.free(path);
    const workspace = try WorkspaceContextService.initEmpty(a, "test");
    defer workspace.deinit();
    const service = try ConfigurationService.init(a, io, workspace, .{ .user_settings_paths = &.{path} });
    defer service.deinit();
    service.attachWindow(&window);

    const Probe = struct {
        service: *ConfigurationService,
        owner: std.Thread.Id,
        calls: usize = 0,
        failure: ?anyerror = null,
        observed: [2]i64 = .{ 0, 0 },

        fn complete(context: *anyopaque, result: anyerror!void) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            result catch |err| {
                self.failure = err;
                return;
            };
            if (self.owner != std.Thread.getCurrentId()) {
                self.failure = error.WrongThread;
                return;
            }
            self.observed[self.calls] = self.service.getValue("editor.tabSize", .{}).?.integer;
            self.calls += 1;
        }
    };
    var probe = Probe{ .service = service, .owner = std.Thread.getCurrentId() };
    const listener = configuration.UpdateListener{ .context = &probe, .complete = Probe.complete };
    const api = service.interface();
    _ = try api.requestUpdateResourceValue("editor.tabSize", .{ .integer = 7 }, .{}, .USER, listener);
    _ = try api.requestUpdateResourceValue("editor.tabSize", .{ .integer = 9 }, .{}, .USER, listener);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    _ = window.dispatch(0);
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    for (0..3000) |_| {
        _ = window.dispatch(0);
        if (probe.calls == 2 or probe.failure != null) break;
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    if (probe.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectEqualSlices(i64, &.{ 7, 9 }, &probe.observed);
    const text = try tmp.dir.readFileAlloc(io, "settings.json", a, .unlimited);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"editor.tabSize\":9") != null);
}
