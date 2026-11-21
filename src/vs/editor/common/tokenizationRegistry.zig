const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const Emitter = @import("../../base/common/event.zig").Emitter;
const ColorId = @import("./encodedTokenAttributes.zig").ColorId;
const ITokenizationSupport = @import("./languages.zig").ITokenizationSupport;
const IBackgroundTokenizerFactory = @import("./languages.zig").IBackgroundTokenizerFactory;
const TokenizationSupportChangedEvent = @import("./languages.zig").TokenizationSupportChangedEvent;
const LazyTokenizationSupport = @import("./languages.zig").LazyTokenizationSupport;
const Color = @import("../../base/common/color.zig").Color;

pub const TokenizationRegistry = struct {
    pub var instance: TokenizationRegistry = TokenizationRegistry.init(std.heap.page_allocator);

    _tokenizationSupports: StringHashMap(ITokenizationSupport),
    _factories: StringHashMap(*LazyTokenizationSupport),
    _onDidChange: Emitter(TokenizationSupportChangedEvent),
    _colorMap: ?[]const Color,
    /// Process-wide async background tokenizer, set by the workbench TextMate
    /// feature. Null keeps the ported synchronous `DefaultBackgroundTokenizer`
    /// fallback (tests, async tokenization disabled, too-large models).
    _backgroundTokenizerFactory: ?IBackgroundTokenizerFactory,
    allocator: Allocator,

    pub fn init(allocator: Allocator) TokenizationRegistry {
        return .{
            ._tokenizationSupports = StringHashMap(ITokenizationSupport).init(allocator),
            ._factories = StringHashMap(*LazyTokenizationSupport).init(allocator),
            ._onDidChange = Emitter(TokenizationSupportChangedEvent).init(allocator),
            ._colorMap = null,
            ._backgroundTokenizerFactory = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TokenizationRegistry) void {
        self._backgroundTokenizerFactory = null;
        var supportIter = self._tokenizationSupports.valueIterator();
        while (supportIter.next()) |support| support.dispose();
        var supportKeys = self._tokenizationSupports.keyIterator();
        while (supportKeys.next()) |key| self.allocator.free(key.*);
        self._tokenizationSupports.deinit();
        var factoryKeys = self._factories.keyIterator();
        while (factoryKeys.next()) |key| self.allocator.free(key.*);
        self._factories.deinit();
        self._onDidChange.deinit();
    }

    pub fn handleChange(self: *TokenizationRegistry, languageIds: []const []const u8) void {
        self._onDidChange.fire(.{ .changedLanguages = languageIds, .changedColorMap = false }) catch {};
    }

    pub fn onDidChange(self: *TokenizationRegistry, ctx: anytype, callback: fn (e: TokenizationSupportChangedEvent, ctx: @TypeOf(ctx)) anyerror!void) !Emitter(TokenizationSupportChangedEvent).ListenerId {
        return try self._onDidChange.listen(ctx, callback);
    }

    pub fn unsubscribe(self: *TokenizationRegistry, id: Emitter(TokenizationSupportChangedEvent).ListenerId) void {
        self._onDidChange.unlisten(id);
    }

    pub fn register(self: *TokenizationRegistry, languageId: []const u8, support: ITokenizationSupport) !void {
        // The language id slice may be owned by an editor's language service,
        // which can be disposed while this global registry entry survives.
        // Keep an owned copy so a later lookup cannot hash freed memory.
        if (self._tokenizationSupports.fetchRemove(languageId)) |entry| {
            var previous = entry.value;
            previous.dispose();
            self.allocator.free(entry.key);
        }
        const key = try self.allocator.dupe(u8, languageId);
        errdefer self.allocator.free(key);
        try self._tokenizationSupports.put(key, support);
        self.handleChange(&[_][]const u8{languageId});
    }

    pub fn unregister(self: *TokenizationRegistry, languageId: []const u8) void {
        if (self._tokenizationSupports.fetchRemove(languageId)) |entry| {
            var support = entry.value;
            support.dispose();
            self.allocator.free(entry.key);
        }
        self.handleChange(&[_][]const u8{languageId});
    }

    pub fn get(self: *TokenizationRegistry, languageId: []const u8) ?ITokenizationSupport {
        return self._tokenizationSupports.get(languageId);
    }

    pub fn setBackgroundTokenizerFactory(self: *TokenizationRegistry, factory: ?IBackgroundTokenizerFactory) void {
        self._backgroundTokenizerFactory = factory;
    }

    pub fn getBackgroundTokenizerFactory(self: *TokenizationRegistry) ?IBackgroundTokenizerFactory {
        return self._backgroundTokenizerFactory;
    }

    pub fn registerFactory(self: *TokenizationRegistry, languageId: []const u8, factory: *LazyTokenizationSupport) !void {
        if (self._factories.fetchRemove(languageId)) |entry| self.allocator.free(entry.key);
        const key = try self.allocator.dupe(u8, languageId);
        errdefer self.allocator.free(key);
        try self._factories.put(key, factory);
    }

    pub fn getOrCreate(self: *TokenizationRegistry, languageId: []const u8) !?ITokenizationSupport {
        if (self.get(languageId)) |support| return support;

        const factory = self._factories.get(languageId) orelse return null;
        if (factory.getTokenizationSupport()) |support| {
            try self.register(languageId, support);
            return support;
        }
        return null;
    }

    pub fn isResolved(self: *TokenizationRegistry, languageId: []const u8) bool {
        if (self.get(languageId) != null) return true;
        const factory = self._factories.get(languageId) orelse return true;
        return factory._tokenizationSupport != null or factory.getTokenizationSupport() != null;
    }

    pub fn setColorMap(self: *TokenizationRegistry, colorMap: []const Color) void {
        self._colorMap = colorMap;
        var languages = std.array_list.Managed([]const u8).init(self.allocator);
        defer languages.deinit();
        var iter = self._tokenizationSupports.keyIterator();
        while (iter.next()) |key| languages.append(key.*) catch {};
        self._onDidChange.fire(.{ .changedLanguages = languages.items, .changedColorMap = true }) catch {};
    }

    pub fn getColorMap(self: *TokenizationRegistry) ?[]const Color {
        return self._colorMap;
    }

    pub fn clearColorMap(self: *TokenizationRegistry) void {
        self._colorMap = null;
        var languages = std.array_list.Managed([]const u8).init(self.allocator);
        defer languages.deinit();
        var iter = self._tokenizationSupports.keyIterator();
        while (iter.next()) |key| languages.append(key.*) catch {};
        self._onDidChange.fire(.{ .changedLanguages = languages.items, .changedColorMap = true }) catch {};
    }

    /// Resolves a token color id through the active theme's color map.
    ///
    /// Upstream consumers index `getColorMap()` directly. The terminal view
    /// needs one lookup for the `u9` color id stored in the token metadata, so
    /// this helper keeps the bounds check in one place. Callers decide the
    /// fallback when no theme has been installed yet.
    pub fn getColorForToken(self: *const TokenizationRegistry, foreground: u9) ?Color {
        const color_map = self._colorMap orelse return null;
        if (foreground >= color_map.len) return null;
        return color_map[foreground];
    }

    pub fn getDefaultBackground(self: *TokenizationRegistry) ?Color {
        const colorMap = self._colorMap orelse return null;
        if (colorMap.len > @backingInt(ColorId.DefaultBackground)) {
            return colorMap[@backingInt(ColorId.DefaultBackground)];
        }
        return null;
    }
};

test "tokenization registry owns language id keys" {
    const languages = @import("./languages.zig");
    const Support = struct {
        fn getInitialState(_: *anyopaque, _: Allocator) anyerror!languages.IState {
            return error.NotImplemented;
        }
        fn tokenizeEncoded(_: *anyopaque, _: Allocator, _: []const u8, _: bool, _: languages.IState) anyerror!languages.EncodedTokenizationResult {
            return error.NotImplemented;
        }
        fn dispose(_: *anyopaque) void {}
    };
    const support_vtable = languages.ITokenizationSupport.VTable{
        .getInitialState = Support.getInitialState,
        .tokenizeEncoded = Support.tokenizeEncoded,
        .dispose = Support.dispose,
    };
    var support_context: u8 = 0;
    const support = languages.ITokenizationSupport{
        .context = @ptrCast(&support_context),
        .vtable = &support_vtable,
    };

    var registry = TokenizationRegistry.init(std.testing.allocator);
    defer registry.deinit();

    var key = [_]u8{ 't', 'e', 's', 't' };
    try registry.register(&key, support);
    @memset(&key, 'x');
    try std.testing.expect(registry.get("test") != null);

    registry.unregister("test");
    try std.testing.expect(registry.get("test") == null);
}
