#!/bin/zsh
# Builds and runs the swift-testing suites. Works with only the Command Line Tools installed.
# Extra arguments go to swift-testing, e.g.  scripts/test.sh --filter Player
set -euo pipefail
cd "$(dirname "$0")/.."

frameworks=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift build --build-tests

runner=.build/testrunner
if [[ ! -x $runner || scripts/testrunner/main.swift -nt $runner ]]; then
    swiftc -F $frameworks -Xfrontend -disable-cross-import-overlays \
        -Xlinker -rpath -Xlinker $frameworks scripts/testrunner/main.swift -o $runner
fi

TEST_BUNDLE_BINARY="$PWD/.build/debug/SusurrusPackageTests.xctest/Contents/MacOS/SusurrusPackageTests" \
DYLD_FRAMEWORK_PATH=$frameworks \
    $runner "$@"
