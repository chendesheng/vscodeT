const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const Emitter = @import("../basics/event.zig").Emitter;
const ColorId = @import("../encodedTokenAttributes.zig").ColorId;
const ITokenizationSupport = @import("../languages.zig").ITokenizationSupport;
const TokenizationSupportChangedEvent = @import("../languages.zig").TokenizationSupportChangedEvent;
const Color = @import("../basics/color.zig").Color;
const LazyTokenizationSupport = @import("../languages.zig").LazyTokenizationSupport;

pub const TokenizationRegistry = struct {
    var _instance: ?TokenizationRegistry = null;
    pub fn instance(allocator: Allocator) *TokenizationRegistry {
        if (_instance == null) {
            _instance = TokenizationRegistry.init(allocator);
        }
        return &(_instance.?);
    }
    pub fn deinitInstance() void {
        if (_instance != null) {
            _instance.?.deinit();
            _instance = null;
        }
    }

    _tokenizationSupports: StringHashMap(*ITokenizationSupport),
    _factories: StringHashMap(TokenizationSupportFactoryData),
    _onDidChange: Emitter(TokenizationSupportChangedEvent),
    _colorMap: ?[]Color,

    pub fn init(allocator: Allocator) TokenizationRegistry {
        return TokenizationRegistry{
            ._tokenizationSupports = StringHashMap(*ITokenizationSupport).init(allocator),
            ._factories = StringHashMap(TokenizationSupportFactoryData).init(allocator),
            ._onDidChange = Emitter(TokenizationSupportChangedEvent).init(allocator),
            ._colorMap = null,
        };
    }

    pub fn deinit(self: *TokenizationRegistry) void {
        self._tokenizationSupports.deinit();
        self._factories.deinit();
        self._onDidChange.deinit();
    }

    pub fn handleChange(self: *TokenizationRegistry, languageIds: []const u8) void {
        self._onDidChange.fire(.{ .changedLanguages = languageIds, .changedColorMap = false });
    }

    pub fn onDidChange(self: *TokenizationRegistry, ctx: anytype, callback: fn (e: TokenizationSupportChangedEvent, ctx: @TypeOf(ctx)) void) !void {
        try self._onDidChange.event(ctx, callback);
    }

    pub fn register(self: *TokenizationRegistry, languageId: []const u8, support: *ITokenizationSupport) !void {
        try self._tokenizationSupports.put(languageId, support);
        self.handleChange(&[_]u8{languageId});
    }

    pub fn unregister(self: *TokenizationRegistry, languageId: []const u8) void {
        if (self._tokenizationSupports.remove(languageId)) {
            self.handleChange(&[_]u8{languageId});
        }
    }

    pub fn get(self: *TokenizationRegistry, languageId: []const u8) ?*ITokenizationSupport {
        return self._tokenizationSupports.get(languageId);
    }

    pub fn registerFactory(self: *TokenizationRegistry, languageId: []const u8, factory: *LazyTokenizationSupport) !void {
        const res = try self._factories.getOrPut(languageId);
        if (res.found_existing) {
            res.value_ptr.deinit();
        }

        res.value_ptr.* = TokenizationSupportFactoryData.init(self, languageId, factory);
    }

    pub fn unregisterFactory(self: *TokenizationRegistry, languageId: []const u8) void {
        _ = self._factories.remove(languageId);
    }

    pub fn getOrCreate(self: *TokenizationRegistry, languageId: []const u8) !?*ITokenizationSupport {
        // check first if the support is already set
        if (self.get(languageId)) |tokenizationSupport| {
            return tokenizationSupport;
        }

        const factory = self._factories.get(languageId);
        if (factory == null or factory.?.isResolved()) {
            // no factory or factory.resolve already finished
            return null;
        }

        factory.?.resolve();

        return self.get(languageId);
    }

    pub fn isResolved(self: *TokenizationRegistry, languageId: []const u8) bool {
        const tokenizationSupport = self.get(languageId);
        if (tokenizationSupport != null) {
            return true;
        }

        const factory = self._factories.get(languageId);
        if (factory == null or factory.?.isResolved()) {
            return true;
        }

        return false;
    }

    pub fn setColorMap(self: *TokenizationRegistry, colorMap: []const Color) void {
        self._colorMap = colorMap;
        self._onDidChange.fire(.{
            // .changedLanguages = getKeys(ITokenizationSupport, self._tokenizationSupports).items,
            .changedColorMap = true,
        });
    }

    pub fn getColorMap(self: *TokenizationRegistry) ?[]Color {
        return self._colorMap;
    }

    pub fn getDefaultBackground(self: *TokenizationRegistry) ?Color {
        if (self._colorMap) |colorMap| {
            if (colorMap.len > ColorId.DefaultBackground) {
                return colorMap[ColorId.DefaultBackground];
            }
        }
        return null;
    }
};

pub const TokenizationSupportFactoryData = struct {
    _registry: *TokenizationRegistry,
    _languageId: []const u8,
    _factory: LazyTokenizationSupport,

    _isDisposed: bool = false,
    // _resolvePromise: ?std.Promise(void) = null,
    _isResolved: bool = false,

    pub fn isResolved(self: *const TokenizationSupportFactoryData) bool {
        return self._isResolved;
    }

    pub fn init(
        registry: *TokenizationRegistry,
        languageId: []const u8,
        factory: *LazyTokenizationSupport,
    ) TokenizationSupportFactoryData {
        return TokenizationSupportFactoryData{
            ._registry = registry,
            ._languageId = languageId,
            ._factory = factory,
            ._isDisposed = false,
            // ._resolvePromise = null,
            ._isResolved = false,
        };
    }

    pub fn deinit(self: *TokenizationSupportFactoryData) void {
        self._factory.deinit();
        self._isDisposed = true;
    }

    pub fn resolve(self: *TokenizationSupportFactoryData) void {
        _ = self;
        // if (self._resolvePromise == null) {
        // self._resolvePromise = try self._create();
        // }
        // return self._resolvePromise;
    }

    fn _create(self: *TokenizationSupportFactoryData) !void {
        self._isResolved = true;
        if (self._factory.getTokenizationSupport()) |tokenizationSupport| {
            if (!self._isDisposed) {
                try self._registry.register(self._languageId, tokenizationSupport);
            }
        }
    }
};
