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
- `SHA256SUMS.txt`: checksums for both archives.

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
```

For a local signed release, provide `SIGNING_IDENTITY` (the full Developer ID
Application identity) and the three Apple notarization variables through your
environment, then run `./scripts/package.sh`. Certificate import is for an
ephemeral GitHub runner only. The workflow deletes its temporary signing keychain
even if the build or notarization fails.

Keep the existing bundle ID, `local.timemachinexray.app`, to preserve the installed
app's identity. Retain the actual build SDK metadata separately from its macOS 14
minimum target so newer systems use their current native control appearance.
