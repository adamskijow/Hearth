# SPDX-License-Identifier: MIT
#
# Homebrew cask for Hearth. Bump the version and sha256 (the DMG's, from
# scripts/release.sh output) for each release.
#
# Install from a tap with:
#   brew install --cask adamskijow/tap/hearth
# (after `brew tap adamskijow/tap`), or point brew straight at this file.
cask "hearth" do
  version "0.2.0"
  sha256 "054c3af96d0907f5169b43cce18e8c1b2790f54c19c599f0734715bdbbedbf7f"

  url "https://github.com/adamskijow/Hearth/releases/download/v#{version}/Hearth-#{version}.dmg"
  name "Hearth"
  desc "Background supervisor that keeps a local LLM runner alive on a headless Mac"
  homepage "https://github.com/adamskijow/Hearth"

  depends_on macos: :sonoma

  app "Hearth.app"

  zap trash: [
    "~/Library/Application Support/Hearth",
    "~/Library/Logs/Hearth",
  ]
end
