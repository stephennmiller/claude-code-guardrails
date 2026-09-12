# claude-code-guardrails

[![test](https://github.com/stephennmiller/claude-code-guardrails/actions/workflows/test.yml/badge.svg)](https://github.com/stephennmiller/claude-code-guardrails/actions/workflows/test.yml)

Claude Code hooks that enforce your CLAUDE.md.

Most CLAUDE.md files say "don't run this without asking" somewhere. The agent
reads it, agrees, and runs it three hours later anyway. By then that line is 200
lines up in a context window full of other things.

These hooks make those lines executable.

## Guards

Six scripts, wired to PreToolUse (Bash and Write/Edit) and PostToolUse.

| Guard | Severity | Catches |
|---|---|---|
| `blast-radius-guard` | block / warn | Irreversible commands. Overwriting generated files, writing a remote DB, re-baselining snapshots, moving a ratchet. |
| `watch-mode-guard` | block | A test runner started in watch mode. Hangs the tool call until it times out. |
| `git-safety` | block | Hook-bypass flags, commits to a protected branch, force-push. |
| `secret-scan-guard` | block | A real-looking credential written into a tracked file. |
| `config-sync-guard` | advisory | One half of a coupled pair changing. CSP and the code that fetches a new origin. |
| `auto-format-code` | none | Formats after an edit so the model's view matches disk. |

Rules live in `.claude/guardrails.config.json`. The scripts are the engine and
stay put. Adding a rule means editing config.

## Install

```bash
git clone https://github.com/stephennmiller/claude-code-guardrails
cd claude-code-guardrails
./install.sh /path/to/your/repo
```

Needs `python3` 3.9+, `jq`, and `bash` 3.2+ (stock macOS works). Merges into an
existing `settings.json` without
touching hooks already there. Idempotent. `--dry-run` prints the plan.

Tested on Linux and macOS, both in CI. Windows is untested. WSL should work
since it is Linux. Native Windows probably does not: the guards are invoked by
shebang, and the shell layer wants `jq`, `sed` and `awk`. If a hook silently
no-ops you are worse off than with no hook at all, so the claim stays off until
a `windows-latest` job proves it.

Then delete every rule that doesn't apply to you. The shipped config is
illustrative, not a starting set. A guard that fires on correct code gets the
whole file switched off inside a week, and the useful rules go with it.

## Verify

```bash
bash .claude/hooks/test-hooks.sh
```

67 assertions, about two seconds, no network and no project dependencies. Wire
it into pre-push or CI. Hooks fail silently, so a broken guard and a guard with
nothing to report look identical.

CI runs the suite on Linux and macOS, breaks a guard on purpose to confirm the
suite goes red, and installs into a scratch repo.

## Writing a rule

Block a command:

```json
{
  "name": "push schema to the linked project",
  "pattern": "<your-cli>\\s+db\\s+push",
  "message": "Writes to the production project. No rollback."
}
```

Remind on an edit:

```json
{
  "name": "CSP allowlist",
  "path": "(^|/)csp\\.json$",
  "content": "(?i)connect-src|script-src",
  "message": "New third-party host in the code? Add a matching CSP source."
}
```

Catch a component nothing registered, the "exists on disk, never deploys" bug:

```json
{
  "name": "function not declared",
  "path": "functions/(?!_shared/)[^/]+/.*\\.ts$",
  "requires_declaration": {
    "capture_name_from": "functions/([^/]+)/",
    "manifest": "config.toml",
    "must_contain": "[functions.{name}]"
  },
  "message": "No manifest entry. The deploy will skip it."
}
```

A block prints its own override:

```text
Blocked: push schema to the linked project -- high blast radius.
  Writes to the production project. No rollback.
If this is genuinely what you want, confirm with the user first, then
re-run prefixed with ALLOW_BLAST_RADIUS=1.
```

The override only counts when it's written into the command. Not from the
environment, where one line in a shell profile would disable everything for the
session. Not from a quoted mention either. One decision per command.

## Commands

| Command | Does |
|---|---|
| `/review-pr [N] [--wait]` | Pulls the automated review off a PR into your session |
| `/review-changes` | Reviews uncommitted work before it's a commit |
| `/implement-spec <name>` | Spec, plan, then test-first implementation |
| `/validate-spec <name>` | Audits an implementation against the spec |

`/review-pr` is the one to steal. Most of its length is two gates that are easy
to get wrong. A sticky review comment is edited in place, so a stale review is
byte-identical to a fresh one, and a reviewer that reports progress posts before
it has finished.

## Limits

Not a sandbox. `sed -i` still reaches files the edit rules watch. These are
speed bumps for agent slips. Use `permissions.deny` for a real boundary.

Not a linter. A hook sees one diff hunk with no type information. Style and
vulnerability rules belong somewhere that can see whole files.

Won't fix a bad CLAUDE.md. It makes a good one binding. There's a starting point
in `templates/CLAUDE.md.template`.

## Design

`docs/PATTERNS.md` has the reasoning. Short version:

1. A `Write|Edit` guard does nothing about `sed -i` via Bash. Register
   file-subject guards under both matchers.
2. Strip heredoc bodies, then quoted spans, in that order. Otherwise the guard
   blocks its own documentation.
3. Exemptions must read raw text. One that reads normalized text fails open.
4. Pick severity by escape hatch. Bash can carry an override, an Edit envelope
   can't, so blocking an edit is a wall with no door.
5. Advisory is a separate tool. When half the coupled surfaces live outside the
   repo, a reminder is honest and a block is noise.
6. A guard that cries wolf takes the good rules down with it.
7. Fail open. A crashing hook must never wedge a tool call.
8. Anchor matches. `test` must not match `test:e2e`.
9. Constrain the agent, not the human. These are Claude Code hooks, not git
   hooks. Contributors aren't affected.
10. Test the hooks. Their failure mode is silence.

## Contributing

Every change to a guard needs an assertion in `test-hooks.sh`. See
`CONTRIBUTING.md`.

## License

MIT.
