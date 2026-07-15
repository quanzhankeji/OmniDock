# Contributing to OmniDock

Thank you for helping improve OmniDock. Contributions should preserve the project's focused macOS behavior, privacy guarantees, and compatibility requirements.

## Before Starting

- Search existing issues before opening a new one.
- Discuss broad behavior changes before investing in a large implementation.
- Keep changes narrowly scoped and avoid application-specific branches.
- Do not add third-party packages without prior maintainer approval.
- Do not submit credentials, signing identities, private paths, account data, or licensed material that cannot be redistributed.
- Report potential vulnerabilities through [SECURITY.md](SECURITY.md), not through a public issue or pull request.

Bug reports, feature ideas, and other non-code feedback do not require a Contributor License Agreement.

## Contributor License Agreement

Code and documentation contributions are accepted only under [CLA.md](CLA.md). Contributors retain ownership of their work while granting the Project Owner the rights needed to distribute OmniDock under GPL v3 and separate official binary licenses.

A pull request must include an affirmative CLA acceptance using the repository pull request template. If You contribute on behalf of an employer or another organization, confirm that You have authority to accept the CLA for that entity.

Maintainers must not merge a copyrightable Contribution until the CLA checkbox is affirmatively recorded in that pull request.

## Development

Review [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) before changing Dock interception, window control, previews, permissions, or global shortcuts. Preserve stored preference compatibility and macOS 12.3 support.

Run at least:

```bash
swift test -Xswiftc -warnings-as-errors
./script/generate_xcode_project.py --check
git diff --check
```

Run `./script/build_and_run.sh --verify` for changes that affect application assembly or resources. Describe relevant manual macOS testing in the pull request.

## Pull Requests

A pull request should:

- Explain the user-visible behavior and why the change is needed.
- Include focused tests for policy or state changes.
- Avoid unrelated formatting or metadata churn.
- Use neutral sample application names in tests and documentation.
- Update public documentation when behavior, permissions, privacy, or distribution changes.
- Identify every third-party source fragment, asset, and license.

The Project Owner may decline a Contribution even when it satisfies these requirements.

## License and Branding

Accepted public source is made available under `GPL-3.0-only`. The contributor grant also permits separate official binary licensing as described in [LICENSING.md](LICENSING.md).

The source license does not grant rights to the OmniDock name, logo, or app icon. Forks and redistributed builds must follow [TRADEMARKS.md](TRADEMARKS.md).
