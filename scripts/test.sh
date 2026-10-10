#!/bin/zsh
set -euo pipefail
SCRIPT_DIRECTORY="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIRECTORY:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.build/TestModuleCache"
/usr/bin/xcrun swift test --package-path "$PROJECT_ROOT" --scratch-path "$PROJECT_ROOT/.build/TestBuild" --disable-sandbox "$@"
