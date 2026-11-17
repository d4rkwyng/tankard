# Releasing

[README](../README.md) · [Using Tankard](usage.md) · [Development](development.md) · [Architecture](architecture.md) · **Releasing**

## Signing a release

Two ways, sharing `Scripts/release.sh`:

**On your Mac** (Developer ID certificate in your login keychain). Once, store the notary
credentials in the keychain:

```sh
xcrun notarytool store-credentials tankard
# Apple ID, Team ID, and an app-specific password made at appleid.apple.com
```

Then:

```sh
Scripts/release.sh --dry-run   # print every step
Scripts/release.sh             # dist/Tankard.app (signed, notarized, stapled) and dist/Tankard.zip
```

It builds universal (`--host-arch` for this Mac's architecture only), finds the
"Developer ID Application:" identity with `security find-identity -v -p codesigning`
(override: `TANKARD_SIGN_ID`), signs nested code first and then the app with
`codesign --force --options runtime --timestamp` (no `--deep`), checks it with
`codesign --verify --strict --deep`, submits a zip with `notarytool --wait` (profile name:
`TANKARD_NOTARY_PROFILE`, default `tankard`), fails unless the status is Accepted, staples,
checks with `spctl -a -vv`, and zips the stapled app with `ditto -c -k --keepParent`.
`--skip-notarize` stops after signing.

The hardened runtime needs no entitlements: the app is plain Swift with no third-party
libraries, plug-ins or JIT, and brew is a child process started with `posix_spawn`, which
the parent's runtime doesn't restrict. (Checked on the arm64 Mac: an ad-hoc,
hardened-runtime build reads real brew data.)

**On GitHub.** `.github/workflows/release.yml` runs on a `v*` tag push (or by hand with a
tag), on `macos-15`: tests, imports the certificate, runs `Scripts/release.sh`, and
attaches `Tankard.zip` to the release. Actions are pinned by commit SHA. The owner must add
five repository secrets first (the workflow stops with a clear message if any is missing):

| secret | value |
|---|---|
| `CERT_P12_BASE64` | `base64 -i DeveloperID.p12` of the exported Developer ID Application certificate and key |
| `CERT_P12_PASSWORD` | the .p12 password |
| `NOTARY_APPLE_ID` | Apple ID |
| `NOTARY_TEAM_ID` | Team ID |
| `NOTARY_PASSWORD` | app-specific password |

No secrets live in the repository.

## The Homebrew cask

`brew install --cask d4rkwyng/tap/tankard` comes from `Casks/tankard.rb` in
[d4rkwyng/homebrew-tap](https://github.com/d4rkwyng/homebrew-tap). It downloads
`Tankard.zip` from this repository's GitHub release for `v#{version}`, needs macOS 14
(`depends_on macos: :sonoma`), and its `zap` removes
`~/Library/Caches/net.mindtricks.tankard`, `~/Library/Logs/Tankard`,
`~/Library/Preferences/net.mindtricks.tankard.plist` and
`~/Library/Saved Application State/net.mindtricks.tankard.savedState`.

The release workflow does not touch the tap. After a release, update `version` and
`sha256` (of the released `Tankard.zip`) in the cask and commit it to the tap.
