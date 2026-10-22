#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mode="${1:-native}"
[[ "$mode" == native || "$mode" == --universal ]] || { echo 'Usage: build-app.sh [--universal]' >&2; exit 1; }
version="$(cat VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'VERSION must contain a semantic version.' >&2; exit 1; }
local_counter="$project_root/dist/.local-build-number"
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    build_number="$BUILD_NUMBER"
else
    previous_build=2
    if [[ -f "$local_counter" ]]; then previous_build="$(cat "$local_counter")"; fi
    [[ "$previous_build" =~ ^[0-9]+$ ]] || { echo 'Invalid local build counter.' >&2; exit 1; }
    build_number="$((previous_build + 1))"
fi
[[ "$build_number" =~ ^[0-9]+$ ]] || { echo 'BUILD_NUMBER must be numeric.' >&2; exit 1; }
build_channel=Development
if [[ "${GITHUB_ACTIONS:-false}" == true ]]; then build_channel=Preview; fi
if [[ "${RECLAIM_PREVIEW:-0}" == 1 ]]; then build_channel=Preview; fi
if [[ "${DISTRIBUTION:-0}" == 1 ]]; then build_channel=Release; fi
app_name='Reclaim Dev'
bundle_id='local.timemachinexray.app.dev'
if [[ "$build_channel" == Release ]]; then
    app_name=Reclaim
    bundle_id='local.timemachinexray.app'
fi
source_revision="$(git rev-parse --verify HEAD)"
source_modified=false
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then source_modified=true; fi
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
[[ "${sdk_version%%.*}" -ge 27 ]] || { echo 'Reclaim requires the macOS 27 SDK (Xcode 27 or later).' >&2; exit 1; }
# Swift Build can otherwise stamp the deployment target as the linked SDK,
# which opts the app into legacy macOS controls. Keep macOS 14 compatibility
# while declaring the actual SDK used to build the native toolbar.
build_options=(-c release --sdk "$sdk_path"
    -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$sdk_version")
if [[ "$mode" == --universal ]]; then build_options+=(--arch arm64 --arch x86_64); fi
swift build "${build_options[@]}"
binary_dir="$(swift build "${build_options[@]}" --show-bin-path)"
app_dir="$project_root/dist/$app_name.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Helpers" "$app_dir/Contents/Frameworks"
cp "$binary_dir/Reclaim" "$app_dir/Contents/MacOS/Reclaim"
cp "$binary_dir/ReclaimWorker" "$app_dir/Contents/Helpers/ReclaimWorker"
cp "$project_root/Resources/Info.plist" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_name" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ReclaimBuildDate string $(date -u +%Y-%m-%dT%H:%M:%SZ)" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ReclaimBuildChannel string $build_channel" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ReclaimSourceRevision string $source_revision" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ReclaimSourceModified bool $source_modified" "$app_dir/Contents/Info.plist"
if [[ "$build_channel" == Release ]]; then
    public_key="$(cat Resources/SparklePublicKey.txt)"
    [[ "$public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo 'Invalid Sparkle public key.' >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://github.com/torbensko/reclaim/releases/latest/download/appcast.xml" "$app_dir/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $public_key" "$app_dir/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :SUEnableAutomaticChecks bool true' "$app_dir/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :SUAutomaticallyUpdate bool false' "$app_dir/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :SURequireSignedFeed bool true' "$app_dir/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :SUVerifyUpdateBeforeExtraction bool true' "$app_dir/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :SUEnableSystemProfiling bool false' "$app_dir/Contents/Info.plist"
fi
sparkle_artifact="$project_root/.build/artifacts/sparkle/Sparkle"
framework="$app_dir/Contents/Frameworks/Sparkle.framework"
# Copy framework symlinks intact; re-sign nested code from the inside out.
rm -rf "$framework"
/usr/bin/ditto "$sparkle_artifact/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$framework"
cp "$sparkle_artifact/LICENSE" "$app_dir/Contents/Resources/Sparkle-LICENSE.txt"
./scripts/build-icon.sh
cp "$project_root/dist/Reclaim.icns" "$app_dir/Contents/Resources/Reclaim.icns"
sign_options=(--force --sign "${SIGNING_IDENTITY:--}")
if [[ "${DISTRIBUTION:-0}" == 1 ]]; then
    [[ "${SIGNING_IDENTITY:-}" == 'Developer ID Application:'* ]] || { echo 'Distribution requires a Developer ID Application identity.' >&2; exit 1; }
    sign_options+=(--options runtime --timestamp)
fi
/usr/bin/codesign "${sign_options[@]}" "$framework/Versions/B/XPCServices/Installer.xpc"
/usr/bin/codesign "${sign_options[@]}" --preserve-metadata=entitlements "$framework/Versions/B/XPCServices/Downloader.xpc"
/usr/bin/codesign "${sign_options[@]}" "$framework/Versions/B/Autoupdate"
/usr/bin/codesign "${sign_options[@]}" "$framework/Versions/B/Updater.app"
/usr/bin/codesign "${sign_options[@]}" "$framework"
/usr/bin/codesign "${sign_options[@]}" "$app_dir/Contents/Helpers/ReclaimWorker"
/usr/bin/codesign "${sign_options[@]}" "$app_dir"
/usr/bin/codesign --verify --deep --strict "$app_dir"
if [[ -z "${BUILD_NUMBER:-}" ]]; then printf '%s\n' "$build_number" > "$local_counter"; fi
printf 'Built %s (%s %s, build %s)\n' "$app_dir" "$build_channel" "$version" "$build_number"
