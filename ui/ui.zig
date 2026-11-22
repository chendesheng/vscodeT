//! A small, standalone terminal UI library.
//!
//! The tree has direct styles (no CSS), a whole-cell layout pass, and a
//! double-buffered cell renderer that emits an ANSI delta. See
//! docs/terminal-ui.md in the parent repository for the design.

pub const ansi = @import("ansi.zig");
pub const box = @import("box.zig");
pub const cell = @import("cell.zig");
pub const cell_border = @import("cell_border.zig");
pub const dialog = @import("dialog.zig");
pub const dom = @import("dom.zig");
pub const event = @import("event.zig");
pub const frame = @import("frame.zig");
pub const image = @import("image.zig");
pub const input = @import("input.zig");
pub const inputbox = @import("inputbox.zig");
pub const layout = @import("layout.zig");
pub const paint = @import("paint.zig");
pub const screen = @import("screen.zig");
pub const scroll_view = @import("scroll_view.zig");
pub const style = @import("style.zig");
pub const surface = @import("surface.zig");

pub const AlignContent = style.AlignContent;
pub const AlignItems = style.AlignItems;
pub const AlignSelf = style.AlignSelf;
pub const BoxTree = box.BoxTree;
pub const BorderStyle = style.BorderStyle;
pub const CellGrid = cell.CellGrid;
pub const Color = style.Color;
pub const ColorDepth = cell.ColorDepth;
pub const Dimension = style.Dimension;
pub const Edges = style.Edges;
pub const Document = dom.Document;
pub const FlexDirection = style.FlexDirection;
pub const FlexWrap = style.FlexWrap;
pub const FocusDirection = event.FocusDirection;
pub const Gap = style.Gap;
pub const Dialog = dialog.Dialog;
pub const DialogTheme = dialog.Theme;
pub const DialogAction = dialog.Action;
pub const DialogButtonRect = dialog.ButtonRect;
pub const DialogLayout = dialog.Layout;
pub const InputBox = inputbox.InputBox;
pub const ScrollView = scroll_view.ScrollView;
pub const FocusEvent = event.FocusEvent;
pub const Frame = frame.Frame;
pub const JustifyContent = style.JustifyContent;
pub const Key = event.Key;
pub const KeyEvent = event.KeyEvent;
pub const LayoutBox = box.LayoutBox;
pub const Listener = event.Listener;
pub const Margin = style.Margin;
pub const MarginEdge = style.MarginEdge;
pub const Modifiers = event.Modifiers;
pub const MouseButton = event.MouseButton;
pub const MouseEvent = event.MouseEvent;
pub const MouseKind = event.MouseKind;
pub const Node = dom.Node;
pub const Overflow = style.Overflow;
pub const OverflowWrap = style.OverflowWrap;
pub const Rect = style.Rect;
pub const Style = style.Style;
pub const TextAlign = style.TextAlign;
pub const TextStyle = style.TextStyle;
pub const UnderlineStyle = style.UnderlineStyle;
pub const WhiteSpace = style.WhiteSpace;
pub const WordBreak = style.WordBreak;
pub const Surface = surface.Surface;
