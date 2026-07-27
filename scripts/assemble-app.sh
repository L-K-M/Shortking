#!/usr/bin/env bash
# Assembles build/Shortking.app — the command scripts/build.sh hands to the shared
# lkm-build engine as BUILD_SWIFTPM_ASSEMBLE, and the one place that knows Shortking's
# bundle is assembled by the Makefile rather than by SwiftPM.
#
# SwiftPM has no notion of an .app bundle, and the bundle is the real build product
# here: TCC identity is bundle- and signature-based, so a bare executable out of
# .build/ makes AXIsProcessTrusted() report on whatever launched it. `make app` is what
# stages the shortking-probe helper into Contents/MacOS beside the app binary, copies
# Resources/Info.plist, and codesigns the result. The engine only ever invokes one
# executable with an optional --debug, so this maps that flag onto the Makefile's
# CONFIG variable and gets out of the way.
#
# SIGN_IDENTITY and TEAM_ID are read straight from the environment by the Makefile
# (`?=` defers to an exported value): unset, `make app` ad-hoc signs — runnable
# locally, but TCC grants lapse on every rebuild because an ad-hoc cdhash changes;
# set, it signs with the hardened runtime and Resources/Shortking.entitlements.
#
# Usage: scripts/assemble-app.sh [--debug]
# Called by scripts/build.sh (via lkm-build); equivalent to `make app [CONFIG=debug]`.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="release"
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG="debug" ;;
    -h|--help) echo "usage: scripts/assemble-app.sh [--debug]"; exit 0 ;;
    *) echo "!! unknown argument: $arg" >&2; exit 2 ;;
  esac
done

exec make app CONFIG="$CONFIG"
