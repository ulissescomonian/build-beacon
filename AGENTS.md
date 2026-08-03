# Build Beacon contributor guide

Build Beacon is a native macOS application for Bitbucket pipeline monitoring
that remains read-only by default. Keep every change focused on a polished,
reliable macOS experience;
do not introduce a web shell, a cross-platform runtime, or a UI implementation
that bypasses AppKit/SwiftUI conventions.

## Project shape

- Deployment target: macOS 14 or later; Swift 6 language mode.
- `Sources/BuildBeaconApp`: executable composition root, app lifecycle, system
  integrations, menu bar, notifications, the single-dashboard coordinator, and
  Dock activation policy.
- `Sources/BuildBeaconKit`: domain models, use cases, API clients, persistence,
  scheduling, and other framework-independent application logic.
- `Sources/BuildBeaconUI`: SwiftUI presentation, resources, localization, and
  accessible interaction design. It depends on `BuildBeaconKit`, never the
  reverse.
- `Tests/BuildBeaconKitTests` and `Tests/BuildBeaconUITests`: deterministic unit
  and presentation tests. Add or update tests with every behavior change. The
  current baseline is 170 executed tests; update public counts after legitimate
  additions or removals, and never delete coverage merely to hide a failure.

Keep boundaries explicit. New network, persistence, clock, notification, or
system behavior belongs behind a protocol and is injected into use cases or
view models. Avoid global mutable state, UI code in `BuildBeaconKit`, and
network access directly from SwiftUI views.

## Everyday validation

Run the narrowest relevant test first, then the full gate before handoff:

```sh
swift test --quiet
swift build -c release
git diff --check
```

Build the distributable universal app and DMG with the repository scripts:

```sh
env SIGNING_IDENTITY=- ./scripts/build_app.sh
./scripts/package_dmg.sh
```

The release bundle must include both `arm64` and `x86_64`, pass
`codesign --verify --deep --strict`, and have a matching SHA-256 sidecar. A
Preview release is ad-hoc signed and is not a substitute for Developer ID
signing or notarization. Never commit `dist/`, `.build/`, generated archives,
or machine-specific signing configuration unless a release workflow explicitly
tracks an artifact outside Git.

## Product and UI rules

- Prefer native SwiftUI controls and macOS interaction patterns. Respect
  Dynamic Type where available, keyboard navigation, focus, VoiceOver labels,
  values, hints, and reduced-motion/accessibility settings.
- Keep dashboard states legible: healthy, failed, running, approval required,
  unavailable, and no-data must remain visually and semantically distinct.
- Treat refresh as asynchronous. Do not block the main actor, discard a newer
  result with an older one, or make polling depend on an open window.
- Make filtering, sorting, favorites, selection, and timeline state stable
  across refreshes. Clear an invalid selection safely when its item disappears.
- Route every dashboard request through one open-or-focus coordinator. Repeated
  requests must never create duplicate windows; restoring an existing window
  must follow normal macOS activation rules rather than keeping it always on
  top. Use the Dock only while the dashboard is open or minimized, return to
  menu-bar-only behavior after close, and keep the Dock app icon distinct from
  the menu-bar status symbol.
- Preserve the silent, persistent semantics of unseen activity: markers must
  survive ordinary refreshes and relaunches, clear only through an explicit
  acknowledgement route, and never turn a polling observation into a claim of
  real-time delivery.
- Every user-visible string must be localized in both English (`en`) and
  Brazilian Portuguese (`pt-BR`). Add keys and translations together; do not
  assemble localized sentences from fragments.

## Security, privacy, and data handling

- Build Beacon monitoring is read-only by default. The only approved remote
  mutation is the isolated, foreground-only, per-monitor opt-in `Approve and
  merge` flow for an open, non-draft pull request whose current source HEAD is
  the commit of a succeeded monitored build. It uses a second Keychain token
  with exactly `read:user:bitbucket`, `read:pullrequest:bitbucket` and
  `write:pullrequest:bitbucket`; identity is validated before any mutation.
  Action Mode also requires `read:pullrequest:bitbucket` on the read-only
  monitoring token. Two fresh remote preflights validate the exact pipeline via
  the monitoring credential and PR/HEAD via the action credential, one before
  each POST. Every action requires explicit confirmation, publishes its real
  progress, and closes every post-mutation ambiguity as `unknown`, without
  retry. It never runs from polling, background work, notifications or deep
  links. Never add another write action, automerge,
  repository administration or Git credential behavior without a new explicit
  product decision recorded in documentation.
- Use HTTPS for remote requests, validate server responses defensively, honor
  rate limits and retry guidance, and avoid exposing tokens or raw API errors in
  the UI, logs, notifications, tests, or crash reports.
- Store account tokens only in the macOS login Keychain. Persist only the
  minimum user-approved local monitoring/history data, with restrictive file
  permissions and atomic writes. Do not persist secrets, credentials, commit
  content, or unneeded personal data.
- Preserve existing user configuration and history across migrations. Use
  versioned, reversible migration behavior, backups/quarantine for invalid
  input, and explicit confirmation before destructive actions such as clearing
  local history or disconnecting an account.
- Notifications must contain only the minimum routing and presentation data
  needed to open the related monitor. Handle notification permissions and
  System Settings navigation through public macOS APIs.

## Documentation and governance

Before implementing a material behavior, security, data-model, or architecture
decision, record the rationale and alternatives in `docs/discussion.md`. Keep
the actionable scope, acceptance criteria, dependencies, and validation status
in `docs/planning.md`. Update both when the decision or implementation changes;
do not leave completed work described as pending.

Keep `README.md`, `SECURITY.md`, and `CONTRIBUTING.md` aligned with user-facing
capabilities, supported release/install flow, privacy guarantees, and current
validation expectations. Documentation is public-facing: it must not reveal
local paths, computer names, usernames, private signing identities, account
details, tokens, repository data, or any reference to external projects used
for research.

## Source-control hygiene

- Inspect `git status`, `git diff`, and `git diff --check` before committing.
- Keep commits intentional and reviewable; do not include IDE state, temporary
  files, build products, or credentials.
- Do not rewrite shared history, force-push, create releases, or upload assets
  unless the task explicitly authorizes it.
- Public source, release notes, assets, tests, documentation, and screenshots
  must be free of secrets and machine-specific information.
