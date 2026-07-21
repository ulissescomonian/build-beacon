# Contributing to Build Beacon

Thanks for helping improve Build Beacon. Contributions should preserve its native macOS experience, privacy posture, and read-only Bitbucket monitoring model.

## Prerequisites

- macOS 14 or later.
- Swift 6.2 or a compatible Xcode toolchain.
- A GitHub account to fork the repository and open a pull request.

## Development flow

1. Fork the repository and create a focused branch from the current default branch.
2. Make a small, reviewable change with tests where behavior changes.
3. Run the test suite:

   ```sh
   swift test
   ```

4. Build the app:

   ```sh
   swift build
   ```

5. Open a pull request describing the user-visible behavior, validation performed, and any relevant trade-offs.

Do not commit generated build products, credentials, tokens, Keychain content, local configuration, screenshots containing private data, or machine-specific paths.

## Architecture boundaries

Keep concerns separated:

- `BuildBeaconKit` owns domain models, Bitbucket API access, token storage abstractions, and monitoring logic.
- `BuildBeaconUI` owns SwiftUI presentation, app state, accessibility, and localized user-facing messages.
- Tests should exercise behavior through fixtures and fakes rather than live Bitbucket accounts.

Avoid coupling view code directly to network transport or Keychain implementation details. Preserve native AppKit/SwiftUI integration and favor small, explicit interfaces at module boundaries.

## Privacy and lifecycle rules

Treat account changes, monitor removal, disconnect, and application relaunch as privacy boundaries. New local state must be scoped to the relevant account or monitor, bounded by retention and size limits, removable by the user, and cleared when its owner is removed. Persist only the minimum data needed for the feature.

Configuration, notification-ledger, history, backup, and quarantine files are local application-support data. They must be written atomically with user-only filesystem permissions. Migration code must reject unknown future schemas without overwriting them, and must preserve a recoverable backup before a destructive migration.

Notifications may be visible on a lock screen. Keep their content minimal, route them only through validated local identifiers, and preserve the user's notification controls. Do not serialize tokens, raw API payloads, URLs with sensitive query values, or unnecessary account metadata into notification payloads or local records.

All network work must remain ephemeral and privacy-preserving: no cookies, persistent URL caches, shared credential storage, telemetry, or live-account fixtures. Keep authorization headers transient and redacted from every log and diagnostic path.

External links must use the approved HTTPS Bitbucket web destination. Build links locally where possible; otherwise validate scheme, host, credentials, port, and path before opening them. Never turn API-provided URLs into arbitrary browser navigation.

## Product invariants

- Bitbucket access is read-only. Do not add code that creates, updates, deletes, or otherwise mutates remote Bitbucket resources.
- Use only the minimum permissions required for account, workspace, repository, and pipeline observation.
- Pull request context is optional and must use only a read-only pull request permission when it is required.
- Never log, render, persist, or include credentials in diagnostics.
- Use synthetic fixtures only. Fixtures, tests, examples, and screenshots must not contain real account, workspace, repository, pipeline, or token data.

## Localization and accessibility

User-facing strings must be available in English and Brazilian Portuguese (`pt-BR`). Keep terminology, placeholders, and error guidance equivalent across both languages. New controls must remain understandable with VoiceOver and should use native accessibility labels where needed.

## Tests and quality

Add or update tests for new behavior, failure handling, and regressions. Keep tests deterministic and offline. Before opening a pull request, run `swift test` and `swift build`; mention any validation that could not be run and why.

## Pull request checklist

- [ ] The change has a focused purpose and clear description.
- [ ] Tests cover changed behavior or explain why no test is needed.
- [ ] `swift test` and `swift build` pass locally.
- [ ] English and `pt-BR` strings are updated together when applicable.
- [ ] The read-only Bitbucket invariant is preserved.
- [ ] New persistence has an explicit retention, removal, migration, and filesystem-permission strategy.
- [ ] Notification content and routes do not expose unnecessary private data or bypass user controls.
- [ ] External links are locally constructed or pass the safe-link allowlist.
- [ ] No generated artifacts, secrets, credentials, private data, or machine-specific paths are included.
- [ ] Documentation reflects material behavior or security changes.

## Respectful collaboration

Be constructive, professional, and considerate in issues, reviews, and pull requests. Focus feedback on the work, assume good intent, and help keep the project welcoming for contributors with different backgrounds and experience levels.
