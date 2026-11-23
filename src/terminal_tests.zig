comptime {
    _ = @import("./vs/platform/terminal/common/terminal.zig");
    _ = @import("./vs/platform/terminal/common/terminalEnvironment.zig");
    _ = @import("./vs/platform/terminal/common/terminalProfiles.zig");
    _ = @import("./vs/platform/terminal/node/terminalProfiles.zig");
    _ = @import("./vs/platform/terminal/node/pty.zig");
    _ = @import("./vs/platform/terminal/test/common/terminalEnvironment.test.zig");
    _ = @import("./vs/platform/terminal/test/node/terminalProfiles.test.zig");
    _ = @import("./vs/workbench/contrib/terminal/browser/terminalEmulator.zig");
    _ = @import("./vs/workbench/contrib/terminal/browser/terminalInstance.zig");
    _ = @import("./vs/workbench/contrib/terminal/browser/terminalGroup.zig");
    _ = @import("./vs/workbench/contrib/terminal/browser/terminalService.zig");
    _ = @import("./vs/workbench/contrib/terminal/common/terminal.zig");
    _ = @import("./vs/workbench/contrib/terminal/common/terminalConfiguration.zig");
    _ = @import("./vs/workbench/contrib/terminal/browser/terminalInput.zig");
    _ = @import("./vs/workbench/contrib/terminal/browser/terminalRenderer.zig");
    _ = @import("./vs/workbench/contrib/terminal/browser/terminalRenderer.test.zig");
    _ = @import("./vs/workbench/contrib/terminal/browser/terminalTabbedView.zig");
    _ = @import("./vs/workbench/contrib/terminal/test/browser/terminalTabsList.test.zig");
    _ = @import("./vs/workbench/contrib/terminal/test/browser/terminalEditorInput.test.zig");
}
