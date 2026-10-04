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
# What it does, in order:
#   1. cmake --install into a staging prefix. The install rules replace the
#      build-tree Contents/lib symlink with real libraries; the bundle in the
#      build tree itself is not relocatable and must never be shipped.
#   2. Move the helper processes from libexec/ into Contents/MacOS, the only
#      place the browser looks for them on macOS.
#   3. Deploy Qt (frameworks, platform plugin, qt.conf) with macdeployqt.
#   4. Copy in every other non-system library the bundle still reaches for
#      (vcpkg dylibs, Homebrew dylibs), repeating until nothing is missing.
#   5. Drop absolute LC_RPATHs and point everything at Contents/lib and
#      Contents/Frameworks instead.
#   6. Re-sign inside out. Helpers keep the hardened runtime and the exact
#      entitlements the upstream build gave them (WebContent and WebWorker
#      need allow-jit); a blanket `codesign --deep` would throw those away.

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

stage="$out/stage"
app="$out/Ladybird.app"
ent_dir="$out/entitlements"
contents="$app/Contents"

rm -rf "$stage" "$app" "$ent_dir"
mkdir -p "$ent_dir"

# --- 1. install ---------------------------------------------------------------

log "Installing $build into staging prefix"
cmake --install "$build" --prefix "$stage" --strip > "$out/install.log"

[[ -d "$stage/bundle/Ladybird.app" ]] || die "install did not produce bundle/Ladybird.app"
mv "$stage/bundle/Ladybird.app" "$app"
[[ -L "$contents/lib" ]] && die "Contents/lib is still the build-tree symlink"

# --- 2. helpers ---------------------------------------------------------------

helpers=()
for f in "$stage/libexec/"*; do
    [[ -f $f && -x $f ]] || continue
    name=$(basename "$f")
    ditto "$f" "$contents/MacOS/$name"
    helpers+=("$name")
done
[[ ${#helpers[@]} -gt 0 ]] || die "no helper processes in $stage/libexec"
log "Helpers: ${helpers[*]}"

# Record how upstream signed every executable in Contents/MacOS (helpers, and
# extras such as WebDriver) before anything below rewrites the files: its
# entitlements, and whether it uses the hardened runtime. Build tree copies
# still carry intact signatures; the bundle copy is the fallback.
extract_entitlements() { # <binary-or-bundle> <dest>
    codesign -d --entitlements - --xml "$1" > "$2" 2> /dev/null || return 1
    [[ -s $2 ]] && plutil -lint -s "$2" > /dev/null
}

executables=()
for f in "$contents/MacOS/"*; do
    name=$(basename "$f")
    [[ -f $f && $name != Ladybird ]] || continue
    file -b "$f" | grep -q 'Mach-O' || continue
    executables+=("$name")
    source_binary=$f
    for candidate in "$build/libexec/$name" "$build/bin/$name"; do
        [[ -f $candidate ]] && { source_binary=$candidate; break; }
    done
    if ! extract_entitlements "$source_binary" "$ent_dir/$name.plist"; then
        rm -f "$ent_dir/$name.plist"
        for helper in "${helpers[@]}"; do
            [[ $helper == "$name" ]] && die "could not read entitlements for helper $name"
        done
    fi
    if codesign -dv "$source_binary" 2>&1 | grep -q 'flags=.*runtime'; then
        touch "$ent_dir/$name.runtime"
    fi
done

if ! extract_entitlements "$build/bin/Ladybird.app" "$ent_dir/Ladybird.plist"; then
    echo "warning: falling back to Meta/DebugEntitlements.plist for the main app" >&2
    cp "$src/Meta/DebugEntitlements.plist" "$ent_dir/Ladybird.plist"
fi

# --- 3. Qt ----------------------------------------------------------------------

vcpkg_libs=()
for d in "$build"/vcpkg_installed/*/lib; do
    [[ -d $d ]] && vcpkg_libs+=("$d")
done

qt_prefix=$(qmake -query QT_INSTALL_PREFIX 2> /dev/null || brew --prefix qt)
macdeployqt="$qt_prefix/bin/macdeployqt"
[[ -x $macdeployqt ]] || macdeployqt=$(command -v macdeployqt) || die "macdeployqt not found"

deploy_args=(-always-overwrite -verbose=1 "-libpath=$contents/lib")
for d in "${vcpkg_libs[@]}"; do deploy_args+=("-libpath=$d"); done
for name in "${executables[@]}"; do deploy_args+=("-executable=$contents/MacOS/$name"); done

log "Deploying Qt with $macdeployqt"
"$macdeployqt" "$app" "${deploy_args[@]}" 2>&1 | tee "$out/macdeployqt.log"
[[ -d "$contents/PlugIns/platforms" ]] || die "macdeployqt did not deploy the Qt platform plugin"

# --- 4. bundle closure --------------------------------------------------------

is_macho() { file -b "$1" | grep -q 'Mach-O'; }

macho_files() {
    find "$contents" -type f ! -name '*.a' -print0 | while IFS= read -r -d '' f; do
        is_macho "$f" && printf '%s\n' "$f"
    done
}

own_id() { otool -D "$1" | sed -n '2p'; }

deps_of() { # load commands, excluding the library's own install name
    local id
    id=$(own_id "$1")
    otool -L "$1" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        [[ $dep == "$id" ]] || printf '%s\n' "$dep"
    done
}

rpaths_of() {
    otool -l "$1" | awk '/cmd LC_RPATH/ {getline; getline; print $2}'
}

is_system() {
    case "$1" in
        /usr/lib/* | /System/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Split "Foo.framework/Versions/A/Foo" style paths.
framework_root() { # <path> -> ".../Foo.framework" or empty
    [[ $1 =~ ^(.*/)?([^/]+\.framework)/ ]] || return 0
    printf '%s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# Find the real file behind an @rpath reference by looking where the original
