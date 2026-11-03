#!/usr/bin/env bash
#
# Turn a finished Ladybird build tree into a self-contained, ad-hoc signed
# Ladybird.app that can be copied to any Apple silicon Mac.
#
# usage: package-macos.sh <source-dir> <build-dir> <output-dir> [bundle-version]
#
#   source-dir      Ladybird checkout
#   build-dir       configured and built tree (e.g. Build/release)
#   output-dir      receives Ladybird.app; recreated on every run
#   bundle-version  written to CFBundleVersion (optional)
#
# The core of the work is upstream's own Meta/package-macos-test-bundle.py.
# Upstream CI runs it on every macOS build to make a bundle that runs on
# another machine: it deploys the Qt platform plugin, copies in every library
# the bundle links (Qt and the rest of vcpkg's), replaces the build tree's
# rpaths with bundle-relative ones, and re-signs each helper with the
# entitlements the build gave it. Using it keeps this packaging in step with
# upstream's install layout, which changes often.
#
# Around it, this script:
#   1. installs the build into a staging prefix (cmake --install --strip);
#   2. adds Qt's native macOS widget style, which upstream's bundle leaves out,
#      before upstream's script runs, so its library and signing passes cover
#      the plugin too;
#   3. records the build version and upstream commit in Info.plist and reseals
#      the bundle, keeping every nested signature and the app's entitlements.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

[[ $# -ge 3 ]] || die "usage: $0 <source-dir> <build-dir> <output-dir> [bundle-version]"
[[ $(uname -s) == Darwin ]] || die "must run on macOS"

src=$(cd "$1" && pwd)
build=$(cd "$2" && pwd)
mkdir -p "$3"
out=$(cd "$3" && pwd)
bundle_version=${4:-}
python=${PYTHON:-python3}

packager="$src/Meta/package-macos-test-bundle.py"
[[ -f $packager ]] || die "upstream no longer has Meta/package-macos-test-bundle.py; this script needs updating"

stage="$out/stage"
app="$out/Ladybird.app"
contents="$app/Contents"

rm -rf "$stage" "$app"

# --- 1. install ---------------------------------------------------------------

log "Installing $build into a staging prefix"
cmake --install "$build" --prefix "$stage" --strip > "$out/install.log"
staged_app="$stage/bundle/Ladybird.app"
[[ -d $staged_app ]] || die "the install did not produce bundle/Ladybird.app"

# --- 2. native widget style -----------------------------------------------------

style=
for candidate in "$build"/vcpkg_installed/*/Qt6/plugins/styles/libqmacstyle.dylib; do
    [[ -f $candidate ]] && { style=$candidate; break; }
done
if [[ -n $style ]]; then
    log "Adding Qt's macOS style plugin"
    mkdir -p "$staged_app/Contents/PlugIns/styles"
    cp "$style" "$staged_app/Contents/PlugIns/styles/"
else
    echo "::warning::no libqmacstyle.dylib in the build's Qt; native controls will use Qt's generic style"
fi

# --- 3. upstream's packager -------------------------------------------------------

log "Making the bundle self-contained with $(basename "$packager")"
"$python" -I "$packager" --build-dir "$build" --install-dir "$stage" --output "$out/upstream-bundle.tar.gz"
rm -f "$out/upstream-bundle.tar.gz"
mv "$staged_app" "$app"
rm -rf "$stage"

# --- 4. metadata and final seal ---------------------------------------------------

set_plist_string() { # <key> <value>; upstream's Info.plist may lack the key
    /usr/libexec/PlistBuddy -c "Delete :$1" "$contents/Info.plist" 2> /dev/null || true
    /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$contents/Info.plist"
}

[[ -z $bundle_version ]] || set_plist_string CFBundleVersion "$bundle_version"
set_plist_string LadybirdSourceCommit "$(git -C "$src" rev-parse HEAD 2> /dev/null || echo unknown)"

# Editing Info.plist breaks the bundle's seal. Re-sign only the bundle itself;
# the libraries and helpers inside keep the signatures upstream's script gave
# them, and the app keeps its own entitlements.
codesign --force --sign - --timestamp=none --preserve-metadata=entitlements "$app"
codesign --verify --deep --strict --verbose=2 "$app"

log "Packaged $app ($(du -sh "$app" | cut -f1))"
