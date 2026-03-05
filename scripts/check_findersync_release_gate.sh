#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_ENT="$ROOT_DIR/FormatKit/FormatKit.entitlements"
EXT_ENT="$ROOT_DIR/FormatKitFinderExtension/FormatKitFinderExtension.entitlements"
PBX="$ROOT_DIR/FormatKit.xcodeproj/project.pbxproj"

echo "Checking entitlements and project wiring..."

required_entitlements=(
  "com.apple.security.app-sandbox"
  "com.apple.security.files.bookmarks.app-scope"
  "com.apple.security.application-groups"
  "group.com.ajbeaver.FormatKit"
)

for file in "$APP_ENT" "$EXT_ENT"; do
  for key in "${required_entitlements[@]}"; do
    if ! grep -q "$key" "$file"; then
      echo "ERROR: Missing '$key' in $file"
      exit 1
    fi
  done
done

if ! grep -q 'CODE_SIGN_ENTITLEMENTS = FormatKit/FormatKit.entitlements;' "$PBX"; then
  echo "ERROR: App target entitlements not wired in project.pbxproj"
  exit 1
fi

if ! grep -q 'CODE_SIGN_ENTITLEMENTS = FormatKitFinderExtension/FormatKitFinderExtension.entitlements;' "$PBX"; then
  echo "ERROR: Finder extension entitlements not wired in project.pbxproj"
  exit 1
fi

echo "Checking for legacy raw-path payload usage in Finder flows..."
if grep -R -n 'URLQueryItem(name: "paths"' "$ROOT_DIR/FormatKitFinderExtension" "$ROOT_DIR/FormatKit" >/dev/null 2>&1; then
  echo "ERROR: Legacy raw path query handoff detected."
  exit 1
fi

echo "Release gate checks passed."
