#!/bin/bash
# Pure regression checks only: no menu-bar clicks, settings changes or AX access.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/floebar-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
compile_and_run() {
    local name=$1
    shift
    xcrun swiftc -O -module-cache-path "$TEST_DIR/cache" "$@" "Tests/$name.swift" -o "$TEST_DIR/$name"
    "$TEST_DIR/$name"
}
compile_and_run NativeOverflowLabelsTests FloeBar/MenuBar/MenuBarItems/NativeOverflowLabels.swift
compile_and_run PrivateHidingPlanTests FloeBar/MenuBar/Experimental/PrivateHidingPlan.swift
xcrun clang -fobjc-arc -c Tests/Support/PrivateLeaseFixture.m -o "$TEST_DIR/lease.o"
compile_and_run PrivateLeaseCallbackTests -import-objc-header Tests/Support/PrivateLeaseFixture.h FloeBar/MenuBar/Experimental/ExperimentalPrivateHiding.swift "$TEST_DIR/lease.o"
compile_and_run MenuBarCaptureGeometryTests FloeBar/Utilities/MenuBarCaptureGeometry.swift
compile_and_run MenuBarGlyphImageTests FloeBar/MenuBar/LayoutBar/MenuBarGlyphImage.swift
compile_and_run NativeMenuBarBoundaryTests FloeBar/MenuBar/MenuBarItems/MacOS27NativeBoundary.swift
compile_and_run NativeDragVisibilityStateTests FloeBar/MenuBar/MenuBarItems/MacOS27NativeBoundary.swift
compile_and_run MacOS27DynamicItemStateTests FloeBar/MenuBar/MenuBarItems/MacOS27DynamicItemState.swift
compile_and_run MacOS27LayoutOwnerTests FloeBar/MenuBar/MenuBarItems/MacOS27DynamicItemState.swift
compile_and_run NativeInteractionTests FloeBar/MenuBar/MenuBarItems/NativeMenuBarInteraction.swift FloeBar/MenuBar/MenuBarItems/NativeMenuBarSnapshot.swift FloeBar/MenuBar/MenuBarItems/MacOS27DynamicItemState.swift
compile_and_run NativeMenuBarScanTests FloeBar/MenuBar/MenuBarItems/NativeMenuBarScan.swift FloeBar/MenuBar/MenuBarItems/NativeMenuBarScanAttributes.swift
compile_and_run NativeReorderVerificationTests FloeBar/MenuBar/MenuBarItems/NativeReorderVerification.swift
compile_and_run NativeDragSessionTests FloeBar/MenuBar/MenuBarItems/NativeMenuBarDragSession.swift
compile_and_run NativeReorderPlanTests FloeBar/MenuBar/MenuBarItems/NativeReorderPlan.swift
compile_and_run DisplayLayoutTests Tests/Support/NativeModelStubs.swift FloeBar/MenuBar/MenuBarItems/MenuBarItemTag.swift FloeBar/MenuBar/MenuBarItems/MacOS27DynamicItemState.swift FloeBar/MenuBar/MenuBarItems/MacOS27NativeBoundary.swift FloeBar/MenuBar/MenuBarItems/MacOS27MenuBarController.swift
compile_and_run SystemAppVisibilityReadbackTests FloeBar/MenuBar/SystemAppVisibilityReadback.swift FloeBar/MenuBar/SystemAppVisibilityModel.swift FloeBar/MenuBar/SystemAppVisibilityGroup.swift
compile_and_run SystemAppVisibilityModelTests FloeBar/MenuBar/SystemAppVisibilityModel.swift FloeBar/MenuBar/SystemAppVisibilityGroup.swift
compile_and_run SystemAppSelectionEditTests FloeBar/MenuBar/SystemAppSelectionEdit.swift FloeBar/MenuBar/SystemAppVisibilityModel.swift FloeBar/MenuBar/SystemAppVisibilityGroup.swift
compile_and_run MenuBarItemDisplayLabelTests FloeBar/MenuBar/LayoutBar/MenuBarItemDisplayLabel.swift FloeBar/MenuBar/MenuBarItems/MacOS27DynamicItemState.swift
compile_and_run SystemAppVisibilityGroupTests FloeBar/MenuBar/SystemAppVisibilityModel.swift FloeBar/MenuBar/SystemAppVisibilityGroup.swift
compile_and_run SystemAppInstallationProofTests FloeBar/MenuBar/SystemAppVisibilityModel.swift FloeBar/MenuBar/SystemAppVisibilityGroup.swift FloeBar/MenuBar/SystemAppInstallationProof.swift
compile_and_run SystemAppVisibilityBackendTests FloeBar/MenuBar/SystemAppVisibilityModel.swift FloeBar/MenuBar/SystemAppVisibilityGroup.swift FloeBar/MenuBar/SystemAppInstallationProof.swift FloeBar/MenuBar/SystemAppVisibilityBackend.swift FloeBar/MenuBar/SystemAppVisibilityReadback.swift FloeBar/MenuBar/SystemMenuBarFilePolicy.swift FloeBar/MenuBar/SystemAppSelectionEdit.swift Tests/Support/VisibilityBackendStubs.swift
compile_and_run SystemMenuBarFilePolicyTests FloeBar/MenuBar/SystemMenuBarFilePolicy.swift
compile_and_run ApplicationLaunchPolicyTests FloeBar/Main/ApplicationLaunchPolicy.swift
compile_and_run GracefulTerminationTests FloeBar/MenuBar/Spacing/GracefulApplicationTermination.swift
compile_and_run DeferredPresentationTests FloeBar/UI/Utilities/DeferredPresentation.swift
compile_and_run PermissionRecoveryTests FloeBar/Permissions/Permission.swift FloeBar/Permissions/AppPermissions.swift
compile_and_run MenuBarPreviewAuthorizationTests FloeBar/Utilities/MenuBarPreviewAuthorization.swift
compile_and_run AppearanceLifecycleTests FloeBar/MenuBar/Appearance/MenuBarAppearanceManager.swift
compile_and_run HotkeyLifecycleTests -target "$(uname -m)-apple-macos14.0" FloeBar/Hotkeys/Hotkey.swift FloeBar/UI/Views/HotkeyRecorder.swift
compile_and_run AverageColorTests FloeBar/Utilities/CGImage+AverageColor.swift
compile_and_run MenuBarOverlayGeometryTests FloeBar/MenuBar/Appearance/MenuBarOverlayGeometry.swift
xcrun clang -c Tests/SpaceTypeBridgeFixture.c -o "$TEST_DIR/space.o"
compile_and_run SpaceTypeBridgeTests Shared/Bridging/Shims.swift "$TEST_DIR/space.o"
python3 scripts/check-localizations.py
