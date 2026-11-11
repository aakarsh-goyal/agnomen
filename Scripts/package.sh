#!/bin/bash
# Builds and zips dist/Agnomen.app for a GitHub release / Homebrew cask. Prints the zip path and sha256.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)
Scripts/build.sh >/dev/null
ZIP="dist/Agnomen-$VERSION-arm64.zip"
rm -f "$ZIP"
ditto -c -k --keepParent dist/Agnomen.app "$ZIP"
echo "$ZIP"
shasum -a 256 "$ZIP" | awk '{print $1}'
