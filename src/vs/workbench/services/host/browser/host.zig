// Port of the window-focus subset of
// src/vs/workbench/services/host/browser/host.ts.
// Auxiliary windows and native window management are not terminal operations.
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const instantiation = @import("../../../../platform/instantiation/common/instantiation.zig");

pub const host_service_id = instantiation.ServiceIdentifier(IHostService, "hostService");

pub const IHostService = struct {
    context: *anyopaque,
    has_focus: *const fn (*anyopaque) bool,
    on_did_change_focus: *Emitter(bool),

    pub fn hasFocus(self: IHostService) bool {
        return self.has_focus(self.context);
    }
};
