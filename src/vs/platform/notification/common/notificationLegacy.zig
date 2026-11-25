// Port of `src/vs/platform/notification/common/notificationLegacy.ts`.
// A typed capability replaces the unique TypeScript symbol. Only the
// extension notification and progress bridges should supply this value;
// ordinary strings and errors always render as literal text.
pub const LegacyExtensionLinkParsing = enum { legacyExtensionLinkParsing };
pub const legacyExtensionLinkParsing: LegacyExtensionLinkParsing = .legacyExtensionLinkParsing;
