#!/usr/bin/env bash
# Builds and runs the app-logic tests (State + Platform/TakeClock.swift) with
# plain swiftc, no Xcode: works on Linux and macOS.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../App/Sources"
out="${TMPDIR:-/tmp}/lumber-applogic-tests"
swiftc -swift-version 6 -Onone \
  "$src"/State/*.swift "$src/Platform/TakeClock.swift" "$here/main.swift" \
  -o "$out"
"$out"
