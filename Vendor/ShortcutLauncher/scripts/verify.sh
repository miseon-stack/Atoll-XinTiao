#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
PROJECT_DIRECTORY=${SCRIPT_DIRECTORY:h}

cd "$PROJECT_DIRECTORY"

swift test
swift build --product ShortcutLauncherIntegrationFixture
"$SCRIPT_DIRECTORY/build-host-app.sh" debug
plutil -lint "$PROJECT_DIRECTORY/HostDemo/Info.plist"
codesign --verify --deep --strict --verbose=2 \
  "$PROJECT_DIRECTORY/.build/ShortcutLauncherHostDemo.app"

print "Shortcut Launcher automated verification passed."
