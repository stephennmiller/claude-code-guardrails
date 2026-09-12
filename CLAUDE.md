# CLAUDE.md

Claude Code hooks that make a CLAUDE.md's "don't run this" list executable.
Six guards plus a test harness for the guards themselves. No runtime
dependencies: `python3` 3.9+, `jq`, `bash` 3.2+.

## Layout

| Path | What |
|------|------|
| `.claude/hooks-scripts/` | The six guards. `_guardrails.py` is the shared engine. |
| `.claude/guardrails.config.json` | Every project-specific rule. Data, not code. |
| `.claude/hooks/test-hooks.sh` | 92 assertions, ~2s. |
| `.claude/hooks/fixtures/` | Config the tests run against, so they exercise the engine. |
| `.claude/settings.json` | Hook wiring, copied into the user's repo by `install.sh`. |
| `docs/PATTERNS.md` | Why each rule is shaped the way it is. Read before writing one. |
| `CONTRIBUTING.md` | What gates a merge, how to cut a release, what is pinned. |
| `.github/workflows/` | `test.yml` gates PRs. Its job names are load-bearing. |
| `templates/CLAUDE.md.template` | Shipped to users. Not this file. |

## Commands

```bash
bash .claude/hooks/test-hooks.sh      # the whole suite, ~2s
bash .claude/hooks/test-hooks.sh -v   # print hook output for failures
bash scripts/verify-repo.sh           # docs, config regexes, hook wiring
bash scripts/release-notes.sh 1.1.0    # the CHANGELOG section a tag would publish
./install.sh "$(mktemp -d)" --dry-run  # what an install would do
```

There is no build, no package manager, and no lockfile. If you reach for one,
stop and ask.

## The contract

Every hook obeys it. Breaking it is a breaking change.

```text
exit 0 = allow    exit 2 = block    exit 1 = internal error, NON-BLOCKING
```

A crashing hook must never wedge a tool call. `run()` in `_guardrails.py` wraps
every entry point to guarantee it.

## Rules, not suggestions

- **Add rules to `guardrails.config.json`, not to a script.** The scripts are
  the engine. If a rule seems to need code, the schema is probably missing
  something. Say so rather than special-casing it.
- **Every guard change needs an assertion in `test-hooks.sh`.** Hooks fail
  silently. A guard broken for a month looks exactly like a guard with nothing
  to report.
- **A user-visible change gets its changelog line in the same edit.** Under
  `## [Unreleased]` in `CHANGELOG.md`. A `config_sync` rule reminds you on
  guards, the shipped config, the wiring and the installer. Written at release
  time instead, it gets reconstructed from `git log`, and whatever missed a
  commit subject is gone.
- **Test the false positives too.** Half a guard's value is staying quiet on
  correct code. 51 of the 87 `expect` calls assert a guard says nothing.
- **No assertions inside subshells.** `( cd X; expect ... )` discards the
  counter increments, so a failing assertion prints in red and leaves the suite
  green. Set `RUN_DIR` instead.
- **Guards must work from a git worktree**, where cwd and the script's location
  differ. Resolve paths by repo markers, never by one absolute path.
- **Comments say why, not what.** A rule's comment should name what broke.
- No emoji. Python is stdlib only. Shell is bash with `set -uo pipefail`.

## Read before writing a rule

`docs/PATTERNS.md` §1-3. These are not obvious and they have all bitten:

1. A `Write|Edit` guard does nothing about `sed -i` via Bash. File-subject
   guards register under both matchers.
2. Grep the raw command and the guard fires on its own documentation. Strip
   heredoc bodies first, then quoted spans. That order is load-bearing.
3. An exemption that reads normalized text fails **open**. Exemptions only ever
   read text that cannot have been stripped.

## Known rough edges

- **`test-hooks.sh` builds two literals at runtime** (`NOVERIFY`,
  `RELEASE_SUBJECT`) so the file can be edited by agents whose own guards scan
  for those strings. Don't "simplify" them back into whole strings.
- **`install.sh` writes stdout through `say()`/`out()`** and sets `trap '' PIPE`.
  Piping it to `head` or `grep -q` closes the pipe, and a direct write would
  EPIPE and abort a successful install. Route new output through those helpers.
- **Two synthetic credentials live in `test-hooks.sh`** as fixtures. Secret
  scanners flag them. They are not real; dismiss rather than deleting the tests.
- **CI runs on macOS as well as Linux**, and under stock macOS bash 3.2. BSD and
  GNU userland differ on `sed -i`, `grep` and `awk`. The Python floor is 3.9
  (PEP 585 generics in annotations); the matrix enforces it.
- **Windows is not supported and not tested.** The Python guards are already
  portable (pathlib throughout, no POSIX-only calls), but ~1,020 lines of shell
  across 5 files are not, and it is unconfirmed whether Claude Code on native
  Windows invokes a shebang at all. Don't add the claim without a
  `windows-latest` job: a hook that silently no-ops is worse than no hook.

## Don't

- Don't add a dependency. There are none, and that is the point.
- Don't add style or vulnerability linting. A hook sees one diff hunk with no
  type information. That work belongs in a linter.
- Don't loosen a guard to make a test pass. Fix the guard or fix the test.
- Don't float a pinned version back to a tag. Actions are pinned to commit
  SHAs and shellcheck to a checksum, deliberately. `CONTRIBUTING.md` has the
  bump procedure.
- Don't rename a CI job casually. Branch protection matches on the check
  name, so a rename leaves the old name required and never reported, which
  blocks every PR.
- Don't edit `.claude/hooks/fixtures/` to make a failing assertion pass.
