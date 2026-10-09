#!/bin/bash
# Baut das Release zum Herunterladen: dist/release/AVP-Play-<Version>.dmg
#
#   AVPPLAY_APP_VERSION      Versionsnummer (Standard 1.0.0)
#   AVPPLAY_SIGN_IDENTITY    "Developer ID Application: Name (TEAMID)" – ohne sie entsteht ein Paket, das macOS
#                            auf fremden Rechnern nicht ohne Weiteres öffnet
#   AVPPLAY_NOTARY_PROFILE   Name eines Profils von `xcrun notarytool store-credentials` für Apples Beglaubigung
#
# Zugangsdaten stehen nie hier und nie in der Umgebung: die Signatur nimmt das Zertifikat aus dem Schlüsselbund,
# die Beglaubigung das dort hinterlegte Profil.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(cd .. && pwd)"
VERSION="${AVPPLAY_APP_VERSION:-1.0.11}"
export AVPPLAY_APP_VERSION="$VERSION"

tools/make-app.sh
APP="$ROOT/dist/AVP Play.app"
[ -d "$APP/Contents/Resources/toolchain" ] || { echo "!! ohne Toolchain im Programmpaket kein Release" >&2; exit 1; }

# Erst das Programm selbst beglaubigen lassen und den Nachweis anheften: dann öffnet es sich nach dem Kopieren
# aus dem Abbild auch ohne Netz. Das Abbild bekommt danach seinen eigenen Nachweis.
if [ -n "${AVPPLAY_SIGN_IDENTITY:-}" ] && [ -n "${AVPPLAY_NOTARY_PROFILE:-}" ]; then
  ZIP="$(mktemp -d)/AVP-Play.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$AVPPLAY_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -rf "$(dirname "$ZIP")"
fi

OUT="$ROOT/dist/release"
DMG="$OUT/AVP-Play-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$OUT"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "AVP Play" -srcfolder "$STAGE" -format UDZO "$DMG"

if [ -n "${AVPPLAY_SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$AVPPLAY_SIGN_IDENTITY" "$DMG"
  if [ -n "${AVPPLAY_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$AVPPLAY_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
    STATE="signiert und von Apple beglaubigt"
  else
    STATE="signiert, NICHT beglaubigt (AVPPLAY_NOTARY_PROFILE fehlt)"
  fi
else
  STATE="NICHT signiert – nur zum Testen auf diesem Mac"
fi
echo "$DMG"
echo "  $STATE"
echo "  $(du -h "$DMG" | cut -f1), SHA-256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
