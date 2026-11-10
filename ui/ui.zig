//! A small, standalone terminal UI library.
//!
//! The tree has direct styles (no CSS), a whole-cell layout pass, and a
//! double-buffered cell renderer that emits an ANSI delta. See
//! docs/terminal-ui.md in the parent repository for the design.

pub const ansi = @import("ansi.zig");
pub const box = @import("box.zig");
pub const cell = @import("cell.zig");
pub const dom = @import("dom.zig");
pub const frame = @import("frame.zig");
pub const layout = @import("layout.zig");
pub const paint = @import("paint.zig");
pub const style = @import("style.zig");
pub const surface = @import("surface.zig");

pub const BoxTree = box.BoxTree;
pub const BorderStyle = style.BorderStyle;
pub const CellGrid = cell.CellGrid;
pub const Color = style.Color;
pub const ColorDepth = cell.ColorDepth;
pub const Dimension = style.Dimension;
pub const Edges = style.Edges;
pub const Document = dom.Document;
pub const Frame = frame.Frame;
pub const LayoutBox = box.LayoutBox;
pub const Node = dom.Node;
pub const Rect = style.Rect;
pub const Style = style.Style;
pub const TextAlign = style.TextAlign;
pub const Surface = surface.Surface;
