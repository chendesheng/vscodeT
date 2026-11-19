// Port of `src/vs/editor/common/services/markerDecorationsService.ts`.
//
// Terminal adaptations:
// - there is no `IModelService`; models register/unregister explicitly;
// - theme color ids are replaced by fixed dark-theme RGB values because the
//   terminal cell renderer has no theme-color lookup at the decoration layer;
// - `MarkerDecorations` maps markers by pointer identity, so a `changeOne`
//   that recreates markers produces a fresh decoration set, matching upstream.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lifecycle = @import("../../../base/common/lifecycle.zig");
const IDisposable = lifecycle.IDisposable;
const Emitter = @import("../../../base/common/event.zig").Emitter;
const TextModel = @import("../model/textModel.zig").TextModel;
const model_mod = @import("../model.zig");
const ModelDecorationOptions = model_mod.ModelDecorationOptions;
const ModelDeltaDecoration = model_mod.ModelDeltaDecoration;
const TrackedRangeStickiness = model_mod.TrackedRangeStickiness;
const OverviewRulerLane = model_mod.OverviewRulerLane;
const range_mod = @import("../core/range.zig");
const Range = range_mod.Range;
const markers = @import("../../../platform/markers/common/markers.zig");
const Marker = markers.Marker;
const MarkerService = @import("../../../platform/markers/common/markerService.zig").MarkerService;
const marker_decorations = @import("markerDecorations.zig");
const IMarkerLimit = marker_decorations.IMarkerLimit;
const LiveMarker = marker_decorations.LiveMarker;
const std_uri = @import("../../../base/common/stdUri.zig");

pub const MAX_MARKER_DECORATIONS_LIMIT: usize = 5000;
const OWNER_ID: usize = 7;
const decoration_owner: []const u8 = "marker-decoration";

var marker_options: [4][3]ModelDecorationOptions = buildOptions();

fn severityIndex(marker: *const Marker) usize {
    return switch (marker.severity) {
        markers.MarkerSeverity.Hint => 0,
        markers.MarkerSeverity.Info => 1,
        markers.MarkerSeverity.Warning => 2,
        else => 3,
    };
}

fn hasTag(marker: *const Marker, tag: u32) bool {
    return std.mem.indexOfScalar(u32, marker.tags, tag) != null;
}

fn decorationClass(severity: u32, unnecessary: bool, deprecated: bool) ?[]const u8 {
    if (severity == markers.MarkerSeverity.Hint) {
        if (deprecated) return null;
        if (unnecessary) return "squiggly-unnecessary";
        return "squiggly-hint";
    }
    return switch (severity) {
        markers.MarkerSeverity.Info => "squiggly-info",
        markers.MarkerSeverity.Warning => "squiggly-warning",
        else => "squiggly-error",
    };
}

fn inlineClass(marker: *const Marker) ?[]const u8 {
    if (hasTag(marker, markers.MarkerTag.deprecated)) return "squiggly-inline-deprecated";
    if (hasTag(marker, markers.MarkerTag.unnecessary)) return "squiggly-inline-unnecessary";
    return null;
}

fn overviewColor(severity: u32) [3]u8 {
    return switch (severity) {
        markers.MarkerSeverity.Info => .{ 55, 148, 255 },
        markers.MarkerSeverity.Warning => .{ 204, 167, 0 },
        markers.MarkerSeverity.Hint => .{ 138, 138, 138 },
        else => .{ 241, 76, 76 },
    };
}

fn buildOptions() [4][3]ModelDecorationOptions {
    var table: [4][3]ModelDecorationOptions = undefined;
    const severities = [_]u32{
        markers.MarkerSeverity.Hint,
        markers.MarkerSeverity.Info,
        markers.MarkerSeverity.Warning,
        markers.MarkerSeverity.Error,
    };
    for (severities, 0..) |severity, severity_index| {
        for (0..3) |tag_state| {
            var options = ModelDecorationOptions.init(decoration_owner, .NeverGrowsWhenTypingAtEdges);
            options.className = decorationClass(severity, tag_state == 1, tag_state == 2);
            options.showIfCollapsed = true;
            options.overviewRuler = .{
                .color = overviewColor(severity),
                .position = .Right,
            };
            options.zIndex = switch (severity) {
                markers.MarkerSeverity.Info => 10,
                markers.MarkerSeverity.Warning => 20,
                markers.MarkerSeverity.Error => 30,
                else => 0,
            };
            options.inlineClassName = switch (tag_state) {
                1 => "squiggly-inline-unnecessary",
                2 => "squiggly-inline-deprecated",
                else => null,
            };
            table[severity_index][tag_state] = options;
        }
    }
    return table;
}

