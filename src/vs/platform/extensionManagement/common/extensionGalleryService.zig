// Port of the query/asset contracts in
// `src/vs/platform/extensionManagement/common/extensionGalleryService.ts` and
// the default capabilities in `extensionGalleryManifestService.ts`.
// Open VSX exposes the compatible extensionquery API. The caller supplies
// the request service/Io and owns each returned page; no UI or host state.
const std = @import("std");
const builtin = @import("builtin");
const validator = @import("../../extensions/common/extensionValidator.zig");
const product = @import("../../product/common/product.zig");
const Allocator = std.mem.Allocator;
const request_mod = @import("../../request/node/requestService.zig");
const Headers = @import("../../../base/parts/request/common/request.zig").Headers;

pub const SortBy = enum(u8) { relevance = 0, updated = 1, name = 2, publisher = 3, installs = 4, rating = 6, published = 10 };
pub const FilterType = enum(u8) { tag = 1, category = 5, extension_name = 7, target = 8, featured = 9, search_text = 10 };
pub const Criterion = struct { filterType: u8, value: ?[]const u8 = null };
pub const Query = struct {
    criteria: []const Criterion,
    page: usize = 1,
    page_size: usize = 50,
    sort_by: SortBy = .relevance,
    sort_order: u8 = 0,
    all_versions: bool = false,

    pub fn encode(self: Query, allocator: Allocator) ![]u8 {
        const criteria = try allocator.alloc(Criterion, self.criteria.len + 1);
        defer allocator.free(criteria);
        @memcpy(criteria[0..self.criteria.len], self.criteria);
        criteria[self.criteria.len] = .{ .filterType = @backingInt(FilterType.target), .value = "Microsoft.VisualStudio.Code" };
        return std.json.Stringify.valueAlloc(allocator, .{
            .filters = .{.{ .criteria = criteria, .pageNumber = self.page, .pageSize = self.page_size, .sortBy = @backingInt(self.sort_by), .sortOrder = self.sort_order }},
            .assetTypes = &[_][]const u8{},
            // Files, categories/tags, version properties, validated results,
            // asset URIs, statistics and the latest version.
            .flags = @as(u32, 0x2 | 0x4 | 0x10 | 0x20 | 0x80 | 0x100 | (if (self.all_versions) @as(u32, 0x1) else 0x200)),
        }, .{ .emit_null_optional_fields = false });
    }
};

