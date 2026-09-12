# Changelog

Notable changes to this project. Format follows [Keep a Changelog][kac]; this
project adheres to [Semantic Versioning][semver].

**What the version number covers:** the hook contract (`exit 0` allow / `2`
block / `1` non-blocking error) and the `guardrails.config.json` schema. Rule
*content* is illustrative and changes freely at any version — you are expected
to replace it. A schema or contract change requires a major bump.

## [Unreleased]

### Added
- A `config_sync` rule reminding you to add a changelog line when a
  user-visible surface changes. Scoped to guards, shipped config, wiring and
  the installer — not docs, tests or CI, where it would be noise.

## [1.2.1] - 2026-09-12

No change to the guards, the hook contract, or the config schema. Supply-chain
hardening and documentation of what was already true.

### Changed
- Actions are pinned to commit SHAs (`actions/checkout` v4.4.0,
  `actions/setup-python` v5.6.0) with the tag in a trailing comment. A floating
  `@v4` resolves to whatever that mutable tag points at today.
- The repository runs GitHub-owned actions only. Pinning protects the actions
  in use; this protects against the ones that are not.
- `release.yml` declares `contents: write` on the job rather than at the top
  level, where every job in the file would inherit it.
- Stated the tested platforms. Linux and macOS are covered by CI; Windows is
  untested, and the README says so rather than implying portability.

### Added
- `CONTRIBUTING.md` records which five checks gate a merge, and warns that
  renaming a job leaves the old name required and never reported — which blocks
  every PR with no obvious cause.
- `CONTRIBUTING.md` documents how to bump the three pinned third-party
  versions (two actions and shellcheck).

## [1.2.0] - 2026-09-12

### Added
- `.github/workflows/release.yml` — pushing a `vX.Y.Z` tag re-runs the suite
  against the tagged tree, lifts the notes out of this file, and publishes.
  Refuses a tag with no changelog section, and never edits an existing release.
- `scripts/release-notes.sh` — prints the section a tag would publish. Run it
  before tagging.
- `settings.json` ships a small `permissions.deny` list, and `install.sh` now
  merges it as a union. Hooks are speed bumps with overrides; deny is a wall.
- Two rules drawn from real failures: a reminder that CI workflows and branch
  protection are coupled, and an advisory on `continue-on-error: true` or a
  trailing `|| true`, which make a step incapable of failing.

### Fixed
- `install.sh` copied the shipped `permissions` block into the target repo but
  never merged it into `settings.json`, so the deny rules were present on disk
  and enforcing nothing.

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
[Unreleased]: https://github.com/stephennmiller/claude-code-guardrails/compare/v1.2.1...HEAD
[1.2.1]: https://github.com/stephennmiller/claude-code-guardrails/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/stephennmiller/claude-code-guardrails/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/stephennmiller/claude-code-guardrails/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/stephennmiller/claude-code-guardrails/releases/tag/v1.0.0
