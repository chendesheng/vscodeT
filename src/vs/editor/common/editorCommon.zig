const std = @import("std");
const Allocator = std.mem.Allocator;

const Range = @import("./core/range.zig").Range;
const Selection = @import("./core/selection.zig").Selection;
const ValidEditOperation = @import("./model.zig").ValidEditOperation;
const TextModel = @import("./model/textModel.zig").TextModel;

const Position = @import("./core/position.zig").Position;

/// Serializable cursor and view state from editorCommon.ts. Positions remain
/// model coordinates, so restoring works across wrapping and view-zone changes.
pub const ICursorState = struct {
    inSelectionMode: bool,
    selectionStart: Position,
    position: Position,
};

pub const IViewState = struct {
    scrollLeft: f64,
    firstPosition: Position,
    firstPositionDeltaTop: f64,
};

pub const ScrollType = enum(u8) {
    Smooth = 0,
    Immediate = 1,
};

/// Built-in commands.
pub const Handler = enum(u8) {
    compositionStart,
    compositionEnd,
    type,
    replacePreviousChar,
    compositionType,
    paste,
    cut,
};

pub const TypePayload = struct {
    text: []const u8,
};

pub const ReplacePreviousCharPayload = struct {
    text: []const u8,
    replaceCharCnt: usize,
};

pub const CompositionTypePayload = struct {
    text: []const u8,
    replacePrevCharCnt: usize,
    replaceNextCharCnt: usize,
    positionDelta: i32,
};

// --- view

pub const IScrollEvent = struct {
    scrollTop: f64,
    scrollLeft: f64,
    scrollWidth: f64,
    scrollHeight: f64,

    scrollTopChanged: bool,
    scrollLeftChanged: bool,
    scrollWidthChanged: bool,
    scrollHeightChanged: bool,
};

pub const IContentSizeChangedEvent = struct {
    contentWidth: f64,
    contentHeight: f64,

    contentWidthChanged: bool,
    contentHeightChanged: bool,
};

pub const ITriggerEditorOperationEvent = struct {
    source: ?[]const u8,
    handlerId: []const u8,
    payload: ?*anyopaque,
};

pub const INewScrollPosition = struct {
    scrollLeft: ?f64 = null,
    scrollTop: ?f64 = null,
};

/// A helper to collect edit operations and to track selections while a command
/// gathers the edits it wants to perform.
///
/// `text == null` means a simple delete. The builder copies the text it is
/// given, so callers keep ownership of the slices they pass in.
pub const IEditOperationBuilder = struct {
    context: *anyopaque,
    add_edit_operation: *const fn (context: *anyopaque, range: Range, text: ?[]const u8, force_move_markers: bool) anyerror!void,
    add_tracked_edit_operation: *const fn (context: *anyopaque, range: Range, text: ?[]const u8, force_move_markers: bool) anyerror!void,
    track_selection: *const fn (context: *anyopaque, selection: Selection) u64,

    pub fn addEditOperation(self: IEditOperationBuilder, range: Range, text: ?[]const u8, force_move_markers: bool) !void {
        return self.add_edit_operation(self.context, range, text, force_move_markers);
    }

    pub fn addTrackedEditOperation(self: IEditOperationBuilder, range: Range, text: ?[]const u8, force_move_markers: bool) !void {
        return self.add_tracked_edit_operation(self.context, range, text, force_move_markers);
    }

    pub fn trackSelection(self: IEditOperationBuilder, selection: Selection) u64 {
        return self.track_selection(self.context, selection);
    }
};

