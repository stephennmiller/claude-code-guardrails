# claude-code-guardrails

**Enforce your CLAUDE.md instead of just writing it.**

Most CLAUDE.md files contain some version of "don't run this without asking."
The agent reads it, agrees, and runs it anyway three hours later — not from
malice, but because that line is 200 lines up in a context window that has since
filled with other things.

This is a small set of Claude Code hooks that make those lines executable, plus
a test harness so you can tell whether they still work.

It is not a skills collection. There are good ones already.

```
.claude/
  guardrails.config.json    <- every project-specific rule lives here
  settings.json             <- hook wiring
  hooks-scripts/            <- the engine (6 guards, ~950 lines)
  hooks/test-hooks.sh       <- 67 assertions, ~2s, no deps
  commands/                 <- 4 slash commands
templates/CLAUDE.md.template
docs/PATTERNS.md            <- why each rule is shaped the way it is
```

## The guards

| Guard | Event | Severity | What it stops |
|---|---|---|---|
| `blast-radius-guard.py` | Bash + Edit | **block** / warn | Irreversible commands: overwriting generated files, writing a remote DB, re-baselining snapshots, moving a ratchet |
| `watch-mode-guard.py` | Bash | **block** | A test runner started in watch mode, which hangs the tool call until it times out |
| `git-safety.sh` | Bash | **block** | Hook-bypass flags, commits to a protected branch, force-push |
| `secret-scan-guard.py` | Edit | **block** | A real-looking credential written into a tracked file |
| `config-sync-guard.py` | Edit | advisory | Changing one half of a coupled pair (CSP + the code that fetches; env schema + the platform's env vars) |
| `auto-format-code.sh` | PostToolUse | — | Formats after an edit, so the model's view stays in sync with disk |

The engine is generic. **Every project-specific rule is data** in
`guardrails.config.json` — you should never need to edit a script to add a rule.

## Install

```bash
git clone https://github.com/<you>/claude-code-guardrails
cd claude-code-guardrails
./install.sh /path/to/your/repo
```

It copies `hooks-scripts/`, `hooks/` and `guardrails.config.json` into the
target's `.claude/`, merges the hook wiring into `settings.json` (existing hooks
preserved), and prints what to do next. `--dry-run` shows the plan.

Requires `python3`, `jq`, and `bash`.

Then — and this is the part that matters — **delete every rule that does not
apply to you.** The shipped config is illustrative, not a starting set. A guard
that fires on correct code gets the whole file disabled within a week, and takes
the useful rules with it.

Verify:

```bash
bash .claude/hooks/test-hooks.sh     # 67 passed, 0 failed
```

Wire that into pre-push or CI. Hooks fail silently; an untested guard is
indistinguishable from a guard with nothing to report.

## Writing a rule

A blocking Bash rule:

```json
{
  "name": "push schema to the linked project",
  "pattern": "<your-cli>\\s+db\\s+push",
  "message": "Writes to the LINKED (production) project. There is no rollback."
}
```

An advisory edit reminder:

```json
{
  "name": "CSP allowlist",
  "path": "(^|/)csp\\.json$",
  "content": "(?i)connect-src|script-src",
  "message": "If code now talks to a new third-party host, add a matching CSP source."
}
```

A "this component is not registered anywhere" check — the generalized form of
*exists on disk, never deploys*:

```json
{
  "name": "edge function not declared",
  "path": "functions/(?!_shared/)[^/]+/.*\\.ts$",
  "requires_declaration": {
    "capture_name_from": "functions/([^/]+)/",
    "manifest": "config.toml",
    "must_contain": "[functions.{name}]"
  },
  "message": "No manifest entry, so the deploy will not include it."
}
```

Blocked commands print the override in the failure message:

```
Blocked: push schema to the linked project -- high blast radius.
  Writes to the LINKED (production) project. There is no rollback.
If this is genuinely what you want, confirm with the user first, then
re-run prefixed with ALLOW_BLAST_RADIUS=1.
```

The override counts **only when written into the command** — never from the
environment, and never from a quoted mention. The goal is one deliberate
decision per command, not a switch someone flips once in a shell profile and
forgets.

## Slash commands

| Command | What it does |
|---|---|
| `/review-pr [N] [--wait]` | Pulls the automated review off a PR into your session — staleness-gated, no browser copy-paste |
| `/review-changes` | Reviews uncommitted work before it becomes a commit |
| `/implement-spec <name>` | Spec -> plan -> test-first implementation |
| `/validate-spec <name>` | Audits an implementation against the spec, read-only |

`/review-pr` is the one worth stealing even if you take nothing else. Most of
its length is two gates that are easy to get wrong: a sticky review comment is
edited in place, so a stale review is byte-identical to a fresh one, and a
reviewer that reports progress posts *before* it has finished.

## What this does not do

- **It is not a sandbox.** `sed -i` reaches files the edit rules watch. These
  are speed bumps against agent slips. For a real boundary use
  `permissions.deny`.
- **It does not lint.** Style and vulnerability rules belong in a linter that
  can see whole files and types. A hook sees one diff hunk.
- **It will not make a bad CLAUDE.md good.** It makes an already-good one
  binding. Start with `templates/CLAUDE.md.template`.

## Design notes

`docs/PATTERNS.md` is the reasoning, and is the actual point of the repo. The
short version:

1. **The matcher gap is a bypass.** A `Write|Edit`-only guard does nothing about
   `sed -i` via Bash. Register file-subject guards under both matchers.
2. **Mentioning a command is not running it.** Strip heredoc bodies, then quoted
   spans — in that order — or the guard blocks its own documentation.
3. **Exemptions must fail closed.** A carve-out may only read text that cannot
   have been stripped.
4. **Pick severity by escape hatch, not by badness.** Bash can carry an
   override; an Edit envelope cannot, so blocking an edit is a wall with no door.
5. **Advisory is a distinct tool.** When half the coupled surfaces live outside
   the repo, a reminder is honest and a block is false positives.
6. **A guard that cries wolf takes the good rules with it.**
7. **Fail open.** A crashing hook must never wedge a tool call.
8. **Anchor matches.** `test` must not match `test:e2e`.
9. **Constrain the agent, not the human.** These are Claude Code hooks, not git
   hooks; contributors are unaffected.
10. **Test the hooks.** Their failure mode is silence.

## License

MIT. See `LICENSE`.
