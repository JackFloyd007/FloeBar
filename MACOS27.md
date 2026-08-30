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
- Hidden and always-hidden sections combine MenuBarAgent preferred-position
  bands with a runtime-loaded MenuBarClientCore visibility restriction. This
  works on wide displays where position changes alone do not cause overflow.
- Native ordering is persisted through MenuBarAgent's
  `TrailingItemPreferredPositions` preference and restored when Ice exits.
- Item images are cropped from MenuBarAgent's composite hosting window, with
  application icons used when Screen Recording is unavailable.
- Screen Recording is optional on macOS 27. Ice does not request it during
  startup or ordinary hide/reveal operations.
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
- Applying or removing the macOS visibility restriction can take about one to
  two seconds.
- Reordering restarts the system-managed MenuBarAgent process so it reloads its
  preferred positions; macOS relaunches it automatically.

## Attribution

The macOS 27 Accessibility enumeration, assessment-mode bridge, and
MenuBarAgent preference approach were adapted from the GPLv3
[Thaw project](https://github.com/thaw-app/Thaw). Ice and these changes remain
licensed under GPL-3.0.