fn optionsFor(marker: *const Marker) *ModelDecorationOptions {
    const tag_state: usize = if (hasTag(marker, markers.MarkerTag.deprecated)) 2 else if (hasTag(marker, markers.MarkerTag.unnecessary)) 1 else 0;
    return &marker_options[severityIndex(marker)][tag_state];
}

const ModelEntry = struct {
    model: *TextModel,
    key: []u8,
    decorations: *MarkerDecorations,
};

pub const MarkerDecorationsService = struct {
    allocator: Allocator,
    marker_service: *MarkerService,
    models: std.array_list.Managed(*ModelEntry),
    suppressed: std.StringHashMap(*std.array_list.Managed(Range)),
    on_did_change_marker: Emitter(*TextModel),
    on_did_change_marker_limit: Emitter(*TextModel),
    listener: ?Emitter(markerChangeEventType()).ListenerId = null,

    fn markerChangeEventType() type {
        return @import("../../../platform/markers/common/markerService.zig").MarkerChangeEvent;
    }

    pub fn init(allocator: Allocator, marker_service: *MarkerService) !*MarkerDecorationsService {
        const self = try allocator.create(MarkerDecorationsService);
        self.* = .{
            .allocator = allocator,
            .marker_service = marker_service,
            .models = std.array_list.Managed(*ModelEntry).init(allocator),
            .suppressed = std.StringHashMap(*std.array_list.Managed(Range)).init(allocator),
            .on_did_change_marker = Emitter(*TextModel).init(allocator),
            .on_did_change_marker_limit = Emitter(*TextModel).init(allocator),
        };
        self.listener = try marker_service.on_marker_changed.listen(self, markerChanged);
        return self;
    }

    pub fn deinit(self: *MarkerDecorationsService) void {
        if (self.listener) |listener| self.marker_service.on_marker_changed.unlisten(listener);
        for (self.models.items) |entry| {
            entry.decorations.deinit();
            var resource = entry.decorations.resource_value;
            resource.deinit(self.allocator);
            self.allocator.destroy(entry.decorations);
            self.allocator.free(entry.key);
            self.allocator.destroy(entry);
        }
        self.models.deinit();
        var suppressed = self.suppressed.valueIterator();
        while (suppressed.next()) |list| {
            list.*.deinit();
            self.allocator.destroy(list.*);
        }
        self.suppressed.deinit();
        self.on_did_change_marker.deinit();
        self.on_did_change_marker_limit.deinit();
        self.allocator.destroy(self);
    }

    pub fn registerModel(self: *MarkerDecorationsService, model: *TextModel) !void {
        if (self.entryFor(model) != null) return;
        const key = try std_uri.resourceKey(self.allocator, model.uri());
        errdefer self.allocator.free(key);
        const entry = try self.allocator.create(ModelEntry);
        errdefer self.allocator.destroy(entry);
        const resource = try markers.Resource.fromUri(self.allocator, model.uri());
        errdefer {
            var owned = resource;
            owned.deinit(self.allocator);
        }
        const decorations = try self.allocator.create(MarkerDecorations);
        decorations.* = MarkerDecorations.init(self.allocator, model, key, resource);
        entry.* = .{ .model = model, .key = key, .decorations = decorations };
        try self.models.append(entry);
        try self.updateEntry(entry);
    }

    pub fn unregisterModel(self: *MarkerDecorationsService, model: *TextModel) void {
        var index: usize = 0;
        while (index < self.models.items.len) : (index += 1) {
            const entry = self.models.items[index];
            if (entry.model != model) continue;
            entry.decorations.deinit();
            var resource = entry.decorations.resource_value;
            resource.deinit(self.allocator);
            self.allocator.destroy(entry.decorations);
            self.allocator.free(entry.key);
            self.allocator.destroy(entry);
            _ = self.models.orderedRemove(index);
            return;
        }
    }

    fn entryFor(self: *MarkerDecorationsService, model: *TextModel) ?*ModelEntry {
        for (self.models.items) |entry| {
            if (entry.model == model) return entry;
        }
        return null;
    }

    fn markerChanged(event: markerChangeEventType(), self: *MarkerDecorationsService) !void {
        for (self.models.items) |entry| {
            for (event.resources) |key| {
                if (std.mem.eql(u8, key, entry.key)) {
                    try self.updateEntry(entry);
                    break;
                }
            }
        }
    }

    fn updateEntry(self: *MarkerDecorationsService, entry: *ModelEntry) !void {
        const read = try self.marker_service.read(self.allocator, .{ .resource = entry.decorations.resource_value, .take = MAX_MARKER_DECORATIONS_LIMIT + 1 });
        defer self.allocator.free(read);

        var count = read.len;
        const exceeded = count > MAX_MARKER_DECORATIONS_LIMIT;
        if (exceeded) count = MAX_MARKER_DECORATIONS_LIMIT;

        var filtered = std.array_list.Managed(*Marker).init(self.allocator);
        defer filtered.deinit();
        for (read[0..count]) |marker| {
            if (self.isSuppressed(entry.key, marker)) continue;
            try filtered.append(marker);
        }

        if (try entry.decorations.update(filtered.items)) {
            try self.on_did_change_marker.fire(entry.model);
        }
        const source_truncated = self.marker_service.isSourceTruncated(entry.decorations.resource_value);
        if (entry.decorations.updateMarkerLimit(source_truncated, exceeded)) {
            try self.on_did_change_marker_limit.fire(entry.model);
        }
    }

    fn isSuppressed(self: *MarkerDecorationsService, key: []const u8, marker: *const Marker) bool {
        const ranges = self.suppressed.get(key) orelse return false;
        const marker_range = Range.init(marker.start_line_number, marker.start_column, marker.end_line_number, marker.end_column);
        for (ranges.items) |range| {
            if (range_mod.areIntersectingOrTouching(&range, &marker_range)) return true;
        }
        return false;
    }

    pub fn addMarkerSuppression(self: *MarkerDecorationsService, model: *TextModel, range: Range) !IDisposable {
        const entry = self.entryFor(model) orelse return error.ModelNotRegistered;
        var list = self.suppressed.get(entry.key);
        if (list == null) {
            const created = try self.allocator.create(std.array_list.Managed(Range));
            created.* = std.array_list.Managed(Range).init(self.allocator);
            try self.suppressed.put(entry.key, created);
            list = created;
        }
        try list.?.append(range);
        try self.updateEntry(entry);
        const registration = try self.allocator.create(SuppressionRegistration);
        registration.* = .{ .service = self, .key = try self.allocator.dupe(u8, entry.key), .range = range };
        return .{ .context = registration, .disposeFn = disposeSuppression };
    }

    fn disposeSuppression(context: *anyopaque) void {
        const registration: *SuppressionRegistration = @ptrCast(@alignCast(context));
        const service = registration.service;
        if (service.suppressed.get(registration.key)) |list| {
            var index: usize = 0;
            while (index < list.items.len) : (index += 1) {
                if (list.items[index].startLineNumber == registration.range.startLineNumber and
                    list.items[index].startColumn == registration.range.startColumn and
                    list.items[index].endLineNumber == registration.range.endLineNumber and
                    list.items[index].endColumn == registration.range.endColumn)
                {
                    _ = list.orderedRemove(index);
                    break;
                }
            }
            if (list.items.len == 0) {
                _ = service.suppressed.remove(registration.key);
                list.deinit();
                service.allocator.destroy(list);
            }
        }
        for (service.models.items) |entry| {
            if (std.mem.eql(u8, entry.key, registration.key)) {
                service.updateEntry(entry) catch {};
                break;
            }
        }
        service.allocator.free(registration.key);
        service.allocator.destroy(registration);
    }
};

