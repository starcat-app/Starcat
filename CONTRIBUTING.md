# Contributing

Thank you for contributing to Starcat, a native macOS GitHub Star manager.

## Before opening a pull request

- Discuss large behavior or architecture changes in an issue first.
- Keep each pull request focused.
- Add or update tests for behavior changes.
- Do not commit credentials, `Configs/Secrets.xcconfig`, `.env` files, Sparkle private
  keys, certificates, generated binaries, or local databases.
- Do not run packaging, notarization, or App Store upload scripts unless a maintainer
  asks you to.
- Security vulnerabilities must be reported privately according to [SECURITY.md](./SECURITY.md).

## Local setup

1. Install Xcode 26 or later on macOS 15+.
2. Clone this repository and work from the `dev` branch.
3. Copy `Configs/Secrets.xcconfig.template` to `Configs/Secrets.xcconfig`. Leave secrets
   empty unless you are running against your own backends.
4. Create your own GitHub OAuth App (enable Device Flow) for local sign-in. Do not put
   production client secrets into the tree. The Client ID in source is a public identifier
   for official builds.
5. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen), then generate the project:

```bash
xcodegen generate
```

6. Open `Starcat.xcodeproj`, select your Development Team, and run the Starcat scheme.

After adding or deleting Swift files, run `xcodegen generate` again before building.

## Tests

Close Xcode (or run tests only inside Xcode). Do not run command-line tests and the Xcode
IDE against the same `testmanagerd` at the same time.

```bash
xcodegen generate
xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' test
```

Run a single suite when iterating:

```bash
xcodebuild -scheme Starcat -destination 'platform=macOS,arch=arm64' \
  -only-testing:StarcatTests/TagRepositoryTests test
```

Any start-up path that talks to Keychain or system authorization dialogs must be gated with
`TestEnvironment.isRunning`, or command-line tests will hang.

## Project conventions

- Commit messages: [`docs/5-规范/Git-提交规范.md`](docs/5-规范/Git-提交规范.md)
  (`<type>(<scope>): <Chinese summary>`).
- User-visible strings: [`docs/5-规范/国际化-规范.md`](docs/5-规范/国际化-规范.md). Use
  `String.l10n` / `Text("key")`; do not add `String(localized:)` or `NSLocalizedString`.
- UI: [`DESIGN.md`](DESIGN.md) and `docs/5-规范/`. Buttons using `.buttonStyle(.plain)`
  must call `.focusEffectDisabled()`.
- Third-party code or assets: register them in `Starcat/Features/About/AboutView.swift`
  (`AboutDependency.all`) per [`docs/5-规范/开源致谢同步-规范.md`](docs/5-规范/开源致谢同步-规范.md).
- Published database schema changes need a new `registerVN` migration. Do not edit the
  shipped `v1-initial` schema and do not ask users to delete their local database.

Changelog files are maintainer-owned. Do not edit `CHANGELOG.md` unless a maintainer asks.

## Pull requests

Complete the repository pull request template, explain the user-visible effect, and include
the commands and results used for verification. Update both `README.md` and `README-ZH.md`
when public contributor-facing behavior changes.
