// Port of the completion subset of `src/vs/editor/common/languages.ts`.
//
// Terminal adaptation: the provider returns plain data and allocates its
// result with the caller-supplied allocator. The suggest controller owns that
// allocator's lifetime and resets its arena after the completion session.

const std = @import("std");
const Allocator = std.mem.Allocator;
const TextModel = @import("../model/textModel.zig").TextModel;
const Position = @import("../core/position.zig").Position;
const Range = @import("../core/range.zig").Range;
const CancellationToken = @import("../../../base/common/cancellation.zig").CancellationToken;
const standalone = @import("../standalone/standaloneEnums.zig");

pub const CompletionItemKind = standalone.CompletionItemKind;
pub const CompletionItemInsertTextRule = standalone.CompletionItemInsertTextRule;
pub const CompletionTriggerKind = standalone.CompletionTriggerKind;
pub const CompletionItemTag = standalone.CompletionItemTag;

pub const CompletionItemLabel = struct {
    label: []const u8,
    detail: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

pub const TextEdit = struct {
    range: Range,
    new_text: []const u8,
};

pub const CompletionItem = struct {
    label: []const u8,
    label_detail: ?[]const u8 = null,
    label_description: ?[]const u8 = null,
    kind: CompletionItemKind = .Text,
    detail: ?[]const u8 = null,
    documentation: ?[]const u8 = null,
    sort_text: ?[]const u8 = null,
    filter_text: ?[]const u8 = null,
    insert_text: []const u8,
    insert_text_rules: u32 = 0,
    range: ?Range = null,
    additional_text_edits: []const TextEdit = &.{},
    commit_characters: []const []const u8 = &.{},
    preselect: bool = false,
    deprecated: bool = false,
    tags: u32 = 0,
    provider_index: usize = 0,
    resolved: bool = false,
};

pub const CompletionList = struct {
    items: []const CompletionItem = &.{},
    is_incomplete: bool = false,
};

pub const CompletionContext = struct {
    trigger_kind: CompletionTriggerKind = .Invoke,
    trigger_character: ?[]const u8 = null,
};

pub const CompletionRequest = struct {
    pub const Callback = *const fn (callback_context: *anyopaque, request_context: *anyopaque, result: anyerror!CompletionList) void;
    context: *anyopaque,
    /// Delivers the promise result on the window thread, possibly immediately.
    /// Cancellation prevents subsequent callbacks. Result storage belongs to
    /// the completion session allocator, including after request disposal.
    on_complete: *const fn (context: *anyopaque, callback_context: *anyopaque, callback: Callback) void,
    cancel: *const fn (context: *anyopaque) void,
};

pub const CompletionItemProvider = struct {
    context: *anyopaque,
    provide_completion_items: *const fn (
        context: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        position: Position,
        trigger: CompletionContext,
        token: CancellationToken,
    ) anyerror!CompletionList,
    trigger_characters: []const []const u8 = &.{},
    provide_completion_items_deferred: ?*const fn (
        context: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        position: Position,
        trigger: CompletionContext,
        token: CancellationToken,
    ) anyerror!?CompletionRequest = null,
    resolve_completion_item: ?*const fn (
        context: *anyopaque,
        allocator: Allocator,
        model: *TextModel,
        item: CompletionItem,
    ) anyerror!CompletionItem = null,
};
