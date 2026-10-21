#!/bin/bash
# Builds the SafeCore installer DMG from the developer's package.
#
#   ./build-dmg.sh <SafeCore-x.y.z.zip | SafeCore-x.y.z.pkg> [options]
#
# Options:
#   --version X.Y.Z     Override the version (default: taken from the file name)
#   --endpoint URL      Pre-fill the Config API endpoint field
#   --domain NAME       Pre-fill the Domain field
#
# Output (in dist/):
#   SafeCore-<ver>-unsigned.dmg   Test build. Opens on this Mac only (ad-hoc signed).
#   SafeCore-<ver>-signing-kit/   Copy this folder to the signing Mac and run sign-and-notarize.sh.
#   package-report.txt            Architectures and signatures of every binary in the package.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
MIN_MACOS=13.0
DMGBUILD_VERSION=1.6.7

SRC="" VERSION="" ENDPOINT="" DOMAIN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION=$2; shift 2 ;;
    --endpoint) ENDPOINT=$2; shift 2 ;;
    --domain) DOMAIN=$2; shift 2 ;;
    -*) echo "Unknown option $1" >&2; exit 64 ;;
    *) SRC=$1; shift ;;
  esac
done
[ -n "$SRC" ] && [ -f "$SRC" ] || { sed -n '2,16p' "$0"; exit 64; }
SRC="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
rm -rf "$BUILD"
mkdir -p "$BUILD" "$DIST"

# 1. Fetch and verify -----------------------------------------------------------
say "1/7 Unpacking $(basename "$SRC")"
SHA=$(shasum -a 256 "$SRC" | cut -d' ' -f1)
echo "SHA-256 $SHA"
case "$SRC" in
  *.zip)
    mkdir -p "$BUILD/pkg-src"
    ditto -x -k "$SRC" "$BUILD/pkg-src"
    PKG=$(find "$BUILD/pkg-src" -name '*.pkg' -not -path '*/__MACOSX/*' | head -1)
    ;;
  *.pkg) PKG="$SRC" ;;
  *) echo "Expected a .zip or .pkg" >&2; exit 64 ;;
esac
[ -n "$PKG" ] || { echo "No .pkg found inside $(basename "$SRC")" >&2; exit 1; }
echo "Package: ${PKG#$BUILD/}"
if [ -z "$VERSION" ]; then
  VERSION=$(basename "$PKG" | sed -nE 's/.*-([0-9]+\.[0-9]+(\.[0-9]+)?)\.pkg$/\1/p')
  [ -n "$VERSION" ] || { echo "Could not read a version from $(basename "$PKG"); pass --version" >&2; exit 1; }
fi
echo "Version: $VERSION"

# 2. Inspect the package ----------------------------------------------------------
say "2/7 Inspecting the package"
pkgutil --expand-full "$PKG" "$BUILD/pkg-expanded" >/dev/null
REPORT="$DIST/package-report.txt"
{
  echo "SafeCore package report"
  echo "Source:  $(basename "$SRC")  sha256=$SHA"
  echo "Package: $(basename "$PKG")  version=$VERSION"
  echo "Package signature: $(pkgutil --check-signature "$PKG" 2>&1 | sed -n 's/^ *Status: //p' | head -1)"
  echo
  echo "Install scripts:"
  find "$BUILD/pkg-expanded" -path '*Scripts*' -type f | sed "s|$BUILD/pkg-expanded/||; s/^/  /"
  echo
  echo "Binaries (architectures | signature):"
} > "$REPORT"

ARCHS_ALL="arm64 x86_64"
SUPPORTED="$ARCHS_ALL"
UNSIGNED=0
while IFS= read -r f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  a=$(lipo -archs "$f" 2>/dev/null || echo "?")
  sig=$(codesign -dv --verbose=2 "$f" 2>&1 || true)
  if echo "$sig" | grep -q 'Authority=Developer ID Application' && echo "$sig" | grep -q 'flags=.*runtime'; then
    s="Developer ID + hardened runtime"
  else
    s="NOT notarization-ready"; UNSIGNED=$((UNSIGNED + 1))
  fi
  echo "  ${f#$BUILD/pkg-expanded/} | $a | $s" >> "$REPORT"
  keep=""
  for x in $SUPPORTED; do case " $a " in *" $x "*) keep="$keep $x" ;; esac; done
  SUPPORTED=$(echo $keep)
done < <(find "$BUILD/pkg-expanded" -type f -perm -u+x -o -type f -name '*.dylib')

[ -n "$SUPPORTED" ] || SUPPORTED="arm64"
ARCH_LABEL=$([ "$SUPPORTED" = "$ARCHS_ALL" ] && echo "Universal" || echo "Apple silicon")
[ "$SUPPORTED" = x86_64 ] && ARCH_LABEL="Intel"
{
  echo
  echo "Runs on: $SUPPORTED ($ARCH_LABEL)"
  echo "Binaries not ready for notarization: $UNSIGNED"
} >> "$REPORT"
cat "$REPORT"

