cask "ladybird-nightly" do
  version "2026.10.04.2013,804d29ba2d"
  sha256 "d79f7fc209c82a74880074c92ed67fc17faa3a0c2cb332912a54ef132c60c86b"

  url "https://github.com/ylluminate/homebrew-ladybird/releases/download/nightly-#{version.csv.first}-#{version.csv.second}/Ladybird-macos-arm64.zip"
  name "Ladybird Nightly"
  desc "Unofficial rolling build of the Ladybird web browser"
  homepage "https://github.com/ylluminate/homebrew-ladybird"

  livecheck do
    url :url
    regex(/^nightly-(\d+(?:\.\d+)+)-(\h+)$/i)
    strategy :github_latest do |json, regex|
      match = json["tag_name"]&.match(regex)
      next if match.blank?

      "#{match[1]},#{match[2]}"
    end
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe

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
      https://github.com/ylluminate/homebrew-ladybird/issues
  CAVEATS
end
