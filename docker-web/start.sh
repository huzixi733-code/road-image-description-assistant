#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export WEB_ROOT=${WEB_ROOT:-"$SCRIPT_DIR/../web"}
export OLLAMA_BASE=${OLLAMA_BASE:-"http://127.0.0.1:11434"}
export PORT=${PORT:-80}

exec python3 "$SCRIPT_DIR/server.py"
