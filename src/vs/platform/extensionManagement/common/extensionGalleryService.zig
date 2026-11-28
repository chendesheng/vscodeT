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
            .flags = @as(u32, 0x2 | 0x4 | 0x10 | 0x20 | 0x80 | 0x100 | 0x200),
        }, .{ .emit_null_optional_fields = false });
    }
};

pub const Asset = struct { assetType: []const u8, source: []const u8 };
pub const Property = struct { key: []const u8, value: []const u8 };
pub const Version = struct {
    version: []const u8,
    targetPlatform: ?[]const u8 = null,
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
pub const Publisher = struct { publisherName: []const u8, displayName: ?[]const u8 = null };
pub const Statistic = struct { statisticName: []const u8, value: f64 };
pub const GalleryExtension = struct {
    extensionName: []const u8,
    displayName: ?[]const u8 = null,
    shortDescription: ?[]const u8 = null,
    publisher: Publisher,
    versions: []const Version = &.{},
    categories: ?[]const []const u8 = null,
    statistics: ?[]const Statistic = null,

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
