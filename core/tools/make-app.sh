#!/bin/bash
# Baut die Mac-App als Programmpaket: dist/AVP Play.app
#
# Das Paket enthält das Programm und die Rezepte – keine Spielinhalte, keine Toolchain, keine Zugangsdaten.
# Signiert wird ohne Identität („ad hoc“): das genügt zum Starten auf dem Mac, der es gebaut hat. Für die
# Weitergabe braucht es eine Developer-ID-Signatur und die Beglaubigung durch Apple (noch nicht eingerichtet).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(cd .. && pwd)"
VERSION="${AVPPLAY_APP_VERSION:-1.1.16}"
# Build number: commit count plus a fixed offset. Releases 1.1.15 and earlier were built from a repository
# with about 340 commits, 1.1.16 from one with 127; the offset keeps every later build above 340 so that
# build numbers never go backwards. AVPPLAY_APP_BUILD overrides the result.
BUILD_OFFSET=214
BUILD="${AVPPLAY_APP_BUILD:-$(( $(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1) + BUILD_OFFSET ))}"
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "!! AVPPLAY_APP_BUILD must contain digits only: $BUILD" >&2; exit 1; }
OUT="$ROOT/dist/AVP Play.app"

swift build -c release --build-path .build-app --product AVPPlayApp
swift build -c release --build-path .build-app --product avpplay
BIN=".build-app/release/AVPPlayApp"

NEW="$ROOT/dist/.AVP Play.app.new"
rm -rf "$NEW"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources/recipes"
cp "$BIN" "$NEW/Contents/MacOS/AVPPlay"
# Die Kommandozeile kommt mit: Der Auftrag aus „Fix with AI“ baut und installiert damit aus einer Arbeitskopie.
# In einen eigenen Ordner: Auf dem üblichen Dateisystem eines Macs sind „AVPPlay“ und „avpplay“ derselbe Name,
# und im selben Ordner würde die eine Datei die andere ersetzen.
mkdir -p "$NEW/Contents/Helpers"
cp ".build-app/release/avpplay" "$NEW/Contents/Helpers/avpplay"
# Ohne die Verweise auf die Bauprodukte: Der Linker trägt in jedes Programm ein, wo die Objektdateien und Quellen
# auf dem bauenden Rechner lagen – der Benutzername und die Ordner dieses Macs, in jedem veröffentlichten Abbild.
# `strip -S` nimmt genau diese Einträge heraus; das Programm selbst und seine Symbole bleiben. Vor dem Signieren.
xcrun strip -S "$NEW/Contents/MacOS/AVPPlay" "$NEW/Contents/Helpers/avpplay"
if LC_ALL=C grep -a -q -E '/Users/[A-Za-z0-9._-]+/' "$NEW/Contents/MacOS/AVPPlay" "$NEW/Contents/Helpers/avpplay"; then
  echo "!! in den Programmen steht noch ein Pfad dieses Rechners" >&2
  exit 1
fi
cp "$ROOT"/recipes/*.json "$NEW/Contents/Resources/recipes/"
# Weitere geprüfte Fassungen einzelner Spiele (RecipeStore.loadVariants), soweit es welche gibt.
if ls "$ROOT"/recipes/versions/*.json >/dev/null 2>&1; then
  mkdir -p "$NEW/Contents/Resources/recipes/versions"
  cp "$ROOT"/recipes/versions/*.json "$NEW/Contents/Resources/recipes/versions/"
fi
# Rezepte für dasselbe Spiel aus einer anderen Kaufquelle (RecipeStore.loadSources), soweit es welche gibt.
if ls "$ROOT"/recipes/sources/*.json >/dev/null 2>&1; then
  mkdir -p "$NEW/Contents/Resources/recipes/sources"
  cp "$ROOT"/recipes/sources/*.json "$NEW/Contents/Resources/recipes/sources/"
fi
# Die Toolchain kommt mit: das neueste Paket aus dist/ samt Beschreibung (oder AVPPLAY_TOOLCHAIN_ARCHIVE).
# Die App installiert es beim ersten Start – geprüft gegen die Beschreibung wie jedes andere Paket.
# Ohne Archiv in dist/ scheitert das `ls` – unter `set -e` samt pipefail würde die Zuweisung das Skript stillschweigend
# beenden, statt in den Zweig „ohne Toolchain“ zu laufen. Deshalb `|| true`.
TOOLCHAIN="${AVPPLAY_TOOLCHAIN_ARCHIVE:-$(ls -t "$ROOT"/dist/klepton-toolchain-*.tar.gz 2>/dev/null | head -1 || true)}"
if [ -n "$TOOLCHAIN" ] && [ -f "$TOOLCHAIN" ] && [ -f "$TOOLCHAIN.json" ]; then
  mkdir -p "$NEW/Contents/Resources/toolchain"
  cp "$TOOLCHAIN" "$TOOLCHAIN.json" "$NEW/Contents/Resources/toolchain/"
else
  echo "!! kein Toolchain-Paket gefunden – das Programmpaket entsteht ohne Toolchain" >&2
fi
# Die eigenen Texte stehen im Programm (L("English", "Deutsch")). Die beiden Ordner sagen macOS nur, in welchen
# Sprachen es seine eigenen Menüs und Dialoge zeigen darf.
for lang in en de; do
  mkdir -p "$NEW/Contents/Resources/$lang.lproj"
  printf '/* %s */\n' "$lang" > "$NEW/Contents/Resources/$lang.lproj/Localizable.strings"
done
cat > "$NEW/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>AVP Play</string>
  <key>CFBundleDisplayName</key><string>AVP Play</string>
  <key>CFBundleIdentifier</key><string>io.github.mymartek.avpplay</string>
  <key>CFBundleExecutable</key><string>AVPPlay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>de</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Das Icon wird gezeichnet, nicht mitgeführt; neu nur, wenn sich die Zeichnung geändert hat.
ICON=".build-app/AppIcon.icns"
if [ ! -f "$ICON" ] || [ tools/make-icon.swift -nt "$ICON" ]; then
  rm -rf .build-app/AppIcon.iconset
  swift tools/make-icon.swift .build-app/AppIcon.iconset
  iconutil -c icns .build-app/AppIcon.iconset -o "$ICON"
fi
cp "$ICON" "$NEW/Contents/Resources/AppIcon.icns"
# Ohne Vorgabe wird ohne Identität signiert („ad hoc“) – das startet nur auf dem Mac, der gebaut hat.
# Für die Weitergabe: AVPPLAY_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)", mit gehärteter Laufzeit
# und Zeitstempel, wie Apples Beglaubigung es verlangt.
if [ -n "${AVPPLAY_SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$AVPPLAY_SIGN_IDENTITY" "$NEW/Contents/Helpers/avpplay"
  codesign --force --options runtime --timestamp --sign "$AVPPLAY_SIGN_IDENTITY" "$NEW"
  codesign --verify --strict "$NEW"
else
  codesign --force --sign - "$NEW" >/dev/null 2>&1
fi
rm -rf "$OUT"
mv "$NEW" "$OUT"
# Prüfung: Das Programm im Paket ist die App und nicht die Kommandozeile.
if ! otool -L "$OUT/Contents/MacOS/AVPPlay" | grep -q "SwiftUI"; then
  echo "!! Contents/MacOS/AVPPlay ist nicht die App" >&2
  exit 1
fi
echo "$OUT ($VERSION, Build $BUILD, $(du -sh "$OUT" | cut -f1))"
