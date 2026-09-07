#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
PROJECT_DIRECTORY=${SCRIPT_DIRECTORY:h}
CONFIGURATION=${1:-debug}

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
  print -u2 "Usage: $0 [debug|release]"
  exit 2
fi

cd "$PROJECT_DIRECTORY"
swift build -c "$CONFIGURATION" --product ShortcutLauncherHostDemo

BIN_DIRECTORY=$(swift build -c "$CONFIGURATION" --show-bin-path)
APP_DIRECTORY="$PROJECT_DIRECTORY/.build/ShortcutLauncherHostDemo.app"
CONTENTS_DIRECTORY="$APP_DIRECTORY/Contents"
MACOS_DIRECTORY="$CONTENTS_DIRECTORY/MacOS"
RESOURCES_DIRECTORY="$CONTENTS_DIRECTORY/Resources"

mkdir -p "$MACOS_DIRECTORY" "$RESOURCES_DIRECTORY"
cp "$BIN_DIRECTORY/ShortcutLauncherHostDemo" "$MACOS_DIRECTORY/ShortcutLauncherHostDemo"
cp "$PROJECT_DIRECTORY/HostDemo/Info.plist" "$CONTENTS_DIRECTORY/Info.plist"
chmod 755 "$MACOS_DIRECTORY/ShortcutLauncherHostDemo"
codesign --force --deep --sign - "$APP_DIRECTORY"

print "$APP_DIRECTORY"
