#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

# Builds Islet, assembles the .app bundle, signs it and (with --install)
# installs it into /Applications.
#
# The bundle is staged in a temporary directory outside ~/Documents: folders synced
# by File Provider gain xattrs (com.apple.provenance etc.) that invalidate codesign.
set -euo pipefail
cd "$(dirname "$0")"

# The icon catalog and the bundle are staged in temp dirs; sweep both however
# the script ends.
ICON_TMP=""
STAGE_TMP=""

cleanup() {
    [[ -n "$ICON_TMP" ]] && rm -rf "$ICON_TMP"
    [[ -n "$STAGE_TMP" ]] && rm -rf "$STAGE_TMP"
    return 0
}
trap cleanup EXIT
# zsh runs the EXIT trap when the script is hung up, but not when it is
# interrupted or terminated; route those through exit so a Ctrl-C partway
# into the build sweeps like any other ending.
trap 'exit 1' INT TERM HUP

# Flags: --dev builds the local-only "Islet (Developer)" variant (its own
# bundle id, so it coexists with the official app); --install puts it in /Applications.
DEV=0
INSTALL=0
TEST=0
TEST_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --dev)     DEV=1 ;;
        --install) INSTALL=1 ;;
        --test)    TEST=1 ;;
        --test-suite=*) TEST=1; TEST_ARGS+=("--suite=${arg#*=}") ;;
        --list-tests) TEST=1; TEST_ARGS+=(--list) ;;
    esac
done

if (( DEV )); then
    APP_NAME="Islet (Developer)"
    EXECUTABLE="IsletDeveloper"
    APP_BUNDLE_ID="com.islet.utils.dev"
    BUILD_VARIANT_FLAGS=(-D ISLET_DEVELOPMENT)
    APP_OPTIMIZATION_FLAGS=(-Onone)
    BUILD_CONFIGURATION="debug"
else
    APP_NAME="Islet"
    EXECUTABLE="Islet"
    APP_BUNDLE_ID="com.islet.utils"
    BUILD_VARIANT_FLAGS=()
    APP_OPTIMIZATION_FLAGS=(-O)
    BUILD_CONFIGURATION="release"
fi
FAN_HELPER_ID="$APP_BUNDLE_ID.fan-control"
# Now Playing is read through /usr/bin/perl loading this library; see
# Sources/NowPlayingAdapter. Staged under Contents/Frameworks, signed on its own.
NOW_PLAYING_ADAPTER_ID="$APP_BUNDLE_ID.now-playing"
NOW_PLAYING_ADAPTER="libIsletNowPlaying.dylib"
TARGET="arm64-apple-macosx14.0"
ENTITLEMENTS="Resources/Islet.entitlements"
LEGACY_IDENTITY="Islet Utils Signing"

developer_id_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' \
        | head -1 \
        | sed -E 's/.*"(.*)".*/\1/' || true
}

# A find-identity listing also names certificates codesign then rejects (an
# expired one fails the build with errSecInternalComponent), and -v excludes
# every self-signed one; ask codesign itself with a throwaway copy of /bin/echo.
legacy_identity_installed() {
    local probe signed=1
    # A locked keychain still lists its identities but cannot sign with them,
    # and this one is locked after every reboot; unlock it before asking.
    security unlock-keychain -p islet-signing \
        "$HOME/Library/Keychains/islet-signing.keychain-db" 2>/dev/null || true
    probe="$(mktemp)"
    cp /bin/echo "$probe"
    /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$probe" \
        >/dev/null 2>&1 && signed=0
    rm -f "$probe"
    return $signed
}

# Any build that lands in /Applications needs a stable signature, not just the
# Developer one: macOS ties Accessibility and Screen Recording grants to the
# exact binary hash, so an ad-hoc rebuild orphans them while System Settings
# keeps showing them as granted, and no new prompt ever appears. A plain
# --install strands them under the released bundle id, on the app the user
# actually relies on. When no identity is installed, create the stable local one
# up front instead of falling through to ad-hoc — setup-signing.sh is free,
# offline and idempotent. Gating on the install rather than the variant keeps
# this off CI, where neither ci.yml nor release.yml passes --install.
if (( DEV || INSTALL )) && [[ -z "$(developer_id_identity)" ]] \
    && ! legacy_identity_installed; then
    echo "▸ No signing identity installed; creating the stable local one…"
    if ! ./Tools/setup-signing.sh; then
        echo "  ⚠ Tools/setup-signing.sh failed; signing ad-hoc instead." >&2
        echo "    Accessibility and Screen Recording grants will not survive rebuilds:" >&2
        echo "    System Settings will show them as granted while the app is not trusted." >&2
        echo "    After fixing the identity, clear the stale grant once with:" >&2
        echo "      tccutil reset Accessibility $APP_BUNDLE_ID" >&2
    fi
fi

codesign_with_timestamp_retry() {
    local attempt
    for attempt in 1 2 3; do
        if /usr/bin/codesign "$@"; then
            return 0
        fi
        if (( attempt < 3 )); then
            echo "  Developer ID signing failed; retrying ($((attempt + 1))/3)"
            sleep "$attempt"
        fi
    done
    return 1
}

write_swift_output_file_map() {
    local output_file="$1"
    local object_dir="$2"
    shift 2
    local source artifact

    {
        print -r -- "{"
        print -r -- "  \"\": {"
        print -r -- "    \"swift-dependencies\": \"$object_dir/master.swiftdeps\""
        print -r -- "  }"
        for source in "$@"; do
            artifact="${source//\//__}"
            artifact="${artifact%.swift}"
            print -r -- ","
            print -r -- "  \"$source\": {"
            print -r -- "    \"object\": \"$object_dir/$artifact.o\","
            print -r -- "    \"swift-dependencies\": \"$object_dir/$artifact.swiftdeps\""
            print -r -- "  }"
        done
        print -r -- "}"
    } > "$output_file"
}

