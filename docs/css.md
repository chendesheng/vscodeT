# Style declarations, class IDs and the document stylesheet

Status: implemented in `ui/` and the first editor ports.

This document describes the CSS-like layer of the terminal UI library. It is
deliberately **not** a CSS implementation: there is no parser, no selector
matching, no specificity, no `!important`, no custom properties and no
generator. It keeps the three things the port needs:

1. style fields inherit from parent elements,
2. a class is a style record, merged in order,
3. an editor CSS file can be ported by hand to a sibling `*_css.zig` file.

## Declarations and computed styles

`ui.Style` is an **authored declaration**. Every field is optional; `null`
means "not specified".

`ui.ComputedStyle` is the resolved value a layout box carries. It has the same
field names with concrete defaults. Resolution uses CSS property inheritance,
not "inherit everything":

- **Inherited (computed):** `text_align`, `visibility`, `white_space`,
  `word_break`, `overflow_wrap`, `pointer`.
- **Inherited (paint pass):** `color`, `bold`, `italic`, `underline`,
  `underline_style`, `strikethrough`, `dim`, `reverse`.
- **Not inherited:** `display`, position/offsets, sizes/bounds, margin, padding,
  border, background, overflow, flex properties, gap, order, z-index and
  translations.

Paint properties stay declarations in `ComputedStyle`; the painter inherits
them down the live box chain. This keeps hover overlays composable: a hover
color on an ancestor still reaches a child that did not declare its own color.
An explicit `false` clears an inherited paint attribute. `background` is never
inherited.

Initial values are the previous `Style` defaults. `display` defaults per tag:
`div`/`generic` are block, `span` is inline. `border_style` keeps the terminal
initial value `single` (a deviation from CSS `none`).

Cascade order for one element:

1. initial values,
2. inherited values from the parent computed style,
3. class declarations in list order (later classes win),
4. the inline declaration (`Node.setStyle`),
5. at paint time, the same paint declarations; hover overlays last. A hover
   `visibility` declaration also applies to the hovered element's descendants,
   which is how the port expresses an upstream `.parent:hover .child` rule
   without a selector engine.

`display: contents` generates no box. Its computed layout/text/pointer values
are threaded to descendants; its inherited paint declarations are carried in a
paint delta on descendant boxes. A `display: contents` element has no hit target
of its own, so hover styling on it is not applied.

## Class IDs and the document stylesheet

Class names are integers. The document owns an **array-backed** stylesheet:

```zig
const Class = enum(u16) {
    panel = 0,
    selected = 1,
};

const styles = [_]ui.Style{
    .{ .padding = ui.EdgeDecl.all(1), .color = fg },
    .{ .background = selection, .bold = true },
};

try doc.registerSheet(.{ .base = 0, .styles = &styles });

const panel = try doc.createElement(.div);
try panel.setClasses(&.{ Class.panel, Class.selected });
```

- `Document.class_styles` is a dense `ArrayListUnmanaged(Style)`; the class ID is
  its index. Lookup is one bounds-checked array access.
- `Document.registerSheet(Sheet)` copies a batch into the array. Without a
  `base` it appends; with a `base` it grows with empty declarations and
  overwrites that range in place (theme re-registration). `Document.addStyle`
  appends one declaration and returns its ID.
- `Node.addClass`, `setClasses`, `removeClass`, `toggleClass` and `hasClass`
  accept any integer or enum name and never take a style record.
- `Document.clear()` keeps registered styles; `Document.deinit()` frees them.
- Out-of-range or unregistered IDs are ignored, like a class with no rule.
- `ui.css.mergeClasses(&doc.class_styles, classes)` returns the merged
  declaration; `Document.mergedClassStyle` is the convenience form.
- Per-side `EdgeDecl`/`MarginDecl`/`GapDecl` declarations let one class set
  `padding-left` without resetting another class's `padding-top`.

## Porting a VSCode CSS file

A port is **hand-written**. There is no `.css` reader and no generator. Put the
file next to its upstream CSS, with `_css.zig` appended to the basename:

```text
vscode/src/vs/editor/browser/viewParts/blockDecorations/blockDecorations.css
src/vs/editor/browser/viewParts/blockDecorations/blockDecorations_css.zig
```

Shape of a port:

```zig
// Port of `.../viewLines.css`.
const ui = @import("ui");

pub const base: u16 = 0x0010;

pub const Class = enum(u16) {
    view_lines = base,
    view_line = base + 1,
};

const styles = [_]ui.Style{
    .{ .white_space = .nowrap },
    .{ .position = .absolute, .width = .{ .percent = 100 } },
};

pub const sheet = ui.css.Sheet{ .base = base, .styles = &styles };
```

Rules:

- Class enum variants use Zig `snake_case`; the literal CSS class name belongs in
  a comment. Enum values must be `base + index`, matching the `styles` array.