const SuppressionRegistration = struct {
    service: *MarkerDecorationsService,
    key: []u8,
    range: Range,
};

const MarkerDecorations = struct {
    allocator: Allocator,
    model: *TextModel,
    key: []u8,
    by_marker: std.AutoHashMap(*Marker, u64),
    by_decoration: std.AutoHashMap(u64, *Marker),
    is_source_truncated: bool = false,
    is_limit_exceeded: bool = false,
    resource_value: markers.Resource = .{},

    fn init(allocator: Allocator, model: *TextModel, key: []u8, resource: markers.Resource) MarkerDecorations {
        return .{
            .allocator = allocator,
            .model = model,
            .key = key,
            .resource_value = resource,
            .by_marker = std.AutoHashMap(*Marker, u64).init(allocator),
            .by_decoration = std.AutoHashMap(u64, *Marker).init(allocator),
        };
    }

    fn deinit(self: *MarkerDecorations) void {
        var ids = std.array_list.Managed(u64).init(self.allocator);
        defer ids.deinit();
        var iterator = self.by_decoration.keyIterator();
        while (iterator.next()) |id| ids.append(id.*) catch {};
        _ = self.model.deltaDecorations(ids.items, &.{}, OWNER_ID) catch {};
        self.by_marker.deinit();
        self.by_decoration.deinit();
    }

    fn update(self: *MarkerDecorations, markers_list: []const *Marker) !bool {
        var old_ids = std.array_list.Managed(u64).init(self.allocator);
        defer old_ids.deinit();
        var added = std.array_list.Managed(*Marker).init(self.allocator);
        defer added.deinit();

        for (markers_list) |marker| {
            if (!self.by_marker.contains(marker)) try added.append(marker);
        }
        var iterator = self.by_marker.iterator();
        while (iterator.next()) |entry| {
            const marker = entry.key_ptr.*;
            var still_present = false;
            for (markers_list) |candidate| {
                if (candidate == marker) {
                    still_present = true;
                    break;
                }
            }
            if (!still_present) try old_ids.append(entry.value_ptr.*);
        }
        if (old_ids.items.len == 0 and added.items.len == 0) return false;

        var new_decorations = std.array_list.Managed(ModelDeltaDecoration).init(self.allocator);
        defer new_decorations.deinit();
        for (added.items) |marker| {
            try new_decorations.append(.{
                .range = try self.createDecorationRange(marker),
                .options = optionsFor(marker),
            });
        }
        const ids = try self.model.deltaDecorations(old_ids.items, new_decorations.items, OWNER_ID);
        defer self.allocator.free(ids);
        for (old_ids.items) |id| {
            if (self.by_decoration.fetchRemove(id)) |removed| _ = self.by_marker.remove(removed.value);
        }
        for (added.items, 0..) |marker, index| {
            try self.by_marker.put(marker, ids[index]);
            try self.by_decoration.put(ids[index], marker);
        }
        return true;
    }

    fn updateMarkerLimit(self: *MarkerDecorations, source_truncated: bool, limit_exceeded: bool) bool {
        if (self.is_source_truncated == source_truncated and self.is_limit_exceeded == limit_exceeded) return false;
        self.is_source_truncated = source_truncated;
        self.is_limit_exceeded = limit_exceeded;
        return true;
    }

    fn limit(self: *const MarkerDecorations) IMarkerLimit {
        return .{
            .is_markers_source_truncated = self.is_source_truncated,
            .is_markers_truncated = if (self.is_limit_exceeded) MAX_MARKER_DECORATIONS_LIMIT else null,
        };
    }

    pub fn getLiveMarkers(self: *MarkerDecorations, allocator: Allocator) ![]LiveMarker {
        var result = std.array_list.Managed(LiveMarker).init(allocator);
        errdefer result.deinit();
        var iterator = self.by_decoration.iterator();
        while (iterator.next()) |entry| {
            const range = self.model.getDecorationRange(entry.key_ptr.*) orelse continue;
            try result.append(.{ .range = range, .marker = entry.value_ptr.* });
        }
        return result.toOwnedSlice();
    }

    fn createDecorationRange(self: *MarkerDecorations, marker: *Marker) !Range {
        var range = Range.init(marker.start_line_number, marker.start_column, marker.end_line_number, marker.end_column);
        if (marker.severity == markers.MarkerSeverity.Hint and
            !hasTag(marker, markers.MarkerTag.unnecessary) and
            !hasTag(marker, markers.MarkerTag.deprecated))
        {
            range = range.setEndPosition(range.startLineNumber, range.startColumn + 2);
        }
        range = self.model.validateRange(range);
        if (range.isEmpty()) {
            const max_column = self.model.getLineLastNonWhitespaceColumn(range.startLineNumber) catch 0;
            const effective_max = if (max_column == 0) self.model.getLineMaxColumn(range.startLineNumber) else max_column;
            if (effective_max == 1 or range.endColumn >= effective_max) return range;
            if (self.model.getWordAtPosition(range.getStartPosition())) |word_value| {
                var word = word_value;
                defer word.deinit();
                range = Range.init(range.startLineNumber, word.startColumn, range.endLineNumber, word.endColumn);
            }
        } else if (marker.end_column == std.math.maxInt(u32) and marker.start_column == 1 and range.startLineNumber == range.endLineNumber) {
            const min_column = self.model.getLineFirstNonWhitespaceColumn(marker.start_line_number) catch 0;
            if (min_column > 0 and min_column < range.endColumn) {
                range = Range.init(range.startLineNumber, min_column, range.endLineNumber, range.endColumn);
                marker.start_column = @intCast(min_column);
            }
        }
        return range;
    }
};
