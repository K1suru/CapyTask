#!/bin/bash
# Compila CapyTask en release y empaqueta build/CapyTask.app
#
#   scripts/build_app.sh                 # binario universal (arm64 + x86_64)
#   ARCHS=arm64 scripts/build_app.sh     # solo Apple Silicon (más rápido)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/CapyTask.app"
RESOURCES="$ROOT/Sources/CapyTask/Resources"
ARCHS="${ARCHS:-arm64 x86_64}"

arch_flags=()
for arch in $ARCHS; do arch_flags+=(--arch "$arch"); done

echo "🍊 Compilando CapyTask (release · $ARCHS)…"
swift build -c release --product CapyTask "${arch_flags[@]}"
BIN_DIR="$(swift build -c release "${arch_flags[@]}" --show-bin-path)"

echo "📦 Empaquetando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CapyTask" "$APP/Contents/MacOS/CapyTask"
cp "$RESOURCES/Info.plist" "$APP/Contents/Info.plist"
cp "$RESOURCES"/Images/*.png "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "🦫 Copiando la animación del capibara (assets_processed → Resources/Sprites)"
SPRITES="$APP/Contents/Resources/Sprites"
mkdir -p "$SPRITES"
cp "$ROOT/assets_processed/metadata.json" "$SPRITES/"
cp -R "$ROOT/assets_processed/frames" "$SPRITES/"
for state in normal worried stressed; do
  count=$(ls "$SPRITES/frames/$state"/frame_*.png 2>/dev/null | wc -l | tr -d ' ')
  [ "$count" -gt 0 ] || { echo "❌ Faltan los fotogramas de '$state'"; exit 1; }
done

echo "🎨 Generando AppIcon.icns a partir de capy_logo.png"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$RESOURCES/Images/capy_logo.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$RESOURCES/Images/capy_logo.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

echo "🔏 Firmando (ad-hoc)"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "✅ Listo: $APP ($(lipo -archs "$APP/Contents/MacOS/CapyTask"))"
echo "   Ábrelo con:  open \"$APP\""
