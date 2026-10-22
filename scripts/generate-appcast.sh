#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SPARKLE_PRIVATE_KEY:?Missing SPARKLE_PRIVATE_KEY for update signing}"
version="$(cat VERSION)"
app="$PWD/dist/Reclaim.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ReclaimBuildChannel' "$app/Contents/Info.plist")" == Release ]]
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
tools="$PWD/.build/artifacts/sparkle/Sparkle/bin"
stage="$(mktemp -d "$PWD/dist/appcast.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
cp dist/Reclaim.zip "$stage/Reclaim.zip"
cp RELEASE_NOTES.md "$stage/Reclaim.md"
# A versioned archive URL remains immutable even after /latest moves forward.
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/generate_appcast" --ed-key-file - \
    --download-url-prefix "https://github.com/torbensko/reclaim/releases/download/v$version/" \
    --embed-release-notes --maximum-deltas 0 --link https://torbensko.com/software/reclaim/ "$stage"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tools/sign_update" --ed-key-file - --verify "$stage/appcast.xml"
swift scripts/verify-appcast.swift "$stage/appcast.xml" "$stage/Reclaim.zip" Resources/SparklePublicKey.txt "$version" "$build_number"
cp "$stage/appcast.xml" dist/appcast.xml
(cd dist && shasum -a 256 Reclaim.dmg Reclaim.zip appcast.xml > SHA256SUMS.txt)
echo 'Generated and verified the signed release update feed.'
