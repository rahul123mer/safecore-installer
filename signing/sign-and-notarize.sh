#!/bin/bash
# Signs, notarizes and staples the SafeCore DMG. Run this on the Mac that holds the
# SafeSpace Developer ID certificates. Needs only Xcode Command Line Tools.
#
#   ./sign-and-notarize.sh --app-id "Developer ID Application: <Name> (<TEAMID>)" \
#                          --notary-profile safecore-notary \
#                          [--installer-id "Developer ID Installer: <Name> (<TEAMID>)"]
#
# --installer-id signs the SafeCore .pkg inside the app if the developer did not sign it.
# The package contents are not changed; only a signature is added.
#
# Input:  SafeCore-<ver>-unsigned.dmg in this folder
# Output: SafeCore-<ver>.dmg in this folder, signed, notarized and stapled
set -euo pipefail
cd "$(dirname "$0")"

APP_ID="" PROFILE="" INSTALLER_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app-id) APP_ID=$2; shift 2 ;;
    --notary-profile) PROFILE=$2; shift 2 ;;
    --installer-id) INSTALLER_ID=$2; shift 2 ;;
    *) echo "Unknown option $1" >&2; exit 64 ;;
  esac
done
[ -n "$APP_ID" ] && [ -n "$PROFILE" ] || { sed -n '2,13p' "$0"; exit 64; }

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mStopped:\033[0m %s\n' "$*" >&2; exit 1; }

IN=$(ls SafeCore-*-unsigned.dmg 2>/dev/null | head -1)
[ -n "$IN" ] || fail "No SafeCore-*-unsigned.dmg in $(pwd)"
VERSION=${IN#SafeCore-}; VERSION=${VERSION%-unsigned.dmg}
OUT="SafeCore-$VERSION.dmg"
WORK=$(mktemp -d)
MNT="$WORK/mnt"
trap 'hdiutil detach "$MNT" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT

say "1/7 Checking certificates and notary profile"
security find-identity -v -p codesigning | grep -qF "$APP_ID" || fail "Certificate not found in Keychain: $APP_ID"
if [ -n "$INSTALLER_ID" ]; then
  security find-identity -v | grep -qF "$INSTALLER_ID" || fail "Certificate not found in Keychain: $INSTALLER_ID"
fi
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || fail "Notary profile '$PROFILE' not found. Run the one-time store-credentials command in README-signing.md."
echo "OK"

say "2/7 Opening $IN for signing"
hdiutil convert "$IN" -format UDRW -o "$WORK/rw.dmg" -quiet
hdiutil attach "$WORK/rw.dmg" -mountpoint "$MNT" -nobrowse -noverify -noautoopen -quiet
APP="$MNT/Install SafeCore.app"
PKG="$APP/Contents/Resources/SafeCore.pkg"
[ -d "$APP" ] || fail "Install SafeCore.app not found inside the DMG"

say "3/7 Checking the SafeCore package"
pkgutil --expand-full "$PKG" "$WORK/pkg" >/dev/null
BAD=0
while IFS= read -r f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  sig=$(codesign -dv --verbose=2 "$f" 2>&1 || true)
  if ! { echo "$sig" | grep -q 'Authority=Developer ID Application' && echo "$sig" | grep -q 'flags=.*runtime' && echo "$sig" | grep -q 'Timestamp='; }; then
    echo "  not ready: ${f#$WORK/pkg/}"; BAD=$((BAD + 1))
  fi
done < <(find "$WORK/pkg" -type f \( -perm -u+x -o -name '*.dylib' \))
[ "$BAD" -eq 0 ] || fail "$BAD binaries in the SafeCore package are not signed with Developer ID, hardened runtime and a timestamp.
Apple will reject notarization. Ask the developer to sign them, e.g.:
  codesign --force --options runtime --timestamp --sign \"$APP_ID\" <binary>
then rebuild the .pkg and run build-dmg.sh again."
echo "All package binaries are signed."

if pkgutil --check-signature "$PKG" | grep -q 'Status: signed by a developer certificate issued by Apple for distribution'; then
  echo "Package is signed."
elif [ -n "$INSTALLER_ID" ]; then
  productsign --sign "$INSTALLER_ID" --timestamp "$PKG" "$WORK/signed.pkg"
  mv "$WORK/signed.pkg" "$PKG"
  echo "Package signed with $INSTALLER_ID."
else
  fail "The SafeCore .pkg is not signed. Re-run with --installer-id \"Developer ID Installer: … (TEAMID)\"."
fi

say "4/7 Signing Install SafeCore.app"
codesign --force --options runtime --timestamp --sign "$APP_ID" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

say "5/7 Rebuilding the DMG"
hdiutil detach "$MNT" -quiet
rm -f "$OUT"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet
codesign --force --timestamp --sign "$APP_ID" "$OUT"

say "6/7 Notarizing (usually 2–10 minutes)"
RESULT=$(xcrun notarytool submit "$OUT" --keychain-profile "$PROFILE" --wait --output-format plist)
STATUS=$(echo "$RESULT" | plutil -extract status raw - 2>/dev/null || echo unknown)
ID=$(echo "$RESULT" | plutil -extract id raw - 2>/dev/null || echo "")
if [ "$STATUS" != Accepted ]; then
  [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" || true
  fail "Notarization status: $STATUS. The log above lists every problem Apple found."
fi
echo "Accepted (submission $ID)"

say "7/7 Stapling and verifying"
xcrun stapler staple "$OUT"
spctl --assess --type open --context context:primary-signature --verbose=2 "$OUT"
echo
printf '\033[1;32mDone:\033[0m %s is signed, notarized and ready to send.\n' "$(pwd)/$OUT"
shasum -a 256 "$OUT"
