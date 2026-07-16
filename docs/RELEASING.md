# Releasing OmniDock

This document describes the maintainer release paths without embedding signing identities, account details, credentials, or machine-specific paths.

## Preflight

Release work starts from a clean Git worktree. Run the tests and verify that the checked-in Xcode project matches the generator:

```bash
swift test -Xswiftc -warnings-as-errors
./script/generate_xcode_project.py --check
```

The generated Xcode project intentionally does not contain a development team. Contributors who need a signed Xcode build select their own team locally in Xcode. Do not commit account-specific signing changes.

The repository source is licensed under `GPL-3.0-only`. An official GitHub binary may use the same GPL terms, while other company binaries may use separate end-user terms under the dual-licensing model in `LICENSING.md`. Never treat the repository `LICENSE` file as the EULA for a separately licensed binary.

For an unsigned Universal build, use the shared `OmniDock` scheme with signing disabled and both `arm64` and `x86_64` architectures enabled. Verify the executable with `lipo` and confirm that the asset catalog, privacy manifest, and English and Simplified Chinese localizations are present in the app bundle.

## Developer ID Distribution

The direct-distribution script requires a Developer ID Application identity with its private key and a working `notarytool` Keychain profile. Keep those assets outside the repository.

```bash
./script/release.sh \
  --version <marketing-version> \
  --build <build-number> \
  --license-mode gpl \
  --notary-profile <keychain-profile>
```

GPL mode installs the repository license as `COPYING.txt` and records both the source and binary license as `GPL-3.0-only` in the private release manifest.

For a separately licensed Developer ID release, use `--license-mode eula --binary-license </secure/path/to/approved-eula.txt>`. The EULA must be an approved, nonempty file stored outside the source repository. The script refuses the GPL source license as a substitute, records the EULA digest without recording its private path, and installs the EULA as `EULA.txt`.

The script refuses a dirty worktree, builds a Universal 2 executable, creates and validates its dSYM, signs the app with the hardened runtime and a secure timestamp, submits the app for notarization, staples the accepted ticket, and verifies Gatekeeper assessment. It then creates, signs, notarizes, and staples a DMG.

Each release is split into two output directories:

- `public/` contains only `OmniDock-<version>.dmg` and `OmniDock-<version>.zip`. These are the binary assets uploaded to GitHub Releases.
- `private/` contains the dSYM, release manifest, and SHA-256 records. Retain these for diagnostics and release traceability; do not upload them as public Release assets.

GitHub automatically adds source ZIP and TAR.GZ archives for the release tag. They do not need to be generated or uploaded by the release script.

Notarization can occasionally outlast the local wait period. The service continues processing after a timeout. Resume that exact release from the same source commit, version, build, license mode, and signing identity without uploading a duplicate:

```bash
./script/release.sh \
  --version <marketing-version> \
  --build <build-number> \
  --license-mode gpl \
  --notary-profile <keychain-profile> \
  --notary-submission-id <submission-uuid>
```

The script verifies that the existing submission's archive name matches the rebuilt candidate before waiting and stapling. Use `--notary-timeout <duration>` to override the default two-hour wait. If the rebuilt signature does not match the accepted ticket, stapling fails and the script stops rather than silently creating another submission.

If DMG notarization times out independently, resume it with `--dmg-notary-submission-id <submission-uuid>`.

The script does not publish a release, upload source, or modify Git history.

## Xcode Archives

Regenerate the project before opening it in Xcode:

```bash
./script/generate_xcode_project.py
```

Select a local development team, review the bundle identifier, version, build number, entitlements, and archive destination, then use Xcode's standard archive validation flow. Signing and upload credentials must be supplied locally and must never be added to the project generator or committed files.

An App Store binary is governed by the EULA presented by the App Store, normally [Apple's Standard EULA](https://www.apple.com/legal/macapps/stdeula/) unless an approved custom EULA is configured. Confirm that the selected EULA and App Store metadata describe the dual-licensed distribution accurately before submission.

The Xcode archive target is an App Sandbox build and compiles with the `APP_STORE` condition. It intentionally disables cross-domain system-shortcut preference reads. The full OmniDock feature set relies on cross-application Accessibility control, so a successful unsigned build does not prove that the signed sandbox distribution works. Test the exact App Store or TestFlight package on a clean Mac before making availability claims; use the notarized Developer ID path for the complete feature set when sandbox restrictions prevent those controls.

The direct-distribution build also reads the Accessibility attribute `AXWindowNumber` when available so that windows with identical titles and frames can still be focused precisely. This attribute is not part of the documented Accessibility constants, may be absent on some applications or future macOS releases, and is treated only as an optional compatibility aid. Its use must not be presented as evidence that the App Store build is compliant or that every application exposes a stable window identifier.
