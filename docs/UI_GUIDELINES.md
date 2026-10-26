# UI guidelines

Ctrl+Calm should look like a quiet, well-made RAD Studio tool window: the sounds and their
levels dominate, everything else recedes.

## Principles

- **Calm first.** No motion animation, no gradients, no badges competing for attention.
  Feedback is immediate and static: fill, border, weight and a small status mark.
- **State is never color-only.** An active tile has an accent fill *and* a 1.5 px accent
  border, a bold name, a check mark and a visible level bar. A paused ("armed") tile keeps
  its border and bar but shows pause bars instead of the check. An unavailable tile shows a
  warning mark and the word "Unavailable".
- **The IDE's theme is the base.** `BuildPalette` derives background, surfaces, borders and
  text from the IDE's style services and adds one restrained accent (forest green by
  default; ocean teal, soft blue, warm amber, muted violet, or the IDE's own highlight).
  Windows high contrast replaces everything with system colors.
- **Nothing is fixed in pixels.** All metrics are 96-DPI values scaled with `CurrentPPI`
  (`S()` in `TCalmControl`); icons are vectors drawn with GDI+ at the exact target size.

## Layout

`TCalmMixerView.Relayout` positions everything from the client width in 96-DPI units:

| Mode | Width | Header | Tiles |
|---|---|---|---|
| Compact | < 300 | two rows (brand + timer/settings; transport + master) | full-width rows (icon, name, level bar on the right), up to 2 columns |
| Comfort | 300-560 | one row, or two rows when the master slider would be shorter than 110 | cards, min. 112 wide, columns from width |
| Expanded | >= 560 | one row | cards, min. 136 wide, larger spacing, column count chosen to avoid a ragged last row |

The mode can be pinned in Settings > Appearance. Presets wrap as chips; the timer is a
collapsible card between presets and tiles; a one-line status footer is always visible.

## Interaction

- Click a tile body to toggle; drag its level bar (only shown when active) to set the level;
  mouse wheel over an active tile changes its level by 5 %.
- Keyboard: Tab moves between controls, Space/Enter toggles, arrows change the level
  (Shift for bigger steps), the context-menu key opens a mix's menu.
- Clicking a sound while paused starts playback (an explicit request to hear it).
- Saving a mix needs no dialog (it is named "My mix N"); renaming uses a small prompt from the
  chip's context menu. Built-in presets (dot) and your favorites (star) are distinct.
- Every control has a tooltip; the status footer explains the current state and problems
  (device lost, settings not saved).

## Icons

`CtrlCalm.UI.Icons` holds 16 original sound icons and the UI glyphs, drawn on a 24 x 24 grid
with 1.6-unit round strokes (1.9 below 20 px). They are not derived from any third-party
icon set. Keep new icons in the same grid, stroke weight and visual density.
