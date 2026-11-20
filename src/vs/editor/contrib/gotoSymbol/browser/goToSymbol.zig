// Port of the portable helper subset of
// `src/vs/editor/contrib/gotoSymbol/browser/goToSymbol.ts`.
//
// Terminal adaptations: providers are called synchronously with an explicit
// allocator, provider failures are skipped, and the caller owns the returned
// `LocationLink` slice (including each URI). `freeLocationLinks` releases it.
const std = @import("std");
const Allocator = std.mem.Allocator;

const registry_mod = @import("../../../common/languageFeatureRegistry.zig");
const languages = @import("../../../common/languages.zig");
const network = @import("../../../../base/common/network.zig");
const TextModel = @import("../../../common/model/textModel.zig").TextModel;
const Position = @import("../../../common/core/position.zig").Position;
const Range = @import("../../../common/core/range.zig").Range;
const CancellationToken = @import("../../../../base/common/cancellation.zig").CancellationToken;

pub fn getDefinitionsAtPosition(
    allocator: Allocator,
    registry: *registry_mod.LanguageFeatureRegistry(languages.DefinitionProvider),
    model: *TextModel,
    position: Position,
    recursive: bool,
    token: CancellationToken,
) ![]languages.LocationLink {
    const providers = try registry.ordered(allocator, model, recursive);
    defer allocator.free(providers);
    var result = std.array_list.Managed(languages.LocationLink).init(allocator);
    errdefer {
        for (result.items) |link| allocator.free(link.uri);
        result.deinit();
    }
    for (providers) |provider| {
        const links = provider.provide_definition(provider.context, allocator, model, position, token) catch continue;
        try appendLocationLinks(allocator, model, &result, links);
    }
    return result.toOwnedSlice();
}

pub fn getDeclarationsAtPosition(
    allocator: Allocator,
    registry: *registry_mod.LanguageFeatureRegistry(languages.DeclarationProvider),
    model: *TextModel,
    position: Position,
    recursive: bool,
    token: CancellationToken,
) ![]languages.LocationLink {
    const providers = try registry.ordered(allocator, model, recursive);
    defer allocator.free(providers);
    var result = std.array_list.Managed(languages.LocationLink).init(allocator);
    errdefer {
        for (result.items) |link| allocator.free(link.uri);
        result.deinit();
    }
    for (providers) |provider| {
        const links = provider.provide_declaration(provider.context, allocator, model, position, token) catch continue;
        try appendLocationLinks(allocator, model, &result, links);
    }
    return result.toOwnedSlice();
}

pub fn getImplementationsAtPosition(
    allocator: Allocator,
    registry: *registry_mod.LanguageFeatureRegistry(languages.ImplementationProvider),
    model: *TextModel,
    position: Position,
    recursive: bool,
    token: CancellationToken,
) ![]languages.LocationLink {
    const providers = try registry.ordered(allocator, model, recursive);
    defer allocator.free(providers);
    var result = std.array_list.Managed(languages.LocationLink).init(allocator);
    errdefer {
        for (result.items) |link| allocator.free(link.uri);
        result.deinit();
    }
    for (providers) |provider| {
        const links = provider.provide_implementation(provider.context, allocator, model, position, token) catch continue;
        try appendLocationLinks(allocator, model, &result, links);
    }
    return result.toOwnedSlice();
}

pub fn getTypeDefinitionsAtPosition(
    allocator: Allocator,
    registry: *registry_mod.LanguageFeatureRegistry(languages.TypeDefinitionProvider),
    model: *TextModel,
    position: Position,
    recursive: bool,
    token: CancellationToken,
) ![]languages.LocationLink {
    const providers = try registry.ordered(allocator, model, recursive);
    defer allocator.free(providers);
    var result = std.array_list.Managed(languages.LocationLink).init(allocator);
    errdefer {
        for (result.items) |link| allocator.free(link.uri);
        result.deinit();
    }
    for (providers) |provider| {
        const links = provider.provide_type_definition(provider.context, allocator, model, position, token) catch continue;
        try appendLocationLinks(allocator, model, &result, links);
    }
    return result.toOwnedSlice();
}

pub fn getReferencesAtPosition(
    allocator: Allocator,
    registry: *registry_mod.LanguageFeatureRegistry(languages.ReferenceProvider),
    model: *TextModel,
    position: Position,
    compact: bool,
    recursive: bool,
    token: CancellationToken,
) ![]languages.LocationLink {
    const providers = try registry.ordered(allocator, model, recursive);
    defer allocator.free(providers);
    var result = std.array_list.Managed(languages.LocationLink).init(allocator);
    errdefer {
        for (result.items) |link| allocator.free(link.uri);
        result.deinit();
    }
    for (providers) |provider| {
        try appendProviderReferences(allocator, model, &result, provider, position, compact, token);
    }
    return result.toOwnedSlice();
}