pub const Asset = struct { assetType: []const u8, source: []const u8 };
pub const Property = struct { key: []const u8, value: []const u8 };
pub const Version = struct {
    version: []const u8,
    targetPlatform: ?[]const u8 = null,
    lastUpdated: ?[]const u8 = null,
    files: ?[]const Asset = null,
    properties: ?[]const Property = null,
    assetUri: ?[]const u8 = null,

    pub fn asset(self: Version, name: []const u8) ?[]const u8 {
        for (self.files orelse &.{}) |file| if (std.mem.eql(u8, file.assetType, name)) return file.source;
        return null;
    }
    pub fn property(self: Version, key: []const u8) ?[]const u8 {
        for (self.properties orelse &.{}) |item| if (std.mem.eql(u8, item.key, key)) return item.value;
        return null;
    }

    pub fn isPreRelease(self: Version) bool {
        const value = self.property("Microsoft.VisualStudio.Code.PreRelease") orelse return false;
        return std.ascii.eqlIgnoreCase(value, "true");
    }

    pub fn isCompatible(self: Version) bool {
        if (self.targetPlatform) |target| {
            const platform = switch (builtin.os.tag) {
                .macos => "darwin",
                .windows => "win32",
                .linux => "linux",
                else => "unknown",
            };
            const arch = switch (builtin.cpu.arch) {
                .x86_64 => "x64",
                .aarch64 => "arm64",
                .arm => "armhf",
                else => "unknown",
            };
            const local = platform ++ "-" ++ arch;
            if (!std.mem.eql(u8, target, "universal") and !std.mem.eql(u8, target, "undefined") and !std.mem.eql(u8, target, local)) return false;
        }
        if (self.property("Microsoft.VisualStudio.Code.Engine")) |engine| {
            const version = std.SemanticVersion.parse(product.extension_engine_version) catch unreachable;
            if (!validator.isEngineValid(version, engine)) return false;
        }
        return true;
    }
};
pub const Publisher = struct { publisherName: []const u8, displayName: ?[]const u8 = null, domain: ?[]const u8 = null, isDomainVerified: ?bool = null };
pub const Statistic = struct { statisticName: []const u8, value: f64 };
pub const GalleryExtension = struct {
    extensionName: []const u8,
    extensionId: ?[]const u8 = null,
    releaseDate: ?[]const u8 = null,
    lastUpdated: ?[]const u8 = null,
    displayName: ?[]const u8 = null,
    shortDescription: ?[]const u8 = null,
    publisher: Publisher,
    versions: []const Version = &.{},
    categories: ?[]const []const u8 = null,
    statistics: ?[]const Statistic = null,

    /// Choose the newest compatible release (or prerelease when requested).
    /// An explicit version never silently falls back to a different version.
    pub fn selectVersion(self: GalleryExtension, exact: ?[]const u8, prefer_prerelease: bool) ?Version {
        var best: ?Version = null;
        for (self.versions) |version| {
            if (!version.isCompatible()) continue;
            if (version.asset("Microsoft.VisualStudio.Services.VSIXPackage") == null) continue;
            if (exact) |value| {
                if (!std.mem.eql(u8, value, version.version)) continue;
            } else if (!prefer_prerelease and version.isPreRelease()) continue;
            if (best) |previous| {
                const current = std.SemanticVersion.parse(version.version) catch continue;
                const old = std.SemanticVersion.parse(previous.version) catch continue;
                if (current.order(old) != .gt) continue;
            }
            best = version;
        }
        return best;
    }

    /// A command that explicitly switches channels requires a version from
    /// that channel; unlike a preference it never falls back to the other.
    pub fn selectReleaseChannel(self: GalleryExtension, prerelease: bool) ?Version {
        var best: ?Version = null;
        for (self.versions) |version| {
            if (!version.isCompatible() or version.isPreRelease() != prerelease) continue;
            if (version.asset("Microsoft.VisualStudio.Services.VSIXPackage") == null) continue;
            if (best) |previous| {
                const current = std.SemanticVersion.parse(version.version) catch continue;
                const old = std.SemanticVersion.parse(previous.version) catch continue;
                if (current.order(old) != .gt) continue;
            }
            best = version;
        }
        return best;
    }

    pub fn statistic(self: GalleryExtension, name: []const u8) ?f64 {
        for (self.statistics orelse &.{}) |item| if (std.mem.eql(u8, item.statisticName, name)) return item.value;
        return null;
    }
};
const MetadataItem = struct { name: []const u8, count: usize };
const Metadata = struct { metadataType: []const u8, metadataItems: []const MetadataItem = &.{} };
const RawPage = struct { results: []const struct { extensions: []const GalleryExtension = &.{}, resultMetadata: []const Metadata = &.{} } };

