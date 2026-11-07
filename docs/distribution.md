# FloeBar distribution

FloeBar is distributed independently from the upstream Ice project.

## Identity

- App bundle identifier: `io.github.jackfloyd007.IceEric` (retained for update and permission continuity)
- XPC bundle identifier: `io.github.jackfloyd007.IceEric.MenuBarItemService`
- Apple Developer team: `JD8S6QP43G`
- Sparkle keychain account: `FloeBar-release-20261107` (1367 onward)
- Sparkle feed: `https://github.com/JackFloyd007/FloeBar/releases/latest/download/appcast.xml`

The Sparkle private key stays in the maintainer's login keychain. Never commit
an exported private key to this repository. The former `Ice_eric` key is not
available on the current Mac; preserve any historical backups of it.

## Initial 2026-11-07 closeout

The accepted development candidate is `0.13.0-macos27.37-dev (1366)`.
Its source matches the frozen validation manifest and its local package uses
Apple Development signing. At this checkpoint the Mac had no valid Developer ID Application
identity and no notarytool credential profile named `FloeBar`.

The maintainer chose to supply those credentials before publishing a formal
automatic update. Source closeout can proceed independently. Keep the current
public release and Sparkle feed unchanged until the checklist below passes;
do not publish the development package as a notarized release. The accepted
1366 app and existing evidence remain preserved under the ignored `build/` tree.

Import the project's Developer ID Application identity, including its private
key, into the login keychain and configure notarytool credentials under the
profile name `FloeBar`. Keep all secrets local. Prepare a new release version
and build number after credentials are available, then follow the checklist.

## Release checklist

### Release 1367 evidence (2026-11-07)

Version `0.13.0-macos27.38 (1367)` preserves the accepted 1366 application logic.
Only the app version/build and embedded Sparkle public key changed for release.

- The new Developer ID Application identity belongs to the existing team
  `JD8S6QP43G`; the exported app passes the original public 1330 app's designated
  requirement. Main app and XPC contain both arm64 and x86_64.
- Apple accepted notarization request `f624d568-a99e-4563-a3ca-96b2939852bc`.
  Stapling, ticket validation, all-architecture deep/strict code verification and
  Gatekeeper assessment passed (`Notarized Developer ID`).
- New Sparkle public key: `xkS5evxhe/vWIC9gmngVsibq/Dzc74vjVSFBn6ACmv8=`.
  The private key is held only in the login keychain under
  `FloeBar-release-20261107`. The old public key is retained in historical 1330
  packages. Full ZIP updates use the existing Apple signing trust for rotation.
- Actual Sparkle 2.8 `SUUpdateValidator` accepted the new archive and rejected a
  corrupted signature; the original public key rejected the new signature as
  expected. `SUPlainInstaller` updated an isolated 1330 copy to 1367 with the
  expected public key and valid code signature.
- Actual Sparkle 2.8 appcast parsing, stable-channel and OS filtering selected
  1367 for 1330 with the exact final ZIP URL/length and no delta. This is native
  discovery/validation/file-installation evidence, not a test of the current
  user's updater UI, quit or relaunch. No FloeBar process was launched or replaced
  during these tests; current preferences, TCC and hiding journal were preserved.

Final ZIP SHA256:
`cfed9a35d2de79a9de9e4dca48c580a2f2f7c08c9ef747f0bc024844fd6f4faa`.
Detailed local evidence is under the ignored `build/release-1367/` directory.
The official 2.8 appcast generator was built from an isolated source copy with
only its cache location changed to that external directory; signing and update
validation logic were unchanged.

### Publishing procedure

1. Increment both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.
2. Archive the `FloeBar` scheme in Release configuration with the Developer ID
   Application certificate and hardened runtime enabled.
3. In Xcode Organizer, select Custom > Direct Distribution > Upload to send the
   archive to Apple's notary service.
4. Export the notarized app and verify it with:

   ```sh
   codesign --verify --deep --strict --verbose=4 FloeBar.app
   spctl --assess --type execute --verbose=4 FloeBar.app
   xcrun stapler validate FloeBar.app
   ```

5. Create a ZIP with `ditto -c -k --keepParent FloeBar.app FloeBar-<version>.zip`.
6. Generate `appcast.xml` with Sparkle's `generate_appcast`, using
   `--account FloeBar-release-20261107` and the tag-specific GitHub Release download URL as
   `--download-url-prefix`.
7. Upload both the ZIP and `appcast.xml` to the matching GitHub Release. Keep
   the exact source tag public to satisfy GPLv3 source-distribution obligations.
8. Verify that `releases/latest/download/appcast.xml` resolves successfully and
   that a previous release can discover, verify, and install the update.
