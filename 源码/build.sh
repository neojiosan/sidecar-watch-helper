#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_dir="$(dirname "$source_dir")"
app_name="随航观影助手.app"
target="$project_dir/$app_name"
stage_parent="${TMPDIR:-/tmp}"
# Sign outside Finder-managed folders when possible, then rename on the same volume.
if [[ "$(stat -f %d "$stage_parent")" != "$(stat -f %d "$project_dir")" ]]; then
    stage_parent="$project_dir"
fi
stage="$(mktemp -d "$stage_parent/.watch-build.XXXXXX")"
# Only the temporary directory created by this build is removed.
trap 'rm -rf "$stage"' EXIT
bundle="$stage/$app_name"

if [[ -e "$target" || -L "$target" ]]; then
    info="$target/Contents/Info.plist"
    if [[ -L "$target" ]] || [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$info" 2>/dev/null || true)" != "local.neo.WatchWithSidecar" ]]; then
        echo "目标路径中已有其他文件，请先移开：$target" >&2
        exit 1
    fi
    # Preserve any additional bundle resources during a rebuild.
    /usr/bin/ditto "$target" "$bundle"
fi

mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$source_dir/Info.plist" "$bundle/Contents/Info.plist"
/usr/bin/plutil -lint "$bundle/Contents/Info.plist"

flags=(-fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter -O2 -mmacosx-version-min=13.0)
/usr/bin/xcrun clang "${flags[@]}" -framework AppKit "$source_dir/BuildAssets.m" -o "$stage/build-assets"
"$stage/build-assets" "$bundle/Contents/Resources/AppIcon.icns"

/usr/bin/xcrun clang "${flags[@]}" -framework AppKit -framework ApplicationServices -framework CoreAudio -framework IOKit \
    "$source_dir/main.m" "$source_dir/WatchSession.m" "$source_dir/SidecarDevice.m" \
    "$source_dir/WatchPlayer.m" "$source_dir/AutoWatch.m" "$source_dir/PlaybackMonitor.m" \
    "$source_dir/NetflixPlayback.m" "$source_dir/TVPlayback.m" "$source_dir/TVSignals.m" -o "$bundle/Contents/MacOS/WatchWithSidecar"
# These Finder metadata fields are prohibited in signed code bundles.
/usr/bin/xattr -rd com.apple.FinderInfo "$bundle" 2>/dev/null || true
/usr/bin/xattr -rd com.apple.ResourceFork "$bundle" 2>/dev/null || true
/usr/bin/codesign --force --sign - --timestamp=none "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
"$stage/build-assets" install "$bundle" "$target"
# A File Provider managing the Desktop may attach FinderInfo when it receives an app.
# The staged bundle passed strict verification before the atomic move.
/usr/bin/codesign --verify "$target"
echo "已生成 $target"
