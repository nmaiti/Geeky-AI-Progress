#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_DIR="$PROJECT_DIR/Monitor_sever"
BUILD_DIR="$PROJECT_DIR/dist"
BINARY_NAME="monitor-server"
GO_VERSION="1.25-alpine"
IMAGE="golang:${GO_VERSION}"

if command -v cygpath >/dev/null 2>&1; then
    PROJECT_DIR_WIN=$(cygpath -w "$PROJECT_DIR")
    MONITOR_DIR_WIN=$(cygpath -w "$MONITOR_DIR")
else
    PROJECT_DIR_WIN="$PROJECT_DIR"
    MONITOR_DIR_WIN="$MONITOR_DIR"
fi

usage() {
    echo "Usage: $0 [linux|windows|all|clean]"
    echo "  linux     Build Linux binary"
    echo "  windows   Build Windows binary"
    echo "  all       Build both (default)"
    echo "  clean     Remove build artifacts"
    exit 1
}

build_linux() {
    echo "[Build] Building Linux binary..."
    mkdir -p "$BUILD_DIR"
    MSYS_NO_PATHCONV=1 docker run --rm \
        -v "${MONITOR_DIR_WIN}:/src" \
        -w /src \
        "$IMAGE" \
        sh -c "go mod tidy && go build -o dist/${BINARY_NAME}-linux-amd64 ."
    echo "[Build] Linux binary: ${BUILD_DIR}/${BINARY_NAME}-linux-amd64"
}

build_windows() {
    echo "[Build] Building Windows binary..."
    mkdir -p "$BUILD_DIR"
    MSYS_NO_PATHCONV=1 docker run --rm \
        -v "${MONITOR_DIR_WIN}:/src" \
        -w /src \
        -e GOOS=windows \
        -e GOARCH=amd64 \
        "$IMAGE" \
        sh -c "go mod tidy && go build -o dist/${BINARY_NAME}-windows-amd64.exe ."
    echo "[Build] Windows binary: ${BUILD_DIR}/${BINARY_NAME}-windows-amd64.exe"
}

clean() {
    echo "[Build] Cleaning build artifacts..."
    rm -rf "$BUILD_DIR"
    echo "[Build] Clean complete."
}

case "${1:-all}" in
    linux)
        build_linux
        ;;
    windows)
        build_windows
        ;;
    all)
        build_linux
        build_windows
        ;;
    clean)
        clean
        ;;
    *)
        usage
        ;;
esac
