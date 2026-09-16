# Ice Eric distribution

This fork is distributed independently from the upstream Ice project.

## Identity

- App bundle identifier: `io.github.jackfloyd007.IceEric`
- XPC bundle identifier: `io.github.jackfloyd007.IceEric.MenuBarItemService`
- Apple Developer team: `JD8S6QP43G`
- Sparkle keychain account: `Ice_eric`
- Sparkle feed: `https://github.com/JackFloyd007/Ice_eric/releases/latest/download/appcast.xml`

The Sparkle private key stays in the maintainer's login keychain. Never commit
an exported private key to this repository.

## Release checklist

1. Increment both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.
2. Archive the `Ice` scheme in Release configuration with the Developer ID
   Application certificate and hardened runtime enabled.
3. In Xcode Organizer, select Custom > Direct Distribution > Upload to send the
   archive to Apple's notary service.
4. Export the notarized app and verify it with:

   ```sh
   codesign --verify --deep --strict --verbose=4 Ice.app
   spctl --assess --type execute --verbose=4 Ice.app
   xcrun stapler validate Ice.app
   ```

5. Create a ZIP with `ditto -c -k --keepParent Ice.app Ice-<version>.zip`.
6. Generate `appcast.xml` with Sparkle's `generate_appcast`, using
   `--account Ice_eric` and the tag-specific GitHub Release download URL as
   `--download-url-prefix`.
7. Upload both the ZIP and `appcast.xml` to the matching GitHub Release. Keep
   the exact source tag public to satisfy GPLv3 source-distribution obligations.
8. Verify that `releases/latest/download/appcast.xml` resolves successfully and
   that a previous release can discover, verify, and install the update.

