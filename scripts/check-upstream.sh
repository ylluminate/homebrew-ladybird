#!/usr/bin/env bash
#
# Decide whether a new build is needed.
#
# usage: check-upstream.sh <ref> <force> <cask-file>
#
# Resolves <ref> (branch, tag or full commit hash) in the upstream repository
# and compares it with the commit recorded in the cask. Prints key=value lines
# suitable for $GITHUB_OUTPUT:
#
#   commit=<full upstream hash>
#   previous=<commit in the current cask, or empty>
#   version=<UTC build stamp, YYYY.MM.DD.HHMM>
#   build=true|false

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[[ $# -eq 3 ]] || die "usage: $0 <ref> <force> <cask-file>"

ref=$1
force=$2
cask=$3
upstream_url=${UPSTREAM_URL:-https://github.com/LadybirdBrowser/ladybird.git}

if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
    commit=$ref
else
    refs=$(git ls-remote "$upstream_url" "refs/heads/$ref" "refs/tags/$ref" "refs/tags/$ref^{}")
    # Prefer the peeled commit of an annotated tag over the tag object itself.
    commit=$(awk '$2 ~ /\^\{\}$/ {print $1; exit}' <<< "$refs")
    [[ -n $commit ]] || commit=$(awk 'NR == 1 {print $1}' <<< "$refs")
    [[ -n $commit ]] || die "cannot resolve $ref in $upstream_url"
fi

previous=
if [[ -f $cask ]]; then
    previous=$(sed -n 's/^  version "[^,]*,\([0-9a-f]*\)"$/\1/p' "$cask")
fi

build=true
if [[ $force != true && -n $previous && $commit == "$previous"* ]]; then
    build=false
fi

echo "commit=$commit"
echo "previous=$previous"
echo "version=$(date -u +%Y.%m.%d.%H%M)"
echo "build=$build"
