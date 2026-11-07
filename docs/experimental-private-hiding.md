# Experimental private hiding (1333)

User authorized a default-off, separately accepted private hiding mode on 2026-09-20.
This supersedes the earlier decision to reject integrating an assessment assertion,
without superseding the observed limitations in assessment-isolation-2026-09-05.md.

## Contract

- Advanced > Experimental private hiding > Enable for this session. Memory-only;
  every launch starts disabled. Normal compatibility mode is unchanged when off.
- FloeBar's own arrow applies the hidden/always-hidden selection. No synthetic
  overflow click, clock forwarding, global input interception or system preference edit.
- MenuBarClientCore is runtime-loaded only on an opted-in activation. This is an
  undocumented menu-bar assertion, not a whole-computer assessment session.
- Hide only whole third-party application bundles. Reject empty plans, unknown
  hidden owners and bundles split across visible/hidden. Apple and own items are
  excluded from the hide request and always allowlisted.
  Keep running apps and protected system hosts on the allowlist; system item IDs
  0 through 8 follow the isolated probe, not a documented compatibility guarantee.
- Activation timeout 3 seconds; automatic release after 45 seconds from request.
  API completion means assertion active, not verified concealment.
- Release on show, disable, layout editing, opening settings, application launch/
  termination, sleep, space/display changes and FloeBar termination. Stale
  activation completion invalidates its exact old lease again. No automatic retry.
- Preserve cached assignments while the assertion changes physical layout.

## Acceptance boundary

Build, signing, bundle-plan regression and translation checks are separate from
runtime acceptance. Verify actual hidden AND allowed icons, own arrow reveal,
clock, native overflow, Control Center, timeout, disable and restart. A private
API callback alone never passes those checks. Clock failure or overbroad hiding
means runtime acceptance fails, even if recovery succeeds. Keep disabled afterward.

This interface is unsupported by Apple and unsuitable for an App Store build.
The public NSStatusItem expanded-interface APIs manage an item's own popup;
they do not supply cross-application hiding. No claim of macOS 27-wide or older
OS runtime compatibility follows from compiling against Xcode 27.

## Local acceptance, 2026-09-20 (macOS 27.0 / 26A428)

- Release universal build 1333, Developer ID signature and compiled nine-language
  catalog (210 keys): passed. Pure regression suite, including bundle conflicts,
  unknown ownership and protected hosts: passed.
- Advanced switch off on launch and opt-in without activation: passed.
- Own arrow activated the assertion; ChatGPT/Notion/Figma/WPS/WeChat icons were
  removed while Stats, CodexBar, password, Spotlight, Wi-Fi, battery and clock
  remained available in the native AX tree. Own arrow released the assertion and
  returned the hidden app entries. Screenshot with system overflow expanded
  confirmed physical concealment and preservation of the FloeBar arrow.
- Native overflow double-chevron remains. When system overflow is collapsed,
  even allowlisted entries including FloeBar can remain within it. This mode
  does not override system overflow placement or claim to remove its control.
- Clock click while active returned no clear notification-panel evidence; the
  Notification Center AX window was a desktop weather widget. This is NOT proof
  of a working clock and NOT a conclusive new clock-failure diagnosis.
- Automatic 45-second release, immediate restore button, disabling an active
  assertion and restart from an enabled session back to disabled: passed in UI.
- Focus mode was absent from the settled active AX tree despite retaining Apple
  bundles/system IDs. The private interface can affect system extras outside our
  hide targets. The UI explicitly warns that system controls may be affected.
- Full native-input compatibility acceptance therefore remains **not passed**.
  Multi-display, sleep, late completions and old macOS runtime paths were not
  exercised interactively in this run. Final installed experimental switch: off.

## Implementation references

Runtime selector knowledge: repository Tests/NativeAssessmentVisibilityProbe.m
(Thaw-derived diagnostic) and https://github.com/fif7y/pelmet . The new bridge is
minimal runtime invocation code; the reference's clock click relay is not included.

## Delivery

Installed `/Applications/FloeBar.app`, version `0.13.0-macos27.4-dev (1333)`.
Developer ID signed, universal arm64/x86_64, not notarized/published.
Backup: `build/backups/FloeBar-1332-before-private-mode.app`.
ZIP: `build/FloeBar-0.13.0-macos27.4-dev.zip`.
SHA-256: `441463bf4d1413a0d585e2f5c91204af49b447354b642ab7f82509cf5d3ee415`.
Logs: `build/verification/developer-id-build-1333.log`, `tests-1333.log`.
Final UI verified the updated limitation text and session toggle OFF.
