# Changelog

Notable changes to this project. Format follows [Keep a Changelog][kac]; this
project adheres to [Semantic Versioning][semver].

**What the version number covers:** the hook contract (`exit 0` allow / `2`
block / `1` non-blocking error) and the `guardrails.config.json` schema. Rule
*content* is illustrative and changes freely at any version — you are expected
to replace it. A schema or contract change requires a major bump.

## [Unreleased]

## [1.3.0] - 2026-09-12

### Added
- `install.sh` prunes hook entries that point at a guard this version no longer
  ships, and removes the orphaned file. A merge preserves whatever is already
  wired, which is right for your own hooks and wrong for one of ours that was
  renamed: upgrading left the stale entry pointing at the old file, still on
  disk, so the repo ran BOTH the old guard and its replacement. Retired names
  are listed explicitly, so a script you added yourself is never touched.
- A `config_sync` rule reminding you to add a changelog line when a
  user-visible surface changes. Scoped to guards, shipped config, wiring and
  the installer — not docs, tests or CI, where it would be noise.
- `install.sh` now ships `templates/CLAUDE.md.template` into the target's
  `.claude/`, and the closing instructions name it. It was
  referenced only from the README, so an installed repo never received the one
  document explaining which rules are worth writing.
- `git-safety` is now Python (`git-safety.py`, replacing `git-safety.sh`) so it
  can use `normalize()`. It matched the raw command, so any Bash call whose text
  merely contained a git command — a heredoc writing a fixture, a doc edit
  describing the hook — was blocked outright while on a protected branch.
- The protected-branch check now reads `git symbolic-ref`, not
  `rev-parse --abbrev-ref`. On an unborn HEAD (a fresh checkout with no commits)
  rev-parse fails, the branch read as empty, and the first commit landed on the
  protected branch unguarded.
- `verify-repo.sh` asserts that rules mirrored into the test fixtures have not
  drifted from the shipped config. A drifted mirror keeps the suite green while
  the rule users actually run is wrong.
- `blast_radius` rules can name an `exempt.predicate` from the registry in
  `_guardrails.py`, for carve-outs a regex cannot decide. The first one closes
  the bare `git checkout <path>` form: it is syntactically identical to
  `git checkout <branch>`, so the predicate asks git in git's own resolution
  order — a name resolving to a commit is a branch switch, a name that does not
  but exists on disk is a pathspec that overwrites the working tree.
- A `blast_radius` rule blocking commands that discard uncommitted work:
  pathspec checkout, `git restore` of the worktree, `git reset --hard`, forced
  checkout, and `git clean -f`. Unlike the rules around it this one is not
  illustrative — keep it. Branch switches, `-b`, `--staged`, `--soft` and `-n`
  are deliberately allowed, since none of them can lose work.
- Reinstalling now refreshes the template and slash commands while they still
  match what was installed, and keeps them once you have edited them. Provenance
  is recorded in `.claude/.guardrails-manifest`; a file of unknown origin is
  treated as edited and never overwritten. `guardrails.config.json` is
  deliberately excluded — it is yours from step 1 onward.
- The installer now says what `--force` costs: it replaces the config, template
  and commands outright, including the rules you deleted in step 1.
- A `config_sync` rule covering `templates/`. The installer copies it by name,
  so a new or renamed template ships nowhere and nothing fails — the shape that
  left the CLAUDE.md template unshipped for the project's whole history.
- A `Coupled surfaces` section in the template, mapping to `config_sync` rules.
  The template previously prompted only for `blast_radius`, leaving the
  works-locally/missing-in-production class of bug undocumented.

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
[Unreleased]: https://github.com/stephennmiller/claude-code-guardrails/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/stephennmiller/claude-code-guardrails/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/stephennmiller/claude-code-guardrails/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/stephennmiller/claude-code-guardrails/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/stephennmiller/claude-code-guardrails/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/stephennmiller/claude-code-guardrails/releases/tag/v1.0.0
