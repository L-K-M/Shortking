#!/usr/bin/env bash
# Builds build/Shortking.app from the command line and reveals it in Finder on success.
# Incremental Release build by default; --clean resets a wedged Swift build toolchain
# and wipes .build/, build/ and dist/ before building.
# Thin stub for the shared lkm-build engine.
#
# Build the bundle, not the bare binary: `swift build` alone produces an executable in
# .build/ whose TCC identity belongs to whatever launched it, so permission grants never
# stick. The engine drives scripts/assemble-app.sh (which runs `make app`), then reveals,
# runs, installs or packages the assembled bundle.
#
# Usage: scripts/build.sh [--clean] [--debug] [--run] [--install] [--zip] [--dmg]
# Shared engine: https://github.com/L-K-M/release-tool (this stub only sets config).
set -euo pipefail

export BUILD_APP_NAME="Shortking"
export BUILD_KIND="swiftpm"
export BUILD_SWIFTPM_ASSEMBLE="scripts/assemble-app.sh"
export BUILD_PRODUCT_PATH="build/Shortking.app"
# The Makefile assembles into build/, not the engine's default dist/ — so --clean has to
# wipe build/ too, or the next run reveals a stale bundle.
export BUILD_CLEAN_PATHS=".build build dist"
export BUILD_INVOKED_AS="scripts/build.sh"

BIN="${LKM_BUILD_BIN:-lkm-build}"
command -v "$BIN" >/dev/null 2>&1 || {
  echo "error: lkm-build not found — clone https://github.com/L-K-M/release-tool and run ./install.sh" >&2
  exit 1
}
exec "$BIN" "$@"
