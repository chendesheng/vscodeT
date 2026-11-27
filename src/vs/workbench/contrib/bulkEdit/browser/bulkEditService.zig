// Port of `src/vs/workbench/contrib/bulkEdit/browser/bulkEditService.ts`.
// The model-reference service supplies all text-edit targets, including
// unmounted working documents. File-operation and preview groups will use
// their corresponding owners before those edit kinds are accepted.
const std = @import("std");
const bulk = @import("../../../../editor/browser/services/bulkEditService.zig");
const languages = @import("../../../../editor/common/languages.zig");
const resolver = @import("../../../../editor/common/services/resolverService.zig");
const Disposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const BulkTextEdits = @import("bulkTextEdits.zig").BulkTextEdits;

pub const BulkEditService = struct {
    allocator: std.mem.Allocator,
    resolver_service: resolver.ITextModelService,

    pub fn interface(self: *BulkEditService) bulk.IBulkEditService {
        return .{ .context = self, .apply_fn = apply, .has_preview_handler_fn = hasPreviewHandler };
    }

    fn apply(context: *anyopaque, edit: languages.WorkspaceEdit, options: bulk.IBulkEditOptions, listener: bulk.EditListener) !?Disposable {
        const self: *BulkEditService = @ptrCast(@alignCast(context));
        if (options.show_preview) return error.PreviewRequired;
        return BulkTextEdits.start(self.allocator, self.resolver_service, edit.edits, options, listener);
    }

    fn hasPreviewHandler(_: *anyopaque) bool {
        return false;
    }
};
