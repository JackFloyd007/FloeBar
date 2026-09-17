<div align="center">
  <img src="FloeBar/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="180" height="180" alt="FloeBar app icon">
  <h1>FloeBar</h1>
  <p>A calm, capable menu bar organizer for macOS.</p>
</div>

<div align="center">

[![Download](https://img.shields.io/badge/download-latest-1677ff?style=flat-square)](https://github.com/JackFloyd007/FloeBar/releases/latest)
![Platform](https://img.shields.io/badge/platform-macOS-111827?style=flat-square)
![Requirements](https://img.shields.io/badge/requires-macOS%2014%2B-0ea5e9?style=flat-square)
[![License](https://img.shields.io/github/license/JackFloyd007/FloeBar?style=flat-square)](LICENSE)

</div>

FloeBar keeps a crowded Mac menu bar under control. Hide items you rarely need,
reveal them with one click, arrange them visually, search them, and customize the
menu bar without replacing the native macOS experience.

> [!NOTE]
> FloeBar is an independently maintained GPLv3 fork of
> [Ice](https://github.com/jordanbaird/Ice) by Jordan Baird. It is not affiliated
> with or endorsed by the upstream project. See [NOTICE.md](NOTICE.md) for full
> attribution.

## Install

1. Download the latest `FloeBar-*.zip` from
   [GitHub Releases](https://github.com/JackFloyd007/FloeBar/releases/latest).
2. Open the ZIP and move `FloeBar.app` to `/Applications`.
3. Launch FloeBar and grant Accessibility permission when prompted.
4. Grant Screen Recording permission only if you want exact menu bar previews
   and the separate Floe Bar panel.

FloeBar release builds are signed with Developer ID, notarized by Apple, and
update through their own Sparkle feed. They do not use the original Ice update
channel.

## Features

- Hide and reveal menu bar items in visible, hidden, and always-hidden sections.
- Arrange supported items with a visual drag-and-drop layout.
- Search menu bar items and trigger configurable hotkeys.
- Show hidden items in a separate Floe Bar panel.
- Customize menu bar tint, shape, shadow, border, and item spacing.
- Launch at login and receive signed automatic updates.
- Native macOS 27 compatibility for menu bar discovery and section boundaries.

## Permissions and privacy

FloeBar does not collect or transmit personal data.

- **Accessibility** is required to discover and arrange menu bar items.
- **Screen Recording** is optional and is used only to render the real appearance
  of menu bar items in Layout and the Floe Bar.

Permissions stay on the Mac and can be revoked at any time in System Settings.

## Compatibility

FloeBar requires macOS 14 or later. The maintained branch includes a dedicated
macOS 27 path that avoids global input interception and fails open when the
native menu bar boundary cannot be verified. Known limitations and technical
validation are documented in [MACOS27.md](MACOS27.md).

## Build from source

Requirements:

- macOS 14 or later
- Current Xcode with the macOS SDK
- SwiftLint, if you want to run the same lint step as CI

Open `FloeBar.xcodeproj`, select the `FloeBar` scheme, and build. Swift package
dependencies are resolved by Xcode. Release signing and notarization instructions
are in [docs/distribution.md](docs/distribution.md).

## Contributing

Bug reports and focused pull requests are welcome. Read
[CONTRIBUTING.md](CONTRIBUTING.md) before opening a change, and report security
issues according to [SECURITY.md](SECURITY.md).

## License and attribution

FloeBar is distributed under the [GNU General Public License v3.0](LICENSE).
Modified versions and binaries must continue to satisfy GPLv3, including source
availability and preservation of applicable copyright notices.

FloeBar modifications are copyright © 2026 JackFloyd007. Portions are copyright
© 2024–2025 Jordan Baird and other Ice contributors.
