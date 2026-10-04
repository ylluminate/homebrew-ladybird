#!/usr/bin/env bash
#
# Check that a packaged Ladybird.app is complete and relocatable, then start it.
#
# usage: verify-bundle.sh <Ladybird.app> [github-output-file]
#
# Fails if any Mach-O in the bundle loads something that is neither part of
# macOS nor inside the bundle, if any absolute LC_RPATH survived packaging, or
# if a copy of the app in an unrelated directory cannot render a page. Prints
# the highest minimum macOS version found in the bundle, and appends
# `min_macos=<version>` to the given output file when one is passed.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

[[ $# -ge 1 ]] || die "usage: $0 <Ladybird.app> [github-output-file]"
app=$(cd "$1" && pwd)
contents="$app/Contents"
output_file=${2:-}

log "Checking signature"
codesign --verify --deep --strict "$app"

log "Checking load commands"
problems=0
min_macos=0

version_gt() { # a > b for dotted versions
    [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1) == "$1" ]]
}

while IFS= read -r -d '' f; do
    file -b "$f" | grep -q 'Mach-O' || continue
    name=${f#"$contents/"}
    dir=$(dirname "$f")
    loadcmds=$(otool -l "$f")

    rpaths=()
    while read -r rp; do
        [[ -n $rp ]] || continue
        case "$rp" in
            @loader_path*) rpaths+=("${dir}${rp#@loader_path}") ;;
            @executable_path*) rpaths+=("$contents/MacOS${rp#@executable_path}") ;;
            *)
                echo "  $name: absolute rpath $rp"
                problems=$((problems + 1))
                ;;
        esac
    done < <(awk '/cmd LC_RPATH/ {getline; getline; print $2}' <<< "$loadcmds")
    # Libraries are also searched through the rpaths of the executable that loaded them.
    rpaths+=("$contents/lib" "$contents/Frameworks")

    id=$(otool -D "$f" | sed -n '2p')
    while read -r dep; do
        [[ -n $dep && $dep != "$id" ]] || continue
        ok=
        case "$dep" in
            /usr/lib/* | /System/*) continue ;;
            @rpath/*)
                for rp in "${rpaths[@]}"; do
                    if [[ -e "$rp/${dep#@rpath/}" ]]; then
                        ok=1
                        break
                    fi
                done
                ;;
            @loader_path/*) [[ -e "$dir/${dep#@loader_path/}" ]] && ok=1 ;;
            @executable_path/*) [[ -e "$contents/MacOS/${dep#@executable_path/}" ]] && ok=1 ;;
        esac
        if [[ -z $ok ]]; then
            echo "  $name: unresolved $dep"
            problems=$((problems + 1))
        fi
    done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')

    minos=$(awk '/cmd LC_BUILD_VERSION/ {found=1} found && $1 == "minos" {print $2; exit}' <<< "$loadcmds")
    if [[ -n $minos ]] && version_gt "$minos" "$min_macos"; then
        min_macos=$minos
    fi
done < <(find "$contents" -type f -print0)

[[ $problems -eq 0 ]] || die "$problems problem(s) in the bundle"
echo "Minimum macOS: $min_macos"
[[ -z $output_file ]] || echo "min_macos=$min_macos" >> "$output_file"

# Run a copy from somewhere else entirely, with a space in the path. In CI the
# build tree's libraries and Homebrew's Qt are moved out of the way first, so
# anything still loaded from there makes this fail.
log "Smoke testing a relocated copy"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/smoke test"
ditto "$app" "$scratch/smoke test/Ladybird.app"
exe="$scratch/smoke test/Ladybird.app/Contents/MacOS/Ladybird"

with_timeout() { perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$@"; }

with_timeout 60 "$exe" --version

marker="ladybird-smoke-$RANDOM$RANDOM"
set +e
with_timeout 180 "$exe" --headless=text --temporary-profile \
    "data:text/html,<title>smoke</title><p>$marker</p>" \
    > "$scratch/stdout" 2> "$scratch/stderr"
status=$?
set -e

if [[ $status -ne 0 ]] || ! grep -q "$marker" "$scratch/stdout"; then
    echo "--- stdout"
    cat "$scratch/stdout"
    echo "--- stderr"
    tail -n 50 "$scratch/stderr"
    die "headless page load failed (exit $status)"
fi

log "Bundle OK"
