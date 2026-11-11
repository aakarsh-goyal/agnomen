#!/bin/bash
# Regenerate Support/AppIcon.icns from Scripts/MakeIcon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
swift Scripts/MakeIcon.swift "$TMP" >/dev/null
SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon-master.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon-master.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Support/AppIcon.icns
cp "$TMP/icon-master.png" Support/icon-master.png
echo "wrote Support/AppIcon.icns"
