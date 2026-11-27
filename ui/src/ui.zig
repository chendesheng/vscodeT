//! A small, standalone terminal UI library.
//!
//! Styles are authored as declarations that cascade from parent computed
//! styles; class names are integer IDs into the document's array-backed
//! stylesheet. There is no CSS parser or selector engine. The renderer is a
//! whole-cell layout pass and a double-buffered ANSI delta. See
//! docs/terminal-ui.md and docs/css.md in the parent repository.

pub const ansi = @import("terminal/ansi.zig");
pub const box = @import("layout/box.zig");
pub const cell = @import("render/cell.zig");
pub const cell_border = @import("render/cell_border.zig");
pub const contextmenu = @import("widgets/contextmenu.zig");
pub const css = @import("style/css.zig");
pub const dialog = @import("widgets/dialog.zig");
pub const dom = @import("dom/dom.zig");
pub const drag_drop = @import("widgets/drag_drop.zig");
pub const event = @import("dom/event.zig");
pub const frame = @import("render/frame.zig");
pub const grapheme = @import("render/grapheme.zig");
pub const image = @import("terminal/image.zig");
pub const input = @import("terminal/input.zig");
pub const inputbox = @import("widgets/inputbox.zig");
pub const layout = @import("layout/layout.zig");
pub const linebreak = @import("layout/linebreak.zig");
pub const paint = @import("render/paint.zig");
pub const pointer = @import("terminal/pointer.zig");
pub const screen = @import("terminal/screen.zig");
pub const scroll = @import("widgets/scroll.zig");
pub const scroll_view = @import("widgets/scroll_view.zig");
pub const style = @import("style/style.zig");
pub const surface = @import("surface.zig");
pub const text_layout = @import("layout/text_layout.zig");

pub const AlignContent = style.AlignContent;
pub const AlignItems = style.AlignItems;
pub const AlignSelf = style.AlignSelf;
pub const BoxTree = box.BoxTree;
pub const BorderStyle = style.BorderStyle;
pub const CellGrid = cell.CellGrid;
pub const Color = style.Color;
pub const ColorDepth = cell.ColorDepth;
pub const ComputedStyle = style.ComputedStyle;
pub const ContextMenu = contextmenu.ContextMenu;
pub const ContextMenuAction = contextmenu.Action;
pub const ContextMenuClickHandler = contextmenu.ClickHandler;
pub const ContextMenuEvent = contextmenu.Event;
pub const ContextMenuItem = contextmenu.Item;
pub const ContextMenuItemType = contextmenu.ItemType;
pub const ContextMenuOnHide = contextmenu.OnHide;
pub const ContextMenuOptions = contextmenu.Options;
pub const ContextMenuTheme = contextmenu.Theme;
pub const Dimension = style.Dimension;
pub const EdgeDecl = style.EdgeDecl;
pub const Edges = style.Edges;
pub const Document = dom.Document;
pub const DragSession = drag_drop.DragSession;
pub const FlexDirection = style.FlexDirection;
pub const FlexWrap = style.FlexWrap;
pub const FocusDirection = event.FocusDirection;
pub const Gap = style.Gap;
pub const GapDecl = style.GapDecl;
pub const Dialog = dialog.Dialog;
pub const DialogTheme = dialog.Theme;
pub const DialogAction = dialog.Action;
pub const DialogButtonRect = dialog.ButtonRect;
pub const DialogLayout = dialog.Layout;
pub const InputBox = inputbox.InputBox;
pub const ScrollView = scroll_view.ScrollView;
pub const ScrollWindow = scroll.ScrollWindow;
pub const FocusEvent = event.FocusEvent;
pub const Frame = frame.Frame;
pub const HoverStyle = style.HoverStyle;
pub const JustifyContent = style.JustifyContent;
pub const Key = event.Key;
pub const KeyEvent = event.KeyEvent;
pub const LayoutBox = box.LayoutBox;
pub const Listener = event.Listener;
pub const Margin = style.Margin;
pub const MarginDecl = style.MarginDecl;
pub const MarginEdge = style.MarginEdge;
pub const Modifiers = event.Modifiers;
pub const MouseButton = event.MouseButton;
pub const MouseEvent = event.MouseEvent;
pub const MouseKind = event.MouseKind;
pub const Node = dom.Node;
pub const Overflow = style.Overflow;
pub const OverflowWrap = style.OverflowWrap;
pub const Overlay = surface.Overlay;
pub const Pointer = style.Pointer;
pub const Position = style.Position;
pub const Display = style.Display;
pub const Visibility = style.Visibility;
pub const Rect = style.Rect;
pub const Style = style.Style;
pub const TextAlign = style.TextAlign;
pub const TextStyle = style.TextStyle;
pub const UnderlineStyle = style.UnderlineStyle;
pub const WhiteSpace = style.WhiteSpace;
pub const WordBreak = style.WordBreak;
pub const Surface = surface.Surface;

/// Thread-affine async execution for window event loops.
pub const WindowIo = @import("runtime/window_io.zig").WindowIo;
