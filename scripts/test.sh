#!/bin/zsh
# Unit tests of LauncherCore.swift (no UI, no game files).
set -e
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/sw-core-tests"
swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos15.0 LauncherCore.swift Tests/*.swift -o "$OUT"
"$OUT"
