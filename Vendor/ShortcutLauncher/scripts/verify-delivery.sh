#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
PROJECT_DIRECTORY=${SCRIPT_DIRECTORY:h}
BUILD_DIRECTORY="$PROJECT_DIRECTORY/.build"
HOST_APP="$BUILD_DIRECTORY/ShortcutLauncherHostDemo.app"
HOST_INFO_PLIST="$PROJECT_DIRECTORY/HostDemo/Info.plist"
EXPECTED_SHORT_VERSION=${SHORTCUT_LAUNCHER_EXPECTED_SHORT_VERSION:-0.6.0}
EXPECTED_BUILD_VERSION=${SHORTCUT_LAUNCHER_EXPECTED_BUILD_VERSION:-7}

fail() {
  print -u2 -- "Delivery verification failed: $1"
  exit 65
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

require_path() {
  [[ -e "$PROJECT_DIRECTORY/$1" ]] || fail "required delivery path is missing: $1"
}

assert_bundle_version() {
  local plist_path=$1
  local short_version
  local build_version

  short_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist_path")
  build_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist_path")

  [[ "$short_version" == "$EXPECTED_SHORT_VERSION" ]] \
    || fail "$plist_path has version $short_version; expected $EXPECTED_SHORT_VERSION"
  [[ "$build_version" == "$EXPECTED_BUILD_VERSION" ]] \
    || fail "$plist_path has build $build_version; expected $EXPECTED_BUILD_VERSION"
}

fingerprint_path() {
  local root=$1
  local entry
  local relative_path
  local digest
  local link_target

  if [[ -L "$root" ]]; then
    link_target=$(readlink "$root")
    print -nr -- "symlink:$link_target" | shasum -a 256 | awk '{print $1}'
    return
  fi
  if [[ -f "$root" ]]; then
    shasum -a 256 -- "$root" | awk '{print $1}'
    return
  fi
  if [[ ! -e "$root" ]]; then
    print -nr -- "absent" | shasum -a 256 | awk '{print $1}'
    return
  fi

  {
    print -r -- "directory"
    while IFS= read -r -d '' entry; do
      relative_path=${entry#"$root"/}
      if [[ -L "$entry" ]]; then
        link_target=$(readlink "$entry")
        print -r -- "link:$relative_path:$link_target"
      elif [[ -f "$entry" ]]; then
        digest=$(shasum -a 256 -- "$entry" | awk '{print $1}')
        print -r -- "file:$relative_path:$digest"
      elif [[ -d "$entry" ]]; then
        print -r -- "directory:$relative_path"
      else
        print -r -- "other:$relative_path"
      fi
    done < <(find -s "$root" -mindepth 1 -print0)
  } | shasum -a 256 | awk '{print $1}'
}

user_runtime_fingerprint() {
  local application_support_directory="$HOME/Library/Application Support"
  local cache_directory="$HOME/Library/Caches"

  {
    print -r -- "host-configuration:$(fingerprint_path "$application_support_directory/ShortcutLauncherHostDemo/ShortcutLauncher")"
    print -r -- "host-automatic-icons:$(fingerprint_path "$cache_directory/ShortcutLauncherHostDemo/ShortcutLauncher/WebsiteIcons-Automatic-v1")"
    print -r -- "generic-configuration:$(fingerprint_path "$application_support_directory/ShortcutLauncher")"
    print -r -- "generic-automatic-icons:$(fingerprint_path "$cache_directory/ShortcutLauncher/WebsiteIcons-Automatic-v1")"
  } | shasum -a 256 | awk '{print $1}'
}

clean_generated_build() {
  [[ "${SHORTCUT_LAUNCHER_PRESERVE_DELIVERY_BUILD:-0}" == "1" ]] && return 0
  case "$BUILD_DIRECTORY" in
    "$PROJECT_DIRECTORY/.build")
      [[ ! -e "$BUILD_DIRECTORY" && ! -L "$BUILD_DIRECTORY" ]] \
        || /bin/rm -rf -- "$BUILD_DIRECTORY"
      ;;
    *)
      print -u2 -- "Refusing to remove unexpected build path: $BUILD_DIRECTORY"
      return 70
      ;;
  esac
}

