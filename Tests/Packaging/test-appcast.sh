#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/../.."
tools="$PWD/.build/artifacts/sparkle/Sparkle/bin"
[[ -d 'dist/Reclaim Dev.app' ]] || { echo 'Build Reclaim Dev first.' >&2; exit 1; }
fixture="$(mktemp -d "$PWD/dist/update-fixture.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/archives"
# Generated signing keys and copies of our own build only. No installed app,
# production signing key, network feed, or user storage is changed.
swift - "$fixture" <<'SWIFT'
import CryptoKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("private.txt"), atomically: true, encoding: .utf8)
try key.publicKey.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("public.txt"), atomically: true, encoding: .utf8)
let other = Curve25519.Signing.PrivateKey()
try other.publicKey.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("wrong-public.txt"), atomically: true, encoding: .utf8)
SWIFT
ditto 'dist/Reclaim Dev.app' "$fixture/Reclaim.app"
plist="$fixture/Reclaim.app/Contents/Info.plist"
key="$(cat "$fixture/public.txt")"
version="$(cat VERSION)"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Reclaim' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.reclaim.update-fixture' "$plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 777' "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $key" "$plist"
/usr/libexec/PlistBuddy -c 'Add :SUFeedURL string https://github.com/torbensko/reclaim/releases/latest/download/appcast.xml' "$plist"
/usr/libexec/PlistBuddy -c 'Add :SURequireSignedFeed bool true' "$plist"
/usr/libexec/PlistBuddy -c 'Add :SUVerifyUpdateBeforeExtraction bool true' "$plist"
codesign --force --sign - "$fixture/Reclaim.app"
ditto -c -k --keepParent "$fixture/Reclaim.app" "$fixture/archives/Reclaim.zip"
cp RELEASE_NOTES.md "$fixture/archives/Reclaim.md"
"$tools/generate_appcast" --ed-key-file "$fixture/private.txt" --maximum-deltas 0 --embed-release-notes \
    --download-url-prefix "https://github.com/torbensko/reclaim/releases/download/v$version/" "$fixture/archives"
feed="$fixture/archives/appcast.xml"
archive="$fixture/archives/Reclaim.zip"
"$tools/sign_update" --verify --ed-key-file "$fixture/private.txt" "$feed"
swift scripts/verify-appcast.swift "$feed" "$archive" "$fixture/public.txt" "$version" 777
if swift scripts/verify-appcast.swift "$feed" "$archive" "$fixture/wrong-public.txt" "$version" 777; then
    echo 'Wrong signing key was accepted.' >&2; exit 1
fi
cp "$archive" "$fixture/tampered.zip"
printf 'tampered' >> "$fixture/tampered.zip"
if swift scripts/verify-appcast.swift "$feed" "$fixture/tampered.zip" "$fixture/public.txt" "$version" 777; then
    echo 'Tampered archive was accepted.' >&2; exit 1
fi
cp "$feed" "$fixture/tampered.xml"
python3 - "$fixture/tampered.xml" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
assert '/releases/download/v' in text
path.write_text(text.replace('/releases/download/v', '/releases/download/tampered-v', 1))
PY
if "$tools/sign_update" --verify --ed-key-file "$fixture/private.txt" "$fixture/tampered.xml"; then
    echo 'Tampered feed was accepted.' >&2; exit 1
fi
echo 'Update packaging checks passed: valid signatures accepted; wrong keys and modified archives/feeds rejected.'
