const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const Emitter = @import("../../base/common/event.zig").Emitter;
const ColorId = @import("./encodedTokenAttributes.zig").ColorId;
const ITokenizationSupport = @import("./languages.zig").ITokenizationSupport;
const TokenizationSupportChangedEvent = @import("./languages.zig").TokenizationSupportChangedEvent;
const LazyTokenizationSupport = @import("./languages.zig").LazyTokenizationSupport;
const Color = @import("../../base/common/color.zig").Color;

pub const TokenizationRegistry = struct {
    pub var instance: TokenizationRegistry = TokenizationRegistry.init(std.heap.page_allocator);

    _tokenizationSupports: StringHashMap(ITokenizationSupport),
    _factories: StringHashMap(*LazyTokenizationSupport),
    _onDidChange: Emitter(TokenizationSupportChangedEvent),
    _colorMap: ?[]const Color,
    allocator: Allocator,

    pub fn init(allocator: Allocator) TokenizationRegistry {
        return .{
            ._tokenizationSupports = StringHashMap(ITokenizationSupport).init(allocator),
            ._factories = StringHashMap(*LazyTokenizationSupport).init(allocator),
            ._onDidChange = Emitter(TokenizationSupportChangedEvent).init(allocator),
            ._colorMap = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TokenizationRegistry) void {
        var supportIter = self._tokenizationSupports.valueIterator();
        while (supportIter.next()) |support| support.dispose();
        self._tokenizationSupports.deinit();
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
        try self._tokenizationSupports.put(languageId, support);
        self.handleChange(&[_][]const u8{languageId});
    }

    pub fn unregister(self: *TokenizationRegistry, languageId: []const u8) void {
        if (self._tokenizationSupports.fetchRemove(languageId)) |entry| {
            var support = entry.value;
            support.dispose();
        }
        self.handleChange(&[_][]const u8{languageId});
    }

    pub fn get(self: *TokenizationRegistry, languageId: []const u8) ?ITokenizationSupport {
        return self._tokenizationSupports.get(languageId);
    }

    pub fn registerFactory(self: *TokenizationRegistry, languageId: []const u8, factory: *LazyTokenizationSupport) !void {
        try self._factories.put(languageId, factory);
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

    pub fn getDefaultBackground(self: *TokenizationRegistry) ?Color {
        const colorMap = self._colorMap orelse return null;
        if (colorMap.len > @backingInt(ColorId.DefaultBackground)) {
            return colorMap[@backingInt(ColorId.DefaultBackground)];
        }
        return null;
    }
};