verify_runtime_and_cleanup() {
  local command_status=$?
  local user_runtime_hash_after

  trap - EXIT
  clean_generated_build || command_status=$?
  user_runtime_hash_after=$(user_runtime_fingerprint)
  if [[ "$USER_RUNTIME_HASH_BEFORE" != "$user_runtime_hash_after" ]]; then
    print -u2 -- "Delivery verification failed: user configuration, UI preferences, website cache, or custom icon assets changed."
    exit 70
  fi
  print "User configuration, UI preferences, cache and assets: UNCHANGED"
  exit "$command_status"
}

clean_host_app() {
  case "$HOST_APP" in
    "$PROJECT_DIRECTORY/.build/ShortcutLauncherHostDemo.app")
      [[ ! -e "$HOST_APP" && ! -L "$HOST_APP" ]] || /bin/rm -rf -- "$HOST_APP"
      ;;
    *)
      fail "refusing to remove unexpected HostDemo path: $HOST_APP"
      ;;
  esac
}

[[ "$(uname -s)" == "Darwin" ]] || fail "this macOS package must be verified on macOS"

for required_command in swift plutil codesign shasum awk grep find; do
  require_command "$required_command"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail "required command is unavailable: /usr/libexec/PlistBuddy"

for required_path in \
  Package.swift \
  README.md \
  Sources/ShortcutLauncherCore \
  Sources/ShortcutLauncherUI \
  Tests/ShortcutLauncherCoreTests \
  Tests/ShortcutLauncherUITests \
  IntegrationFixture/main.swift \
  HostDemo/ShortcutLauncherHostDemo/main.swift \
  HostDemo/Info.plist \
  scripts/build-host-app.sh; do
  require_path "$required_path"
done

print "[1/11] Delivery archive residue and Agent-state guard"
typeset -a forbidden_paths
while IFS= read -r -d '' forbidden_path; do
  forbidden_paths+=("${forbidden_path#"$PROJECT_DIRECTORY"/}")
