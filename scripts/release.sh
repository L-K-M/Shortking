#!/usr/bin/env bash
# Cuts a release: bumps the version, commits, tags "v<version>", and with --push
# pushes branch + tag — which triggers .github/workflows/release.yml to test, build,
# sign, notarize, staple and publish the GitHub Release (.dmg + .zip + SHA-256 sums).
#
# Shortking is a SwiftPM package with no pbxproj, so the version lives in the bundle's
# Info.plist and that file is the source of truth: `make app` copies it verbatim into
# Contents/, and CI builds from the *committed* plist at the tagged commit — the tag
# only names the Release. release.yml refuses to publish when the two disagree, so a
# release named v1.3.0 can never contain a 0.1.0 bundle.
#
# CFBundleVersion is auto-incremented alongside CFBundleShortVersionString (the same
# rule the gradle-android kind applies to versionCode): macOS treats it as the build
# number that distinguishes two bundles sharing a marketing version.
#
#   scripts/release.sh 1.3.0          # bump Info.plist + README, commit, tag v1.3.0
#   scripts/release.sh 1.3.0 --push   # …also push the commit + tag (CI then publishes)
#   scripts/release.sh                # tag the current committed version as-is
#
# Usage: scripts/release.sh [X.Y[.Z]] [--push]
# Shared engine: https://github.com/L-K-M/release-tool (this stub only sets config).
set -euo pipefail

export RELEASE_APP_NAME="Shortking"
export RELEASE_KIND="plist"
export RELEASE_PLIST="Resources/Info.plist"
# Read-modify-write on the same file the engine just bumped. ${RELEASE_NEW_VERSION} is
# not referenced here — only the build number changes — but the engine still rolls the
# whole bump back if this exits non-zero.
# shellcheck disable=SC2016
export RELEASE_POST_BUMP='/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist) + 1 ))" Resources/Info.plist'
export RELEASE_CI_NOTE="CI (release.yml) will now test the tagged commit, assemble the bundle, sign it with Developer ID, notarize and staple it, and publish the GitHub Release (Shortking-<version>.dmg + .zip, each with a SHA-256 sum) for <tag>."
export RELEASE_INVOKED_AS="scripts/release.sh"

BIN="${LKM_RELEASE_BIN:-lkm-release}"
command -v "$BIN" >/dev/null 2>&1 || {
  echo "error: lkm-release not found — clone https://github.com/L-K-M/release-tool and run ./install.sh" >&2
  exit 1
}
exec "$BIN" "$@"