# build would have looked.
locate_rpath_dep() { # <file> <rel>
    local file=$1 rel=$2 dir rp
    for dir in "$contents/lib" "$contents/Frameworks" "$build/lib" "${vcpkg_libs[@]}" "$qt_prefix/lib"; do
        [[ -e "$dir/$rel" ]] && { printf '%s\n' "$dir/$rel"; return 0; }
    done
    while read -r rp; do
        case "$rp" in /*) [[ -e "$rp/$rel" ]] && { printf '%s\n' "$rp/$rel"; return 0; } ;; esac
    done < <(rpaths_of "$file")
    return 1
}

# Copy a library or framework into the bundle. Prints the reference the
# dependant should use from now on.
import_dep() { # <real-path> <rel-name>
    local real=$1 rel=$2 fw
    fw=$(framework_root "$rel")
    if [[ -n $fw ]]; then
        local src_fw name
        src_fw=$(framework_root "$real")
        name=$(basename "$fw")
        if [[ ! -d "$contents/Frameworks/$name" ]]; then
            log "  + Frameworks/$name" >&2
            mkdir -p "$contents/Frameworks"
            ditto "$src_fw" "$contents/Frameworks/$name"
            rm -rf "$contents/Frameworks/$name/Headers" "$contents/Frameworks/$name/Versions/"*/Headers
            chmod -R u+w "$contents/Frameworks/$name"
            install_name_tool -id "@rpath/$rel" "$contents/Frameworks/$rel" 2> /dev/null
        fi
        printf '@rpath/%s\n' "$rel"
    else
        local name
        name=$(basename "$rel")
        if [[ ! -e "$contents/lib/$name" ]]; then
            log "  + lib/$name" >&2
            cp -L "$real" "$contents/lib/$name"
            chmod u+w "$contents/lib/$name"
            install_name_tool -id "@rpath/$name" "$contents/lib/$name" 2> /dev/null
        fi
        printf '@rpath/%s\n' "$name"
    fi
}

