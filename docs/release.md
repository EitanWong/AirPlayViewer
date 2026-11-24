# Release workflow

## Branches and versions

- `dev` is the integration branch. Open feature and fork PRs against `dev`.
- Promote `dev` to `main` via PR. The `Main ready` check requires the PR to come from this repository's `dev`, the version to increase from `main`, and the macOS tests and local DMG checks to pass.
- [VERSION](../VERSION) is the source of truth. Start at `0.1.0`. Bump patch for fixes, minor for backwards-compatible features, and major for breaking changes when API stability is promised. Use only stable `MAJOR.MINOR.PATCH` values; the release tag adds a `v` prefix.

## GitHub setup

1. Make `main` the default branch and create `dev` from it. Protect `main` with a ruleset: require PRs, reviews, and the `Main ready` status check; require the branch to be up to date; disable force pushes, deletion, and bypasses. Review workflow/script changes before merging.
2. Set the repository Actions variable `AIRPLAYVIEWER_MACOS_RUNNER=macos-27` **only when** GitHub lists a hosted Arm64 image with a compatible Xcode. Until then, the macOS job is skipped and `Main ready` fails closed. Do not send public PR code to a personal or persistent signing runner.
3. Create a protected `release` environment limited to `main`. Configure `APPLE_SIGNING_IDENTITY` (full Developer ID Application identity name), `APPLE_CERT_P12_B64`, `APPLE_CERT_PASSWORD`, `APPLE_NOTARY_KEY_P8_B64`, `APPLE_NOTARY_KEY_ID`, and `APPLE_NOTARY_ISSUER_ID` as environment secrets. Use a team App Store Connect API key for notarization. Do not commit these values.
4. Enable [immutable releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases/using-immutable-releases) to prevent published tags and assets from being replaced. Set `AIRPLAYVIEWER_RELEASE_ENABLED=true` only after the prerequisites below are satisfied.

## Publication

Run `sh scripts/ci.sh` locally. It runs Swift tests, builds the app, verifies resources and linkage, then creates and mounts an ad-hoc signed DMG. The result is for local testing, not distribution.

After a push to `main`, CI tests that exact commit again. The protected release job signs the app and disk image, notarizes and staples both, checks Gatekeeper, verifies the mounted app, then publishes `AirPlayViewer-<version>-arm64.dmg` and its SHA-256 file as a GitHub Release. A manual run on `main` can publish the first `0.1.0` after setup. A successful rerun skips an existing release for the same commit; it does not overwrite assets. If publishing leaves an incomplete draft, inspect and remove only that draft before retrying; never delete a published tag to retry.

## Before making it public

1. Have the owner confirm the first-party license and add the approved root `LICENSE`. Review third-party provenance, license compatibility, corresponding-source and static-link distribution requirements, and publish any required source or relinking materials with the matching release.
2. Review the staged file list and Git history before pushing. CI rejects tracked files that match ignore rules, but ignore rules are not a history scrub. Keep private notes, credentials, logs, and local output out of Git.
3. Verify discovery, connect/reconnect, video, and audio on real devices, and verify English, Simplified Chinese, and pseudolocalization. Test installation of the signed and notarized DMG on a clean Apple silicon Mac.
