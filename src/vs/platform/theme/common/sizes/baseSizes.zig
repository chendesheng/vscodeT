// Port of `src/vs/platform/theme/common/sizes/baseSizes.ts`.
//
// The explicit registry is passed in instead of using the platform-global one.
const size_utils = @import("../sizeUtils.zig");

pub const bodyFontSize = "bodyFontSize";
pub const bodyFontSizeSmall = "bodyFontSize.small";
pub const bodyFontSizeXSmall = "bodyFontSize.xSmall";
pub const fontSizeHeading1 = "fontSize.heading1";
pub const fontSizeHeading2 = "fontSize.heading2";
pub const fontSizeHeading3 = "fontSize.heading3";
pub const fontSizeBody1 = "fontSize.body1";
pub const fontSizeBody2 = "fontSize.body2";
pub const fontSizeLabel1 = "fontSize.label1";
pub const fontSizeLabel2 = "fontSize.label2";
pub const fontSizeLabel3 = "fontSize.label3";
pub const fontWeightRegular = "fontWeight.regular";
pub const fontWeightSemiBold = "fontWeight.semiBold";
pub const codiconFontSize = "codiconFontSize";
pub const codiconFontSizeCompact = "codiconFontSize.compact";
pub const cornerRadiusMedium = "cornerRadius.medium";
pub const cornerRadiusXSmall = "cornerRadius.xSmall";
pub const cornerRadiusSmall = "cornerRadius.small";
pub const cornerRadiusLarge = "cornerRadius.large";
pub const cornerRadiusXLarge = "cornerRadius.xLarge";
pub const cornerRadiusCircle = "cornerRadius.circle";
pub const strokeThickness = "strokeThickness";
pub const spacingNone = "spacing.sizeNone";
pub const spacingSize20 = "spacing.size20";
pub const spacingSize40 = "spacing.size40";
pub const spacingSize60 = "spacing.size60";
pub const spacingSize80 = "spacing.size80";
pub const spacingSize100 = "spacing.size100";
pub const spacingSize120 = "spacing.size120";
pub const spacingSize160 = "spacing.size160";
pub const spacingSize200 = "spacing.size200";
pub const spacingSize240 = "spacing.size240";
pub const spacingSize280 = "spacing.size280";
pub const spacingSize320 = "spacing.size320";
pub const spacingSize360 = "spacing.size360";
pub const spacingSize400 = "spacing.size400";

pub fn registerBaseSizes(registry: *size_utils.SizeRegistry) !void {
    const specs = [_]struct { id: []const u8, value: f64, unit: size_utils.SizeUnit }{
        .{ .id = bodyFontSize, .value = 13, .unit = .px },
        .{ .id = bodyFontSizeSmall, .value = 12, .unit = .px },
        .{ .id = bodyFontSizeXSmall, .value = 11, .unit = .px },
        .{ .id = fontSizeHeading1, .value = 26, .unit = .px },
        .{ .id = fontSizeHeading2, .value = 18, .unit = .px },
        .{ .id = fontSizeHeading3, .value = 13, .unit = .px },
        .{ .id = fontSizeBody1, .value = 13, .unit = .px },
        .{ .id = fontSizeBody2, .value = 11, .unit = .px },
        .{ .id = fontSizeLabel1, .value = 12, .unit = .px },
        .{ .id = fontSizeLabel2, .value = 11, .unit = .px },
        .{ .id = fontSizeLabel3, .value = 10, .unit = .px },
        .{ .id = fontWeightRegular, .value = 400, .unit = .unitless },
        .{ .id = fontWeightSemiBold, .value = 600, .unit = .unitless },
        .{ .id = codiconFontSize, .value = 16, .unit = .px },
        .{ .id = codiconFontSizeCompact, .value = 12, .unit = .px },
        .{ .id = cornerRadiusMedium, .value = 6, .unit = .px },
        .{ .id = cornerRadiusXSmall, .value = 2, .unit = .px },
        .{ .id = cornerRadiusSmall, .value = 4, .unit = .px },
        .{ .id = cornerRadiusLarge, .value = 8, .unit = .px },
        .{ .id = cornerRadiusXLarge, .value = 12, .unit = .px },
        .{ .id = cornerRadiusCircle, .value = 9999, .unit = .px },
        .{ .id = strokeThickness, .value = 1, .unit = .px },
        .{ .id = spacingNone, .value = 0, .unit = .px },
        .{ .id = spacingSize20, .value = 2, .unit = .px },
        .{ .id = spacingSize40, .value = 4, .unit = .px },
        .{ .id = spacingSize60, .value = 6, .unit = .px },
        .{ .id = spacingSize80, .value = 8, .unit = .px },
        .{ .id = spacingSize100, .value = 10, .unit = .px },
        .{ .id = spacingSize120, .value = 12, .unit = .px },
        .{ .id = spacingSize160, .value = 16, .unit = .px },
        .{ .id = spacingSize200, .value = 20, .unit = .px },
        .{ .id = spacingSize240, .value = 24, .unit = .px },
        .{ .id = spacingSize280, .value = 28, .unit = .px },
        .{ .id = spacingSize320, .value = 32, .unit = .px },
        .{ .id = spacingSize360, .value = 36, .unit = .px },
        .{ .id = spacingSize400, .value = 40, .unit = .px },
    };
    for (specs) |spec| {
        _ = try registry.registerSize(spec.id, .{ .defaults = size_utils.sizeForAllThemes(spec.value, spec.unit) }, "Base size", null, null);
    }
}
