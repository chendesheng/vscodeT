// Port of `src/vs/editor/common/services/textModelSync/textModelSync.protocol.ts`.
//
// `IModelChangedEvent` is the same shape as `ModelContentChangedEvent`, so the
// event type is reused instead of being declared twice.
const std = @import("std");
const textModelEvents = @import("../../textModelEvents.zig");
const ModelContentChangedEvent = textModelEvents.ModelContentChangedEvent;

/// The raw data needed to create a mirror text model in another process.
pub const IRawModelData = struct {
    /// The string url of the model. Borrowed.
    url: []const u8,
    version_id: i64,
    /// The lines of the model. Borrowed: the array and every line.
    lines: []const []const u8,
    /// The end of line sequence, e.g. `"\n"`.
    eol: []const u8,
};

/// The receiving side of the text model synchronization channel.
pub const IWorkerTextModelSyncChannelServer = struct {
    context: *anyopaque,
    accept_new_model: *const fn (context: *anyopaque, data: IRawModelData) void,
    accept_model_changed: *const fn (context: *anyopaque, strUrl: []const u8, e: *const ModelContentChangedEvent) void,
    accept_removed_model: *const fn (context: *anyopaque, strUrl: []const u8) void,

    /// `$acceptNewModel`
    pub fn acceptNewModel(self: IWorkerTextModelSyncChannelServer, data: IRawModelData) void {
        self.accept_new_model(self.context, data);
    }

    /// `$acceptModelChanged`
    pub fn acceptModelChanged(self: IWorkerTextModelSyncChannelServer, strUrl: []const u8, e: *const ModelContentChangedEvent) void {
        self.accept_model_changed(self.context, strUrl, e);
    }

    /// `$acceptRemovedModel`
    pub fn acceptRemovedModel(self: IWorkerTextModelSyncChannelServer, strUrl: []const u8) void {
        self.accept_removed_model(self.context, strUrl);
    }
};

test "textModelSync.protocol: dispatches to the implementation" {
    const Recorder = struct {
        new_models: usize = 0,
        changed_models: usize = 0,
        removed_models: usize = 0,
        last_url: []const u8 = "",

        fn acceptNewModel(context: *anyopaque, data: IRawModelData) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.new_models += 1;
            self.last_url = data.url;
        }

        fn acceptModelChanged(context: *anyopaque, strUrl: []const u8, e: *const ModelContentChangedEvent) void {
            _ = e;
            const self: *@This() = @ptrCast(@alignCast(context));
            self.changed_models += 1;
            self.last_url = strUrl;
        }

        fn acceptRemovedModel(context: *anyopaque, strUrl: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.removed_models += 1;
            self.last_url = strUrl;
        }
    };

    var recorder = Recorder{};
    const channel = IWorkerTextModelSyncChannelServer{
        .context = &recorder,
        .accept_new_model = Recorder.acceptNewModel,
        .accept_model_changed = Recorder.acceptModelChanged,
        .accept_removed_model = Recorder.acceptRemovedModel,
    };

    const lines = [_][]const u8{ "a", "b" };
    channel.acceptNewModel(.{ .url = "file:///a", .version_id = 1, .lines = &lines, .eol = "\n" });
    try std.testing.expectEqual(@as(usize, 1), recorder.new_models);
    try std.testing.expectEqualStrings("file:///a", recorder.last_url);

    var event = ModelContentChangedEvent{
        .changes = std.array_list.Managed(textModelEvents.ModelContentChange).init(std.testing.allocator),
        .eol = .LF,
        .versionId = 2,
        .isUndoing = false,
        .isRedoing = false,
        .isFlush = false,
        .isEolChange = false,
    };
    defer event.deinit();
    channel.acceptModelChanged("file:///b", &event);
    try std.testing.expectEqual(@as(usize, 1), recorder.changed_models);
    try std.testing.expectEqualStrings("file:///b", recorder.last_url);

    channel.acceptRemovedModel("file:///c");
    try std.testing.expectEqual(@as(usize, 1), recorder.removed_models);
    try std.testing.expectEqualStrings("file:///c", recorder.last_url);
}
