#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mode="${1:-native}"
[[ "$mode" == native || "$mode" == --universal ]] || { echo 'Usage: build-app.sh [--universal]' >&2; exit 1; }
version="$(cat VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'VERSION must contain a semantic version.' >&2; exit 1; }
build_number="${BUILD_NUMBER:-2}"
[[ "$build_number" =~ ^[0-9]+$ ]] || { echo 'BUILD_NUMBER must be numeric.' >&2; exit 1; }
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
app_dir="$project_root/dist/Reclaim.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Helpers"
cp "$binary_dir/Reclaim" "$app_dir/Contents/MacOS/Reclaim"
cp "$binary_dir/ReclaimWorker" "$app_dir/Contents/Helpers/ReclaimWorker"
cp "$project_root/Resources/Info.plist" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_dir/Contents/Info.plist"
./scripts/build-icon.sh
cp "$project_root/dist/Reclaim.icns" "$app_dir/Contents/Resources/Reclaim.icns"
sign_options=(--force --sign "${SIGNING_IDENTITY:--}")
if [[ "${DISTRIBUTION:-0}" == 1 ]]; then
    [[ "${SIGNING_IDENTITY:-}" == 'Developer ID Application:'* ]] || { echo 'Distribution requires a Developer ID Application identity.' >&2; exit 1; }
    sign_options+=(--options runtime --timestamp)
fi
/usr/bin/codesign "${sign_options[@]}" "$app_dir/Contents/Helpers/ReclaimWorker"
/usr/bin/codesign "${sign_options[@]}" "$app_dir"
/usr/bin/codesign --verify --deep --strict "$app_dir"
printf 'Built %s\n' "$app_dir"
