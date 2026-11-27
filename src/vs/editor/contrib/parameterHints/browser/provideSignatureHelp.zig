// Port of `src/vs/editor/contrib/parameterHints/browser/provideSignatureHelp.ts`.
// Providers are tried in registry order; their promises resume through the
// existing dispatcher, and the winning result owns its extension cache entry.
const std = @import("std");
const languages = @import("../../../common/languages.zig");
const Registry = @import("../../../common/languageFeatureRegistry.zig").LanguageFeatureRegistry(languages.SignatureHelpProvider);
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Position = @import("../../../common/core/position.zig").Position;
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;

pub const Request = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    model: *TextModel,
    position: Position,
    trigger: languages.SignatureHelpContext,
    providers: []const languages.SignatureHelpProvider = &.{},
    next: usize = 0,
    pending: ?IDisposable = null,
    result: ?languages.SignatureHelpResult = null,
    callback: Callback,

    pub const Callback = struct {
        context: *anyopaque,
        complete: *const fn (*anyopaque, *Request) void,
    };

    pub fn create(allocator: std.mem.Allocator, model: *TextModel, position: Position, trigger: languages.SignatureHelpContext, callback: Callback) !*Request {
        const self = try allocator.create(Request);
        self.* = .{ .allocator = allocator, .arena = .init(allocator), .model = model, .position = position, .trigger = trigger, .callback = callback };
        return self;
    }

    pub fn provideSignatureHelp(self: *Request, registry: *Registry) !void {
        self.providers = try registry.ordered(self.arena.allocator(), self.model, false);
        self.advance();
    }

    fn advance(self: *Request) void {
        const a = self.arena.allocator();
        while (self.next < self.providers.len) {
            const provider = self.providers[self.next];
            self.next += 1;
            if (provider.request_signature_help) |request| {
                self.pending = request(provider.context, a, self.model, self.position, self.trigger, .{ .context = self, .complete = ready }) catch continue;
                return;
            }
            const result = provider.provide_signature_help(provider.context, a, self.model, self.position, self.trigger, .None) catch continue;
            if (result) |value| {
                self.result = value;
                self.callback.complete(self.callback.context, self);
                return;
            }
        }
        self.callback.complete(self.callback.context, self);
    }

    fn ready(context: *anyopaque, result: anyerror!?languages.SignatureHelpResult) void {
        const self: *Request = @ptrCast(@alignCast(context));
        self.pending = null;
        if (result) |maybe| {
            if (maybe) |value| {
                self.result = value;
                self.callback.complete(self.callback.context, self);
                return;
            }
        } else |_| {}
        self.advance();
    }

    pub fn deinit(self: *Request) void {
        if (self.pending) |pending| pending.dispose();
        if (self.result) |*result| result.dispose();
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};
