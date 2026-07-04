# SPDX-License-Identifier: MIT
#
# Homebrew cask for Hearth. Bump the version and sha256 (the DMG's, from
# scripts/release.sh output) for each release.
#
# Install from a tap with:
#   brew install --cask adamskijow/tap/hearth
# (after `brew tap adamskijow/tap`), or point brew straight at this file.
cask "hearth" do
  version "1.1.0"
  sha256 "ac39ac5b7ed249a03f0ae0f110fcace8971d4d3069a2544cbeef9a0a04956e8d"

  url "https://github.com/adamskijow/Hearth/releases/download/v#{version}/Hearth-#{version}.dmg"
  name "Hearth"
  desc "Background supervisor that keeps a local LLM runner alive on a headless Mac"
  homepage "https://github.com/adamskijow/Hearth"

  depends_on macos: :sonoma

  app "Hearth.app"
  # The app bundle is also the `hearth` CLI (doctor, status, setup, wait-ready),
  # which the README and docs route you to. Put it on PATH.
  binary "#{appdir}/Hearth.app/Contents/MacOS/Hearth", target: "hearth"

  zap trash: [
    "~/Library/Application Support/Hearth",
    "~/Library/Logs/Hearth",
  ]
end
