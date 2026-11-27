# Security

Use GitHub's [private vulnerability reporting](https://github.com/dong4j/lane/security/advisories/new) for security issues in the current `main` branch or its CI builds. Include the Lane version or commit, macOS version, affected feature, and enough detail to reproduce the issue in a test environment.

Replace any SSH keys, passwords, pairing files, and sensitive routes in your report with sample data. Use regular [GitHub issues](https://github.com/dong4j/lane/issues) for feature requests and non-security bugs.

Each Agent pairing is private to a macOS account. A process that can read a pairing file can use that pairing. If you suspect a file was exposed, revoke it in **Settings → Agent Access** and create a new pairing for the client.
