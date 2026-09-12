# Contributing

## The one rule

**Every change to a guard needs an assertion in `.claude/hooks/test-hooks.sh`.**

Hooks fail silently. A guard that has been broken for a month looks exactly like
a guard with nothing to report, so the test suite is the only thing standing
between "this works" and "nobody has noticed yet."

```bash
bash .claude/hooks/test-hooks.sh      # must be green before and after
bash .claude/hooks/test-hooks.sh -v   # prints hook output for failures
```

## Adding a rule

Most rules need no code. Add them to `.claude/guardrails.config.json` — the
scripts are the engine and should not change to accommodate a new rule. If you
find yourself editing a script to add a rule, say so in the PR; either the
schema is missing something, or the rule belongs somewhere else.

Before writing one, read `docs/PATTERNS.md`. Most of the sharp edges are there
and they are not obvious:

- A `Write|Edit`-only guard does nothing about `sed -i` via Bash (§1)
- Grepping the raw command makes a guard fire on its own documentation (§2)
- An exemption that reads normalized text fails **open** (§3)

## Adding an assertion

Assertions are `expect <exit> <name> <script> <envelope> [substring]`:

```bash
expect 2 "blocks a remote schema push" blast-radius-guard.py \
    "$(bash_envelope 'testcli db push')" "Blocked"
```

Two things to get right:

1. **Test the false positives too.** Roughly half the value of a guard is that
   it stays quiet on correct code. A guard that cries wolf gets disabled, and
   takes the useful rules with it.
2. **Keep assertions out of subshells.** `( cd X; expect ... )` discards the
   counter increments, so a failing assertion prints in red and still leaves the
   suite green. Set `RUN_DIR` instead.

Tests run against `.claude/hooks/fixtures/guardrails.config.json`, not the
shipped config, so they exercise the engine rather than whichever rules happen
to be configured. Add fixture rules there as needed.

## The contract

Every hook obeys it, and a change that breaks it is a breaking change:

```
exit 0 = allow    exit 2 = block    exit 1 = internal error, NON-BLOCKING
```

A hook that crashes must never wedge a tool call. When in doubt, fail open —
except inside a guard's own text handling, where a failed transform should fall
back to the raw command rather than an empty string. An empty scan matches
nothing and silently allows everything.

## Style

- Comments explain **why**, not what. A rule's comment should say what broke.
- No emoji in scripts or output.
- Shell: `bash`, `set -uo pipefail`. Python: stdlib only, no third-party deps.
- Guards must work from a git worktree, where cwd and the script's location
  differ.

## Scope

In scope: the hook engine, the contract, the harness, the schema.

Out of scope: style and vulnerability linting. A hook sees one diff hunk with no
type information; a linter sees whole files. Rules that need more context belong
in a linter, not here.
