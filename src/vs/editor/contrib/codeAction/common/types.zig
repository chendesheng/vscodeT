// Port of `src/vs/editor/contrib/codeAction/common/types.ts`.
const std = @import("std");
const Kind = @import("../../../../base/common/hierarchicalKind.zig").HierarchicalKind;
const languages = @import("../../../common/languages.zig");
const Position = @import("../../../common/core/position.zig").Position;

pub const CodeActionKind = struct {
    pub const QuickFix = Kind.init("quickfix");
    pub const Refactor = Kind.init("refactor");
    pub const RefactorExtract = Kind.init("refactor.extract");
    pub const RefactorInline = Kind.init("refactor.inline");
    pub const RefactorMove = Kind.init("refactor.move");
    pub const RefactorRewrite = Kind.init("refactor.rewrite");
    pub const Notebook = Kind.init("notebook");
    pub const Source = Kind.init("source");
    pub const SourceOrganizeImports = Kind.init("source.organizeImports");
    pub const SourceFixAll = Kind.init("source.fixAll");
    pub const SurroundWith = Kind.init("refactor.surround");
};

pub const CodeActionAutoApply = enum { IfSingle, First, Never };
pub const CodeActionTriggerSource = enum { Refactor, RefactorPreview, Lightbulb, Default, SourceAction, QuickFix, FixAll, OrganizeImports, AutoFix, QuickFixHover, OnSave, ProblemsView };

pub const CodeActionFilter = struct {
    include: ?Kind = null,
    excludes: []const Kind = &.{},
    include_source_actions: bool = false,
    only_include_preferred_actions: bool = false,
};

fn excludesAction(provided: Kind, excluded: Kind, included: ?Kind) bool {
    if (!excluded.contains(provided)) return false;
    if (included) |include| if (excluded.contains(include)) return false;
    return true;
}

pub fn mayIncludeActionsOfKind(filter: CodeActionFilter, provided: Kind) bool {
    if (filter.include) |include| if (!include.intersects(provided)) return false;
    for (filter.excludes) |exclude| if (excludesAction(provided, exclude, filter.include)) return false;
    if (!filter.include_source_actions and CodeActionKind.Source.contains(provided)) return false;
    return true;
}

pub fn filtersAction(filter: CodeActionFilter, action: languages.CodeAction) bool {
    const action_kind: ?Kind = if (action.kind) |value| .init(value) else null;
    if (filter.include) |include| if (action_kind == null or !include.contains(action_kind.?)) return false;
    if (action_kind) |kind| {
        for (filter.excludes) |exclude| if (excludesAction(kind, exclude, filter.include)) return false;
        if (!filter.include_source_actions and CodeActionKind.Source.contains(kind)) return false;
    }
    if (filter.only_include_preferred_actions and !action.is_preferred) return false;
    return true;
}

pub const CodeActionTrigger = struct {
    selection: ?@import("../../../common/core/selection.zig").Selection = null,
    type: languages.CodeActionTriggerType,
    trigger_action: CodeActionTriggerSource,
    filter: CodeActionFilter = .{},
    auto_apply: ?CodeActionAutoApply = null,
    context: ?struct { not_available_message: []const u8, position: Position } = null,
};

pub const CodeActionCommandArgs = struct {
    kind: Kind,
    apply: CodeActionAutoApply,
    preferred: bool = false,

    pub fn fromUser(arg: ?std.json.Value, defaults: CodeActionCommandArgs) CodeActionCommandArgs {
        const value = arg orelse return defaults;
        if (value != .object) return defaults;
        var result = defaults;
        if (value.object.get("kind")) |kind| if (kind == .string) {
            result.kind = .init(kind.string);
        };
        if (value.object.get("apply")) |apply| if (apply == .string) {
            if (std.ascii.eqlIgnoreCase(apply.string, "first")) result.apply = .First else if (std.ascii.eqlIgnoreCase(apply.string, "never")) result.apply = .Never else if (std.ascii.eqlIgnoreCase(apply.string, "ifsingle")) result.apply = .IfSingle;
        };
        result.preferred = if (value.object.get("preferred")) |preferred| preferred == .bool and preferred.bool else false;
        return result;
    }
};

pub const CodeActionItem = struct {
    action: languages.CodeAction,
    provider: ?languages.CodeActionProvider = null,
    registration_time: ?u64 = null,
    highlight_range: ?bool = null,

    /// Provider resolve fills the missing workspace edit while preserving the
    /// identity and metadata of the original item, as in upstream resolve().
    pub fn resolve(self: CodeActionItem, allocator: std.mem.Allocator, token: @import("../../../../base/common/cancellation.zig").CancellationToken, listener: languages.ResolveCodeActionCallback) !?@import("../../../../base/common/lifecycle.zig").IDisposable {
        if (self.action.edit == null) if (self.provider) |provider| {
            if (provider.request_resolve_code_action) |request| return request(provider.context, allocator, self.action, token, listener);
            if (provider.resolve_code_action) |callback| {
                listener.complete(listener.context, callback(provider.context, allocator, self.action, token));
                return null;
            }
        };
        listener.complete(listener.context, null);
        return null;
    }

    pub fn acceptResolved(self: *CodeActionItem, value: ?languages.CodeAction) void {
        if (value) |action| {
            self.action.edit = action.edit;
            self.action.edit_json = action.edit_json;
        }
    }
};