/// A helper to get the inverse edit operations and previously tracked
/// selections once the edit operations were applied.
pub const ICursorStateComputerData = struct {
    context: *anyopaque,
    /// Returns the inverse edit operations, in reverse order. The slice is
    /// borrowed from the helper and stays valid as long as the helper does.
    get_inverse_edit_operations: *const fn (context: *anyopaque) []const ValidEditOperation,
    get_tracked_selection: *const fn (context: *anyopaque, id: u64) Selection,

    pub fn getInverseEditOperations(self: ICursorStateComputerData) []const ValidEditOperation {
        return self.get_inverse_edit_operations(self.context);
    }

    pub fn getTrackedSelection(self: ICursorStateComputerData, id: u64) Selection {
        return self.get_tracked_selection(self.context, id);
    }
};

/// A command is a unit of work that translates a user gesture into edits plus
/// the cursor state that should follow them.
pub const ICommand = struct {
    context: *anyopaque,
    /// Signal that this command is inserting automatic whitespace that should
    /// be trimmed if possible.
    inserts_auto_whitespace: ?bool = null,
    get_edit_operations: *const fn (context: *anyopaque, model: *TextModel, builder: IEditOperationBuilder) anyerror!void,
    compute_cursor_state: *const fn (context: *anyopaque, model: *TextModel, helper: ICursorStateComputerData) anyerror!Selection,

    /// Get the edit operations needed to execute this command.
    pub fn getEditOperations(self: ICommand, model: *TextModel, builder: IEditOperationBuilder) !void {
        return self.get_edit_operations(self.context, model, builder);
    }

    /// Compute the cursor state after the edit operations were applied.
    pub fn computeCursorState(self: ICommand, model: *TextModel, helper: ICursorStateComputerData) !Selection {
        return self.compute_cursor_state(self.context, model, helper);
    }
};

/// Adapts a concrete command (a struct with `getEditOperations` and
/// `computeCursorState` methods) to the `ICommand` vtable.
///
/// ```zig
/// var command = ReplaceCommand.init(range, "text", false);
/// const iface = commandOf(ReplaceCommand).of(&command);
/// try iface.getEditOperations(model, builder);
/// ```
pub fn commandOf(comptime T: type) type {
    return struct {
        fn getEditOperationsFn(context: *anyopaque, model: *TextModel, builder: IEditOperationBuilder) anyerror!void {
            const self: *T = @ptrCast(@alignCast(context));
            return self.getEditOperations(model, builder);
        }

        fn computeCursorStateFn(context: *anyopaque, model: *TextModel, helper: ICursorStateComputerData) anyerror!Selection {
            const self: *T = @ptrCast(@alignCast(context));
            return self.computeCursorState(model, helper);
        }

        /// Returns the `ICommand` view of `self`.
        pub fn of(self: *T) ICommand {
            var command = ICommand{
                .context = self,
                .get_edit_operations = getEditOperationsFn,
                .compute_cursor_state = computeCursorStateFn,
            };
            if (@hasField(T, "insertsAutoWhitespace")) {
                command.inserts_auto_whitespace = self.insertsAutoWhitespace;
            }
            return command;
        }
    };
}

test "editorCommon: handler names" {
    try std.testing.expectEqualStrings("compositionStart", @tagName(Handler.compositionStart));
    try std.testing.expectEqualStrings("compositionEnd", @tagName(Handler.compositionEnd));
    try std.testing.expectEqualStrings("type", @tagName(Handler.type));
    try std.testing.expectEqualStrings("replacePreviousChar", @tagName(Handler.replacePreviousChar));
    try std.testing.expectEqualStrings("compositionType", @tagName(Handler.compositionType));
    try std.testing.expectEqualStrings("paste", @tagName(Handler.paste));
    try std.testing.expectEqualStrings("cut", @tagName(Handler.cut));
}

test "editorCommon: payloads" {
    const type_payload = TypePayload{ .text = "hello" };
    try std.testing.expectEqualStrings("hello", type_payload.text);

    const replace_payload = ReplacePreviousCharPayload{ .text = "x", .replaceCharCnt = 2 };
    try std.testing.expectEqual(@as(usize, 2), replace_payload.replaceCharCnt);

    const composition_payload = CompositionTypePayload{
        .text = "abc",
        .replacePrevCharCnt = 1,
        .replaceNextCharCnt = 2,
        .positionDelta = -1,
    };
    try std.testing.expectEqual(@as(i32, -1), composition_payload.positionDelta);
}

