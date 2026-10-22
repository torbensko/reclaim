# Publishing Reclaim

Reclaim follows Brief and Pop's distribution process: GitHub Actions builds a
universal Mac app, signs the app and its embedded cleanup helper, submits it to
Apple for notarization, staples the accepted ticket, and publishes a DMG, ZIP
and SHA-256 checksums. A failed test, signature or notarization stops publication.
No cleanup or scheduling is run as part of packaging.

## First release

The repository is `torbensko/reclaim`. Add these **repository Actions secrets**
under **Settings → Secrets and variables → Actions**. Reuse the original
credentials used for Brief and Pop; GitHub cannot copy their stored secret values
back out. Never commit certificates, passwords, or local signing settings.

| Secret | Value |
| --- | --- |
| `CERTIFICATE_P12` | Base64-encoded exported **Developer ID Application** certificate, including its private key |
| `CERTIFICATE_PASSWORD` | Password for that P12 export |
| `APPLE_ID` | Apple Developer account email |
| `APPLE_ID_PASSWORD` | Apple app-specific password for notarization |
| `APPLE_TEAM_ID` | Developer team identifier associated with the signing certificate |
| `SPARKLE_PRIVATE_KEY` | Sparkle's base64 Ed25519 private key, matching `Resources/SparklePublicKey.txt` |

No Actions variables are needed. The workflow uses GitHub's `xcode-27` runner,
matching the successful Brief and Pop builds. The optional `MACOS_RUNNER`
variable can select another runner with Xcode 27 or later. The app still targets
macOS 14; the newer SDK is required to compile the native toolbar controls.

After adding the secrets, open **Actions → Build and release → Run workflow**
and choose `main`. Releases are manual; pushing commits does not publish an app.
The workflow refuses to overwrite an existing version or tag. It publishes only
after all assets have uploaded to a draft release. If publication fails after a
draft is created, inspect that draft before retrying; never replace a public
release silently.

Successful releases contain:

- `Reclaim.dmg`: drag Reclaim into Applications.
- `Reclaim.zip`: the same signed and stapled app.
- `SHA256SUMS.txt`: checksums for both archives and the update feed.
- `appcast.xml`: signed Sparkle feed pointing at the version-specific ZIP URL.

The stable DMG URL is
`https://github.com/torbensko/reclaim/releases/latest/download/Reclaim.dmg`.
The README and website's `torbensko-site/src/content/projects/reclaim.md` use this
URL, so subsequent releases need no link changes. Enable public download links
only after the signed assets are verified; never present an unsigned preview as
a notarized release.

## Validation and subsequent versions

Every push to `main` and pull request runs **Test and package**. It needs no
signing secrets and retains clearly named unsigned preview archives as workflow
artifacts, never as public release downloads. Tests use mocks and generated
fixtures rather than deleting the user's data or installing a cleanup job.

Before a release, update `VERSION` and `RELEASE_NOTES.md`. The build script writes
the version and workflow run number into the packaged app. Both the main app and
the worker contain `arm64` and `x86_64`; packaging verifies both architectures.
Interactive verification is currently on Apple Silicon with macOS 27. Intel and
older supported systems still need hands-on validation.

Local checks:

```sh
swift test
./scripts/package.sh --unsigned
./Tests/Packaging/test-appcast.sh
```

For a local signed release, provide `SIGNING_IDENTITY` (the full Developer ID
Application identity) and the three Apple notarization variables through your
environment, then run `./scripts/package.sh`. Certificate import is for an
ephemeral GitHub runner only. The workflow deletes its temporary signing keychain
even if the build or notarization fails.

Keep the existing bundle ID, `local.timemachinexray.app`, to preserve the installed
app's identity. Retain the actual build SDK metadata separately from its macOS 14
minimum target so newer systems use their current native control appearance.

## Development and production

Build and run `dist/Reclaim Dev.app` locally. Development and CI preview builds
use `local.timemachinexray.app.dev`, display their channel and build provenance,
and never start Sparkle. They do not replace `/Applications/Reclaim.app`.
The production app keeps its original identifier. Use the actual published
download when testing the production installation, rather than rebuilding it
locally. The optional installer accepts only signed, notarized production apps
and backs up the installed copy. The development menu opens the installed app.

Do not use local build numbers to order public releases. `CFBundleVersion` in
releases comes from this release workflow's monotonically increasing run number;
Sparkle compares that field. If the workflow is replaced or its numbering resets,
choose a `BUILD_NUMBER` higher than every published release before publishing.
`VERSION` is the human-readable version; increment it and update the release notes
for every release. Published versions and archives are immutable.

## Sparkle updates

Sparkle 2.10.0 is pinned in `Package.swift` and `Package.resolved`. Packaging copies
the framework with its symlinks and signs its nested services, updater and library
before signing Reclaim. `SUPublicEDKey`, the stable feed URL, signature verification
and automatic checks are stamped into release bundles only. Automatic installation
is off by default; the user chooses when to install. The app offers a menu toggle
for checks and waits for active storage work before a requested restart.

The update feed is a release asset at:

`https://github.com/torbensko/reclaim/releases/latest/download/appcast.xml`

After notarization, `scripts/generate-appcast.sh` signs the feed and exact final
ZIP. Its enclosure uses `/releases/download/v<VERSION>/Reclaim.zip`, never a moving
latest URL. It embeds release notes, verifies the feed signature, verifies the ZIP
against the public key shipped in the app, checks the version and macOS minimum,
and includes the feed in `SHA256SUMS.txt`. All assets upload to a draft together;
only then is the release published as latest. The current feed has one full update
for macOS 14 and later. Revisit feed history before dropping an older supported OS.

Keep the update key in the login Keychain under account
`local.timemachinexray.app`. `scripts/configure-updates.sh` can transfer that key
directly into the repository's `SPARKLE_PRIVATE_KEY` Actions secret after checking
that its public key matches the committed file. The temporary export is private
and removed afterward. Never print, commit or upload the private key as an artifact.
Back up the signing key securely; do not regenerate it for subsequent releases.

CI tests packaging with temporary keys and copies of the development app. It
checks valid archives, wrong keys, modified archives and modified feeds, without
installing an update or using production secrets. The first Sparkle-enabled
release must be installed manually once; v1.1.0 has no updater to bootstrap it.

For a local signed release, provide `SPARKLE_PRIVATE_KEY` through a secret
environment along with the signing/notarization credentials and an appropriate
`BUILD_NUMBER`, then run `scripts/generate-appcast.sh` after `scripts/package.sh`.
Do not publish a ZIP that differs from the signed feed's archive.

References: [Sparkle setup](https://sparkle-project.org/documentation/),
[SwiftUI integration](https://sparkle-project.org/documentation/programmatic-setup/),
[publishing updates](https://sparkle-project.org/documentation/publishing/),
[manual framework signing](https://sparkle-project.org/documentation/sandboxing/#code-signing).
