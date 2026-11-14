#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist"
TMP="${TMPDIR:-/tmp}/side-player-universal"
APP="$OUT/side-player.app"

rm -rf "$OUT" "$TMP"
mkdir -p "$OUT" "$TMP/arm64" "$TMP/x86_64" "$TMP/merge" "$TMP/clang-cache" "$TMP/swift-cache" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cd "$ROOT"
CLANG_MODULE_CACHE_PATH="$TMP/clang-cache" SWIFT_MODULECACHE_PATH="$TMP/swift-cache" \
  swift build --disable-sandbox --triple arm64-apple-macosx14.0 --scratch-path "$TMP/arm64"
CLANG_MODULE_CACHE_PATH="$TMP/clang-cache" SWIFT_MODULECACHE_PATH="$TMP/swift-cache" \
  swift build --disable-sandbox --triple x86_64-apple-macosx14.0 --scratch-path "$TMP/x86_64"

ARM_BIN="$TMP/arm64/out/Products/Debug/side-player"
INTEL_BIN="$TMP/x86_64/out/Products/Debug/side-player"
if [[ ! -f "$ARM_BIN" || ! -f "$INTEL_BIN" ]]; then
  echo "Could not locate both architecture builds." >&2
  exit 1
fi
lipo -create "$ARM_BIN" "$INTEL_BIN" -output "$APP/Contents/MacOS/side-player"
chmod +x "$APP/Contents/MacOS/side-player"

RESOURCE_DIR="$TMP/arm64/out/Products/Debug/side-player_SidePlayer.bundle"
if [[ -d "$RESOURCE_DIR" ]]; then
  cp -R "$RESOURCE_DIR" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>side-player</string>
  <key>CFBundleIdentifier</key><string>com.zhengxinshushe.side-player</string>
  <key>CFBundleName</key><string>side-player</string>
  <key>CFBundleDisplayName</key><string>side-player</string>
  <key>CFBundleIconFile</key><string>side-player.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.0.0</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string></string>
</dict></plist>
PLIST

ICON_SOURCE="$ROOT/Sources/SidePlayer/Resources/side-player.png"
ICON_DIR="$TMP/icon"
mkdir -p "$ICON_DIR"
for size in 16 32 64 128 256 512 1024; do
  sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICON_DIR/$size.png" >/dev/null
done
python3 - "$ICON_DIR" "$APP/Contents/Resources/side-player.icns" <<'PYICON'
from pathlib import Path
from struct import pack
import sys

source, output = map(Path, sys.argv[1:])
# ICNS permits PNG payloads in these icon element types.
elements = [(16, b"icp4"), (32, b"icp5"), (64, b"icp6"), (128, b"ic07"),
            (256, b"ic08"), (512, b"ic09"), (1024, b"ic10")]
chunks = []
for size, kind in elements:
    png = (source / f"{size}.png").read_bytes()
    chunks.append(pack(">4sI", kind, 8 + len(png)) + png)
body = b"".join(chunks)
output.write_bytes(pack(">4sI", b"icns", 8 + len(body)) + body)
PYICON

cp "$ROOT/Sources/SidePlayer/Resources/side-player.png" "$APP/Contents/Resources/side-player.png"
cp "$ROOT/Sources/SidePlayer/Resources/slide-player.svg" "$APP/Contents/Resources/slide-player.svg"
for FFMPEG_PATH in /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg; do
  if [[ -x "$FFMPEG_PATH" ]] && lipo -verify_arch arm64 x86_64 "$FFMPEG_PATH" >/dev/null 2>&1; then
    cp "$FFMPEG_PATH" "$APP/Contents/Frameworks/ffmpeg"
    chmod +x "$APP/Contents/Frameworks/ffmpeg"
    break
  fi
done
echo "Created $APP"
