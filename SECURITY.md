# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| 1.0.x Preview | Yes |
| Earlier versions | No |

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting flow for this repository:

1. Open the repository's **Security** tab.
2. Select **Report a vulnerability**.
3. Provide a minimal, reproducible description and the security impact.

Do not open a public issue for a suspected vulnerability. Do not send reports by email.

Never include any of the following in a report:

- API tokens, passwords, cookies, or authorization headers.
- Keychain exports, dumps, or screenshots.
- Real API responses, request payloads, or logs that can identify an account, workspace, repository, or pipeline.

Replace sensitive values with clearly marked placeholders. A synthetic reproduction is preferred.

## Security scope

Build Beacon is a native macOS app that observes Bitbucket pipeline information. The product boundary is read-only: it must not create, modify, or delete Bitbucket resources. Security reports are especially useful for issues involving:

- Authentication, token handling, or Keychain access.
- Data exposure through logs, alerts, diagnostics, or user interface state.
- Authorization or scope validation failures.
- Network transport, response parsing, or persistence of sensitive data.
- Privacy regressions affecting account, workspace, repository, or pipeline metadata.

The app is designed to keep credentials in the macOS Keychain and to minimize the collection and retention of remote data. Treat any behavior that weakens those expectations as security-relevant.

## Local data and notifications

Build Beacon stores the API token only in the macOS Keychain. Its local application-support data is limited to non-secret configuration, a notification deduplication ledger, and—when the user enables it—bounded pipeline history. These files are retained only as long as needed for their feature, use user-only filesystem permissions, and are written atomically. History and ledger records contain only the minimum identifiers, state transitions, and timestamps needed for local behavior; they do not contain API payloads, commit text, branches, steps, headers, or credentials.

Notification and history retention are bounded. Removing a monitor or disconnecting an account removes related local records and pending notifications. Changes to schemas or corrupted files must preserve recoverability: migration code must not silently overwrite unknown future data, and backups or quarantined files must receive the same restrictive permissions as their source data.

Notifications can reveal pipeline context such as a repository or build state on the lock screen, according to the user's notification and macOS preview settings. Users control whether notifications and local history are enabled. A report involving unexpected notification content, lock-screen disclosure, stale notifications after account changes, or records that cannot be cleared is security-relevant.

## Network access and links

Network access is limited to the read-only Bitbucket API contract. Requests use TLS and an ephemeral session configuration; cookies, credential storage, and persistent URL caching are not used. Authorization is created only for the request and must never be recorded in logs, diagnostics, or local files.

Links opened by the app must be constructed or validated locally. External links are restricted to HTTPS and the approved Bitbucket web host, without embedded credentials or unexpected ports. A link that can bypass this allowlist, leak data in a query string, or open an arbitrary destination should be reported privately.

## Permissions and future scope

The required token permissions are read-only. Pull request context is optional and, if enabled, must use only the additional read-only pull request permission. Build Beacon must not add remote write actions, including through notifications, deep links, or background tasks. Any proposal to expand privileges or introduce a remote mutation requires a new threat model, explicit product approval, and a coordinated security review before implementation.

## What happens next

Reports are reviewed on a best-effort basis; no response or remediation SLA is offered for this preview release. We may ask for clarification or a sanitized proof of concept through the private report.

Please allow time for investigation and a coordinated fix before public disclosure. If a vulnerability is confirmed, we will coordinate disclosure timing and acknowledge the reporter when appropriate and with their permission.

Do not publish proof-of-concept code, screenshots, or technical details until the coordinated disclosure process is complete. If you believe a report is being actively exploited, state that in the private report along with the impact and any safe containment steps.