finalize_installed_bundle_after_child() {
    local bundle="$1"
    local helper="$bundle/Contents/Library/LaunchServices/$FAN_HELPER_ID"
    local adapter="$bundle/Contents/Frameworks/$NOW_PLAYING_ADAPTER"
    local devid
    devid="$(developer_id_identity)"

    echo "▸ Finalizing installed signature…"
    sleep 3
    if [[ -n "$devid" ]]; then
        [[ -f "$helper" ]] && codesign_with_timestamp_retry --force --strip-disallowed-xattrs \
            --options runtime --timestamp --identifier "$FAN_HELPER_ID" --sign "$devid" "$helper"
        [[ -f "$adapter" ]] && codesign_with_timestamp_retry --force --strip-disallowed-xattrs \
            --options runtime --timestamp --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$devid" "$adapter"
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$devid" "$bundle"
    elif legacy_identity_installed; then
        [[ -f "$helper" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$FAN_HELPER_ID" --sign "$LEGACY_IDENTITY" "$helper"
        [[ -f "$adapter" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$LEGACY_IDENTITY" "$adapter"
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$bundle"
    else
        [[ -f "$helper" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$FAN_HELPER_ID" --sign - "$helper"
        [[ -f "$adapter" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign - "$adapter"
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign - "$bundle"
    fi
    [[ -f "$helper" ]] && /usr/bin/codesign --verify --strict "$helper"
    [[ -f "$adapter" ]] && /usr/bin/codesign --verify --strict "$adapter"
    /usr/bin/codesign --verify --deep --strict "$bundle"
    echo "✓ Signature ready: $bundle"
}

if (( INSTALL && ! TEST )) && [[ "${ISLET_INSTALL_CHILD:-0}" != "1" ]]; then
    ISLET_INSTALL_CHILD=1 "$0" "$@"
    child_status=$?
    if (( child_status != 0 )); then
        exit "$child_status"
    fi
    finalize_installed_bundle_after_child "/Applications/$APP_NAME.app"
    exit 0
fi

# Prefer the macOS 26 SDK when present: the 27 SDK turns SwiftUI property wrappers
# into macros (SwiftUIMacros plugin) that the Command Line Tools cannot load yet.
PINNED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    SDK="$(xcrun --show-sdk-path)"
elif [[ -d "$PINNED_SDK" ]]; then
    SDK="$PINNED_SDK"
else
    SDK="$(xcrun --show-sdk-path)"
fi
SDK_COMPAT_FLAGS=()
VM_STATISTICS_COMPAT_FLAGS=(-I Sources/VMStatisticsCompat)
HID_EVENT_SYSTEM_FLAGS=(-I Sources/HIDEventSystem)
if [[ "$SDK" == "$PINNED_SDK" ]]; then
    # Swift 6.4 can read the SDK 26 interfaces when given their compiler version.
    SDK_COMPAT_FLAGS=(-Xfrontend -interface-compiler-version -Xfrontend 6.3.2)
fi

# The defaults migrations under test need a real UserDefaults suite, and every
# suite leaves an empty plist in ~/Library/Preferences. The tests already clear
# the domains, but cfprefsd writes the emptied file back out around the time the
# process that owned it exits, so only a caller that outlives the run can remove
# them. `PreferenceNamespaceTests` scans every compiled Swift test file against
# these namespaces, which keeps this sweep complete without a second list.
discard_test_preferences() {
    local preferences="${1:-$HOME/Library/Preferences}" name attempt
    local survivors=0 quiet_passes=0
    # cfprefsd can recreate an emptied domain after the first removal. Require
    # two quiet checks, but keep a hard limit so persistent failures still fail CI.
    for attempt in {1..10}; do
        for name in "vorss.tests." "com.islet.tests."; do
            rm -f "$preferences"/$name*.plist(N)
        done
        rm -f "$preferences/metrics-tests.plist"
        sleep 0.2
        survivors=$(find "$preferences" -maxdepth 1 \
            \( -name "vorss.tests.*.plist" -o -name "com.islet.tests.*.plist" \
               -o -name "metrics-tests.plist" \) 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$survivors" == "0" ]]; then
            quiet_passes=$((quiet_passes + 1))
            if (( quiet_passes == 2 )); then return 0; fi
        else
            quiet_passes=0
        fi
    done
    echo "✗ test preferences did not settle in $preferences ($survivors remaining)" >&2
    return 1
}

# Standalone automated tests: pure contracts plus isolated disk, subprocess,
# keyboard-data and media fixtures. No application windows or device capture.
if (( TEST )); then
    python3 Tests/generate_sources.py
    TEST_OBJECT_DIR="build/objects/tests"
    mkdir -p "$TEST_OBJECT_DIR"
    TEST_SOURCES=(
        Sources/Islet/Services/Media/MediaSupport.swift
        Sources/Islet/Core/QuitProtectionSupport.swift
        Sources/Islet/Core/QuitProtectionStrings.swift
        Sources/Islet/Core/Defaults.swift
        Sources/Islet/Core/NotchStrings.swift
        Sources/Islet/Core/NotchTourStrings.swift
        Sources/Islet/Core/NotchEditorStrings.swift
        Sources/Islet/UI/Settings/NotchSettingsTabRow.swift
        Sources/Islet/Core/NotchActivityStrings.swift
        Sources/Islet/Services/Notch/NotchTimerSupport.swift
        Sources/Islet/Services/Notch/NotchAppFullscreen.swift
        Sources/Islet/Services/Notch/NotchTimerAlert.swift
        Sources/Islet/UI/Notch/NotchIslandAlert.swift
        Sources/Islet/Services/Notch/NotchAccessorySupport.swift
        Sources/Islet/Services/Notch/NotchAccessoryConnectionMonitor.swift
        Sources/Islet/Services/QuickTools/CameraPreviewSupport.swift
        Sources/Islet/Core/NotchMusicExtrasStrings.swift
        Sources/Islet/Core/NotchClipboardSizeStrings.swift
        Sources/Islet/Services/Notch/NotchLyricsSupport.swift
        Sources/Islet/Services/Notch/NotchQueueSupport.swift
        Sources/Islet/Services/Notch/NotchPreferredPlayer.swift
        Sources/Islet/Core/NotchFilesStrings.swift
        Sources/Islet/Core/NotchWatchStrings.swift
        Sources/Islet/Services/Notch/NotchWatchSupport.swift
        Sources/Islet/Core/NotchMascotStrings.swift
        Sources/Islet/Services/Notch/NotchMascotSupport.swift
        Sources/Islet/Services/CommandBar/CommandBarDropletMotion.swift
        Sources/Islet/Services/Notch/NotchFileToolsSupport.swift
        Sources/Islet/Services/Notch/NotchDownloadSupport.swift
        Sources/Islet/Services/Notch/NotchDownloadProgressObserver.swift
        Sources/Islet/Core/NotchCalendarStrings.swift
        Sources/Islet/Core/NotchNotificationStrings.swift
        Sources/Islet/Core/NotchGestureStrings.swift
        Sources/Islet/Core/NotchAgentStrings.swift
        Sources/Islet/Core/CodexAccountStrings.swift
        Sources/Islet/Core/ClaudeAccountStrings.swift
        Sources/Islet/Services/Notch/NotchAgentSupport.swift
        Sources/Islet/Core/NotchLockScreenStrings.swift
        Sources/Islet/Services/Notch/NotchLockScreenSupport.swift
        Sources/Islet/Services/AgentUsage/AgentUsageModels.swift
        Sources/Islet/Services/AgentUsage/AgentPricing.swift
        Sources/Islet/Services/AgentUsage/AgentLogObject.swift
        Sources/Islet/Services/AgentUsage/AgentLogParser.swift
        Sources/Islet/Services/AgentUsage/Harness/AgentHarnessReader.swift
        Sources/Islet/Services/AgentUsage/Harness/ClaudeReader.swift
        Sources/Islet/Services/AgentUsage/Harness/CodexReader.swift
        Sources/Islet/Services/AgentUsage/Harness/OpenCodeReader.swift
        Sources/Islet/Services/AgentUsage/Harness/CopilotReader.swift
        Sources/Islet/Services/AgentUsage/AgentUsageSummary.swift
        Sources/Islet/Services/AgentUsage/AgentUsageStore.swift
        Sources/Islet/Services/AgentUsage/AgentUsageArchive.swift
        Sources/Islet/Services/AgentUsage/AgentClaudeAppUsage.swift
        Sources/Islet/Services/AgentUsage/AgentCLIConversation.swift
        Sources/Islet/Services/AgentUsage/AgentClaudeServer.swift
        Sources/Islet/Services/AgentUsage/ClaudeAccountProfile.swift
        Sources/Islet/Services/AgentUsage/AgentCodexServer.swift
        Sources/Islet/Services/AgentUsage/CodexAccountLimits.swift
        Sources/Islet/Services/AgentUsage/CodexProfileLimitsService.swift
        Sources/Islet/Services/AgentUsage/AgentOpenCodeReader.swift
        Sources/Islet/Services/Notch/NotchGestureSupport.swift
        Sources/Islet/Services/Notch/NotchSectionPaging.swift
        Sources/Islet/Services/Notch/NotchSliderEditing.swift
        Sources/Islet/Services/Notch/NotchNotificationSupport.swift
        Sources/Islet/Services/Notch/NotchNotificationReaderCore.swift
        Sources/Islet/Services/Notch/NotchCalendarSupport.swift
        Sources/Islet/Services/Notch/NotchKeepAwakeSupport.swift
        Sources/Islet/Services/Notch/NotchSupport.swift
        Sources/Islet/Services/Notch/NotchAudioLevelSupport.swift
        Sources/Islet/Services/Notch/NotchVolumeKeyGate.swift
        Sources/Islet/Services/Notch/NotchMusicSupport.swift
        Sources/Islet/UI/Notch/NotchDecorativeClock.swift
        Sources/Islet/Services/Notch/NotchBrowserArtworkSupport.swift
        Sources/Islet/UI/Notch/NotchEqualizerBars.swift
        Sources/Islet/UI/Notch/NotchScrollEdgeFade.swift
        Sources/Islet/UI/Notch/NotchAgentAnimationView.swift
        Sources/Islet/UI/WindowVisibilityReader.swift
        Sources/Islet/Services/Notch/NotchMusicAutomationSupport.swift
        Sources/Islet/Services/Notch/NotchMusicAutomation.swift
        Sources/Islet/Services/Notch/NotchPlaybackSource.swift
        Sources/Islet/Services/Notch/NotchPlaybackCommand.swift
        Sources/Islet/Services/Notch/NotchMusicCommandWriter.swift
        Sources/Islet/Core/FeatureCatalog.swift
        Sources/Islet/Core/FeaturePresets.swift
        Sources/Islet/Core/FeatureHubStrings.swift
        Sources/Islet/Core/MixerScreenSharingStrings.swift
        Sources/Islet/Core/ShortcutSettingsStrings.swift
        Sources/Islet/Core/SwitcherShortcutStrings.swift
        Sources/Islet/Core/SettingsBackupSupport.swift
        Sources/Islet/Core/BackupStrings.swift
        Sources/Islet/Core/SnippetStrings.swift
        Sources/Islet/Core/AlertSoundStrings.swift
        Sources/Islet/Core/BrightnessStrings.swift
        Sources/Islet/Core/MediaImageStrings.swift
        Sources/Islet/Core/QuickToggleStrings.swift
        Sources/Islet/Core/ScreenshotStrings.swift
        Sources/Islet/Core/RecentCaptureStrings.swift
        Sources/Islet/Core/RecorderStrings.swift
        Sources/Islet/Core/RecorderShareStrings.swift
        Sources/Islet/Core/CameraPreviewStrings.swift
        Sources/Islet/Core/WallpaperStrings.swift
        Sources/Islet/Services/Wallpaper/WallpaperSupport.swift
        Sources/Islet/UI/MenuPanel/WallpaperThumbnailView.swift
        Sources/Islet/Core/ScratchpadStrings.swift
        Sources/Islet/Core/FinderRenameStrings.swift
        Sources/Islet/Core/CommandBarStrings.swift
        Sources/Islet/Core/FeedbackStrings.swift
        Sources/Islet/Core/RadialMenuStrings.swift
        Sources/Islet/Core/MenuBarAppearanceStrings.swift
        Sources/Islet/Core/AppAppearance.swift
        Sources/Islet/Core/AppearanceStrings.swift
        Sources/Islet/Core/GeneralSettingsStrings.swift
        Sources/Islet/Core/SettingsPageStrings.swift
        Sources/Islet/Core/BatteryTimeStrings.swift
        Sources/Islet/Core/CPUCoreStrings.swift
        Sources/Islet/Core/MonitorLayoutStrings.swift
        Sources/Islet/Core/KeepAwakeStrings.swift
        Sources/Islet/Core/BluetoothSleepStrings.swift
        Sources/Islet/Core/PermissionGuideStrings.swift
        Sources/Islet/Core/FanControlStrings.swift
        Sources/Islet/Core/ConnectedDevicesStrings.swift
        Sources/Islet/Services/FanControl/FanControlSupport.swift
        Sources/Islet/Services/FanControl/FanControlResumeSupport.swift
        Sources/Islet/Services/Snippets/TextSnippetSupport.swift
        Sources/Islet/Services/RadialMenu/RadialMenuSupport.swift
        Sources/Islet/Services/QuickTools/ScratchpadSupport.swift
        Sources/Islet/Services/QuickTools/ScratchpadStore.swift
        Sources/Islet/Services/KillProcess/KillProcessSupport.swift
        Sources/Islet/Services/Recorder/RecorderSupport.swift
        Sources/Islet/Services/Recorder/RecorderSampleTiming.swift
        Sources/Islet/Services/Recorder/RecorderWriter.swift
        Sources/Islet/Services/Recorder/RecorderCaptureEngine.swift
        Sources/Islet/Core/RecorderExportStrings.swift
        Sources/Islet/Services/Recorder/RecorderComposer.swift
        Sources/Islet/Services/Recorder/RecorderComposerPlan.swift
        Sources/Islet/Services/Recorder/RecorderCursorSprite.swift
        Sources/Islet/Services/Recorder/RecorderTextRenderer.swift
        Sources/Islet/Services/Recorder/RecorderImageRenderer.swift
        Sources/Islet/Services/Recorder/RecorderExporter.swift
        Sources/Islet/Services/Recorder/RecorderGIFClipboard.swift
        Sources/Islet/Services/Recorder/RecorderGIFWriter.swift
        Sources/Islet/Services/Recorder/RecorderGIFWorkspace.swift
        Sources/Islet/Services/Recorder/RecorderComposition.swift
        Sources/Islet/Services/Recorder/RecordingSharingSupport.swift
        Sources/Islet/Services/PrivateFileStore.swift
        Sources/Islet/Services/Recorder/RecorderTakeStore.swift
        Sources/Islet/Services/Recorder/RecorderPresetImageStore.swift
        Sources/Islet/Services/Recorder/RecorderMotion.swift
        Sources/Islet/Services/Recorder/RecorderPointerTrack.swift
        Sources/Islet/Services/Recorder/RecorderTypingTrack.swift
        Sources/Islet/Services/Recorder/RecorderTimeline.swift
        Sources/Islet/Services/Recorder/RecorderTextOverlay.swift
        Sources/Islet/Services/Recorder/RecorderImageOverlay.swift
        Sources/Islet/Services/Recorder/RecorderBlurRegion.swift
        Sources/Islet/Services/Recorder/RecorderEditDocument.swift
        Sources/Islet/Core/AppInfo.swift
        Sources/Islet/Core/GlobalShortcut.swift
        Sources/Islet/Core/SymbolicHotKeys.swift
        Sources/Islet/Services/SystemShortcutTakeoverSupport.swift
        Sources/Islet/Core/Localization.swift
        Sources/Islet/Core/Localizations/Strings+*.swift
        Sources/Islet/Core/FeatureStrings.swift
        Sources/Islet/Core/KillProcessStrings.swift
        Sources/Islet/Core/PortManagerStrings.swift
        Sources/Islet/Core/WhatsAppDownloadStrings.swift
        Sources/Islet/Core/WhatsAppOrganizerStrings.swift
        Sources/Islet/Core/ReleaseNotes.swift
        Sources/Islet/Core/ReleaseDigest.swift
        Sources/Islet/Core/ReleaseChangeAliases.swift
        Sources/Islet/Core/WhatsNewStrings.swift
        Sources/Islet/Core/URLCleaning.swift
        Sources/Islet/Services/URLCleanerLinkMetadata.swift
        Sources/Islet/Services/GeneralPasteboardAccess.swift
        Sources/Islet/Services/Clipboard/ClipboardHistoryWrite.swift
        Sources/Islet/Services/Audio/AirPlayRouteManager.swift
        Sources/Islet/Services/Audio/MixerRoutingSupport.swift
        Sources/Islet/Services/Audio/MusicLaunchSupport.swift
        Sources/Islet/Services/Bluetooth/BluetoothSleepSupport.swift
        Sources/Islet/UI/MenuPanel/MixerPercentNativeTextField.swift
        Sources/Islet/UI/MenuPanel/MixerAppDragSource.swift
        Sources/Islet/Services/Audio/BoostLimiter.swift
        Sources/Islet/Services/Audio/MixerRender.swift
        Sources/Islet/Services/Audio/PreciseVolumeRollerSupport.swift
        Sources/Islet/Services/DockPreview/DockPreviewSupport.swift
        Sources/Islet/Services/DockPreview/DockAutohideHold.swift
        Sources/Islet/Services/SpacesOrder/SpacesOrderHold.swift
        Sources/Islet/Services/Homebrew/HomebrewSupport.swift
        Sources/Islet/Services/Homebrew/HomebrewEnvironment.swift
        Sources/Islet/Services/AppUpdates/AppUpdatesSupport.swift
        Sources/Islet/Services/AppUpdates/AppUpdateFeedSupport.swift
        Sources/Islet/Core/AppUpdateStrings.swift
        Sources/Islet/Core/DiskImageInstallerStrings.swift
        Sources/Islet/Services/DiskImageInstaller/DiskImageInstallerSupport.swift
        Sources/Islet/UI/NonModalAlert.swift
        Sources/Islet/Services/Clipboard/ClipboardHistorySupport.swift
        Sources/Islet/Core/ColorValue.swift
        Sources/Islet/Services/Clipboard/ClipboardAutoClearSupport.swift
        Sources/Islet/Services/AutoQuit/AutoQuitSupport.swift
        Sources/Islet/Core/AutoQuitDockAppsStrings.swift
        Sources/Islet/Services/Shelf/ShelfSupport.swift
        Sources/Islet/Services/Shelf/ShelfFilePromiseTransfer.swift
        Sources/Islet/Core/ShelfPromiseDeliveryStrings.swift
        Sources/Islet/Services/Finder/FinderRenameSupport.swift
        Sources/Islet/Services/Update/UpdateInstallerSupport.swift
        Sources/Islet/Services/Update/UpdateServiceSupport.swift
        Sources/Islet/Services/InstalledApps.swift
        Sources/Islet/Services/LaunchAtLoginSupport.swift
        Sources/Islet/UI/Settings/SettingsSearchSupport.swift
        Sources/Islet/UI/Settings/SettingsSidebarSupport.swift
        Sources/Islet/UI/Settings/FeatureVisibilitySupport.swift
        Sources/Islet/UI/Onboarding/WhatsNewSupport.swift
        Sources/Islet/UI/Settings/SettingsWindow.swift
        Sources/Islet/Core/SettingsNavigationStrings.swift
        Sources/Islet/App/MenuBarSpacingSupport.swift
        Sources/Islet/App/MenuBarAllowanceSupport.swift
        Sources/Islet/App/ReopenRequestSupport.swift
        Sources/Islet/App/StatusItemAnchorSupport.swift
        Sources/Islet/Services/DockClick/DockClickSupport.swift
        Sources/Islet/Services/Finder/CutPasteProgressSupport.swift
        Sources/Islet/Services/Finder/CutPastePrivilegeSupport.swift
        Sources/Islet/Services/Finder/FinderPasteImageSupport.swift
        Sources/Islet/Services/MiddleClick/MiddleClickSupport.swift
        Sources/Islet/Services/MouseNavigation/MouseNavigationSupport.swift
        Sources/Islet/Services/MouseNavigation/MouseNavigationKeys.swift
        Sources/Islet/Services/MouseButtons/MouseButtonShortcutSupport.swift
        Sources/Islet/Services/MouseButtons/MouseSpacesGestureSupport.swift
        Sources/Islet/Services/MouseClickDebounce/MouseClickDebounceSupport.swift
        Sources/Islet/Services/MouseExceptions/MouseAppExceptionSupport.swift
        Sources/Islet/Services/MouseExceptions/MouseAppExceptions.swift
        Sources/Islet/Services/WindowServerSupport.swift
        Sources/Islet/Services/WindowMaximizerSupport.swift
        Sources/Islet/Core/MouseButtonStrings.swift
        Sources/Islet/Core/MouseClickDebounceStrings.swift
        Sources/Islet/Core/MouseExceptionStrings.swift
        Sources/Islet/Core/ClipboardIgnoredAppsStrings.swift
        Sources/Islet/Core/ClipboardRetentionStrings.swift
        Sources/Islet/Core/WindowLayoutIgnoredAppsStrings.swift
        Sources/Islet/Services/WindowLayout/WindowLayoutIgnoredApps.swift
        Sources/Islet/Core/WindowPreviewExclusionStrings.swift
        Sources/Islet/Core/WindowMaximizerExclusionStrings.swift
        Sources/Islet/Core/DiskExclusionStrings.swift
        Sources/Islet/Core/SwitcherAppRulesStrings.swift
        Sources/Islet/Services/QuickTools/QuickToolsSupport.swift
        Sources/Islet/Services/CommandBar/CommandBarSupport.swift
        Sources/Islet/Services/CommandBar/CommandBarPreferences.swift
        Sources/Islet/Services/CommandBar/CommandBarMath.swift
        Sources/Islet/Services/CommandBar/CommandBarUnits.swift
        Sources/Islet/Services/CommandBar/CommandBarColors.swift
        Sources/Islet/Services/CommandBar/CommandBarEmoji.swift
        Sources/Islet/Services/CommandBar/CommandBarLinks.swift
        Sources/Islet/Services/CommandBar/CommandBarDates.swift
        Sources/Islet/Services/CommandBar/CommandBarRowShortcuts.swift
        Sources/Islet/Services/CommandBar/CommandBarSystemSettingsSupport.swift
        Sources/Islet/Services/CommandBar/CommandBarFileSearchSupport.swift
        Sources/Islet/Services/CommandBar/CommandBarQueryMemory.swift
        Sources/Islet/Services/SpotlightNamesSupport.swift
        Sources/Islet/Services/QuickTools/MicMuteSupport.swift
        Sources/Islet/Services/QuickTools/QuickTogglesSupport.swift
        Sources/Islet/Services/QuickTools/ScreenshotCapturePolicy.swift
        Sources/Islet/Services/QuickTools/ScreenshotSupport.swift
        Sources/Islet/Services/QuickTools/ScreenshotCanvasSupport.swift
        Sources/Islet/UI/Settings/ScreenCaptureToolPicker.swift
        Sources/Islet/UI/Settings/MonitorToken.swift
        Sources/Islet/Services/QuickTools/ScreenshotRenderer.swift
        Sources/Islet/Services/QuickTools/ScreenshotImageLayerRendering.swift
        Sources/Islet/Services/QuickTools/RecentCaptureStore.swift
        Sources/Islet/Services/QuickTools/ScreenshotSharingSupport.swift
        Sources/Islet/Services/QuickTools/WindowActivationPolicy.swift
        Sources/Islet/Services/KeyboardDebounce/KeyboardDebounceSupport.swift
        Sources/Islet/Services/SuperKey/SuperKeySupport.swift
        Sources/Islet/Services/SuperKey/SuperKeyMappingGuard.swift
        Sources/Islet/Core/SuperKeyStrings.swift
        Sources/Islet/Core/InputSourceSelection.swift
        Sources/Islet/Services/SessionActivity.swift
        Sources/Islet/Services/SessionActivitySupport.swift
        Sources/Islet/Services/EventTimestamp.swift
        Sources/Islet/Services/OwnKeyEvent.swift
        Sources/Islet/Services/ScrollWheelSupport.swift
        Sources/Islet/Services/HorizontalWheelScrolling.swift
        Sources/Islet/Services/SmoothScrollSupport.swift
        Sources/Islet/Services/MouseAcceleration/MouseAccelerationSupport.swift
        Sources/Islet/Services/FocusFollowsMouse/FocusFollowsMouseSupport.swift
        Sources/Islet/Services/AssistiveKeyboard.swift
        Sources/Islet/Services/Switcher/SwitcherModels.swift
        Sources/Islet/Services/Switcher/WindowServerCaptureQueue.swift
        Sources/Islet/Services/Switcher/SwitcherSupport.swift
        Sources/Islet/Services/Switcher/SpaceHopSupport.swift
        Sources/Islet/Services/Switcher/WindowUseOrder.swift
        Sources/Islet/Services/Metrics/MetricFormat.swift
        Sources/Islet/Services/Metrics/VMStatisticsDecoder.swift
        Sources/Islet/Services/KeepAwakeAutomationSupport.swift
        Sources/Islet/Services/SudoersSupport.swift
        Sources/Islet/Services/Metrics/BatteryTimeSupport.swift
        Sources/Islet/Services/Metrics/BatteryPowerSupport.swift
        Sources/Islet/Services/BoundedProcessRunner.swift
        Sources/Islet/Services/DetachedProcess.swift
        Sources/Islet/Services/ShellSupport.swift
        Sources/Islet/Services/PortManager/PortManagerSupport.swift
        Sources/Islet/Services/Metrics/NetworkProcessSupport.swift
        Sources/Islet/Services/Metrics/NetworkSampler.swift
        Sources/Islet/Services/Metrics/NetworkAddressService.swift
        Sources/Islet/Services/Metrics/SpeedTest.swift
        Sources/Islet/Services/Metrics/PeripheralBatterySampler.swift
        Sources/Islet/Services/Metrics/PeripheralBatterySupport.swift
        Sources/Islet/Services/Metrics/DiskSupport.swift
        Sources/Islet/Services/Metrics/MonitorSamplingPolicy.swift
        Sources/Islet/Services/Metrics/USBDeviceSampler.swift
        Sources/Islet/Services/Metrics/CPUCoreSampler.swift
        Sources/Islet/Services/Metrics/MaxCapacityProbe.swift
        Sources/Islet/Services/Metrics/TemperatureSensorSelector.swift
        Sources/Islet/Services/Metrics/SustainedAlertGate.swift
        Sources/Islet/Services/WindowLayout/WindowLayoutSupport.swift
        Sources/Islet/Services/WindowLayout/WindowStageManagerSupport.swift
        Sources/Islet/Core/WindowStageManagerStrings.swift
        Sources/Islet/Services/WindowLayout/WindowGestureSupport.swift
        Sources/Islet/Core/WindowDirectionalStrings.swift
        Sources/Islet/Core/PointerDisplayStrings.swift
        Sources/Islet/Core/GraphScaleStrings.swift
        Sources/Islet/Core/NotchLowBatteryStrings.swift
        Sources/Islet/Services/CleaningMode/CleaningUnlockCounter.swift
        Sources/Islet/Services/CleaningMode/CleaningMouseReleaseGate.swift
        Sources/Islet/Services/Display/ExtraBrightnessSupport.swift
        Sources/Islet/Services/Display/BrightnessSupport.swift
        Sources/Islet/Services/Display/LidDimmingSupport.swift
        Sources/Islet/Services/Cleaner/CleanerSupport.swift
        Sources/Islet/Services/Cleaner/CleanerPolicy.swift
        Sources/Islet/Services/Cleaner/CleanerSchedule.swift
        Sources/Islet/Services/Uninstall/UninstallerSupport.swift
        Sources/Islet/Services/ManagedDownloads/WhatsAppDownloadSupport.swift
        Sources/Islet/Core/SecureInputSupport.swift
        Tests/*.swift
        build/generated-tests/*.swift
    )
    TEST_OUTPUT_FILE_MAP="$TEST_OBJECT_DIR/output-file-map.json"
    write_swift_output_file_map "$TEST_OUTPUT_FILE_MAP" "$TEST_OBJECT_DIR" "${TEST_SOURCES[@]}"
    echo "▸ Building & running tests against $(basename "$SDK")…"
    swiftc -Onone -incremental -enable-batch-mode -j "$(sysctl -n hw.logicalcpu)" \
        -module-name IsletTests -output-file-map "$TEST_OUTPUT_FILE_MAP" \
        -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" \
        "${VM_STATISTICS_COMPAT_FLAGS[@]}" "${TEST_SOURCES[@]}" -o build/metrics-tests
    test_status=0
    ./build/metrics-tests "${TEST_ARGS[@]}" || test_status=$?
    if (( ${#TEST_ARGS} == 0 )); then
        ./Tests/PreferenceCleanupTests.sh || test_status=1
        ./Tests/UninstallSpacesTests.sh || test_status=1
        ./Tests/DeveloperInstallIsolationTests.sh || test_status=1
    fi
    discard_test_preferences || test_status=1
    exit $test_status
fi

echo "▸ Compiling ($BUILD_CONFIGURATION) against $(basename "$SDK")…"
APP_SOURCES=(Sources/Islet/**/*.swift)
if (( ! DEV )); then
    # A release starts from an empty build directory, so nothing an earlier
    # build left behind (an old icon catalog, a staged bundle) can reach it.
    # Only the compiler's incremental records stay: they rebuild whatever
    # changed since, and a fresh checkout has none.
    find build -mindepth 1 -maxdepth 1 ! -name objects -exec rm -rf {} + 2>/dev/null || true
fi
APP_OBJECT_DIR="build/objects/$EXECUTABLE"
mkdir -p build "$APP_OBJECT_DIR"
APP_OUTPUT_FILE_MAP="$APP_OBJECT_DIR/output-file-map.json"
write_swift_output_file_map "$APP_OUTPUT_FILE_MAP" "$APP_OBJECT_DIR" "${APP_SOURCES[@]}"
# Without -j the driver compiles one file at a time, and without batch mode
# each file's compiler parses the whole module again: a clean release took a
# quarter of an hour. Batches share that work and run on every core, and the
# optimization stays per file, as before.
swiftc "${APP_OPTIMIZATION_FLAGS[@]}" -incremental -enable-batch-mode -j "$(sysctl -n hw.logicalcpu)" \
    -output-file-map "$APP_OUTPUT_FILE_MAP" \
    -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${VM_STATISTICS_COMPAT_FLAGS[@]}" "${HID_EVENT_SYSTEM_FLAGS[@]}" \
    "${BUILD_VARIANT_FLAGS[@]}" \
    "${APP_SOURCES[@]}" -o "build/$EXECUTABLE"

echo "▸ Compiling protected fan helper…"
swiftc -O -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${BUILD_VARIANT_FLAGS[@]}" \
    Sources/Islet/Services/FanControl/FanControlSupport.swift \
    Sources/Islet/Services/FanControl/FanControlXPC.swift \
    Sources/Islet/Services/SystemMonitor/SMCClient.swift \
    Sources/Islet/Services/Metrics/TemperatureSensorSelector.swift \
    Sources/Islet/Services/FanControl/FanControlHardware.swift \
    Sources/FanControlHelper/main.swift \
    -o "build/$FAN_HELPER_ID"
"build/$FAN_HELPER_ID" --selftest

echo "▸ Compiling Now Playing adapter…"
swiftc -O -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" -emit-library \
    -module-name IsletNowPlaying \
    Sources/NowPlayingAdapter/NowPlayingAdapter.swift \
    Sources/NowPlayingAdapter/NowPlayingQueue.swift \
    Sources/NowPlayingAdapter/NowPlayingSelection.swift \
    Sources/Islet/Services/Notch/NotchPlaybackSource.swift \
    Sources/Islet/Services/Notch/NotchPlaybackCommand.swift \
    -o "build/$NOW_PLAYING_ADAPTER"

echo "▸ Generating app icon…"
swift Tools/MakeIcon.swift build/AppIcon.iconset
xattr -c -r build/AppIcon.iconset build/AppIcon.icns build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png 2>/dev/null || true
ACTOOL_BIN="$(xcrun --find actool 2>/dev/null || true)"
ICON_TMP="$(mktemp -d)"
ADAPTIVE_SKIP=""
if [[ ! -d Resources/Brand/AppIcon.icon ]]; then
    ADAPTIVE_SKIP="no Icon Composer project; using AppIcon.icns"
elif [[ -z "$ACTOOL_BIN" ]]; then
    ADAPTIVE_SKIP="actool not found (adaptive icons need Xcode 26+)"
else
    echo "▸ Compiling adaptive icon catalog…"
    # actool crashes on File Provider-synced paths, so compile a local copy.
    ditto "Resources/Brand/AppIcon.icon" "$ICON_TMP/AppIcon.icon"
    # Xcode 27 beta actool requires the --compile target directory to already exist.
    mkdir -p "$ICON_TMP/catalog"
    if "$ACTOOL_BIN" "$ICON_TMP/AppIcon.icon" \
            --compile "$ICON_TMP/catalog" \
            --app-icon AppIcon \
            --platform macosx \
            --target-device mac \
            --minimum-deployment-target 14.0 \
            --enable-on-demand-resources NO \
            --output-partial-info-plist "$ICON_TMP/partial-info.plist" \
            >"$ICON_TMP/actool.log" 2>&1 && [[ -s "$ICON_TMP/catalog/Assets.car" ]]; then
        mv "$ICON_TMP/catalog/Assets.car" build/Assets.car
    else
        ADAPTIVE_SKIP="actool could not compile the catalog"
    fi
fi
if [[ -n "$ADAPTIVE_SKIP" ]]; then
    cp "$ICON_TMP/actool.log" build/actool-failure.log 2>/dev/null || true
    echo "  adaptive icon skipped: $ADAPTIVE_SKIP (Dock falls back to AppIcon.icns)"
fi
echo "▸ Assembling and signing bundle…"
STAGE_TMP="$(mktemp -d)"
STAGE="$STAGE_TMP/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" \
    "$STAGE/Contents/Library/LaunchDaemons" "$STAGE/Contents/Library/LaunchServices"
cp "build/$EXECUTABLE" "$STAGE/Contents/MacOS/$EXECUTABLE"
cp "build/$FAN_HELPER_ID" "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID"
mkdir -p "$STAGE/Contents/Frameworks"
cp "build/$NOW_PLAYING_ADAPTER" "$STAGE/Contents/Frameworks/$NOW_PLAYING_ADAPTER"
cp Resources/now-playing.pl "$STAGE/Contents/Resources/now-playing.pl"
cp Resources/agent-prices.json "$STAGE/Contents/Resources/agent-prices.json"
cp Resources/com.islet.utils.fan-control.plist \
    "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp CHANGELOG.md "$STAGE/Contents/Resources/CHANGELOG.md"
for lproj in Resources/*.lproj(N); do
    cp -R "$lproj" "$STAGE/Contents/Resources/"
done
if (( DEV )); then
    # A distinct identity so the Developer build installs and runs next to the
    # official app, with its own permissions, preferences and login item.
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_ID" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE" "$STAGE/Contents/Info.plist"
    FAN_PLIST="$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
    /usr/libexec/PlistBuddy -c "Set :Label $FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Set :BundleProgram Contents/Library/LaunchServices/$FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Delete :MachServices:com.islet.utils.fan-control" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Add :MachServices:$FAN_HELPER_ID bool true" "$FAN_PLIST"
    # Stamp the source commit + build time so the running dev app shows (in About)
    # exactly which code it was compiled from. Lets you verify it matches HEAD before
    # testing, instead of unknowingly running a stale build. Dev-only; never shipped.
    SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    [[ -n "$(git status --porcelain 2>/dev/null)" ]] && SHA="$SHA-dirty"
    /usr/libexec/PlistBuddy -c "Add :IsletBuildCommit string '$SHA · $(date '+%Y-%m-%d %H:%M')'" "$STAGE/Contents/Info.plist"
    echo "  stamped dev build: $SHA"
fi
FAN_HELPER_VERSION="$(
    export LC_ALL=C
    /usr/bin/shasum -a 256 \
        "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID" \
        "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist" \
        | /usr/bin/awk '{print $1}' | /usr/bin/shasum -a 256 \
        | /usr/bin/awk '{print $1}'
)"
/usr/libexec/PlistBuddy -c "Add :IsletFanControlHelperVersion string '$FAN_HELPER_VERSION'" \
    "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
cp build/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
cp build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png "$STAGE/Contents/Resources/"
if [[ -f build/Assets.car ]]; then
    cp build/Assets.car "$STAGE/Contents/Resources/Assets.car"
fi
if [[ -d Resources/Gifs ]]; then
    mkdir -p "$STAGE/Contents/Resources/Gifs"
    cp Resources/Gifs/*.gif "$STAGE/Contents/Resources/Gifs/"
fi
if ! cmp -s Resources/Gifs/highlights-notch.gif "$STAGE/Contents/Resources/Gifs/highlights-notch.gif"; then
    echo "Dynamic Island tour GIF is missing or differs from the bundled copy" >&2
    exit 1
fi
if [[ -d Resources/Images ]]; then
    mkdir -p "$STAGE/Contents/Resources/Images"
    cp Resources/Images/* "$STAGE/Contents/Resources/Images/"
fi
xattr -c -r "$STAGE" 2>/dev/null || true

# Signing, in order of preference:
#   1. Developer ID Application — the real, Apple-issued identity used for
#      notarized releases. Signed with the hardened runtime (required for
#      notarization), the app's entitlements and a secure timestamp. Gives a
#      stable, team-based designated requirement, so permissions persist across
#      updates AND Gatekeeper shows no "unverified developer" warning.
#   2. "Islet Utils Signing" — the legacy stable self-signed identity, kept
#      as a fallback so contributors without a Developer ID still get a constant
#      designated requirement across their local builds.
#   3. Ad-hoc — fresh clone with no identity at all.
DEVID="$(developer_id_identity)"
codesign_app() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --sign - "$target"
    fi
}

codesign_fan_helper() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --identifier "$FAN_HELPER_ID" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --identifier "$FAN_HELPER_ID" \
            --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --identifier "$FAN_HELPER_ID" --sign - "$target"
    fi
}

codesign_now_playing_adapter() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --identifier "$NOW_PLAYING_ADAPTER_ID" \
            --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --identifier "$NOW_PLAYING_ADAPTER_ID" --sign - "$target"
    fi
}

sign_bundle() {
    local bundle="$1"
    local executable="$bundle/Contents/MacOS/$EXECUTABLE"
    local helper="$bundle/Contents/Library/LaunchServices/$FAN_HELPER_ID"
    local adapter="$bundle/Contents/Frameworks/$NOW_PLAYING_ADAPTER"

    if [[ -n "$DEVID" ]]; then
        echo "  signing with Developer ID (hardened runtime): $DEVID"
    elif legacy_identity_installed; then
        echo "  signing with legacy self-signed identity: $LEGACY_IDENTITY"
    else
        echo "  signing ad-hoc (no identity installed — run Tools/setup-signing.sh)"
    fi
    [[ -f "$helper" ]] && codesign_fan_helper "$helper"
    [[ -f "$adapter" ]] && codesign_now_playing_adapter "$adapter"
    codesign_app "$bundle"

    # If local filesystem metadata invalidates the first signature, sign once
    # more. The installed Developer bundle is signed again after the final copy.
    if ! codesign --verify --deep --strict "$bundle" >/dev/null 2>&1; then
        echo "  re-signing after filesystem metadata settled"
        xattr -c -r "$bundle" 2>/dev/null || true
        [[ -f "$helper" ]] && codesign_fan_helper "$helper"
        [[ -f "$adapter" ]] && codesign_now_playing_adapter "$adapter"
        codesign_app "$bundle"
    fi
    [[ -f "$executable" ]] && codesign --verify --strict "$executable"
    [[ -f "$helper" ]] && codesign --verify --strict "$helper"
    [[ -f "$adapter" ]] && codesign --verify --strict "$adapter"
    codesign --verify --deep --strict "$bundle"
}

sign_installed_bundle() {
    local bundle="$1"
    wait_for_install_metadata "$bundle"
    sign_bundle "$bundle"
}

sign_bundle "$STAGE"

process_is_running() {
    local proc="$1"
    if (( ${#proc} > 15 )); then
        pgrep -f "/Contents/MacOS/$proc" >/dev/null 2>&1
    else
        pgrep -x "$proc" >/dev/null 2>&1
    fi
}

stop_process() {
    local proc="$1"
    if (( ${#proc} > 15 )); then
        pkill -f "/Contents/MacOS/$proc" 2>/dev/null || true
    else
        pkill -x "$proc" 2>/dev/null || true
    fi
    for _ in {1..50}; do
        if ! process_is_running "$proc"; then
            return 0
        fi
        sleep 0.1
    done
    echo "✗ $proc is still running — quit it and retry" >&2
    return 1
}

wait_for_install_metadata() {
    local bundle="$1"
    local missing
    for _ in {1..50}; do
        missing=0
        while IFS= read -r file; do
            if ! xattr -p com.apple.provenance "$file" >/dev/null 2>&1; then
                missing=1
                break
            fi
        done < <(find "$bundle/Contents" -type f ! -path "*/_CodeSignature/*")
        if (( missing == 0 )); then
            return 0
        fi
        sleep 0.1
    done
}

# Installed development builds only need the copy in /Applications. Retaining
# another app in each checkout pollutes application search with stale builds.
if (( DEV )); then
    for old_bundle in "build/stage/$APP_NAME.app" "build/stage.noindex/$APP_NAME.app"; do
        if [[ -d "$old_bundle" ]]; then
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
                -u "$PWD/$old_bundle" >/dev/null 2>&1 || true
            rm -rf "$old_bundle"
        fi
    done
fi

if (( !DEV || !INSTALL )); then
    STAGE_DIRECTORY="build/stage"
    (( DEV )) && STAGE_DIRECTORY="build/stage.noindex"
    mkdir -p "$STAGE_DIRECTORY"
    BUILD_STAGE="$STAGE_DIRECTORY/$APP_NAME.app"
    rm -rf "$BUILD_STAGE"
    ditto --noextattr --noqtn "$STAGE" "$BUILD_STAGE"
    xattr -c -r "$BUILD_STAGE" 2>/dev/null || true
    if ! codesign --verify --deep --strict "$BUILD_STAGE" >/dev/null 2>&1; then
        if xattr -lr "$BUILD_STAGE" 2>/dev/null | grep -Eq 'com\.apple\.(FinderInfo|ResourceFork|provenance|fileprovider)'; then
            echo "  staging copy has local filesystem metadata; temp bundle was verified"
        else
            codesign --verify --deep --strict "$BUILD_STAGE"
        fi
    fi
    echo "✓ Bundle ready: $BUILD_STAGE"
fi

if (( INSTALL )); then
    echo "▸ Installing into /Applications…"
    stop_process "$EXECUTABLE"
    INSTALL_DEST="/Applications/$APP_NAME.app"
    rm -rf "$INSTALL_DEST"
    ditto --noextattr --noqtn "$STAGE" "$INSTALL_DEST"
    sign_installed_bundle "$INSTALL_DEST"
    echo "✓ Installed: $INSTALL_DEST"
fi
