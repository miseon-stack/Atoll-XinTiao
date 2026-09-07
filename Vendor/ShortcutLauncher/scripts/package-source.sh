#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY=${0:A:h}
PROJECT_DIRECTORY=${SCRIPT_DIRECTORY:h}
VERSION=${SHORTCUT_LAUNCHER_VERSION:-0.6.0}
BUILD_VERSION=${SHORTCUT_LAUNCHER_BUILD_VERSION:-7}
OUTPUT_PARENT=${1:-"$PROJECT_DIRECTORY/dist"}
RELEASE_NAME="ShortcutLauncher-$VERSION-release"
SOURCE_NAME="ShortcutLauncher-$VERSION-public-source"
FINAL_RELEASE_DIRECTORY="$OUTPUT_PARENT/$RELEASE_NAME"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    print -u2 "Required packaging command is unavailable: $1"
    exit 69
  }
}

for required_command in cp find grep mktemp shasum awk tee zip; do
  require_command "$required_command"
done

if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$' ]]; then
  print -u2 "Invalid release version: $VERSION"
  exit 64
fi

if [[ -e "$FINAL_RELEASE_DIRECTORY" ]]; then
  print -u2 "Refusing to overwrite an existing delivery: $FINAL_RELEASE_DIRECTORY"
  exit 73
fi

mkdir -p "$OUTPUT_PARENT"
OUTPUT_PARENT=$(cd "$OUTPUT_PARENT" && pwd -P)
FINAL_RELEASE_DIRECTORY="$OUTPUT_PARENT/$RELEASE_NAME"

TEMPORARY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/shortcut-launcher-package.XXXXXX")
WORK_RELEASE_DIRECTORY="$TEMPORARY_ROOT/$RELEASE_NAME"
SOURCE_DIRECTORY="$WORK_RELEASE_DIRECTORY/$SOURCE_NAME"

cleanup() {
  local command_status=$?
  trap - EXIT INT TERM
  case "$TEMPORARY_ROOT" in
    /tmp/shortcut-launcher-package.*|/private/tmp/shortcut-launcher-package.*|${TMPDIR:-/tmp}/shortcut-launcher-package.*)
      [[ -d "$TEMPORARY_ROOT" ]] && /bin/rm -rf -- "$TEMPORARY_ROOT"
      ;;
    *)
      print -u2 "Refusing to remove unexpected temporary path: $TEMPORARY_ROOT"
      command_status=70
      ;;
  esac
  exit "$command_status"
}
trap cleanup EXIT INT TERM

mkdir -p "$SOURCE_DIRECTORY"

copy_file() {
  local relative_path=$1
  local source_path="$PROJECT_DIRECTORY/$relative_path"
  local destination_path="$SOURCE_DIRECTORY/$relative_path"

  if [[ ! -f "$source_path" || -L "$source_path" ]]; then
    print -u2 "Required regular file is missing or unsafe: $relative_path"
    exit 66
  fi
  mkdir -p "${destination_path:h}"
  cp -p -- "$source_path" "$destination_path"
}

