#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export WEB_ROOT=${WEB_ROOT:-"$SCRIPT_DIR/../web"}
export OLLAMA_BASE=${OLLAMA_BASE:-"http://127.0.0.1:11434"}
export PORT=${PORT:-80}
export TTS_MODEL=${TTS_MODEL:-"$SCRIPT_DIR/../tts-models/zh_CN-huayan-medium.onnx"}

TTS_RUNNER="$SCRIPT_DIR/../.tts-venv/bin/python"
if [ -x "$TTS_RUNNER" ]; then
  exec "$TTS_RUNNER" "$SCRIPT_DIR/server.py"
fi
exec python3 "$SCRIPT_DIR/server.py"
