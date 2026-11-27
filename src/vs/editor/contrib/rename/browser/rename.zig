// Port of `RenameSkeleton` from `src/vs/editor/contrib/rename/browser/rename.ts`.
// Native cancellable continuations replace provider promises. The skeleton
// owns the provider order, prepare location, and accumulated rejection messages.
const std = @import("std");
const languages = @import("../../../common/languages.zig");
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const Registry = @import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(languages.RenameProvider);
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;

pub const RenameSkeleton = struct {
    arena: std.heap.ArenaAllocator,
    model: *TextModel,
    position: Position,
    providers: []const languages.RenameProvider,
    provider_index: usize = 0,
    pending: ?IDisposable = null,
    rejects: std.ArrayList([]const u8) = .empty,
    prepare_callback: ?languages.RenameLocationCallback = null,
    edits_callback: ?languages.RenameEditCallback = null,
    new_name: []const u8 = "",

    pub fn init(a: std.mem.Allocator, model: *TextModel, position: Position, registry: *Registry) !RenameSkeleton {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const providers = try registry.ordered(arena.allocator(), model, false);
        return .{ .arena = arena, .model = model, .position = position, .providers = providers };
    }
    pub fn deinit(self: *RenameSkeleton) void {
        self.cancel();
        self.arena.deinit();
    }
    pub fn cancel(self: *RenameSkeleton) void {
        if (self.pending) |pending| pending.dispose();
        self.pending = null;
        self.prepare_callback = null;
        self.edits_callback = null;
    }
    pub fn hasProvider(self: *const RenameSkeleton) bool {
        return self.providers.len > 0;
    }

    pub fn resolveRenameLocation(self: *RenameSkeleton, callback: languages.RenameLocationCallback) void {
        self.cancel();
        self.provider_index = 0;
        self.rejects.clearRetainingCapacity();
        self.prepare_callback = callback;
        self.advanceLocation() catch |err| self.finishLocation(err);
    }
    fn finishLocation(self: *RenameSkeleton, result: anyerror!?languages.RenameLocation) void {
        const callback = self.prepare_callback orelse return;
        self.prepare_callback = null;
        callback.complete(callback.context, result);
    }
    fn acceptLocation(self: *RenameSkeleton, result: ?languages.RenameLocation) !bool {
        const value = result orelse return false;
        if (value.reject_reason) |reason| {
            try self.rejects.append(self.arena.allocator(), reason);
            return false;
        }
        self.finishLocation(value);
        return true;
    }
    fn locationReady(context: *anyopaque, result: anyerror!?languages.RenameLocation) void {
        const self: *RenameSkeleton = @ptrCast(@alignCast(context));
        self.pending = null;
        const value = result catch |err| return self.finishLocation(err);
        if (self.acceptLocation(value) catch |err| return self.finishLocation(err)) return;
        self.provider_index += 1;
        self.advanceLocation() catch |err| self.finishLocation(err);
    }
    fn advanceLocation(self: *RenameSkeleton) !void {
        const a = self.arena.allocator();
        while (self.provider_index < self.providers.len) : (self.provider_index += 1) {
            const provider = self.providers[self.provider_index];
            const resolve = provider.resolve_rename_location orelse break;
            if (provider.request_rename_location) |request| {
                self.pending = try request(provider.context, a, self.model, self.position, .{ .context = self, .complete = locationReady });
                return;
            }
            if (try self.acceptLocation(try resolve(provider.context, a, self.model, self.position, .None))) return;
        }
        // No provider could prepare a location. Use the word at the cursor
        // and restart rename edits at the first ranked provider.
        self.provider_index = 0;
        const reason = if (self.rejects.items.len > 0) try std.mem.join(a, "\n", self.rejects.items) else null;
        if (self.model.getWordAtPosition(self.position)) |value| {
            var word = value;
            defer word.deinit();
            self.finishLocation(.{ .range = Range.init(self.position.lineNumber, word.startColumn, self.position.lineNumber, word.endColumn), .text = try a.dupe(u8, word.word.items), .reject_reason = reason });
        } else self.finishLocation(.{ .range = Range.fromPositions(self.position, self.position), .reject_reason = reason });
    }

    pub fn provideRenameEdits(self: *RenameSkeleton, new_name: []const u8, callback: languages.RenameEditCallback) void {
        self.cancel();
        self.rejects.clearRetainingCapacity();
        self.edits_callback = callback;
        self.new_name = self.arena.allocator().dupe(u8, new_name) catch |err| return self.finishEdits(err);
        self.advanceEdits() catch |err| self.finishEdits(err);
    }
    fn finishEdits(self: *RenameSkeleton, result: anyerror!?languages.RenameEdit) void {
        const callback = self.edits_callback orelse return;
        self.edits_callback = null;
        callback.complete(callback.context, result);
    }
    fn acceptEdit(self: *RenameSkeleton, result: ?languages.RenameEdit) !bool {
        const value = result orelse {
            try self.rejects.append(self.arena.allocator(), "No result.");
            return false;
        };
        if (value.reject_reason) |reason| {
            try self.rejects.append(self.arena.allocator(), reason);
            return false;
        }
        self.finishEdits(value);
        return true;
    }
    fn editsReady(context: *anyopaque, result: anyerror!?languages.RenameEdit) void {
        const self: *RenameSkeleton = @ptrCast(@alignCast(context));
        self.pending = null;
        const value = result catch |err| return self.finishEdits(err);
        if (self.acceptEdit(value) catch |err| return self.finishEdits(err)) return;
        self.provider_index += 1;
        self.advanceEdits() catch |err| self.finishEdits(err);
    }
    fn advanceEdits(self: *RenameSkeleton) !void {
        const a = self.arena.allocator();
        while (self.provider_index < self.providers.len) : (self.provider_index += 1) {
            const provider = self.providers[self.provider_index];
            if (provider.request_rename_edits) |request| {
                self.pending = try request(provider.context, a, self.model, self.position, self.new_name, .{ .context = self, .complete = editsReady });
                return;
            }
            if (try self.acceptEdit(try provider.provide_rename_edits(provider.context, a, self.model, self.position, self.new_name, .None))) return;
        }
        self.finishEdits(.{ .reject_reason = try std.mem.join(a, "\n", self.rejects.items) });
    }
};
