# CI/CD

Shortking is a SwiftPM package that builds a macOS `.app` bundle. CI tests and assembles
the bundle on every change; the release workflow signs it with a Developer ID
certificate, notarizes it, staples the ticket, and publishes a `.dmg` and `.zip` with
SHA-256 sums to a GitHub Release.

Unlike the sibling macOS apps (Top Drawer, Zap), **Shortking is never published
unsigned.** It asks for Accessibility and Input Monitoring, it cannot ship on the Mac App
Store (per-pid event taps are unsupported under App Sandbox, and it reads other apps'
preference domains), and Developer ID + notarization is the only channel it has. A tag
pushed without the signing secrets configured fails the release rather than falling back
to an ad-hoc build.

## Workflows

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| [`ci.yml`](.github/workflows/ci.yml) | Pull requests, pushes to `main`, manual dispatch | `swift test`, assemble the `.app`, and assert the bundle layout. |
| [`release.yml`](.github/workflows/release.yml) | Pushing a `v*` tag (e.g. `v1.2.0`) | Re-test the tagged commit, sign, notarize, staple, and publish the GitHub Release. |
| [`zai-code-review.yml`](.github/workflows/zai-code-review.yml) | Non-draft PRs from this repository | GLM 5.2 review when `ZAI_API_KEY` is configured. Never runs for fork PRs — `pull_request_target` has access to secrets. |

Both `ci.yml` and `release.yml` run on `macos-14` with **Xcode 16.2** pinned via
`maxim-lobanov/setup-xcode`, so a runner-image bump can't silently change the toolchain.
Bump the two together, and keep them in step with Top Drawer and Zap.

The family hardening trio applies to `ci.yml`: least-privilege `permissions: contents:
read`; `concurrency: ci-${{ github.ref }}` with `cancel-in-progress` gated on
`github.event_name == 'pull_request'`, so a superseded PR run is cancelled but an
in-progress `main` run never is (a permanently "cancelled" main commit masks breakage and
puts holes in CI-status bisection); and a `timeout-minutes` on every job, because the
wedged Swift build service (the `CreateBuildDescription` / clang-probe hang) would
otherwise burn the 6-hour default.

## Continuous integration (`ci.yml`)

A single **Test & assemble** job:

1. `swift test` — the pure unit tests (parsers, modifier round-trips, conflict
   classification, the confidence curve).
2. `make app` — assembles `build/Shortking.app`, ad-hoc signed. No certificate is
   available here and none is needed to prove the bundle assembles.
3. Asserts `Contents/MacOS/Shortking`, `Contents/MacOS/shortking-probe`,
   `Contents/Info.plist` and `Contents/PkgInfo` all exist, then `codesign --verify
   --strict`.
4. Uploads the bundle as an artifact (14-day retention).

**Why step 3 exists:** `ShortkingApp` resolves the probe helper with
`Bundle.main.url(forAuxiliaryExecutable:)`. A Makefile change that stopped staging
`shortking-probe` into `Contents/MacOS` would still produce a bundle that builds, launches
and looks fine — probing would just silently return nothing at runtime. The assertion
turns that into a build failure.

### Running CI checks locally

```sh
swift test
make app
```

`scripts/build.sh` is the friendlier local equivalent of `make app`: it wraps the same
assembly with a wedged-toolchain reset (`--clean`), a Finder reveal, and `--run`,
`--install`, `--zip`, `--dmg`.

## Releases (`release.yml`)

Cut a release with the helper, which bumps the version, commits, tags, and pushes:

```sh
scripts/release.sh 1.2.3 --push
```

That bumps `CFBundleShortVersionString` in `Resources/Info.plist`, auto-increments
`CFBundleVersion`, updates the README version marker, commits, creates the annotated tag
`v1.2.3`, and pushes branch + tag. The tag push triggers the workflow.

`Resources/Info.plist` is the source of truth, not the tag: `make app` copies it verbatim
into `Contents/`, so CI builds whatever version is committed at the tagged commit and the
tag only *names* the Release. The workflow's second step asserts the two agree and fails
the release if they don't — otherwise a Release named `v1.3.0` could contain a `0.1.0`
bundle. Always cut releases with `scripts/release.sh` so they stay in step.

