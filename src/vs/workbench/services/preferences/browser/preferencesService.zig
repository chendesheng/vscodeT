// Port of the editable JSON settings and keybindings paths in
// src/vs/workbench/services/preferences/browser/preferencesService.ts.
// Terminal profile adaptation: the last configured settings/keybindings
// path is editable, preceding VS Code profile paths are read-only inputs.
// Default-settings split editors, remote profiles and the settings GUI are
// not yet ported. Keep the established terminal empty JSON document contents.
const std = @import("std");
const IPreferencesService = @import("../common/preferences.zig").IPreferencesService;
const IEditorService = @import("../../editor/common/editorService.zig").IEditorService;
const TextFileService = @import("../../textfile/common/textFileService.zig").TextFileService;

const empty_editable_settings_content = "{\n}\n";
const empty_keybindings_content = "[\n]\n";

pub const PreferencesService = struct {
    allocator: std.mem.Allocator,
    editor_service: *const IEditorService,
    text_file_service: *TextFileService,
    settings_paths: *const []const []const u8,
    keybindings_paths: *const []const []const u8,

    pub fn interface(self: *PreferencesService) IPreferencesService {
        return .{
            .context = self,
            .open_user_settings_fn = struct {
                fn run(context: *anyopaque) !void {
                    const service: *PreferencesService = @ptrCast(@alignCast(context));
                    try service.openUserSettings();
                }
            }.run,
            .open_global_keybinding_settings_fn = struct {
                fn run(context: *anyopaque, textual: bool) !void {
                    const service: *PreferencesService = @ptrCast(@alignCast(context));
                    try service.openGlobalKeybindingSettings(textual);
                }
            }.run,
        };
    }

    pub fn openUserSettings(self: *PreferencesService) !void {
        const resource = try editableResource(self.settings_paths.*);
        try self.createIfNotExists(resource, empty_editable_settings_content);
        try self.editor_service.openEditor(resource, .{});
    }

    pub fn openGlobalKeybindingSettings(self: *PreferencesService, textual: bool) !void {
        if (!textual) return error.KeybindingsEditorNotPorted;
        const resource = try editableResource(self.keybindings_paths.*);
        try self.createIfNotExists(resource, empty_keybindings_content);
        try self.editor_service.openEditor(resource, .{});
    }

    fn editableResource(paths: []const []const u8) ![]const u8 {
        if (paths.len == 0) return error.NoConfigPath;
        return paths[paths.len - 1];
    }

    fn createIfNotExists(self: *PreferencesService, resource: []const u8, contents: []const u8) !void {
        const existing = self.text_file_service.read(resource, self.allocator) catch |err| switch (err) {
            error.FileNotFound => return self.text_file_service.write(resource, contents),
            else => return err,
        };
        self.allocator.free(existing);
    }
};
