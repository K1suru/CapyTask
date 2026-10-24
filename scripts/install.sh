#!/bin/bash
# Instala CapyTask.app en /Applications (o ~/Applications si no hay permisos) y lo abre.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/CapyTask.app"

if [ ! -d "$APP" ] || [ "${REBUILD:-0}" = "1" ]; then
  "$ROOT/scripts/build_app.sh"
fi

DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

if pgrep -x CapyTask >/dev/null; then
  echo "🛁 Cerrando la instancia en ejecución…"
  pkill -x CapyTask || true
  sleep 1
fi

rm -rf "$DEST/CapyTask.app"
cp -R "$APP" "$DEST/"
echo "✅ Instalado en $DEST/CapyTask.app"
open "$DEST/CapyTask.app"
