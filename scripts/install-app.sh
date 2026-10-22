#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_app="$project_root/dist/Reclaim.app"
open_app=false
source_selected=false
usage() { echo 'Usage: install-app.sh (--built | --from /path/to/Reclaim.app) [--open]'; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --built)
            [[ "$source_selected" == false ]] || { usage >&2; exit 1; }
            source_selected=true; shift ;;
        --from)
            [[ $# -ge 2 && "$source_selected" == false ]] || { usage >&2; exit 1; }
            source_app="$2"; source_selected=true; shift 2 ;;
        --open) open_app=true; shift ;;
        --help) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done
[[ "$source_selected" == true ]] || { usage >&2; echo 'Development builds run from dist/Reclaim Dev.app; this installer accepts signed releases only.' >&2; exit 1; }
if /usr/bin/pgrep -x Reclaim >/dev/null; then
    echo 'Quit Reclaim, then run this installer again.' >&2
    exit 1
fi

target_app='/Applications/Reclaim.app'
expected_id='local.timemachinexray.app'
[[ -d "$source_app" && ! -L "$source_app" && ! -L "$target_app" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist")" == "$expected_id" ]]
channel="$(/usr/libexec/PlistBuddy -c 'Print :ReclaimBuildChannel' "$source_app/Contents/Info.plist" 2>/dev/null || true)"
[[ -z "$channel" || "$channel" == Release ]] || { echo 'Development builds must not replace the production app.' >&2; exit 1; }
source_app="$(cd "$source_app" && pwd -P)"
[[ "$source_app" != "$target_app" ]] || { echo 'That app is already installed in Applications.' >&2; exit 1; }
if [[ -e "$target_app" ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target_app/Contents/Info.plist")" == "$expected_id" ]]
fi

stage_dir="$(mktemp -d /Applications/.reclaim-install.XXXXXX)"
backup_app=''
cleanup() {
    if [[ ! -e "$target_app" && -n "$backup_app" && -d "$backup_app" ]]; then
        mv "$backup_app" "$target_app"
    fi
    rm -rf "$stage_dir"
}
trap cleanup EXIT
/usr/bin/ditto "$source_app" "$stage_dir/Reclaim.app"
/usr/bin/codesign --verify --deep --strict "$stage_dir/Reclaim.app"
/usr/sbin/spctl --assess --type execute "$stage_dir/Reclaim.app"
if [[ -e "$target_app" ]]; then
    backup_root="$HOME/Library/Application Support/Reclaim/App Backups"
    mkdir -p "$backup_root"
    backup_dir="$(mktemp -d "$backup_root/$(date +%Y%m%d-%H%M%S).XXXXXX")"
    backup_app="$backup_dir/Reclaim.app"
    mv "$target_app" "$backup_app"
fi
mv "$stage_dir/Reclaim.app" "$target_app"
printf 'Installed %s\n' "$target_app"
if [[ -n "$backup_app" ]]; then printf 'Previous app saved at %s\n' "$backup_app"; fi
if [[ "$open_app" == true ]]; then /usr/bin/open "$target_app"; fi
