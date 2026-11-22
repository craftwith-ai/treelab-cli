#!/usr/bin/env bash
# Starts the app on a free port (PORT=… to force one) and prints the URL. Adapt the last line to the project.
set -euo pipefail
cd "$(dirname "$0")/.."
port="${PORT:-}"
if [ -z "$port" ]; then port=3000; while lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; do port=$((port + 1)); done; fi
echo "→ http://localhost:$port"
# served build: lane, revision, port and pid recorded for session starts; without lab, nothing is written
if command -v lab >/dev/null 2>&1; then lab served "$port" --pid "$$" >/dev/null 2>&1 || true; fi
PORT="$port" exec {{DEV_COMMAND}}
