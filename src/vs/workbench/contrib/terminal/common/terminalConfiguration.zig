// Port of the default values and the read subset of
// `src/vs/workbench/contrib/terminal/common/terminalConfiguration.ts`.
//
// The settings registry is JSON-driven here; the workbench composition root
// registers `defaults_json` next to the search defaults. Settings that only
// affect browser/xterm rendering (font, GPU, images, smooth scrolling) are not
// part of this slice.

const std = @import("std");
const configuration = @import("../../../../platform/configuration/common/configuration.zig");
const terminal = @import("../../../../platform/terminal/common/terminal.zig");

const ConfigurationService = @import("../../../services/configuration/browser/configurationService.zig").ConfigurationService;

pub const defaults_json =
    \\{
    \\  "terminal": {
    \\    "integrated": {
    \\      "tabs": {
    \\        "title": "${process}",
    \\        "description": "${task}${separator}${local}${separator}${cwdFolder}",
    \\        "separator": " - ",
    \\        "hideCondition": "singleTerminal"
    \\      },
    \\      "scrollback": 1000,
    \\      "cursorStyle": "block",
    \\      "cursorStyleInactive": "outline",
    \\      "cursorBlinking": false,
    \\      "defaultLocation": "view",
    \\      "cwd": null,
    \\      "env": {
    \\        "linux": {},
    \\        "osx": {},
    \\        "windows": {}
    \\      },
    \\      "inheritEnv": true,
    \\      "enableBell": false,
    \\      "enableVisualBell": false,
    \\      "hideOnLastClosed": true,
    \\      "defaultProfile": {
    \\        "linux": null,
    \\        "osx": null,
    \\        "windows": null
    \\      },
    \\      "shellIntegration": {
    \\        "enabled": true
    \\      }
    \\    }
    \\  }
    \\}
;

pub const Config = struct {
    title: []const u8 = "${process}",
    description: []const u8 = "${task}${separator}${local}${separator}${cwdFolder}",
    separator: []const u8 = " - ",
    scrollback: usize = 1000,
    cursor_style: []const u8 = "block",
    cursor_style_inactive: []const u8 = "outline",
    cursor_blinking: bool = false,
    default_location: []const u8 = "view",
    cwd: ?[]const u8 = null,
    inherit_env: bool = true,
    enable_bell: bool = false,
    enable_visual_bell: bool = false,
    hide_on_last_closed: bool = true,
    default_profile_name: ?[]const u8 = null,
    shell_integration_enabled: bool = true,

    pub fn load(service: ?*ConfigurationService) Config {
        const config = service orelse return .{};
        var result: Config = .{};
        if (stringValue(config, "terminal.integrated.tabs.title")) |found| result.title = found;
        if (stringValue(config, "terminal.integrated.tabs.description")) |found| result.description = found;
        if (stringValue(config, "terminal.integrated.tabs.separator")) |found| result.separator = found;
        if (numberValue(config, "terminal.integrated.scrollback")) |found| result.scrollback = found;
        if (stringValue(config, "terminal.integrated.cursorStyle")) |found| result.cursor_style = found;
        if (stringValue(config, "terminal.integrated.cursorStyleInactive")) |found| result.cursor_style_inactive = found;
        if (boolValue(config, "terminal.integrated.cursorBlinking")) |found| result.cursor_blinking = found;
        if (stringValue(config, "terminal.integrated.defaultLocation")) |found| result.default_location = found;
        if (stringValue(config, "terminal.integrated.cwd")) |found| result.cwd = found;
        if (boolValue(config, "terminal.integrated.inheritEnv")) |found| result.inherit_env = found;
        if (boolValue(config, "terminal.integrated.enableBell")) |found| result.enable_bell = found;
        if (boolValue(config, "terminal.integrated.enableVisualBell")) |found| result.enable_visual_bell = found;
        if (boolValue(config, "terminal.integrated.hideOnLastClosed")) |found| result.hide_on_last_closed = found;
        if (boolValue(config, "terminal.integrated.shellIntegration.enabled")) |found| result.shell_integration_enabled = found;
        const os = terminal.currentOperatingSystem();
        if (stringValue(config, terminal.defaultProfileSettingId(os))) |found| result.default_profile_name = found;
        return result;
    }
};

fn value(service: *ConfigurationService, section: []const u8) ?*const configuration.Value {
    return service.getValue(section, .{});
}

fn stringValue(service: *ConfigurationService, section: []const u8) ?[]const u8 {
    const found = value(service, section) orelse return null;
    return switch (found.*) {
        .string => |text| text,
        else => null,
    };
}

fn boolValue(service: *ConfigurationService, section: []const u8) ?bool {
    const found = value(service, section) orelse return null;
    return switch (found.*) {
        .bool => |flag| flag,
        else => null,
    };
}

fn numberValue(service: *ConfigurationService, section: []const u8) ?usize {
    const found = value(service, section) orelse return null;
    return switch (found.*) {
        .integer => |number| if (number > 0) @intCast(number) else null,
        else => null,
    };
}

test "terminalConfiguration: defaults parse and load without a service" {
    const config = Config.load(null);
    try std.testing.expectEqualStrings("${process}", config.title);
    try std.testing.expectEqual(@as(usize, 1000), config.scrollback);
    try std.testing.expect(config.inherit_env);
}
