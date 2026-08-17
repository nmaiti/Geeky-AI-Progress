#!/usr/bin/env bash
set -euxo pipefail

IMAGE="infinitecoding/platformio-for-ci:latest"
PORT="${1:-}"

if [[ -z "$PORT" ]]; then
    echo "Usage: $0 <serial-port>"
    echo "  Linux:   /dev/ttyUSB0"
    echo "  Windows: COM3"
    exit 1
fi

if command -v cygpath >/dev/null 2>&1; then
    PROJECT_DIR=$(cygpath -w "$(pwd)")
else
    PROJECT_DIR=$(pwd)
fi

echo "[Arduino Docker] Building ESP8266 firmware..."
MSYS_NO_PATHCONV=1 docker run --rm \
    -v "${PROJECT_DIR}:/workspace" \
    -w /workspace \
    "$IMAGE" \
    platformio run

echo "[Arduino Docker] Programming $PORT ..."
MSYS_NO_PATHCONV=1 docker run --rm \
    -v "${PROJECT_DIR}:/workspace" \
    -w /workspace \
    --device="$PORT" \
    "$IMAGE" \
    platformio run -t upload

echo "[Arduino Docker] Done."
