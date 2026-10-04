# homebrew-ladybird

Unofficial macOS builds of [Ladybird](https://ladybird.org), made from the
upstream `master` branch, plus a Homebrew tap to install and update them.

Builds are for Apple silicon only. Ladybird is pre-alpha software; these
builds exist so that following its development doesn't mean compiling it
yourself.

## Install

```sh
brew tap ylluminate/ladybird
brew install --cask ladybird-nightly
```

## Update

```sh
brew update
brew upgrade --cask ladybird-nightly
```

Every build has its own version (`2026.10.03.1723,7c1993b8e4` is a build
stamp plus the upstream commit), so a plain `brew upgrade` picks up new builds
and `brew outdated --cask` tells you when one is waiting.

To go back to an older build, download it from the
[releases](https://github.com/ylluminate/homebrew-ladybird/releases) page. The
last 14 builds are kept.

## How builds are made

A scheduled workflow runs at 05:23 and 17:23 UTC. It first checks the newest
upstream commit against the one in the cask and stops if nothing changed, so a
quiet day costs nothing.

When there is something new, it builds on a GitHub `macos-26` runner using
upstream's own CI setup (same Xcode, Homebrew dependencies and Rust toolchain),
with ccache and the vcpkg binary cache carried between runs. Packaging then:

- installs the build into a staging prefix and moves the helper processes into
  the app bundle,
- copies Qt and every other non-system library the app uses into the bundle and
  rewrites library paths so it runs from anywhere,
- re-signs everything ad hoc, keeping the hardened runtime and per-process
  entitlements upstream gives the helpers (WebContent and WebWorker need JIT),
- checks every binary's load commands and starts a relocated copy in headless
  mode to make sure it can render a page.

Only if all of that passes is a release published and the cask updated. A
failed build leaves the previous release and cask untouched.

Each release has a zip (used by the cask), a dmg, `SHA256SUMS` and
`build-info.json` recording the upstream commit, toolchain versions and minimum
macOS version. The app's `Info.plist` also carries the upstream commit under
`LadybirdSourceCommit`.

To build right away, or to build a specific branch, tag or commit, run the
**Nightly** workflow from the Actions tab.

## Notes

- The app is ad-hoc signed, not notarized. The cask removes the quarantine
  attribute after installing so Gatekeeper doesn't block it. If you use the
  dmg instead, run `xattr -dr com.apple.quarantine /Applications/Ladybird.app`
  once after copying it.
- These builds are not affiliated with the Ladybird project. Please report
  problems with the build here, and only report bugs upstream if you can
  reproduce them with your own build of Ladybird.
- The scripts in `scripts/` run on any Mac with a finished Ladybird build:
  `scripts/package-macos.sh <ladybird> <ladybird>/Build/release dist` followed
  by `scripts/verify-bundle.sh dist/Ladybird.app`.

## Credits

Earlier work by [remusa/ladybird-builds](https://github.com/remusa/ladybird-builds),
[jhult/ladybird-builds](https://github.com/jhult/ladybird-builds) and
[mrndstvndv/build-ladybird-macos](https://github.com/mrndstvndv/build-ladybird-macos)
showed the way.
