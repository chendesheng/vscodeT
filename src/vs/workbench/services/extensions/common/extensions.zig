// Port of activation status contracts from
// `src/vs/workbench/services/extensions/common/extensions.ts`.
const std = @import("std");
const Emitter = @import("../../../../base/common/event.zig").Emitter;

pub const ActivationTimes = struct {
    code_loading_time: f64,
    activate_call_time: f64,
    activate_resolved_time: f64,
    startup: bool,
    activation_event: []const u8,
};

pub const IExtensionsStatus = struct {
    activation_started: bool = false,
    activation_times: ?ActivationTimes = null,
};

/// Borrowed runtime status valid until the owning host publishes a change.
pub const IExtensionStatusService = struct {
    context: *anyopaque,
    get_status: *const fn (*anyopaque, []const u8) ?IExtensionsStatus,
    on_did_change_extensions_status: *Emitter(void),

    pub fn getStatus(self: IExtensionStatusService, identifier: []const u8) ?IExtensionsStatus {
        return self.get_status(self.context, identifier);
    }
};
