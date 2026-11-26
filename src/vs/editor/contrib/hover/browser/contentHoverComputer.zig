// Port of `src/vs/editor/contrib/hover/browser/contentHoverComputer.ts`.
//
// The computer merges independently completing participant streams in
// resolution order. The native request owns detachable callbacks and a scratch
// arena through cancellation; the wrapper copies part values immediately.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;

const ModelDecoration = @import("../../../common/model.zig").ModelDecoration;
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;
const hoverTypes = @import("./hoverTypes.zig");
const HoverAnchor = hoverTypes.HoverAnchor;
const HoverAnchorType = hoverTypes.HoverAnchorType;
const HoverStartSource = hoverTypes.HoverStartSource;
const IEditorHoverParticipant = hoverTypes.IEditorHoverParticipant;
const IHoverPart = hoverTypes.IHoverPart;
const Sink = @import("hoverOperation.zig").AsyncResultSink(IHoverPart);
const Disposable = @import("../../../../base/common/lifecycle.zig").IDisposable;

pub const ContentHoverComputerOptions = struct {
    should_focus: bool = false,
    anchor: HoverAnchor,
    source: HoverStartSource = .mouse,
    insist_on_keeping_hover_visible: bool = false,
};

pub const ContentHoverComputer = struct {
    model: *TextModel,
    participants: []const IEditorHoverParticipant,
    scratch: std.heap.ArenaAllocator,

    pub fn init(allocator: Allocator, model: *TextModel, participants: []const IEditorHoverParticipant) ContentHoverComputer {
        return .{
            .model = model,
            .participants = participants,
            .scratch = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *ContentHoverComputer) void {
        self.scratch.deinit();
    }

    /// Drops the previous computation's parts. Must be called before a new
    /// hover operation starts.
    pub fn beginComputation(self: *ContentHoverComputer) void {
        _ = self.scratch.reset(.retain_capacity);
    }

    fn getLineDecorations(self: *ContentHoverComputer, anchor: *const HoverAnchor) ![]ModelDecoration {
        const anchor_type = anchor.getType();
        const supports_marker_hover = switch (anchor.*) {
            .foreign_element => |foreign| foreign.supports_marker_hover orelse false,
            .range => true,
        };
        if (anchor_type != .range and !supports_marker_hover) return &.{};

        const range = anchor.getRange();
        const line_number = range.startLineNumber;
        if (line_number > self.model.getLineCount()) return &.{};

        const decorations = try self.model.getLineDecorations(line_number, 0, false);
        defer if (decorations.len > 0) self.model.getAllocator().free(decorations);
        const allocator = self.scratch.allocator();
        var result = ArrayList(ModelDecoration).init(allocator);

        const max_column = self.model.getLineMaxColumn(line_number);
        for (decorations) |decoration| {
            if (decoration.options.isWholeLine orelse false) {
                try result.append(decoration);
                continue;
            }
            const start_column = if (decoration.range.startLineNumber == line_number) decoration.range.startColumn else 1;
            const end_column = if (decoration.range.endLineNumber == line_number) decoration.range.endColumn else max_column;

            if (decoration.options.showIfCollapsed orelse false) {
                // Relax the check around `showIfCollapsed` decorations to also
                // include +/- 1 character, as upstream does.
                if (start_column > range.startColumn + 1 or range.endColumn - 1 > end_column) continue;
            } else {
                if (start_column > range.startColumn or range.endColumn > end_column) continue;
            }
            try result.append(decoration);
        }
        return try result.toOwnedSlice();
    }

    const AsyncComputation = struct {
        options: ContentHoverComputerOptions,
        decorations: []const ModelDecoration,
        token: CancellationToken,
        sink: Sink,
        slots: []Slot,
        remaining: usize,
        starting: bool = true,
        canceled: bool = false,

        const Slot = struct {
            owner: *AsyncComputation,
            participant: IEditorHoverParticipant,
            pending: ?Disposable = null,
            done: bool = false,

            fn emit(context: *anyopaque, values: []const IHoverPart) void {
                const self: *Slot = @ptrCast(@alignCast(context));
                if (self.done or self.owner.canceled) return;
                self.owner.sink.emit(self.owner.sink.context, values);
            }

            fn complete(context: *anyopaque) void {
                const self: *Slot = @ptrCast(@alignCast(context));
                const owner = self.owner;
                if (self.done or owner.canceled) return;
                self.done = true;
                self.pending = null;
                owner.remaining -= 1;
                if (!owner.starting and owner.remaining == 0) owner.sink.complete(owner.sink.context);
            }
        };

        fn start(self: *AsyncComputation) ?Disposable {
            for (self.slots) |*slot| {
                const participant = slot.participant;
                if (participant.request_async) |request| {
                    const pending = request(participant.context, &self.options.anchor, self.decorations, self.options.source, self.token, .{ .context = slot, .emit = Slot.emit, .complete = Slot.complete }) catch null;
                    if (!slot.done) {
                        slot.pending = pending;
                        if (pending == null) Slot.complete(slot);
                    }
                } else {
                    if (participant.compute_async) |compute| Slot.emit(slot, compute(participant.context, &self.options.anchor, self.decorations, self.options.source, self.token));
                    Slot.complete(slot);
                }
            }
            self.starting = false;
            if (self.remaining == 0) {
                self.sink.complete(self.sink.context);
                return null;
            }
            return Disposable.from(AsyncComputation, self, cancel);
        }

        fn cancel(self: *AsyncComputation) void {
            self.canceled = true;
            for (self.slots) |*slot| {
                if (slot.pending) |pending| pending.dispose();
                slot.pending = null;
            }
        }
    };

    pub fn requestAsync(self: *ContentHoverComputer, options: ContentHoverComputerOptions, token: CancellationToken, sink: Sink) !?Disposable {
        const a = self.scratch.allocator();
        const request = try a.create(AsyncComputation);
        var count: usize = 0;
        for (self.participants) |participant| if (participant.request_async != null or participant.compute_async != null) {
            count += 1;
        };
        request.* = .{ .options = options, .decorations = try self.getLineDecorations(&options.anchor), .token = token, .sink = sink, .slots = try a.alloc(AsyncComputation.Slot, count), .remaining = count };
        var index: usize = 0;
        for (self.participants) |participant| {
            if (participant.request_async == null and participant.compute_async == null) continue;
            request.slots[index] = .{ .owner = request, .participant = participant };
            index += 1;
        }
        return request.start();
    }

    /// Upstream `computeAsync`: merges the async results of all participants.
    pub fn computeAsync(
        self: *ContentHoverComputer,
        options: ContentHoverComputerOptions,
        token: CancellationToken,
    ) ![]const IHoverPart {
        const line_decorations = try self.getLineDecorations(&options.anchor);
        var result = ArrayList(IHoverPart).init(self.scratch.allocator());
        for (self.participants) |participant| {
            const compute = participant.compute_async orelse continue;
            const parts = compute(participant.context, &options.anchor, line_decorations, options.source, token);
            try result.appendSlice(parts);
        }
        return try result.toOwnedSlice();
    }

    /// Upstream `computeSync`: concatenates the synchronous results. Providers
    /// are coalesced; the terminal path has no nullable slots.
    pub fn computeSync(self: *ContentHoverComputer, options: ContentHoverComputerOptions) ![]const IHoverPart {
        const line_decorations = try self.getLineDecorations(&options.anchor);
        var result = ArrayList(IHoverPart).init(self.scratch.allocator());
        for (self.participants) |participant| {
            const compute = participant.compute_sync orelse continue;
            const parts = compute(participant.context, &options.anchor, line_decorations, options.source);
            try result.appendSlice(parts);
        }
        return try result.toOwnedSlice();
    }
};

test "contentHoverComputer: merges participant results" {
    const testing = std.testing;
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;
    const Range = @import("../../../common/core/range.zig").Range;

    const Participant = struct {
        part: [1]IHoverPart,

        fn compute(context: *anyopaque, anchor: *const HoverAnchor, decorations: []const ModelDecoration, source: HoverStartSource) []const IHoverPart {
            _ = anchor;
            _ = decorations;
            _ = source;
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.part[0..];
        }
    };

    const Valid = struct {
        fn check(_: *const IHoverPart, _: *const HoverAnchor) bool {
            return true;
        }
    };

    const allocator = testing.allocator;
    var ctx = try TestModel.init(allocator, "hello", "nullLanguage");
    defer ctx.deinit();

    var participant_state = Participant{
        .part = .{.{
            .owner = @ptrFromInt(1),
            .range = Range.init(1, 1, 1, 3),
            .is_valid_for_hover_anchor = Valid.check,
        }},
    };
    const participants = [_]IEditorHoverParticipant{.{
        .context = &participant_state,
        .hover_ordinal = 1,
        .compute_sync = Participant.compute,
    }};

    var computer = ContentHoverComputer.init(allocator, ctx.model, &participants);
    defer computer.deinit();
    computer.beginComputation();

    const parts = try computer.computeSync(.{
        .anchor = .{ .range = hoverTypes.HoverRangeAnchor.init(1, Range.init(1, 1, 1, 2)) },
    });
    try testing.expectEqual(@as(usize, 1), parts.len);
}
