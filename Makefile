# SPDX-License-Identifier: MIT

.PHONY: build release run test ci hooks smoke validate package install dmg icon clean

# Build the library and the menubar agent (debug).
build:
	swift build

# Optimized build.
release:
	swift build -c release

# Build and launch the agent from the command line (menubar item appears).
run:
	swift run Hearth

# Run the SupervisorCore test suite. Uses scripts/test.sh so the Swift Testing
# framework resolves under the Command Line Tools as well as full Xcode.
test:
	./scripts/test.sh

# Local CI: build (debug + release), unit tests, and lint. This is the gate the
# pre-push hook runs. There is no hosted runner.
ci:
	./scripts/ci.sh

# Install the pre-push hook so `make ci` runs before every push.
hooks:
	./scripts/install-hooks.sh

# End-to-end smoke test against the fake runner (needs a desktop session).
smoke:
	./scripts/smoke-test.sh

# End-to-end gate against a real ollama serve (needs Ollama and a pulled model).
validate:
	./scripts/validate-real.sh

# Assemble a Hearth.app bundle under dist/ (see scripts/package-app.sh).
package:
	./scripts/package-app.sh

# Build, ad-hoc sign, and install Hearth.app to /Applications for local use
# (dogfooding before a notarized release). No Developer ID required.
install:
	./scripts/install-app.sh

# Build a drag-to-install DMG from dist/Hearth.app (see scripts/make-dmg.sh).
# scripts/release.sh signs and notarizes it; on its own this is unsigned.
dmg:
	./scripts/make-dmg.sh

# Rebuild assets/AppIcon.icns from the icon source.
icon:
	./scripts/make-icon.sh

clean:
	swift package clean
	rm -rf dist
