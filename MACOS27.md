# macOS 27 compatibility

This fork contains an experimental compatibility layer for macOS 27, where
menu bar items are no longer exposed as independent WindowServer windows.

## What changed

- Menu bar items are discovered through each running application's
  `AXExtrasMenuBar` accessibility tree.
- Stable synthetic IDs preserve layout assignments across refreshes and app
  relaunches.
- Hidden and always-hidden sections use a runtime-loaded MenuBarClientCore
  assessment-mode assertion instead of oversized divider windows.
- Native ordering is persisted through MenuBarAgent's
  `TrailingItemPreferredPositions` preference.
- Item images are cropped from MenuBarAgent's composite hosting window, with
  application icons used when Screen Recording is unavailable.
- The obsolete macOS 26 item-attribution XPC service is not started on macOS 27.

## Limitations

- The hiding API is private and loaded defensively at runtime. A later macOS 27
  beta may rename or remove it; Ice then keeps the layout editor available but
  cannot conceal items.
- Third-party hiding is bundle-granular. If one application publishes multiple
  status items, Ice keeps the whole bundle visible when any sibling is assigned
  to the Visible section.
- Only the nine system items exposed by Apple's internal system-item allowlist
  can be hidden independently. Other MenuBarAgent extras, including Now Playing
  and Audio/Video, remain visible to avoid hiding unrelated system items.
- Reordering restarts the system-managed MenuBarAgent process so it reloads its
  preferred positions; macOS relaunches it automatically.

## Attribution

The macOS 27 Accessibility enumeration, assessment-mode bridge, and
MenuBarAgent preference approach were adapted from the GPLv3
[Thaw project](https://github.com/thaw-app/Thaw). Ice and these changes remain
licensed under GPL-3.0.
