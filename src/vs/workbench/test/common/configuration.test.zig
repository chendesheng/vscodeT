// Tests for `src/vs/workbench/common/configuration.ts`'s migration registry
// and contribution, adapted to the terminal's actual local configuration
// targets. There is no application/remote store to exercise here.
const std = @import("std");
const migration = @import("../../common/configuration.zig");
const Config = @import("../../services/configuration/browser/configurationService.zig").ConfigurationService;
const Workspace = @import("../../services/workspaces/common/workspaceContextService.zig").WorkspaceContextService;
const descriptor = @import("../../contrib/codeEditor/browser/diffEditorHelper.zig").configuration_migrations[0];

const legacy = "diffEditor.experimental.collapseUnchangedRegions";
const current = "diffEditor.hideUnchangedRegions.enabled";

test "configuration migration: rename settings in each exact JSONC scope without touching other text" {
    const a = std.testing.allocator;
    const text =
        \\{
        \\  // keep this comment
        \\  "diffEditor.experimental.collapseUnchangedRegions": true,
        \\  "diffEditor.hideUnchangedRegions.enabled": false, // old wins
        \\  "[zig][rust]": {
        \\    "diffEditor.experimental.collapseUnchangedRegions": false,
        \\    "editor.wordWrap": "on",
        \\  },
        \\  "unrelated": {"diffEditor.experimental.collapseUnchangedRegions": true},
        \\  "literal": "diffEditor.experimental.collapseUnchangedRegions",
        \\}
    ;
    const result = (try migration.migrateConfigurationText(a, text, false, &.{descriptor})).?;
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "// keep this comment") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"diffEditor.hideUnchangedRegions.enabled\": true, // old wins") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"diffEditor.hideUnchangedRegions.enabled\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"unrelated\": {\"diffEditor.experimental.collapseUnchangedRegions\": true}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"literal\": \"diffEditor.experimental.collapseUnchangedRegions\"") != null);
    try std.testing.expect((try migration.migrateConfigurationText(a, result, false, &.{descriptor})) == null);
    try std.testing.expect((try migration.migrateConfigurationText(a, "{ broken", false, &.{descriptor})) == null);
}

test "configuration migration: workspace settings and duplicate old keys use the effective value" {
    const a = std.testing.allocator;
    const text =
        \\{"settings": {
        \\  "diffEditor.experimental.collapseUnchangedRegions": false,
        \\  "diffEditor.experimental.collapseUnchangedRegions": true,
        \\  "diffEditor.hideUnchangedRegions.enabled": false,
        \\}, "diffEditor.experimental.collapseUnchangedRegions": false}
    ;
    const result = (try migration.migrateConfigurationText(a, text, true, &.{descriptor})).?;
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"diffEditor.hideUnchangedRegions.enabled\": true") != null);
    try std.testing.expect(std.mem.endsWith(u8, result, "\"diffEditor.experimental.collapseUnchangedRegions\": false}"));
    try std.testing.expect((try migration.migrateConfigurationText(a, result, true, &.{descriptor})) == null);
}

test "configuration migration: startup, late registration and added folder events edit their own files" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const user = try std.fs.path.join(a, &.{ root, "user.json" });
    defer a.free(user);
    const workspace_file = try std.fs.path.join(a, &.{ root, "work.code-workspace" });
    defer a.free(workspace_file);
    const folder_one = try std.fs.path.join(a, &.{ root, "one" });
    defer a.free(folder_one);
    const folder_two = try std.fs.path.join(a, &.{ root, "two" });
    defer a.free(folder_two);
    try tmp.dir.createDirPath(io, "one/.vscode");
    try tmp.dir.createDirPath(io, "two/.vscode");
    try tmp.dir.writeFile(io, .{ .sub_path = "user.json", .data = "{\n // keep\n \"diffEditor.experimental.collapseUnchangedRegions\": true, \"late.old\": 42,\n}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "work.code-workspace", .data = "{\"settings\":{\"diffEditor.experimental.collapseUnchangedRegions\": false}}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "one/.vscode/settings.json", .data = "{\"diffEditor.experimental.collapseUnchangedRegions\": true}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "two/.vscode/settings.json", .data = "{\"[zig]\":{\"diffEditor.experimental.collapseUnchangedRegions\": false}}" });
    const workspace = try Workspace.initWithFolders(a, "test", &.{folder_one});
    defer workspace.deinit();
    try workspace.setConfiguration(workspace_file);
    const config = try Config.init(a, io, workspace, .{ .user_settings_paths = &.{user} });
    defer config.deinit();
    var contribution = migration.ConfigurationMigrationWorkbenchContribution.init(a);
    defer contribution.deinit();
    try contribution.registry.registerConfigurationMigrations(&.{descriptor});
    try contribution.bind(config);
    try std.testing.expect(config.getValue(legacy, .{}) != null);
    try migration.ConfigurationMigrationWorkbenchContribution.start(&contribution);
    try std.testing.expect(config.getValue(legacy, .{}) == null);
    try std.testing.expectEqual(false, config.getValue(current, .{}).?.bool);
    try std.testing.expectEqual(true, config.getValue(current, .{ .resource = folder_one }).?.bool);
    const user_text = try tmp.dir.readFileAlloc(io, "user.json", a, .limited(4096));
    defer a.free(user_text);
    try std.testing.expect(std.mem.indexOf(u8, user_text, "// keep") != null);
    try contribution.registry.registerConfigurationMigrations(&.{.{ .key = "late.old", .rename_to = "late.new" }});
    try std.testing.expect(config.getValue("late.old", .{}) == null);
    try std.testing.expectEqual(@as(i64, 42), config.getValue("late.new", .{}).?.integer);
    try workspace.addFolder(folder_two);
    try std.testing.expectEqual(false, config.getValue(current, .{ .resource = folder_two, .override_identifier = "zig" }).?.bool);
    const second = try tmp.dir.readFileAlloc(io, "two/.vscode/settings.json", a, .limited(4096));
    defer a.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, legacy) == null);
}
