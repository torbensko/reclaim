#!/bin/bash
# Run only on an ephemeral GitHub runner; never print certificate or password values.
set -euo pipefail
: "${RUNNER_TEMP:?}"
: "${GITHUB_ENV:?}"
: "${CERTIFICATE_P12:?Missing CERTIFICATE_P12 secret}"
: "${CERTIFICATE_PASSWORD:?Missing CERTIFICATE_PASSWORD secret}"
KEYCHAIN_PATH="$RUNNER_TEMP/reclaim-signing.keychain-db"
P12_PATH="$RUNNER_TEMP/reclaim-certificate.p12"
KEYCHAIN_PASSWORD="$(openssl rand -base64 32)"
echo "::add-mask::$KEYCHAIN_PASSWORD"
printf 'KEYCHAIN_PATH=%s\n' "$KEYCHAIN_PATH" >> "$GITHUB_ENV"
trap 'rm -f "$P12_PATH"' EXIT
umask 077
printf '%s' "$CERTIFICATE_P12" | base64 --decode > "$P12_PATH"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$P12_PATH" -k "$KEYCHAIN_PATH" -P "$CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security list-keychains -d user -s "$KEYCHAIN_PATH" login.keychain-db
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p')"
[[ -n "$IDENTITY" && "$IDENTITY" != *$'\n'* ]] || { echo 'Supply exactly one Developer ID Application identity.' >&2; exit 1; }
printf 'SIGNING_IDENTITY=%s\n' "$IDENTITY" >> "$GITHUB_ENV"
