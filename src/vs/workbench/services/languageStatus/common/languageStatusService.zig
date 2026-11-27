// Port of `src/vs/workbench/services/languageStatus/common/languageStatusService.ts`.
const std = @import("std");
const registry = @import("../../../../editor/common/languageFeatureRegistry.zig");
const selector = @import("../../../../editor/common/languageSelector.zig");
const TextModel = @import("../../../../editor/common/model/textModel.zig").TextModel;
const Severity = @import("../../../../base/common/severity.zig").Severity;
const LinkedText = @import("../../../../base/common/linkedText.zig").LinkedText;
const Command = @import("../../../../editor/common/languages.zig").Command;
const IDisposable = @import("../../../../base/common/lifecycle.zig").IDisposable;
const Emitter = @import("../../../../base/common/event.zig").Emitter;
const Allocator = std.mem.Allocator;

pub const ILanguageStatus = struct {
    id: []const u8,
    name: []const u8,
    selector: selector.Selector,
    severity: Severity,
    label: []const u8,
    short_label: ?[]const u8 = null,
    detail: LinkedText,
    busy: bool,
    source: []const u8,
    command: ?Command = null,
    accessibility_label: ?[]const u8 = null,
    accessibility_role: ?[]const u8 = null,
};

pub const ILanguageStatusService = struct {
    context: *anyopaque,
    on_did_change: *Emitter(usize),
    add_status: *const fn (*anyopaque, ILanguageStatus) anyerror!IDisposable,
    get_language_status: *const fn (*anyopaque, Allocator, *TextModel) anyerror![]ILanguageStatus,

    pub fn addStatus(self: ILanguageStatusService, status: ILanguageStatus) !IDisposable {
        return self.add_status(self.context, status);
    }

    pub fn getLanguageStatus(self: ILanguageStatusService, allocator: Allocator, model: *TextModel) ![]ILanguageStatus {
        return self.get_language_status(self.context, allocator, model);
    }
};

pub const language_status_service_id = @import("../../../../platform/instantiation/common/instantiation.zig").ServiceIdentifier(ILanguageStatusService, "languageStatusService");

pub const LanguageStatusService = struct {
    provider: registry.LanguageFeatureRegistry(ILanguageStatus),

    pub fn init(allocator: Allocator) LanguageStatusService {
        return .{ .provider = .init(allocator) };
    }

    pub fn deinit(self: *LanguageStatusService) void {
        self.provider.deinit();
    }

    pub fn interface(self: *LanguageStatusService) ILanguageStatusService {
        const Adapter = struct {
            fn add(context: *anyopaque, status: ILanguageStatus) !IDisposable {
                const service: *LanguageStatusService = @ptrCast(@alignCast(context));
                return service.addStatus(status);
            }
            fn get(context: *anyopaque, allocator: Allocator, model: *TextModel) ![]ILanguageStatus {
                const service: *LanguageStatusService = @ptrCast(@alignCast(context));
                return service.getLanguageStatus(allocator, model);
            }
        };
        return .{ .context = self, .on_did_change = self.onDidChange(), .add_status = Adapter.add, .get_language_status = Adapter.get };
    }

    pub fn onDidChange(self: *LanguageStatusService) *Emitter(usize) {
        return &self.provider.on_did_change;
    }

    /// Status data is borrowed from the registrar until it disposes the entry.
    pub fn addStatus(self: *LanguageStatusService, status: ILanguageStatus) !IDisposable {
        return self.provider.register(status.selector, status);
    }

    pub fn getLanguageStatus(self: *LanguageStatusService, allocator: Allocator, model: *TextModel) ![]ILanguageStatus {
        const result = try self.provider.ordered(allocator, model, false);
        std.mem.sort(ILanguageStatus, result, {}, lessThan);
        return result;
    }

    fn lessThan(_: void, a: ILanguageStatus, b: ILanguageStatus) bool {
        if (a.severity != b.severity) return @backingInt(a.severity) > @backingInt(b.severity);
        if (!std.mem.eql(u8, a.source, b.source)) return std.mem.order(u8, a.source, b.source) == .lt;
        return std.mem.order(u8, a.id, b.id) == .lt;
    }
};
