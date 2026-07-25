# CI/CD

Shortking is a SwiftPM package that builds a macOS `.app` bundle. CI tests and assembles
the bundle on every change; the release workflow packages a `.dmg` and `.zip` with SHA-256
sums and publishes them to a GitHub Release.

Shortking cannot ship on the Mac App Store — per-pid event taps are unsupported under App
Sandbox, and it reads other apps' preference domains — so **Developer ID + notarization is
the channel to aim for**, and an app that asks for Accessibility and Input Monitoring is a
poor candidate for a Gatekeeper warning. But the release workflow behaves the same way its
siblings (Top Drawer, Zap, Copywraith) do rather than blocking on a certificate that may
not exist yet:

| Signing secrets | What the release does |
| --- | --- |
| All seven set | Signs with the Developer ID certificate, notarizes, staples, verifies with `spctl`. |
| None set | Ad-hoc signs (identity `-`), publishes with the Gatekeeper workaround in the notes. |
| Some set | Fails with the list of missing ones. |

The middle row is the fallback; the last is not a policy, it's a typo guard — a
half-configured signing setup should not silently degrade to an unsigned build. Configure
the secrets in the [Secrets](#secrets) table and the next tag upgrades itself to the
signed path with no workflow change.

## Workflows

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| [`ci.yml`](.github/workflows/ci.yml) | Pull requests, pushes to `main`, manual dispatch | `swift test`, assemble the `.app`, and assert the bundle layout. |
| [`release.yml`](.github/workflows/release.yml) | Pushing a `v*` tag (e.g. `v1.2.0`) | Re-test the tagged commit, build, sign (Developer ID or ad-hoc), and publish the GitHub Release. |
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

1. **Resolves the signing path** from the seven secrets — all set, none set, or the
   partial case that fails. Nothing is built before this passes.
2. Re-runs `swift test`. A `v*` tag can land on any commit — including one CI never saw.
3. *(signed only)* Imports the Developer ID certificate into a temporary keychain, appended
   to the search list rather than replacing it (notarization credentials live in the
   default keychain and must stay reachable). The signing identity is resolved to its SHA-1
   with `security find-identity`, so the certificate's common name doesn't have to be a
   separate secret.
4. *(signed only)* Stores App Store Connect API credentials as a `notarytool` keychain
   profile.
5. Builds through the Makefile, so the published artifact is assembled by exactly the same
   path a maintainer uses locally:
   - signed: `make notarize`, which chains `dmg` → `app` → `sign`. The probe helper and the
     bundle are both signed with the hardened runtime, a secure timestamp and
     `Resources/Shortking.entitlements`; the DMG is submitted and the ticket stapled to
     both the DMG and the `.app`.
   - unsigned: `make dmg`, the same chain minus notarization. With `SIGN_IDENTITY` unset
     the `sign` target ad-hoc signs (identity `-`), which carries no trust but *is*
     required for the bundle to launch at all on Apple Silicon.
6. Verifies. Signed, the way a user's machine will: `codesign --verify --deep --strict`, an
   explicit check that the hardened-runtime flag is present (notarization requires it, and
   a missing one only surfaces as a Gatekeeper rejection later), `stapler validate` on both
   artifacts, and `spctl --assess --type exec`. Unsigned, `codesign --verify --deep
   --strict` alone — an ad-hoc signature can't be stapled or assessed by Gatekeeper, but it
   still catches a bundle whose helper was staged after signing.
7. Packages `Shortking-<version>.dmg` and `Shortking-<version>.zip` plus a combined
   `.sha256` file, and publishes them. A tag containing a hyphen (`v1.3.0-rc.1`) is
   published as a pre-release.
8. Deletes the signing keychain, whatever happened.

The release notes are generated to match the path that ran, because the two ask completely
different things of whoever downloads the build: the signed body says it opens without a
prompt, the unsigned one carries the right-click-Open and `xattr -dr com.apple.quarantine`
workaround, plus the warning to grant Accessibility and Input Monitoring only *after*
moving the app to its final location (macOS keys TCC grants to signature and path). Both
end with the permissions summary and the `shasum -c` line.

The `.zip` is produced with `ditto -c -k --keepParent`, not `zip`: it is the only archiver
that preserves the bundle's symlinks, resource forks and extended attributes, and
therefore its signature and stapled ticket.

### Ad-hoc releases and permission grants

An ad-hoc signature's cdhash is derived from the binary, so it is stable for one published
artifact — a user who grants Accessibility to a downloaded ad-hoc build keeps that grant.
What they don't get is any continuity across versions: every release is a different app as
far as TCC is concerned, so each upgrade asks for the permissions again. A Developer ID
signature is what makes an upgrade an upgrade. That, and the Gatekeeper prompt, is the
argument for configuring the secrets — not that the fallback is unusable.

## Secrets

`ci.yml` needs none. `release.yml` takes the signed path when all seven of these are set
and the ad-hoc path when none of them are — they are the family's standard names for the
signed-macOS path:

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

- **`Release signing is partially configured`** — some of the seven secrets are set and
  some aren't, which is almost always a misspelled secret name. Set the missing ones (or
  clear the rest to take the ad-hoc path deliberately) and re-push the tag.
- **A release published unsigned when you expected it signed** — the workflow logs a
  `::warning::` naming the fallback in the "Resolve the signing path" step. Repository
  secrets aren't available to workflow runs triggered from a fork, and environment-scoped
  secrets aren't visible to a job with no `environment:`; check where the secrets live.
- **`No 'Developer ID Application' identity found`** — the `.p12` holds an *Apple
  Development* certificate, which cannot be notarized. Export a Developer ID Application
  certificate instead.
- **`the signed bundle does not have the hardened runtime enabled`** — the Makefile's
  `sign` target lost `--options runtime`. This check only runs on the signed path, so it
  means the identity resolved but the signing flags didn't.
- **Notarization rejected** — `xcrun notarytool log <submission-id> --keychain-profile
  shortking-notary` gives the per-binary reason. Usually a nested binary missing the
  hardened runtime or a secure timestamp.
- **`Tag vX.Y.Z does not match CFBundleShortVersionString`** — the tag was created by hand.
  Delete it and re-cut with `scripts/release.sh`.
- **TCC grants keep lapsing between local builds** — expected without `SIGN_IDENTITY`. An
  ad-hoc signature's cdhash changes on every build, so macOS treats each rebuild as a new
  app. Set `SIGN_IDENTITY` for anything permission-related.
