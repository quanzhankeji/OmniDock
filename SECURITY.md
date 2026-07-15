# Security Policy

OmniDock interacts with macOS Accessibility, Input Monitoring, Screen Recording, global shortcuts, and application windows. Please report behavior that could expose window content, retain sensitive data unexpectedly, control the wrong application, or bypass an expected permission boundary as a security issue.

## Supported Versions

Security fixes are made against the current `main` branch and the latest official binary release, when one exists. Older source snapshots and unofficial builds may not receive security updates.

## Reporting a Vulnerability

Do not disclose vulnerability details in a public issue.

Use GitHub's private vulnerability reporting option in the repository Security tab when it is available. If that option is unavailable, open a public issue containing only a request for a private maintainer contact route. Do not include the vulnerability, proof of concept, screenshots, window titles, file paths, credentials, or personal information in that public request.

A useful private report includes:

- The affected OmniDock version or source commit.
- The macOS version and hardware architecture.
- The permissions granted to OmniDock when the behavior occurred.
- Reproduction steps and the expected security boundary.
- The practical impact and whether the issue is already public.
- Logs or images only after removing unrelated private content.

## Disclosure

Please allow maintainers a reasonable opportunity to reproduce and correct a confirmed vulnerability before publishing technical details. The project will coordinate disclosure timing for confirmed issues when practical.