test "editorCommon: scroll event shape" {
    const event = IScrollEvent{
        .scrollTop = 10,
        .scrollLeft = 20,
        .scrollWidth = 100,
        .scrollHeight = 200,
        .scrollTopChanged = true,
        .scrollLeftChanged = false,
        .scrollWidthChanged = true,
        .scrollHeightChanged = false,
    };
    try std.testing.expect(event.scrollTopChanged);
    try std.testing.expect(!event.scrollHeightChanged);

    const new_position = INewScrollPosition{ .scrollTop = 5 };
    try std.testing.expectEqual(@as(?f64, 5), new_position.scrollTop);
    try std.testing.expectEqual(@as(?f64, null), new_position.scrollLeft);
}

test "editorCommon: command vtable adapts a concrete command" {
    const TestCommand = struct {
        text: []const u8,
        insertsAutoWhitespace: bool = true,

        pub fn getEditOperations(self: *@This(), model: *TextModel, builder: IEditOperationBuilder) !void {
            _ = model;
            try builder.addEditOperation(Range.init(1, 1, 1, 2), self.text, false);
        }

        pub fn computeCursorState(self: *@This(), model: *TextModel, helper: ICursorStateComputerData) !Selection {
            _ = self;
            _ = model;
            return helper.getTrackedSelection(42);
        }
    };

    const Builder = struct {
        saw_text: ?[]const u8 = null,

        fn addEditOperationFn(context: *anyopaque, range: Range, text: ?[]const u8, force_move_markers: bool) anyerror!void {
            _ = range;
            _ = force_move_markers;
            const self: *@This() = @ptrCast(@alignCast(context));
            self.saw_text = text;
        }

        fn addTrackedEditOperationFn(context: *anyopaque, range: Range, text: ?[]const u8, force_move_markers: bool) anyerror!void {
            return addEditOperationFn(context, range, text, force_move_markers);
        }

        fn trackSelectionFn(context: *anyopaque, selection: Selection) u64 {
            _ = context;
            _ = selection;
            return 42;
        }
    };

    var command = TestCommand{ .text = "x" };
    var builder_state = Builder{};
    const builder = IEditOperationBuilder{
        .context = &builder_state,
        .add_edit_operation = Builder.addEditOperationFn,
        .add_tracked_edit_operation = Builder.addTrackedEditOperationFn,
        .track_selection = Builder.trackSelectionFn,
    };

    const command_iface = ICommand{
        .context = &command,
        .inserts_auto_whitespace = command.insertsAutoWhitespace,
        .get_edit_operations = struct {
            fn call(context: *anyopaque, model: *TextModel, b: IEditOperationBuilder) anyerror!void {
                const self: *TestCommand = @ptrCast(@alignCast(context));
                return self.getEditOperations(model, b);
            }
        }.call,
        .compute_cursor_state = struct {
            fn call(context: *anyopaque, model: *TextModel, helper: ICursorStateComputerData) anyerror!Selection {
                const self: *TestCommand = @ptrCast(@alignCast(context));
                return self.computeCursorState(model, helper);
            }
        }.call,
    };

    // `getEditOperations` only needs the model when it reads the document; the
    // test command ignores it, so a dangling pointer is enough here.
    try std.testing.expectEqual(@as(?bool, true), command_iface.inserts_auto_whitespace);
    try builder.addEditOperation(Range.init(1, 1, 1, 2), "y", false);
    try std.testing.expectEqualStrings("y", builder_state.saw_text.?);
    try std.testing.expectEqual(@as(u64, 42), builder.trackSelection(Selection.init(1, 1, 1, 1)));
}
