# homebrew-ladybird

Unofficial macOS builds of [Ladybird](https://ladybird.org), made from the
upstream `master` branch, plus a Homebrew tap to install and update them.

Builds are for Apple silicon only. Ladybird is pre-alpha software; these
builds exist so that following its development doesn't mean compiling it
yourself.

## Install

```sh
brew tap ylluminate/ladybird
brew trust --cask ylluminate/ladybird/ladybird-nightly
brew install --cask ladybird-nightly
```

Homebrew won't load casks from a third-party tap until you trust them; the
second line does that for this cask only.

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

When there is something new, it builds on GitHub's `xcode-27` runner (macOS 27
with Xcode 27, the Xcode upstream uses) with upstream's own CI setup: the same
Homebrew dependencies, Rust toolchain and vcpkg, Qt included. ccache, sccache
and the vcpkg binary cache are carried between runs. If upstream pins an Xcode
the runner doesn't have, the build uses the runner's newest stable Xcode and
notes it in the log. To build on another image, set the `MACOS_RUNNER`
repository variable.

Packaging uses upstream's own `Meta/package-macos-test-bundle.py`, which
upstream CI runs on every macOS build, so it follows upstream's install layout
as it changes. It:

- copies Qt, its platform plugin and every other library the app links into
  the bundle, and rewrites library paths so it runs from anywhere,
- re-signs the helpers ad hoc with the entitlements the build gave them
  (hardened runtime; WebContent and WebWorker need JIT).

On top of that this repository adds Qt's native macOS style plugin, records the
build in `Info.plist`, and then checks every binary's load commands and starts a
relocated copy in headless mode, with the build tree hidden, to make sure it can
load a page and run its JavaScript.

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
