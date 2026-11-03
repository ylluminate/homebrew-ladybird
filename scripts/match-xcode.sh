#!/usr/bin/env bash
#
# Make upstream's Xcode pin usable on this runner.
#
# usage: match-xcode.sh <setup-action.yml> [applications-dir]
#
# Upstream's setup action pins the Xcode its own machines have (for example
# '27'). GitHub's images do not always carry that version, and setup-xcode
# then fails before anything is built. If no stable Xcode on this runner
# satisfies the pin, rewrite it to 'latest-stable' so the build uses the newest
# Xcode the runner has, and say so in the log. A pin the runner can satisfy is
# left alone.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[[ $# -ge 1 ]] || die "usage: $0 <setup-action.yml> [applications-dir]"
action=$1
apps=${2:-/Applications}
[[ -f $action ]] || die "no such file: $action"

pin=$(sed -n "s/^ *xcode-version: *'\([^']*\)'.*$/\1/p" "$action" | head -n1)
if [[ -z $pin ]]; then
    echo "No Xcode pin in $action"
    exit 0
fi

# setup-xcode treats '27' as any stable 27.x and '26.6' as any 26.6.x. Stable
# Xcodes are installed as Xcode_<digits and dots>.app; betas and release
# candidates carry a suffix and do not count.
found=
for app in "$apps"/Xcode_*.app; do
    [[ -e $app ]] || continue
    version=$(basename "$app" .app)
    version=${version#Xcode_}
    [[ $version =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
    if [[ $version == "$pin" || $version == "$pin".* ]]; then
        found=$app
        break
    fi
done

if [[ -n $found ]]; then
    echo "Upstream pins Xcode $pin; this runner has $(basename "$found")"
    exit 0
fi

echo "::warning::Upstream pins Xcode $pin, which this runner does not have; using the newest stable Xcode instead"
sed -i.orig "s/xcode-version: *'$pin'/xcode-version: 'latest-stable'/" "$action"
rm -f "$action.orig"
