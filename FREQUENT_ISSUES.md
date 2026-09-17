# Frequent issues

## A newly launched item appears in Always Hidden

macOS normally inserts a new status item at the far left of the menu bar. That
position may be inside FloeBar's always-hidden section. Some apps recreate their
status item each time they launch, so macOS treats it as new even after you moved
it previously.

Reveal the always-hidden section, then hold Command and drag the item to the
section you want. FloeBar does not silently rewrite another app's saved menu bar
position.

## An item seems to have disappeared

FloeBar does not remove third-party menu bar items. Reveal both hidden sections
and look for the item at the far left. If it remains missing, quit and reopen the
app that owns the item.

## FloeBar does not remember an item's order

Some apps destroy and recreate their status items or publish changing labels.
FloeBar preserves stable identities where macOS exposes them, but cannot reliably
restore every dynamically recreated item. Include the owning app and FloeBar
version when filing an issue.

## Layout reports that the menu bar is automatically hidden

FloeBar cannot safely arrange a menu bar that macOS is currently hiding:

1. Open **System Settings**.
2. Open **Control Center**.
3. Set **Automatically hide and show the menu bar** to **Never**.
4. Arrange items in FloeBar's **Menu Bar Layout**.
5. Restore your preferred automatic-hiding setting.

## Layout shows blurred or missing previews

Grant Screen Recording permission to FloeBar, quit it completely, and reopen it.
The permission is optional for basic hiding but required for pixel-accurate menu
bar previews. FloeBar falls back to a named placeholder when macOS cannot provide
a usable image.
