#!/usr/bin/env bash
#
# Print Casks/ladybird-nightly.rb for one published build.
#
# usage: render-cask.sh <version> <commit> <sha256> <min-macos> [repository]
#
#   version     build stamp, e.g. 2026.10.03.1723
#   commit      upstream commit the build came from (shortened to 10 chars)
#   sha256      checksum of Ladybird-macos-arm64.zip
#   min-macos   highest LC_BUILD_VERSION minos in the bundle, e.g. 26.0
#   repository  owner/name of this tap (default: $GITHUB_REPOSITORY)

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

[[ $# -ge 4 ]] || die "usage: $0 <version> <commit> <sha256> <min-macos> [repository]"

version=$1
commit=${2:0:10}
sha256=$3
min_macos=$4
repository=${5:-${GITHUB_REPOSITORY:-}}

[[ $version =~ ^[0-9]{4}(\.[0-9]+)+$ ]] || die "bad version: $version"
[[ $commit =~ ^[0-9a-f]{10}$ ]] || die "bad commit: $2"
[[ $sha256 =~ ^[0-9a-f]{64}$ ]] || die "bad sha256: $sha256"
[[ $repository =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "bad repository: $repository"

# Homebrew names macOS releases (a bare name means that release or newer); map
# the bundle's minimum to the oldest one that satisfies it.
case "${min_macos%%.*}" in
    0 | 1[0-3]) macos=":ventura" ;;
    14) macos=":sonoma" ;;
    15) macos=":sequoia" ;;
    26) macos=":tahoe" ;;
    *) die "no Homebrew name known for macOS $min_macos; extend render-cask.sh" ;;
esac

cat << EOF
cask "ladybird-nightly" do
  version "$version,$commit"
  sha256 "$sha256"

  url "https://github.com/$repository/releases/download/nightly-#{version.csv.first}-#{version.csv.second}/Ladybird-macos-arm64.zip"
  name "Ladybird Nightly"
  desc "Unofficial rolling build of the Ladybird web browser"
  homepage "https://github.com/$repository"

  livecheck do
    url :url
    regex(/^nightly-(\d+(?:\.\d+)+)-(\h+)\$/i)
    strategy :github_latest do |json, regex|
      match = json["tag_name"]&.match(regex)
      next if match.blank?

      "#{match[1]},#{match[2]}"
    end
  end

  depends_on arch: :arm64
  depends_on macos: $macos

  app "Ladybird.app"

  # The app is ad-hoc signed and not notarized, so Gatekeeper would refuse to
  # open it straight out of a quarantined download.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Ladybird.app"]
  end

  zap trash: [
    "~/Library/Application Support/Ladybird",
    "~/Library/Caches/Ladybird",
    "~/Library/Preferences/Ladybird",
    "~/Library/Preferences/org.ladybird.Ladybird.plist",
    "~/Library/Saved Application State/org.ladybird.Ladybird.savedState",
  ]

  caveats <<~CAVEATS
    This is an unofficial build of Ladybird's development branch, made from
    LadybirdBrowser/ladybird@#{version.csv.second}. Ladybird is pre-alpha
    software. Report problems with the build itself at
      https://github.com/$repository/issues
  CAVEATS
end
EOF
