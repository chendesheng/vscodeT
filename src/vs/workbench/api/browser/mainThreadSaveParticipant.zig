// Port of `src/vs/workbench/api/browser/mainThreadSaveParticipant.ts`.
// The text-file working copy suspends its window fiber while listeners run;
// workspace-edit RPCs are delivered by the normal window dispatcher.
const std = @import("std");
const TextModel = @import("../../../editor/common/model/textModel.zig").TextModel;
const TextFiles = @import("../../services/textfile/common/textFileService.zig");
const Window = @import("../../../base/common/windowDispatch.zig").Queue;
const HostManager = @import("../../services/extensions/common/extensionHostManager.zig").HostManager;
const rpc = @import("../../services/extensions/common/rpcProtocol.zig");
const protocol = @import("../common/extHost.protocol.zig");
const proxy = @import("../../services/extensions/common/proxyIdentifier.zig");
const std_uri = @import("../../../base/common/stdUri.zig");

pub const MainThreadSaveParticipant = struct {
    allocator: std.mem.Allocator,
    host: *HostManager,
    window: *Window,
    models: struct {
        context: *anyopaque,
        synchronize: *const fn (*anyopaque, *TextModel) anyerror!bool,
    },

    pub fn interface(self: *MainThreadSaveParticipant) TextFiles.DocumentSaveParticipant {
        return .{ .context = self, .participate = participate };
    }

    fn participate(context: *anyopaque, model: *TextModel, executor: std.Io) !void {
        const self: *MainThreadSaveParticipant = @ptrCast(@alignCast(context));
        if (!model.shouldSynchronizeModel()) return;
        if (!try self.models.synchronize(self.models.context, model)) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const identifier = proxy.identifierFromEnum(protocol.ExtHostContext.ExtHostDocumentSaveParticipant);
        const args = [_]rpc.Arg{
            .{ .json = try std_uri.jsonComponents(a, model.uri()) },
            .{ .json = .{ .integer = 1 } }, // SaveReason.EXPLICIT
        };
        const reply = if (@import("ui").WindowIo.inFiber(executor))
            try self.host.requestAwait(self.window, a, identifier, "$participateInSave", &args, null, 1750)
        else
            try self.host.requestSync(a, identifier, "$participateInSave", &args, null, 1750);
        if (reply != .array) return error.InvalidSaveParticipantResult;
        for (reply.array.items) |result| {
            if (result != .bool or !result.bool) return error.SaveParticipantFailed;
        }
    }
};
