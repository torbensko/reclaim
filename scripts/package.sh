#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-release}"
[[ "$mode" == release || "$mode" == --unsigned ]] || { echo 'Usage: package.sh [--unsigned]' >&2; exit 1; }
if [[ "$mode" == release ]]; then
    : "${SIGNING_IDENTITY:?Developer ID Application signing identity is required}"
    : "${APPLE_ID:?Missing APPLE_ID}"
    : "${APPLE_ID_PASSWORD:?Missing APPLE_ID_PASSWORD}"
    : "${APPLE_TEAM_ID:?Missing APPLE_TEAM_ID}"
    [[ "$SIGNING_IDENTITY" == 'Developer ID Application:'* ]] || { echo 'A Developer ID Application certificate is required.' >&2; exit 1; }
    export DISTRIBUTION=1
else
    export SIGNING_IDENTITY=- DISTRIBUTION=0 RECLAIM_PREVIEW=1
fi
./scripts/build-app.sh --universal
app_name=Reclaim
if [[ "$mode" == --unsigned ]]; then app_name='Reclaim Dev'; fi
app="$PWD/dist/$app_name.app"
for binary in "$app/Contents/MacOS/Reclaim" "$app/Contents/Helpers/ReclaimWorker"; do
    for architecture in arm64 x86_64; do
        lipo "$binary" -verify_arch "$architecture"
    done
done
stage="$(mktemp -d "$PWD/dist/package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
notarize() {
    xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --password "$APPLE_ID_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" --wait --timeout 30m --output-format json > "$2"
    python3 - "$2" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    result = json.load(f)
if result.get('status') != 'Accepted':
    sys.exit(f"Notarization failed: {result.get('id')} {result.get('status')}. Retrieve the notarytool log before retrying.")
PY
}
suffix=-unsigned
if [[ "$mode" == release ]]; then
    suffix=''
    ditto -c -k --keepParent "$app" "$stage/submission.zip"
    notarize "$stage/submission.zip" "$PWD/dist/notary-app.json"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose "$app"
fi
mkdir -p "$stage/image"
ditto "$app" "$stage/image/$app_name.app"
ln -s /Applications "$stage/image/Applications"
cp README.md "$stage/image/README.md"
dmg="$PWD/dist/Reclaim${suffix}.dmg"
zip="$PWD/dist/Reclaim${suffix}.zip"
hdiutil create -volname Reclaim -srcfolder "$stage/image" -ov -format UDZO "$dmg"
if [[ "$mode" == release ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$dmg"
    notarize "$dmg" "$PWD/dist/notary-dmg.json"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
fi
ditto -c -k --keepParent "$app" "$zip"
(cd dist && shasum -a 256 "Reclaim${suffix}.dmg" "Reclaim${suffix}.zip" > "SHA256SUMS${suffix}.txt")
printf 'Packaged %s\n' "$dmg"
