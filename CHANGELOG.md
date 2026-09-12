# Changelog

Notable changes to this project. Format follows [Keep a Changelog][kac]; this
project adheres to [Semantic Versioning][semver].

**What the version number covers:** the hook contract (`exit 0` allow / `2`
block / `1` non-blocking error) and the `guardrails.config.json` schema. Rule
*content* is illustrative and changes freely at any version — you are expected
to replace it. A schema or contract change requires a major bump.

## [Unreleased]

Nothing yet.

## [1.1.0] - 2026-09-12

### Added
- `scripts/verify-repo.sh` — checks the things the hook harness cannot see:
  docs naming files that exist, every rule regex compiling, every guard wired
  to a matcher, and `blast-radius-guard` registered under both matchers.
- CI: repo self-checks, a Python 3.9-3.13 matrix, and the harness under stock
  macOS bash 3.2.
- CI: shellcheck pinned to a checksummed v0.11.0 release rather than apt, so a
  required check cannot redden on a runner-image bump.

### Changed
- The lint job is blocking. It previously carried both `continue-on-error` and
  a trailing `|| true`, so it was incapable of failing.
- Documented the actual version floors: Python 3.9 (PEP 585 generics) and
  bash 3.2.

## [1.0.0] - 2026-09-12

Initial public release.

### Added
- **`blast-radius-guard`** — blocks irreversible Bash commands, warns on edits
  to protected files. Two severities chosen by escape hatch: Bash can carry an
  `ALLOW_BLAST_RADIUS=1` override, an Edit envelope cannot.
- **`watch-mode-guard`** — blocks a test runner started in watch mode, which
  otherwise hangs the tool call until it times out. Handles the `npm run test
  --run` trap, where npm swallows the flag and forwards nothing.
- **`git-safety`** — blocks hook-bypass flags, commits to a protected branch,
  and force-push. Constrains the agent only; human contributors are unaffected.
- **`secret-scan-guard`** — blocks a credential written into a tracked file.
  Requires two independent signals (assignment shape *and* a value that looks
  real) before blocking.
- **`config-sync-guard`** — advisory reminders when one half of a coupled pair
  changes. Never blocks, because half the coupled surfaces live outside the repo.
- **`auto-format-code`** — formats after an edit so the model's view stays in
  sync with disk. Every formatter call is best-effort.
- **`test-hooks.sh`** — 67 assertions, ~2s, no network or project dependencies.
- Four slash commands: `/review-pr`, `/review-changes`, `/implement-spec`,
  `/validate-spec`.
- `install.sh` — idempotent, merges into an existing `settings.json` without
  clobbering hooks already configured there.
- `templates/CLAUDE.md.template` and `docs/PATTERNS.md`.
- CI: the hook harness runs on Linux and macOS, plus a mutation check that
  asserts the harness fails when a guard is deliberately broken, and an
  end-to-end `install.sh` run against a scratch repo.
- `CONTRIBUTING.md` and this changelog.

### Fixed
- `install.sh` no longer fails when its output is piped to a consumer that
  exits early (`head`, `grep -q`). Those close the pipe, and the next write
  raised EPIPE which `set -e` turned into a failed install — non-deterministically,
  since it depended on whether the installer had finished writing. Caught by CI
  on the first run.

[kac]: https://keepachangelog.com/en/1.1.0/
[semver]: https://semver.org/spec/v2.0.0.html
[Unreleased]: https://github.com/stephennmiller/claude-code-guardrails/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/stephennmiller/claude-code-guardrails/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/stephennmiller/claude-code-guardrails/releases/tag/v1.0.0
