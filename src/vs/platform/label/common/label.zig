// Port of the file-URI label contract used by snippet variables in
// `src/vs/platform/label/common/label.ts`.
const std = @import("std");
const ServiceIdentifier = @import("../../instantiation/common/instantiation.zig").ServiceIdentifier;

pub const LabelOptions = struct { relative: bool = false, noPrefix: bool = false };

pub const ILabelService = struct {
    context: *anyopaque,
    get_uri_label: *const fn (*anyopaque, std.mem.Allocator, std.Uri, LabelOptions) anyerror![]u8,

    pub fn getUriLabel(self: ILabelService, allocator: std.mem.Allocator, resource: std.Uri, options: LabelOptions) ![]u8 {
        return self.get_uri_label(self.context, allocator, resource, options);
    }
};

pub const label_service_id = ServiceIdentifier(ILabelService, "labelService");