log "Collecting libraries the bundle still depends on"
pass=0
while :; do
    pass=$((pass + 1))
    [[ $pass -le 20 ]] || die "dependency closure did not settle"
    changed=0
    while read -r f; do
        while read -r dep; do
            [[ -n $dep ]] || continue
            is_system "$dep" && continue
            case "$dep" in
                @rpath/*)
                    rel=${dep#@rpath/}
                    [[ -e "$contents/lib/$rel" || -e "$contents/Frameworks/$rel" ]] && continue
                    real=$(locate_rpath_dep "$f" "$rel") || die "$(basename "$f"): cannot find $dep"
                    import_dep "$real" "$rel" > /dev/null
                    changed=1
                    ;;
                @executable_path/* | @loader_path/*)
                    # Resolved and checked by verify-bundle.sh.
                    ;;
                /*)
                    [[ -e $dep ]] || die "$(basename "$f"): missing $dep"
                    fw=$(framework_root "$dep")
                    if [[ -n $fw ]]; then
                        rel="$(basename "$fw")${dep#"$fw"}"
                    else
                        rel=$(basename "$dep")
                    fi
                    new=$(import_dep "$dep" "$rel")
                    install_name_tool -change "$dep" "$new" "$f"
                    changed=1
                    ;;
            esac
        done < <(deps_of "$f")
    done < <(macho_files)
    [[ $changed -eq 1 ]] || break
done

# --- 5. rpaths ------------------------------------------------------------------

log "Normalising rpaths"
while read -r f; do
    # One "../" per directory between the file and Contents/.
    up=$(dirname "${f#"$contents/"}" | sed -E 's#[^/]+#..#g')/

    while read -r rp; do
        case "$rp" in
            @*) ;;
            *) install_name_tool -delete_rpath "$rp" "$f" ;;
        esac
    done < <(rpaths_of "$f")

    deps=$(deps_of "$f")
    grep -q '^@rpath/' <<< "$deps" || continue
    existing=$(rpaths_of "$f")
    for want in "@loader_path/${up}lib" "@loader_path/${up}Frameworks"; do
        grep -qxF "$want" <<< "$existing" || install_name_tool -add_rpath "$want" "$f"
    done
done < <(macho_files)

# --- metadata ---------------------------------------------------------------------

set_plist_string() { # <key> <value>; upstream's Info.plist may lack the key
    /usr/libexec/PlistBuddy -c "Delete :$1" "$contents/Info.plist" 2> /dev/null || true
    /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$contents/Info.plist"
}

[[ -z $bundle_version ]] || set_plist_string CFBundleVersion "$bundle_version"
set_plist_string LadybirdSourceCommit "$(git -C "$src" rev-parse HEAD 2> /dev/null || echo unknown)"

# --- 6. signing -------------------------------------------------------------------

sign() { codesign --force --sign - --timestamp=none "$@"; }

log "Signing"
xattr -cr "$app"

while IFS= read -r -d '' lib; do
    sign "$lib"
done < <(find "$contents" -type f -name '*.dylib' ! -path '*.framework/*' -print0)

if [[ -d "$contents/Frameworks" ]]; then
    for fw in "$contents/Frameworks/"*.framework; do
        [[ -d $fw ]] || continue
        # A framework without a usable Info.plist cannot be signed as a
        # bundle; sign its binary instead.
        if ! sign "$fw" 2> /dev/null; then
            sign "$fw/Versions/Current/$(basename "$fw" .framework)"
        fi
    done
fi

for name in "${executables[@]}"; do
    args=()
    [[ -f "$ent_dir/$name.plist" ]] && args+=(--entitlements "$ent_dir/$name.plist")
    [[ -f "$ent_dir/$name.runtime" ]] && args+=(--options runtime)
    sign ${args[@]+"${args[@]}"} "$contents/MacOS/$name"
done

sign --entitlements "$ent_dir/Ladybird.plist" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

rm -rf "$stage"
log "Packaged $app ($(du -sh "$app" | cut -f1))"