done < <(
  find "$PROJECT_DIRECTORY" -mindepth 1 \
    \( \
      -name '.git' -o \
      -name '.build' -o \
      -name '.swiftpm' -o \
      -name 'DerivedData' -o \
      -name 'xcuserdata' -o \
      -name '*.xcuserstate' -o \
      -name '*.xcresult' -o \
      -name '*.profraw' -o \
      -name '*.app' -o \
      -name '*.dSYM' -o \
      -name '*.xctest' -o \
      -name '*.swiftmodule' -o \
      -name '*.swiftdoc' -o \
      -name '*.o' -o \
      -name '*.log' -o \
      -name '.DS_Store' -o \
      -name 'runtime-data' -o \
      -name 'launcher-config.json' -o \
      -name 'launcher-config.backup.json' -o \
      -name 'configuration-v1.json' -o \
      -name 'launcher-ui-preferences.json' -o \
      -name 'launcher-ui-preferences.backup.json' -o \
      -name 'website-icon-assets-v1.json' -o \
      -name 'WebsiteIcons-Automatic-v1' -o \
      -name 'WebsiteIcons-Custom-v1' -o \
      -name 'AGENTS.md' -o \
      -name 'CLAUDE.md' -o \
      -name 'HANDOFF.md' -o \
      -name 'DECISIONS.md' -o \
      -name 'LESSONS.md' -o \
      -name 'MEMORY_WORKFLOW.md' -o \
      -name 'PRE_COMPACTION_CHECKLIST.md' -o \
      -name 'memory' -o \
      -name '.codex' -o \
      -name '.agents' -o \
      -name '.claude' \
    \) -prune -print0
)
if (( ${#forbidden_paths[@]} > 0 )); then
  print -u2 -- "Delivery verification failed: generated, runtime, or Agent-only paths are present:"
  printf '  %s\n' "${forbidden_paths[@]}" >&2
  exit 65
fi

typeset -a archive_symlinks
while IFS= read -r -d '' archive_symlink; do
  archive_symlinks+=("${archive_symlink#"$PROJECT_DIRECTORY"/}")
done < <(find "$PROJECT_DIRECTORY" -mindepth 1 -type l -print0)
if (( ${#archive_symlinks[@]} > 0 )); then
  print -u2 -- "Delivery verification failed: source archives must not contain symlinks:"
  printf '  %s\n' "${archive_symlinks[@]}" >&2
  exit 65
fi

print "[2/11] Absolute private-path and secret-marker scan"
typeset -a archive_files
while IFS= read -r -d '' archive_file; do
  archive_files+=("$archive_file")
done < <(find "$PROJECT_DIRECTORY" -type f -print0)
(( ${#archive_files[@]} > 0 )) || fail "archive contains no files to scan"

PRIVATE_USER_ROOT='/Users'
LINUX_USER_ROOT='/home'
PRIVATE_KEY_MARKER='PRIVATE KEY'
AWS_ACCESS_KEY_PREFIX='AKIA'
GOOGLE_API_KEY_PREFIX='AIza'
GITHUB_TOKEN_PREFIX='gh'
PRIVACY_SCAN_PATTERN="(${PRIVATE_USER_ROOT}/[^/[:space:]]+/|${LINUX_USER_ROOT}/[^/[:space:]]+/|${AWS_ACCESS_KEY_PREFIX}[0-9A-Z]{16}|${GOOGLE_API_KEY_PREFIX}[0-9A-Za-z_-]{35}|${GITHUB_TOKEN_PREFIX}[pousr]_[0-9A-Za-z]{30,}|BEGIN (RSA |OPENSSH |EC )?${PRIVATE_KEY_MARKER})"

set +e
LC_ALL=C grep -I -nE -- "$PRIVACY_SCAN_PATTERN" "${archive_files[@]}"
privacy_scan_status=$?
set -e
case "$privacy_scan_status" in
  0)
    fail "an absolute private path or likely secret was found"
    ;;
  1)
    ;;
  *)
    fail "privacy scan could not complete (grep $privacy_scan_status)"
    ;;
esac

USER_RUNTIME_HASH_BEFORE=$(user_runtime_fingerprint)
trap verify_runtime_and_cleanup EXIT

cd "$PROJECT_DIRECTORY"

print "[3/11] Swift unit, component and module tests"
swift test

print "[4/11] Deterministic website-icon fixture tests"
print "Public-network favicon checks: DISABLED; only injected loaders and temporary storage are used."
swift test --filter 'WebsiteIconOriginParserTests|WebsiteIconResourceServiceTests|WebsiteIconStorageImageTests'

print "[5/11] Second-host public-contract and dependency-injection smoke"
swift run ShortcutLauncherIntegrationFixture --smoke

print "[6/11] UI automation and real-permission boundary"
print "XCUITest, HostDemo launch, real global hotkeys, target opening and file panels: DISABLED."

print "[7/11] Swift Debug build"
swift build

print "[8/11] Swift Release build"
swift build -c release

print "[9/11] Debug HostDemo assembly, plist, version and ad-hoc signature"
plutil -lint "$HOST_INFO_PLIST"
assert_bundle_version "$HOST_INFO_PLIST"
clean_host_app
/bin/zsh "$SCRIPT_DIRECTORY/build-host-app.sh" debug
plutil -lint "$HOST_APP/Contents/Info.plist"
assert_bundle_version "$HOST_APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$HOST_APP"

print "[10/11] Release HostDemo assembly, plist, version and ad-hoc signature"
clean_host_app
/bin/zsh "$SCRIPT_DIRECTORY/build-host-app.sh" release
plutil -lint "$HOST_APP/Contents/Info.plist"
assert_bundle_version "$HOST_APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$HOST_APP"

print "[11/11] Delivery verification summary"
print "Shortcut Launcher source delivery verification passed."
