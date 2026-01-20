const std = @import("std");
const ArrayList = std.array_list.Managed;
const Allocator = std.mem.Allocator;
const TextModel = @import("../textModel/textModel.zig").TextModel;
const Uri = std.Uri;
const TextModelCreationOptions = @import("../textModel/model.zig").TextModelCreationOptions;
const Emitter = @import("../basics/event.zig").Emitter;
const IConfigurationService = @import("../languages/configuration.zig").IConfigurationService;
const UndoRedoService = @import("../textModel/undoRedoService.zig").UndoRedoService;

const Self = @This();

_onModelAdded: Emitter(*TextModel),
_onModelRemoved: Emitter(*TextModel),
_onModelLanguageChanged: Emitter(ModelLanguageChangedEvent),
_configurationService: *IConfigurationService,

const ModelLanguageChangedEvent = struct {
    model: *TextModel,
    languageId: []const u8,
};

pub fn createModel(allocator: Allocator, text: *std.Io.Reader, languageId: []const u8, resource: ?Uri, isForSimpleWidget: bool) !*TextModel {
    _ = allocator;
    _ = text;
    _ = languageId;
    _ = resource;
    _ = isForSimpleWidget;
    return undefined;
}

pub fn destroyModel(resource: Uri) void {
    _ = resource;
}

pub fn getModels() ArrayList(*TextModel) {
    return undefined;
}

pub fn getCreationOptions(resource: Uri) ?TextModelCreationOptions {
    _ = resource;
    return undefined;
}

pub fn getModel(resource: Uri) ?*TextModel {
    _ = resource;
    return undefined;
}

pub fn onModelAdded(self: *Self, ctx: anytype, callback: fn (*TextModel, ctx: @TypeOf(ctx)) void) void {
    try self._onModelAdded.event(ctx, callback);
}

pub fn onModelRemoved(self: *Self, ctx: anytype, callback: fn (*TextModel, ctx: @TypeOf(ctx)) void) void {
    try self._onModelRemoved.event(ctx, callback);
}

pub fn onModelLanguageChanged(self: *Self, ctx: anytype, callback: fn (ModelLanguageChangedEvent, ctx: @TypeOf(ctx)) void) void {
    try self._onModelLanguageChanged.event(ctx, callback);
}
