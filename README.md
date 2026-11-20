# Cookie iOS

Native SwiftUI email client for Cookie. See `AGENTS.md` for working rules and
`docs/superpowers/specs/` for design specs.

## Requirements

- Xcode 27.0 (build 27A266a)
- XcodeGen 2.48.0 and SwiftLint 0.65.1 (`brew install xcodegen swiftlint`)

Pinned versions live in `scripts/toolchain.env`.

## Commands

```sh
xcodegen generate     # create Cookie.xcodeproj from project.yml
scripts/format.sh     # format every first-party Swift file
scripts/lint.sh       # strict swift-format and SwiftLint checks
```

Regenerate the project after adding, moving or removing files. Tests run in
GitHub Actions, not locally.

## Regression coverage

The shared `Cookie` test plan includes Swift Testing unit tests and XCUITest
navigation, reply, authentication-state, error-recovery, and large-text checks.
GitHub Actions runs both targets. Automated tests must not be run locally.

UI tests launch Debug builds with `-ui-testing` and synthetic in-process
responses. `-ui-testing-signed-in` starts that fixture signed in, and
`-ui-testing-empty-today` exercises empty triage recovery. The fixture uses
isolated credential and logout state and never contacts production services;
Release builds do not include this entry point.

## Reader and session behavior

Unread rows, sidebar counts, and AI Today update after a successful mark-read
request. A failed read mutation is retryable and does not delay body display.
AI Today reuses downloaded bodies and can resolve sender metadata through
existing paginated mailbox routes when a bounded thread omits the message.

The HTML reader keeps JavaScript disabled and remote content blocked until the
user chooses Show images. Its reading size follows Dynamic Type. Reply sending
retains a fixed submitted payload for retries and preserves subsequent edits.
Outgoing replies use the original recipient; missing recipients cannot be sent.

Logout immediately removes the signed-in UI and blocks token access. Credential
operations are serialized so a pending renewal cannot restore credentials after
logout. A nonsecret, app-local preference records incomplete credential removal
for the next launch; credentials remain exclusively in Keychain. The privacy
manifest declares this app-local UserDefaults use under Apple's
[CA92.1 reason](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
