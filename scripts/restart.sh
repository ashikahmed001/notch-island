#!/usr/bin/env bash
# Rebuild Notch Island, quit the copy that's running, and open the new one.
#   scripts/restart.sh
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/bundle.sh

# Quit the running copy (the .app, or one started with `swift run`), then wait for it to exit.
pkill -x NotchIsland 2>/dev/null || true
for _ in {1..20}; do
  pgrep -x NotchIsland >/dev/null || break
  sleep 0.1
done

open build/NotchIsland.app
echo "Notch Island restarted with the new build."