# 3. Build the app ------------------------------------------------------------------
say "3/7 Building SafeCore.app (universal)"
( cd "$ROOT/installer-app" && swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -E 'error|Build complete' )
BIN="$(cd "$ROOT/installer-app" && swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/SafeCore"

APP="$BUILD/stage/Install SafeCore.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SafeCore"

mkdir -p "$BUILD/art"
swift "$ROOT/tools/make-art.swift" "$BUILD/art" "$VERSION" "$ARCH_LABEL" "$ROOT/brand/safespace-mark.png" >/dev/null
ICONSET="$BUILD/art/AppIcon.iconset"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$BUILD/art/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$BUILD/art/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
tiffutil -cathidpicheck "$BUILD/art/dmg-background.png" "$BUILD/art/dmg-background@2x.png" -out "$BUILD/art/dmg-background.tiff" 2>/dev/null

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>ai.safespaceglobal.safecore</string>
  <key>CFBundleName</key><string>SafeCore</string>
  <key>CFBundleDisplayName</key><string>SafeCore</string>
  <key>CFBundleExecutable</key><string>SafeCore</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© SafeSpace Global</string>
  <key>SafeCoreSupportedArchs</key><string>$(echo $SUPPORTED | tr ' ' ',')</string>
  <key>SafeCoreDefaultEndpoint</key><string>$ENDPOINT</string>
  <key>SafeCoreDefaultDomain</key><string>$DOMAIN</string>
  <key>SafeCorePackageSHA256</key><string>$SHA</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# 4. Bundle the package and helper, ad-hoc sign for local testing -------------------------
say "4/7 Bundling the package"
cp "$PKG" "$APP/Contents/Resources/SafeCore.pkg"
cp "$ROOT/installer-app/Resources/safecore-helper.sh" "$APP/Contents/Resources/"
cp "$ROOT/installer-app/Resources/safecore-watchdog.sh" "$ROOT/installer-app/Resources/ai.safespaceglobal.safecore-watchdog.plist" "$APP/Contents/Resources/"
cp "$ROOT/brand/safespace-mark.png" "$APP/Contents/Resources/"
chmod 755 "$APP/Contents/Resources/safecore-helper.sh" "$APP/Contents/Resources/safecore-watchdog.sh"
codesign --force --sign - "$APP"
lipo -archs "$APP/Contents/MacOS/SafeCore"

# 5. Make the branded DMG -------------------------------------------------------------
say "5/7 Making the DMG"
VENV="$ROOT/.venv-dmgbuild"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet "dmgbuild==$DMGBUILD_VERSION"
fi
cat > "$BUILD/dmg-settings.py" <<PY
import os.path
files = [os.path.join(defines['stage'], 'Install SafeCore.app')]
symlinks = {}
hide_extensions = ['Install SafeCore.app']
icon = os.path.join(defines['stage'], 'Install SafeCore.app', 'Contents', 'Resources', 'AppIcon.icns')
background = defines['background']
format = 'UDZO'
filesystem = 'HFS+'
size = None
window_rect = ((200, 160), (660, 400))
default_view = 'icon-view'
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {'Install SafeCore.app': (470, 190)}
PY
UNSIGNED_DMG="$DIST/SafeCore-$VERSION-unsigned.dmg"
rm -f "$UNSIGNED_DMG"
"$VENV/bin/dmgbuild" -s "$BUILD/dmg-settings.py" \
  -D stage="$BUILD/stage" -D background="$BUILD/art/dmg-background.tiff" \
  "SafeCore $VERSION" "$UNSIGNED_DMG"

# 6. Signing kit --------------------------------------------------------------------------
say "6/7 Preparing the signing kit"
KIT="$DIST/SafeCore-$VERSION-signing-kit"
rm -rf "$KIT"; mkdir -p "$KIT"
cp "$UNSIGNED_DMG" "$KIT/"
cp "$ROOT/signing/sign-and-notarize.sh" "$ROOT/signing/README-signing.md" "$KIT/"
cp "$REPORT" "$KIT/"
chmod 755 "$KIT/sign-and-notarize.sh"

# 7. Summary ----------------------------------------------------------------------------------
say "7/7 Done"
echo "Test DMG:     $UNSIGNED_DMG"
echo "Signing kit:  $KIT"
echo "Runs on:      $SUPPORTED ($ARCH_LABEL)"
if [ "$UNSIGNED" -gt 0 ]; then
  printf '\033[1;33mWarning:\033[0m %s binaries in the package are not signed with Developer ID + hardened runtime.\n' "$UNSIGNED"
  echo "         Notarization will fail until the developer signs them. See $REPORT"
fi
[ "$ARCH_LABEL" = Universal ] || printf '\033[1;33mWarning:\033[0m the package only runs on %s. The app will refuse other Macs.\n' "$ARCH_LABEL"