- `base` blocks are assigned by hand and must not overlap. Current blocks are
  registered in `src/vs/editor/browser/editorCss.zig`:

  | file | base | classes |
  | --- | --- | --- |
  | `blockDecorations.css` | `0x0000` | container, block |
  | `viewLines.css` (structural) | `0x0010` | view-lines, view-line |
  | `overlayWidgets.css` | `0x0020` | overlayWidgets |
  | `sash.css` | `0x0030` | sash, vertical, horizontal, vertical minimum/maximum |
  | `folding.css` | `0x0040` | codicon-folding, codicon-folding-collapsed, alwaysShowFoldIcons |
  | `gridview.css` | `0x0050` | monaco-grid-view |
  | `splitview.css` | `0x0060` | split-view-view, hidden view |
  | `editorgroupview.css` | `0x0070` | editor-group-container, title, editor-instance, empty editor container, grid-view-container, editor group watermark and shortcut rows |
  | `editor.css` (viewport) | `0x0080` | monaco-editor, overflow-guard |
  | `searchview.css` | `0x0090` | search-view, search-widgets-container, search-widget, search/replace containers, query details and file types |
  | `searchEditor.css` | `0x00a0` | search-editor, context line input and toggle |
  | `scm.css` | `0x00b0` | commit input and split action button, Graph labels and badges |
  | Workbench `style.css` | `0x00c0` | main container, platform and modal-dialog visibility classes |
  | Workbench `part.css` | `0x00d0` | part containers, main window part names and position classes |
  | Diff editor `style.css` | `0x00e0` | unchanged-region row, drag controls, center label, compact placeholder and breadcrumbs |
  | `codelensWidget.css` | `0x00f0` | one-row CodeLens content and clickable command links |
  | `zoneWidget.css` | `0x0100` | model-anchored zone widget and frame container |
  | `peekViewWidget.css` | `0x0110` | peek header, title, actions and body |
  | Multi-diff editor `style.css` | `0x0120` | file header, disclosure, labels, actions, keyboard focus and binary placeholder |

  The multi-diff changed-files list's
  `media/multiDiffEditorWithFileList.css` is projected directly through the
  shared tree row renderer: clipped file/folder labels, one-cell spacing and
  trailing Git status color. It has no DOM row class IDs; font and selector
  rules are browser-only. Its geometry uses the shared SplitView.

- The editor registers every sheet once in `View.init` through
  `editorCss.register(document)`. `Document.clear()` preserves them.
- Theme variables (`var(--vscode-...)`) are an editor-boundary problem. A themed
  port exposes a `Colors` input and builds its `styles` outside the static table;
  the TUI resolves theme IDs and re-registers the sheet range. The first ports
  are theme-free.
- Unsupported browser-only rules are omitted with a header comment:
  `box-sizing`, `box-shadow`, `border-radius`, `user-select`, transitions,
  animations, media queries, `!important`, descendant selectors and span rules.
  A widget chooses the class records it needs; there is no selector engine.
- Keep inline geometry (position/size) where the terminal view already computes
  it; classes can still contribute the CSS declaration and are overridden by the
  inline style.

The ports attach classes in the terminal view:

- `View.block_root` and each block node (`blockDecorations_css`),
- the line-scroll content and each `ViewLine` DOM node (`viewLines_css`),
- `View.overlay_widgets_root` (`overlayWidgets_css`),
- the editor group's retained watermark and action rows (`editorgroupview_css`),
- the find widget's resize handle (`sash_css`),
- each gutter fold cell (`folding_css`); the margin root carries its
  `HoverStyle`, which reveals the hidden expanded icons while the gutter is
  hovered;
- the Search sidebar form attaches the `searchview_css` classes. Its windowed
  result rows use the stylesheet's spacing and match/replacement paint rules.
  Rounded input outlines use negotiated cell borders and fall back to a themed
  background. Browser textarea mirrors, font metrics, and high-contrast
  dashed borders have no direct terminal equivalent.

The sidebar, editor splits, diff gutter and terminal splitters use the sash
cursor declarations with their cell hit tests. The find widget attaches the
sheet's `HoverStyle` to its sash node. The sidebar and editor splits use the
same `sash.hoverBorder` declaration for native cell borders or line glyphs.
The terminal uses one-cell sash geometry. Linked orthogonal handles and the
browser's sash limit and disabled styling are outside the port.

## Examples

`ui/examples/css.zig` (`zig build example-css`, also in the gallery) shows a
local class enum and sheet, ordered merging, inherited text color/attributes, an
explicit `false`, and an inline text declaration that beats an inherited class
value.

## Native backend note

`ui.css.Sheet` and class enums are plain data. A future native renderer can
define the same enum names and values with a different `styles` array (pixel
units or a different scale) at comptime; the cascade and document table do not
depend on terminal cells. No backend parameter or px unit is added yet.

## Limitations

- No selectors/specificity, `!important`, custom properties, media queries,
  animations, transitions, pseudo-elements or unit conversion.
- `visibility` cascades and affects focusability; the cell painter still does
  not hide boxes with `visibility: hidden` (pre-existing behavior).
- `display: contents` has no hover target.
- Style arrays are owned by the document; class ID ranges are a manual registry.
- Hover remains a paint-only `Element.hover_style` overlay; there is no
  `:hover` selector pipeline. `HoverStyle.visibility` can reveal paint-hidden
  descendants while an ancestor is hovered (the folding gutter uses this for
  `.margin-view-overlays:hover .codicon`), but the library applies the
  declaration to the whole hovered subtree; it does not match selectors.
- `visibility: hidden` now skips the element's background, border and text in
  the painter; layout and hit testing are unchanged, and a descendant with
  `visibility: visible` still paints.
