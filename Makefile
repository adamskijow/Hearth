# SPDX-License-Identifier: MIT

.PHONY: build test run release package clean

# Build the library and the menubar agent (debug).
build:
	swift build

# Run the SupervisorCore test suite. Uses scripts/test.sh so the Swift Testing
# framework resolves under the Command Line Tools as well as full Xcode.
test:
	./scripts/test.sh

# Build and launch the agent from the command line (menubar item appears).
run:
	swift run Hearth

# Optimized build.
release:
	swift build -c release

# Assemble a Hearth.app bundle under dist/ (see scripts/package-app.sh).
package:
	./scripts/package-app.sh

clean:
	swift package clean
	rm -rf dist