copy_tree() {
  local relative_root=$1
  local source_root="$PROJECT_DIRECTORY/$relative_root"
  local source_path
  local relative_path

  if [[ ! -d "$source_root" || -L "$source_root" ]]; then
    print -u2 "Required directory is missing or unsafe: $relative_root"
    exit 66
  fi

  while IFS= read -r -d '' source_path; do
    relative_path=${source_path#"$PROJECT_DIRECTORY/"}
    [[ "${relative_path:t}" == ".DS_Store" ]] && continue
    copy_file "$relative_path"
  done < <(find "$source_root" -type f -print0)
}

typeset -a root_files=(
  .gitattributes
  .gitignore
  AI_CONTEXT.md
  API_STABILITY.md
  CHANGELOG.md
  CODE_OF_CONDUCT.md
  CONTRIBUTING.md
  Package.swift
  PUBLICATION_CHECKLIST.md
  README.md
  README.zh-CN.md
  SECURITY.md
  SUPPORT.md
)

typeset -a documentation_files=(
  docs/architecture.md
  docs/configuration-format.md
  docs/development.md
  docs/integration.md
  docs/privacy.md
  docs/troubleshooting.md
)

typeset -a script_files=(
  scripts/build-host-app.sh
  scripts/package-source.sh
  scripts/verify-delivery.sh
  scripts/verify.sh
)

typeset -a source_trees=(
  Sources
  Tests
  HostDemo
  IntegrationFixture
  UITestHost
  .github
)

for relative_path in $root_files $documentation_files $script_files; do
  copy_file "$relative_path"
done

if [[ -f "$PROJECT_DIRECTORY/LICENSE" && ! -L "$PROJECT_DIRECTORY/LICENSE" ]]; then
  copy_file LICENSE
fi

for relative_root in $source_trees; do
  copy_tree "$relative_root"
done

chmod +x "$SOURCE_DIRECTORY/scripts/build-host-app.sh"
chmod +x "$SOURCE_DIRECTORY/scripts/package-source.sh"
chmod +x "$SOURCE_DIRECTORY/scripts/verify-delivery.sh"
chmod +x "$SOURCE_DIRECTORY/scripts/verify.sh"

if find "$SOURCE_DIRECTORY" -type l -print -quit | grep -q .; then
  print -u2 "Packaging failed: symbolic links are not allowed in the delivery."
  exit 65
fi

typeset -a forbidden_names=(
  AGENTS.md
  DECISIONS.md
  HANDOFF.md
  LESSONS.md
  MEMORY_WORKFLOW.md
  PRE_COMPACTION_CHECKLIST.md
  .DS_Store
)
for forbidden_name in $forbidden_names; do
  if find "$SOURCE_DIRECTORY" -name "$forbidden_name" -print -quit | grep -q .; then
    print -u2 "Packaging failed: forbidden file present: $forbidden_name"
    exit 65
  fi
done

PRIVATE_USER_ROOT='/Users'
LINUX_USER_ROOT='/home'
INTERNAL_WORKSPACE_MARKER='agent''-blueprint'
CLIPBOARD_MARKER='codex''-clipboard'
SOURCE_PRIVACY_PATTERN="(${PRIVATE_USER_ROOT}/[^/]+/|${LINUX_USER_ROOT}/[^/]+/|${INTERNAL_WORKSPACE_MARKER}|${CLIPBOARD_MARKER})"
if grep -R -I -n -E "$SOURCE_PRIVACY_PATTERN" "$SOURCE_DIRECTORY" >/dev/null 2>&1; then
  print -u2 "Packaging failed: a private absolute path or internal workspace marker remains."
  grep -R -I -n -E "$SOURCE_PRIVACY_PATTERN" "$SOURCE_DIRECTORY" >&2 || true
  exit 65
fi

print "[1/3] Verifying the clean, history-free source tree"
(
  cd "$SOURCE_DIRECTORY"
  SHORTCUT_LAUNCHER_EXPECTED_SHORT_VERSION="$VERSION" \
    SHORTCUT_LAUNCHER_EXPECTED_BUILD_VERSION="$BUILD_VERSION" \
    ./scripts/verify-delivery.sh
) 2>&1 | tee "$WORK_RELEASE_DIRECTORY/verification.log"

cat > "$WORK_RELEASE_DIRECTORY/VERIFICATION.md" <<EOF
# ShortcutLauncher $VERSION delivery verification

- Result: PASSED
- HostDemo version: $VERSION (Build $BUILD_VERSION)
- Source shape: clean snapshot without Git history
- Verification entry point: \`./scripts/verify-delivery.sh\`
- Network/UI policy: no public website requests, no HostDemo launch, no XCUITest execution, and no macOS automation-permission prompts
- Covered: full Swift tests, deterministic favicon fixtures, public API compile test, second-host smoke, Debug/Release builds, HostDemo assembly, plist/version checks, ad-hoc signature verification, privacy scan, and user-data fingerprints

The complete command output is stored in \`verification.log\` beside this report. Ad-hoc signing verifies bundle assembly only; it is not Developer ID distribution signing or Apple notarization.
EOF
cp -p -- "$WORK_RELEASE_DIRECTORY/VERIFICATION.md" "$SOURCE_DIRECTORY/VERIFICATION.md"

print "[2/3] Generating the reproducible source manifest"
MANIFEST_PATH="$SOURCE_DIRECTORY/SOURCE_MANIFEST.md"
{
  print "# ShortcutLauncher $VERSION source manifest"
  print
  print "This list covers every regular file in the source delivery except this manifest itself."
  print
  print '| SHA-256 | Path |'
  print '| --- | --- |'
  while IFS= read -r source_path; do
    relative_path=${source_path#"$SOURCE_DIRECTORY/"}
    [[ "$relative_path" == "SOURCE_MANIFEST.md" ]] && continue
    digest=$(shasum -a 256 -- "$source_path" | awk '{print $1}')
    print "| \`$digest\` | \`$relative_path\` |"
  done < <(find "$SOURCE_DIRECTORY" -type f -print | LC_ALL=C sort)
} > "$MANIFEST_PATH"
cp -p -- "$MANIFEST_PATH" "$WORK_RELEASE_DIRECTORY/SOURCE_MANIFEST.md"
cp -p -- "$SOURCE_DIRECTORY/AI_CONTEXT.md" \
  "$WORK_RELEASE_DIRECTORY/ShortcutLauncher-$VERSION-AI_CONTEXT.md"

print "[3/3] Creating the source ZIP and checksums"
(
  cd "$WORK_RELEASE_DIRECTORY"
  /usr/bin/zip -X -q -r "ShortcutLauncher-$VERSION-source.zip" "$SOURCE_NAME"
)

(
  cd "$WORK_RELEASE_DIRECTORY"
  typeset -a checksum_targets=(
    "ShortcutLauncher-$VERSION-source.zip"
    "ShortcutLauncher-$VERSION-AI_CONTEXT.md"
    SOURCE_MANIFEST.md
    VERIFICATION.md
    verification.log
  )
  for checksum_target in $checksum_targets; do
    shasum -a 256 -- "$checksum_target"
  done > "ShortcutLauncher-$VERSION-SHA256SUMS.txt"
)

mv -- "$WORK_RELEASE_DIRECTORY" "$FINAL_RELEASE_DIRECTORY"
print "Delivery created at: $FINAL_RELEASE_DIRECTORY"
