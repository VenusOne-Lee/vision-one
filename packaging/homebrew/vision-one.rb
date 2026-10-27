# Homebrew cask for Vision One. The release workflow fills in the version
# and sha256 and pushes it to VenusOne-Lee/homebrew-tap, so people can run:
#
#   brew install --cask venusone-lee/tap/vision-one
cask "vision-one" do
  version "{{VERSION}}"
  sha256 "{{SHA256}}"

  url "https://github.com/VenusOne-Lee/vision-one/releases/download/v#{version}/Vision-One-#{version}.dmg"
  name "Vision One"
  desc "Screen recorder with a transcript-first editor that runs on your Mac"
  homepage "https://github.com/VenusOne-Lee/vision-one"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Sparkle updates the app in place, so brew leaves upgrades to it.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :sequoia"

  app "Vision One.app"

  # Recordings in ~/Movies/Vision One are yours and are never removed.
  zap trash: [
    "~/Library/Caches/za.co.versionone.visionone",
    "~/Library/HTTPStorages/za.co.versionone.visionone",
    "~/Library/Preferences/za.co.versionone.visionone.plist",
    "~/Library/Saved Application State/za.co.versionone.visionone.savedState",
  ]
end
