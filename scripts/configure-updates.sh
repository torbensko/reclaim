#!/bin/bash
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
tool="$PWD/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
[[ -x "$tool" ]] || { echo 'Run swift package resolve first.' >&2; exit 1; }
account=local.timemachinexray.app
# Never rotate a published update key implicitly.
public_key="$("$tool" --account "$account" -p)"
[[ "$public_key" == "$(cat Resources/SparklePublicKey.txt)" ]] || {
    echo 'The Keychain key does not match the committed public key. Stop and review key recovery or rotation.' >&2
    exit 1
}
secret_dir="$(mktemp -d "${TMPDIR:-/tmp}/reclaim-update-key.XXXXXX")"
trap 'rm -rf "$secret_dir"' EXIT
"$tool" --account "$account" -x "$secret_dir/key"
# The private key goes directly to GitHub's encrypted secret store, never stdout.
gh secret set SPARKLE_PRIVATE_KEY --repo torbensko/reclaim < "$secret_dir/key"
echo 'Configured the Reclaim update-signing secret. The original key remains in your login Keychain.'