pub const Page = struct {
    parsed: std.json.Parsed(RawPage),
    extensions: []const GalleryExtension,
    total: usize,

    pub fn parse(allocator: Allocator, bytes: []const u8) !Page {
        const parsed = try std.json.parseFromSlice(RawPage, allocator, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        if (parsed.value.results.len == 0) return .{ .parsed = parsed, .extensions = &.{}, .total = 0 };
        const result = parsed.value.results[0];
        var total = result.extensions.len;
        for (result.resultMetadata) |metadata| {
            if (!std.mem.eql(u8, metadata.metadataType, "ResultCount")) continue;
            for (metadata.metadataItems) |item| if (std.mem.eql(u8, item.name, "TotalCount")) {
                total = item.count;
            };
        }
        return .{ .parsed = parsed, .extensions = result.extensions, .total = total };
    }

    pub fn deinit(self: *Page) void {
        self.parsed.deinit();
    }
};

pub const ExtensionGalleryService = struct {
    allocator: Allocator,
    io: std.Io,
    service_url: []const u8,

    pub fn getExtension(self: ExtensionGalleryService, identifier: []const u8) !Page {
        return self.query(.{ .criteria = &.{.{ .filterType = @backingInt(FilterType.extension_name), .value = identifier }}, .page_size = 1, .all_versions = true });
    }

    pub fn query(self: ExtensionGalleryService, options: Query) !Page {
        var request = request_mod.RequestService.init(self.allocator, self.io);
        defer request.deinit();
        var headers = Headers.init(self.allocator);
        defer headers.deinit();
        try headers.append("Content-Type", "application/json");
        try headers.append("Accept", "application/json;api-version=3.0-preview.1");
        const payload = try options.encode(self.allocator);
        defer self.allocator.free(payload);
        const url = try std.fmt.allocPrint(self.allocator, "{s}/extensionquery", .{std.mem.trimEnd(u8, self.service_url, "/")});
        defer self.allocator.free(url);
        var response = try request.request(.{ .url = url, .type = "POST", .headers = &headers, .data = payload, .call_site = "extensionGalleryService.query" });
        defer response.deinit();
        if (response.status_code != 200) return error.GalleryRequestFailed;
        return Page.parse(self.allocator, response.body.bytes);
    }
};

/// Fetch a gallery asset using the same network boundary as query. Caller owns
/// the bytes; missing assets are reported rather than synthesized.
pub fn getAsset(allocator: Allocator, io: std.Io, url: []const u8) ![]u8 {
    var request = request_mod.RequestService.init(allocator, io);
    defer request.deinit();
    var response = try request.request(.{ .url = url, .call_site = "extensionGalleryService.getAsset" });
    defer response.deinit();
    if (response.status_code != 200) return error.GalleryRequestFailed;
    return allocator.dupe(u8, response.body.bytes);
}

/// Date.parse boundary for the gallery's ISO 8601 timestamps. Fractions beyond
/// milliseconds are truncated, as in the JavaScript Date representation.
pub fn parseGalleryTimestamp(value: []const u8) ?i64 {
    if (value.len < 20 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or value[13] != ':' or value[16] != ':') return null;
    const year = parseDecimal(u16, value[0..4]) orelse return null;
    const month = parseDecimal(u8, value[5..7]) orelse return null;
    const day = parseDecimal(u8, value[8..10]) orelse return null;
    const hour = parseDecimal(u8, value[11..13]) orelse return null;
    const minute = parseDecimal(u8, value[14..16]) orelse return null;
    const second = parseDecimal(u8, value[17..19]) orelse return null;
    if (year < 1970 or month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 59) return null;
    if (day > std.time.epoch.getDaysInMonth(year, @fromBackingInt(@intCast(@as(u4, @intCast(month)))))) return null;
    var cursor: usize = 19;
    var millis: i64 = 0;
    if (value[cursor] == '.') {
        cursor += 1;
        const start = cursor;
        while (cursor < value.len and std.ascii.isDigit(value[cursor])) : (cursor += 1) {
            if (cursor - start < 3) millis = millis * 10 + value[cursor] - '0';
        }
        if (cursor == start) return null;
        var digits = cursor - start;
        while (digits < 3) : (digits += 1) millis *= 10;
    }
    if (cursor >= value.len) return null;
    var offset_seconds: i64 = 0;
    if (value[cursor] == 'Z') {
        if (cursor + 1 != value.len) return null;
    } else if (value[cursor] == '+' or value[cursor] == '-') {
        if (cursor + 6 != value.len or value[cursor + 3] != ':') return null;
        const offset_hour = parseDecimal(u8, value[cursor + 1 .. cursor + 3]) orelse return null;
        const offset_minute = parseDecimal(u8, value[cursor + 4 .. cursor + 6]) orelse return null;
        if (offset_hour > 23 or offset_minute > 59) return null;
        offset_seconds = @as(i64, offset_hour) * 3600 + @as(i64, offset_minute) * 60;
        if (value[cursor] == '-') offset_seconds = -offset_seconds;
    } else return null;
    var days: i64 = day - 1;
    var y: u16 = 1970;
    while (y < year) : (y += 1) days += std.time.epoch.getDaysInYear(y);
    var m: u8 = 1;
    while (m < month) : (m += 1) days += std.time.epoch.getDaysInMonth(year, @fromBackingInt(@intCast(@as(u4, @intCast(m)))));
    return (days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second - offset_seconds) * 1000 + millis;
}

fn parseDecimal(comptime T: type, value: []const u8) ?T {
    for (value) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseInt(T, value, 10) catch null;
}
