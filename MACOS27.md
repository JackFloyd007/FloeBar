# macOS 27 compatibility

This fork contains an experimental compatibility layer for macOS 27, where
menu bar items are no longer exposed as independent WindowServer windows.

## What changed

- Menu bar items are discovered through each running application's
  `AXExtrasMenuBar` accessibility tree.
- Stable synthetic IDs preserve layout assignments across refreshes and app
  relaunches.
- Clicking Ice's permanent menu-bar button toggles only the items assigned to
  Hidden or Always Hidden. Ice itself and the core system controls stay visible.
- Clicking empty menu-bar space does not toggle sections on macOS 27, even if
  an older Ice installation left `Show on click` enabled. The permanent Ice
  button is the only menu-bar click target for revealing or concealing items.
- Hidden and always-hidden sections use a runtime-loaded MenuBarClientCore
  visibility restriction. Replacement restrictions overlap briefly so the
  menu bar is never unrestricted between hide and reveal states.
- Ice's permanent control item is placed through MenuBarAgent's
  `TrailingItemPreferredPositions` preference at the boundary between Visible
  and Hidden. Positions remain stable while toggling, avoiding icon movement.
- The legacy Hidden and Always-Hidden divider status items are not published on
  macOS 27. The permanent Ice toggle is the only Ice item in the menu bar, so
  section changes do not create duplicate icons or reserve empty slots.
- Item images are cropped from MenuBarAgent's composite hosting window, with
  Accessibility-derived menu bar symbols and text used when Screen Recording
  is unavailable. The layout never substitutes the owning application's icon.
- Screen Recording is optional on macOS 27. Ice does not request it during
  startup or ordinary hide/reveal operations, and permission checks are cached
  instead of polling TCC on every layout refresh.
- The obsolete macOS 26 item-attribution XPC service is not started on macOS 27.

## Limitations

- The hiding API is private and loaded defensively at runtime. A later macOS 27
  update may rename or remove it; Ice then fails open instead of collapsing the
  menu bar.
- Third-party hiding is bundle-granular. If one application publishes multiple
  status items, Ice keeps the whole bundle visible when any sibling is assigned
  to the Visible section.
- Only the nine system items exposed by Apple's internal system-item allowlist
  can be controlled independently. While a hidden section is concealed, the
  attached Now Playing and Audio/Video extras follow macOS's visibility
  restriction and may temporarily disappear; revealing the section restores
  them.
- Revealing a section waits briefly for its replacement visibility restriction
  to activate before retiring the old one. This prevents full-bar flicker.
- Reordering restarts the system-managed MenuBarAgent process so it reloads its
  preferred positions; macOS relaunches it automatically.

## Attribution

The macOS 27 Accessibility enumeration, assessment-mode bridge, and
MenuBarAgent preference approach were adapted from the GPLv3
[Thaw project](https://github.com/thaw-app/Thaw). Ice and these changes remain
licensed under GPL-3.0.
