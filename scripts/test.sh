#!/bin/bash
# Ejecuta los tests. Con solo las Command Line Tools, el sistema de build de
# SwiftPM a veces olvida pasar el plugin de macros de Swift Testing
# ("plugin for module 'TestingMacros' not found"); se lo indicamos explícitamente.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TOOLCHAIN="$(dirname "$(dirname "$(xcrun --find swift)")")"
PLUGINS="$TOOLCHAIN/lib/swift/host/plugins/testing"

if [ -d "$PLUGINS" ]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
  swift test "$@"
fi