The job then:

1. **Validates every signing secret up front** and fails with the list of missing ones.
   Nothing is built before this passes.
2. Re-runs `swift test`. A `v*` tag can land on any commit — including one CI never saw.
3. Imports the Developer ID certificate into a temporary keychain, appended to the search
   list rather than replacing it (notarization credentials live in the default keychain
   and must stay reachable). The signing identity is resolved to its SHA-1 with `security
   find-identity`, so the certificate's common name doesn't have to be a separate secret.
4. Stores App Store Connect API credentials as a `notarytool` keychain profile.
5. `make notarize` — which chains `dmg` → `app` → `sign`, so the published artifact is
   assembled by exactly the same path a maintainer uses locally: the probe helper and the
   bundle are both signed with the hardened runtime, a secure timestamp and
   `Resources/Shortking.entitlements`; the DMG is then submitted and the ticket stapled to
   both the DMG and the `.app`.
6. Verifies the result the way a user's machine will: `codesign --verify --deep --strict`,
   an explicit check that the hardened-runtime flag is present (notarization requires it,
   and a missing one only surfaces as a Gatekeeper rejection later), `stapler validate` on
   both artifacts, and `spctl --assess --type exec`.
7. Packages `Shortking-<version>.dmg` and `Shortking-<version>.zip` plus a combined
   `.sha256` file, and publishes them with auto-generated notes. A tag containing a hyphen
   (`v1.3.0-rc.1`) is published as a pre-release.
8. Deletes the signing keychain, whatever happened.

The `.zip` is produced with `ditto -c -k --keepParent`, not `zip`: it is the only archiver
that preserves the bundle's symlinks, resource forks and extended attributes, and
therefore its signature and stapled ticket.

## Secrets

`ci.yml` needs none. `release.yml` requires all seven — these are the family's standard
names for the signed-macOS path:

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Developer ID Application certificate + private key, exported as `.p12` and base64-encoded (`base64 < cert.p12 \| tr -d '\n' \| pbcopy`) |
| `DEVELOPER_ID_P12_PASSWORD` | The password set when exporting the `.p12` |
| `KEYCHAIN_PASSWORD` | Any random string; protects the temporary keychain for the length of the run |
| `APPLE_TEAM_ID` | The 10-character Apple Developer team identifier |
| `AC_API_KEY_BASE64` | App Store Connect API key (`AuthKey_XXXX.p8`), base64-encoded |
| `AC_API_KEY_ID` | The key's ID (the `XXXX` in the filename) |
| `AC_API_ISSUER_ID` | The issuer UUID from App Store Connect → Users and Access → Integrations |

`zai-code-review.yml` uses `ZAI_API_KEY` and skips itself cleanly when it is unset.

Base64 secrets are decoded through `tr -d ' \t\r\n'` first, so a 76-column wrapped paste
or a stray carriage return doesn't fail the release — only genuinely invalid base64 does.

## Troubleshooting

- **`Release signing is not fully configured`** — one of the seven secrets is unset. This
  is deliberate: see the note at the top. Add the secret and re-push the tag.
- **`No 'Developer ID Application' identity found`** — the `.p12` holds an *Apple
  Development* certificate, which cannot be notarized. Export a Developer ID Application
  certificate instead.
- **`the signed bundle does not have the hardened runtime enabled`** — the Makefile's
  `sign` target lost `--options runtime`, or `SIGN_IDENTITY` was empty and it fell through
  to the ad-hoc branch.
- **Notarization rejected** — `xcrun notarytool log <submission-id> --keychain-profile
  shortking-notary` gives the per-binary reason. Usually a nested binary missing the
  hardened runtime or a secure timestamp.
- **`Tag vX.Y.Z does not match CFBundleShortVersionString`** — the tag was created by hand.
  Delete it and re-cut with `scripts/release.sh`.
- **TCC grants keep lapsing between local builds** — expected without `SIGN_IDENTITY`. An
  ad-hoc signature's cdhash changes on every build, so macOS treats each rebuild as a new
  app. Set `SIGN_IDENTITY` for anything permission-related.
