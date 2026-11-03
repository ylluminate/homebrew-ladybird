#!/usr/bin/env bash
#
# Tests for the scripts that can run without a Ladybird build:
# check-upstream.sh and render-cask.sh.

set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
scripts="$root/scripts"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }
check() { # <description> <command...>
    local desc=$1
    shift
    if "$@" > /dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
value() { sed -n "s/^$1=//p"; }
expect() { # <description> <actual> <expected>
    if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi
}

# A throwaway upstream with a branch and an annotated tag.
upstream="$tmp/upstream"
git init -q -b master "$upstream"
git -C "$upstream" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
first=$(git -C "$upstream" rev-parse HEAD)
git -C "$upstream" -c user.name=t -c user.email=t@t tag -a v1 -m v1
git -C "$upstream" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
head=$(git -C "$upstream" rev-parse HEAD)
export UPSTREAM_URL="$upstream"

sha=$(printf 'a%.0s' {1..64})
cask="$tmp/ladybird-nightly.rb"

# --- check-upstream.sh -----------------------------------------------------------

out=$("$scripts/check-upstream.sh" master false "$tmp/missing.rb")
expect "builds when there is no cask yet" "$(value build <<< "$out")" "true"
expect "resolves a branch" "$(value commit <<< "$out")" "$head"
check "emits a build stamp" grep -Eq '^20[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]{4}$' <<< "$(value version <<< "$out")"

"$scripts/render-cask.sh" 2026.10.03.1723 "$head" "$sha" 26.0 owner/homebrew-tap > "$cask"
out=$("$scripts/check-upstream.sh" master false "$cask")
expect "skips a commit that is already published" "$(value build <<< "$out")" "false"
expect "reports the published commit" "$(value previous <<< "$out")" "${head:0:10}"

out=$("$scripts/check-upstream.sh" master true "$cask")
expect "force rebuilds a published commit" "$(value build <<< "$out")" "true"

out=$("$scripts/check-upstream.sh" v1 false "$cask")
expect "peels annotated tags" "$(value commit <<< "$out")" "$first"
expect "builds a different commit" "$(value build <<< "$out")" "true"

out=$("$scripts/check-upstream.sh" "$first" false "$cask")
expect "accepts a full commit hash" "$(value commit <<< "$out")" "$first"

check "fails on an unknown ref" bash -c "! '$scripts/check-upstream.sh' no-such-branch false '$cask'"

# --- render-cask.sh ----------------------------------------------------------------

check "cask pins version and commit" grep -q '^  version "2026.10.03.1723,'"${head:0:10}"'"$' "$cask"
check "cask pins the checksum" grep -q "^  sha256 \"$sha\"$" "$cask"
check "maps macOS 26 to tahoe" grep -q 'depends_on macos: :tahoe' "$cask"
check "url follows the tag scheme" grep -q 'releases/download/nightly-#{version.csv.first}-#{version.csv.second}/' "$cask"
check "cask is valid Ruby" ruby -c "$cask"

"$scripts/render-cask.sh" 2026.10.03.1723 "$head" "$sha" 14.0 owner/homebrew-tap > "$tmp/sonoma.rb"
check "maps macOS 14 to sonoma" grep -q 'depends_on macos: :sonoma' "$tmp/sonoma.rb"

"$scripts/render-cask.sh" 2026.10.03.1723 "$head" "$sha" 27.0 owner/homebrew-tap > "$tmp/golden_gate.rb"
check "maps macOS 27 to golden_gate" grep -q 'depends_on macos: :golden_gate' "$tmp/golden_gate.rb"

check "rejects a bad checksum" bash -c "! '$scripts/render-cask.sh' 2026.10.03.1723 $head nothex 26.0 owner/tap"
check "rejects a bad version" bash -c "! '$scripts/render-cask.sh' latest $head $sha 26.0 owner/tap"
check "rejects an unknown macOS" bash -c "! '$scripts/render-cask.sh' 2026.10.03.1723 $head $sha 99.0 owner/tap"
check "requires a repository" bash -c "unset GITHUB_REPOSITORY; ! '$scripts/render-cask.sh' 2026.10.03.1723 $head $sha 26.0"

# --- match-xcode.sh ------------------------------------------------------------------

# An upstream setup action pinning <pin>, and an /Applications holding the given Xcodes.
xcode_fixture() { # <name> <pin> <xcode-app-name>...
    local dir="$tmp/xcode-$1" pin=$2
    shift 2
    mkdir -p "$dir/Applications"
    printf "    - uses: maxim-lobanov/setup-xcode@v1\n      with:\n        xcode-version: '%s'\n" "$pin" > "$dir/action.yml"
    for app in "$@"; do mkdir -p "$dir/Applications/$app"; done
    printf '%s\n' "$dir"
}
pin_of() { sed -n "s/^ *xcode-version: *'\(.*\)'$/\1/p" "$1/action.yml"; }

d=$(xcode_fixture major-present 27 Xcode_26.6.app Xcode_27.1.app)
"$scripts/match-xcode.sh" "$d/action.yml" "$d/Applications" > /dev/null
expect "keeps a pin the runner has" "$(pin_of "$d")" "27"

d=$(xcode_fixture exact-present 26.6 Xcode_26.5.app Xcode_26.6.app)
"$scripts/match-xcode.sh" "$d/action.yml" "$d/Applications" > /dev/null
expect "keeps an exact pin the runner has" "$(pin_of "$d")" "26.6"

d=$(xcode_fixture major-missing 27 Xcode_26.5.app Xcode_26.6.app)
"$scripts/match-xcode.sh" "$d/action.yml" "$d/Applications" > /dev/null
expect "falls back when the runner lacks the pinned Xcode" "$(pin_of "$d")" "latest-stable"

d=$(xcode_fixture prerelease-only 27 Xcode_26.6.app Xcode_27.2_Release_Candidate.app Xcode_27.0_beta.app)
"$scripts/match-xcode.sh" "$d/action.yml" "$d/Applications" > /dev/null
expect "does not count betas or release candidates" "$(pin_of "$d")" "latest-stable"

d=$(xcode_fixture prefix-only 2 Xcode_26.6.app)
"$scripts/match-xcode.sh" "$d/action.yml" "$d/Applications" > /dev/null
expect "matches whole version components" "$(pin_of "$d")" "latest-stable"

mkdir -p "$tmp/xcode-no-pin/Applications"
echo "runs: {}" > "$tmp/xcode-no-pin/action.yml"
check "accepts an action without an Xcode pin" "$scripts/match-xcode.sh" "$tmp/xcode-no-pin/action.yml" "$tmp/xcode-no-pin/Applications"
expect "leaves an action without a pin untouched" "$(cat "$tmp/xcode-no-pin/action.yml")" "runs: {}"

# Homebrew only lints casks that live in a tap, so mount a throwaway one.
if command -v brew > /dev/null && [[ -z ${SKIP_BREW:-} ]]; then
    tap_user="cask-check-$$"
    tap_dir="$(brew --repository)/Library/Taps/$tap_user/homebrew-check"
    trap 'rm -rf "$tmp" "$(dirname "$tap_dir")"' EXIT
    mkdir -p "$tap_dir/Casks"
    cp "$cask" "$tap_dir/Casks/ladybird-nightly.rb"
    export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1
    # Homebrew loads casks only from trusted taps. Trust the throwaway tap in a
    # private trust file, so the real one is never touched.
    export XDG_CONFIG_HOME="$tmp/config"
    brew trust "$tap_user/check" > /dev/null
    check "brew style accepts the cask" brew style "$tap_user/check/ladybird-nightly"
    check "brew audit accepts the cask" brew audit --cask --strict "$tap_user/check/ladybird-nightly"
fi

echo
if [[ $failures -eq 0 ]]; then
    echo "all tests passed"
else
    echo "$failures test(s) failed"
    exit 1
fi