/// Releases a result returned by the helpers above.
pub fn freeLocationLinks(allocator: Allocator, links: []languages.LocationLink) void {
    for (links) |link| allocator.free(link.uri);
    allocator.free(links);
}

fn appendLocationLinks(
    allocator: Allocator,
    model: *TextModel,
    result: *std.array_list.Managed(languages.LocationLink),
    links: []languages.LocationLink,
) !void {
    for (links, 0..) |link, index| {
        if (!shouldIncludeUri(model, link.uri)) {
            allocator.free(link.uri);
            continue;
        }
        result.append(link) catch |err| {
            allocator.free(link.uri);
            for (links[index + 1 ..]) |rest| allocator.free(rest.uri);
            allocator.free(links);
            return err;
        };
    }
    allocator.free(links);
}

fn appendProviderReferences(
    allocator: Allocator,
    model: *TextModel,
    result: *std.array_list.Managed(languages.LocationLink),
    provider: languages.ReferenceProvider,
    position: Position,
    compact: bool,
    token: CancellationToken,
) !void {
    var chosen = provider.provide_references(
        provider.context,
        allocator,
        model,
        position,
        .{ .include_declaration = true },
        token,
    ) catch return;

    if (compact and chosen.len == 2) {
        const without_declaration = provider.provide_references(
            provider.context,
            allocator,
            model,
            position,
            .{ .include_declaration = false },
            token,
        ) catch null;
        if (without_declaration) |locations| {
            if (locations.len == 1) {
                freeLocations(allocator, chosen);
                chosen = locations;
            } else {
                freeLocations(allocator, locations);
            }
        }
    }

    for (chosen, 0..) |location, index| {
        if (!shouldIncludeUri(model, location.uri)) {
            allocator.free(location.uri);
            continue;
        }
        result.append(.{
            .origin_selection_range = null,
            .uri = location.uri,
            .range = location.range,
            .target_selection_range = location.range,
        }) catch |err| {
            allocator.free(location.uri);
            for (chosen[index + 1 ..]) |rest| allocator.free(rest.uri);
            allocator.free(chosen);
            return err;
        };
    }
    allocator.free(chosen);
}

fn freeLocations(allocator: Allocator, locations: []languages.Location) void {
    for (locations) |location| allocator.free(location.uri);
    allocator.free(locations);
}

fn shouldIncludeUri(model: *TextModel, target_uri: []const u8) bool {
    const source = model.uri();
    const target = std.Uri.parse(target_uri) catch return true;
    if (std.mem.eql(u8, source.scheme, target.scheme)) return true;
    if (std.mem.eql(u8, target.scheme, network.Schemas.walk_through)) return false;
    if (std.mem.eql(u8, target.scheme, network.Schemas.walk_through_snippet)) return false;
    return true;
}

test "goToSymbol: compact references retry and merge" {
    const testing = std.testing;
    const TestModel = @import("../../../test/common/port/testSupport.zig").TestModel;

    const State = struct {
        fn references(context: *anyopaque, allocator: Allocator, _: *TextModel, _: Position, reference_context: languages.ReferenceContext, _: CancellationToken) ![]languages.Location {
            _ = context;
            const count: usize = if (reference_context.include_declaration) 2 else 1;
            const locations = try allocator.alloc(languages.Location, count);
            for (locations, 0..) |*location, index| {
                location.* = .{
                    .uri = try allocator.dupe(u8, "file:///tmp/test.ts"),
                    .range = Range.init(index + 1, 1, index + 1, 2),
                };
            }
            return locations;
        }
        fn failing(_: *anyopaque, _: Allocator, _: *TextModel, _: Position, _: languages.ReferenceContext, _: CancellationToken) ![]languages.Location {
            return error.ProviderFailed;
        }
    };

    var model = try TestModel.init(testing.allocator, "value\nvalue\n", "typescript");
    defer model.deinit();
    var registry = registry_mod.LanguageFeatureRegistry(languages.ReferenceProvider).init(testing.allocator);
    defer registry.deinit();
    var context: u8 = 0;
    const failing_registration = try registry.register(.{ .language = "*" }, .{
        .context = &context,
        .provide_references = State.failing,
    });
    defer failing_registration.dispose();
    const registration = try registry.register(.{ .language = "*" }, .{
        .context = &context,
        .provide_references = State.references,
    });
    defer registration.dispose();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const links = try getReferencesAtPosition(
        arena.allocator(),
        &registry,
        model.model,
        Position.init(1, 1),
        true,
        false,
        CancellationToken.None,
    );
    try testing.expectEqual(@as(usize, 1), links.len);
    try testing.expectEqualStrings("file:///tmp/test.ts", links[0].uri);
}
