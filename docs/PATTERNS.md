# Patterns

The reasoning behind the hooks. Each section is a failure mode that cost real
time before the rule existed. If you only read one, read the first.

---

## 1. The matcher gap is a bypass

A hook registered for `Write|Edit|MultiEdit` does not run on `Bash`. So this is
guarded:

```
Edit  vitest.config.ts   ->  blocked
```

and this is not:

```
Bash  sed -i '' 's/74/0/' vitest.config.ts   ->  allowed
```

Same edit, different door. Every guard whose subject is *a file* must be
registered under **both** matchers, or it protects only the door you thought of.
This is why `blast-radius-guard.py` appears twice in `settings.json`.

The general form: **enumerate the tools that can produce the effect, not the
tools you picture the agent using.** `bash -c`, `sed -i`, `tee`, `python -c`,
and a heredoc redirect are all "edit a file".

Accept that this is a speed bump, not a sandbox. `sed -i` still reaches files
the edit rules watch, because the Bash rules match commands rather than
resolving every path a command might touch. If you need a real boundary, use
`permissions.deny` — a hook is for catching slips, not adversaries.

---

## 2. Mentioning a command is not running it

The naive guard greps the raw command string. It then blocks:

```bash
echo "never run deploy-cli db push"
git commit -m "docs: explain why db push is blocked"
gh pr create --body-file - <<'EOF'
Do not run db push against prod.
EOF
```

All three are talking *about* the command. A guard that cannot tell the
difference fires on its own documentation, and the first thing anyone does is
disable it.

`normalize()` strips the two places where text is data:

1. **Heredoc bodies** — prose fed to stdin, never a command.
2. **Quoted spans** — messages, grep patterns, echo arguments.

**Order is load-bearing.** Heredocs first: stripping quotes first eats a quoted
delimiter (`<<'MSG'` becomes `<<`) and leaves the body looking like ordinary
command text. Getting this backwards is subtle, silent, and cost a blocked
`gh pr create` whose body documented this very guard.

### The wrapper exception

`bash -c "..."` carries the *real* command inside quotes. Strip there and every
guard becomes a one-word bypass:

```bash
bash -c "deploy-cli db push"   # quotes stripped -> nothing left to match
```

So a shell wrapper is detected and scanned raw. And detect it properly: `-c` is
frequently not adjacent to the shell name (`bash -eux -c`, `bash --norc -c`,
`env bash -l -c`). A pattern matching only `-[a-z]*c` catches the combined
`-euxc` spelling and misses every separated one, which is the more common way to
write it.

### Opting out per rule

One rule *needs* the raw text: "did you hand-author a release commit?" The
giveaway is the commit message itself, which lives exactly where normalization
strips. Hence `scan_raw` — a per-rule opt-out, keyed on an explicit field rather
than on the rule's name. (An earlier version keyed it on `"release" in name`;
renaming the rule would have silently disabled it.)

---

## 3. Exemptions must fail closed

Carve-outs are where guards leak, because a carve-out's bug looks like success.

The type-generation rule blocks regenerating types from the remote schema, but
exempts the documented-safe local form. The exemption is evaluated against the
**raw** command, and that is not an accident:

```bash
# Against the NORMALIZED command, the quoted target is erased first, the
# clobber check finds nothing, the exemption fires, and the dangerous write
# sails straight through.
deploy-cli gen types --db-url postgresql://localhost/db > "src/types/generated.ts"
```

Rule: **an exemption may only ever look at text that cannot have been stripped.**

### When the carve-out is not a regex

Some carve-outs are not decidable from the string at all. `git checkout main`
and `git checkout main.py` differ only in what the *repository* says the word
means, so a regex must either miss the destructive form or block every branch
switch — and a rule that blocks every branch switch gets deleted, taking the
rest of the file with it.

For these, `exempt.predicate` names a function from the registry in
`_guardrails.py`, and the rule stays declarative in config. The predicate for
checkout asks git in **git's own resolution order**: a name that resolves to a
commit is a branch switch, which git refuses rather than performs when it would
lose changes; a name that does not resolve but exists on disk is a pathspec,
which overwrites the working tree silently. Agreeing with git's precedence is
what makes it precise instead of heuristic.

The same fail-closed rule applies, and one extra: a predicate that cannot parse
what it was handed must **not** exempt. Returning "I don't know" as "allow" is
how a carve-out becomes a bypass.

Two more traps in the same rule, both found the hard way:

- **`>` vs `>>`.** A pattern matching a single `>` matches the first bracket of
  `>>`, and the capture group swallows the second — so the redirect target
  resolves to `">"`, matches nothing, and an *append* onto the protected file is
  waved through. Match `>>?` and exclude `>` from the target character class.

- **Anchoring to one absolute path breaks in git worktrees.** cwd is the
  worktree root while the hook may be the main checkout's copy, so an
  `__file__`-relative comparison fails and the exemption allows a real clobber.
  Instead: match the trailing path segments, then require repo markers
  (`package.json`, `.claude`) in the directory above. That matches every
  checkout's copy and still rejects `/tmp/backup/src/types/generated.ts`, which
  ends with the same segments but has no repo root above it.

---

## 4. Two severities, chosen by escape hatch

Not "how bad is it" — **can the agent get past it if it is right and you are
wrong?**

| | Bash | Edit |
|---|---|---|
| Can carry an override | yes (`ALLOW_BLAST_RADIUS=1 <cmd>`) | no |
| Recoverable if wrong | often not | always (it is in git) |
| **Therefore** | **block** | **warn** |

An Edit envelope has nowhere to put an env var, so blocking an edit is a wall
with no door. Everything on the edit list is plain text recoverable from git, so
a warning in the model's context is the right weight.

### Make the override a decision, not a setting

The override counts **only when written into the command**:

- Not `os.environ` — an exported `ALLOW_BLAST_RADIUS=1` in a shell profile
  silently disables every rule for the whole session, invisibly and permanently.
- Not a raw-string match — `\b` sees a word boundary at a quote, so
  `echo "ALLOW_BLAST_RADIUS=1"; <cmd>` reads as consent. A mention is not a
  decision. Check the *normalized* command, which also means prose documenting
  the override does not grant it.

The point is one deliberate decision per command.

---

## 5. Advisory guards are a distinct tool, not a weak one

`config-sync-guard.py` never blocks, and it should not. Its subject is
coordination across surfaces, and **several of those surfaces are outside the
repo** — a hosting platform's env vars, a provider's dashboard, a DNS record.
The hook can name them; it cannot verify them. Blocking would be false positives
all the way down.

What it is good at: the failure that is invisible locally and only appears in
production. The canonical instance is shipping a third-party script key without
adding the matching CSP source — nothing fails in dev, and auth goes down on
deploy.

The `requires_declaration` rule generalizes the nastiest member of that family:
a component that exists on disk, looks complete, and is never deployed because
nothing added it to the manifest. The symptom always appears far from the cause
(a 404 on the preflight, surfaced by the browser as a CORS error, sending you to
debug CORS).

---

## 6. A guard that cries wolf takes the good rules with it

An earlier version of the secret scanner also flagged `eval(`, `innerHTML =`,
and `../` as path traversal. In a JS codebase `../` matches **every relative
import**. Within a week the whole hook is off, and the credential rule — the one
that actually mattered — goes with it.

So: `secret-scan-guard.py` does one thing, and requires two independent signals
before blocking — the assignment *shape* looks like a credential, **and** the
value looks real (length, character mix, Shannon entropy, not a placeholder).
Known provider formats (`ghp_`, `AKIA`, `sk-ant-`) are unambiguous and block on
shape alone.

Style and vulnerability rules belong in a linter that can see the whole file and
its types. A hook sees one diff hunk and has no type information.

**Test the false positives, not just the true ones.** Half the assertions in
`test-hooks.sh` for this guard are `expect 0`.

---

## 7. Fail open, always

```
exit 0 = allow    exit 2 = block    exit 1 = internal error, NON-BLOCKING
```

Every hook wraps `main()` in a catch-all that exits 1. A hook that crashes must
never wedge a tool call, because the failure is invisible — the agent sees a
tool error it cannot act on, and the user sees an agent that has mysteriously
stopped working.

The same principle applies inside the guards. When a text transform fails,
`watch-mode-guard` falls back to the raw command rather than an empty string: an
empty scan matches nothing and silently allows everything, while the raw command
fails *closed* — at worst a false block, which is visible and fixable, rather
than a missed one, which is not.

And when there is no config at all, every guard allows. `test-hooks.sh` asserts
this.

---

## 8. Anchor matches to exact names

`npm run test` as a substring also matches `test:e2e`, `test:coverage`,
`test:integration`, `test:a11y` — none of which are watch-mode, several of which
are not even the same runner. Requiring a trailing whitespace/quote/end-of-line
excludes every `name:*` sibling, because `:` is none of those.

The corollary: a sibling that genuinely *does* hang (`test:ui` starts a UI
server) must then be listed explicitly, because the anchoring that saved you
also skips it.

### The npm `--` trap

```bash
npm run test --run    # npm SWALLOWS the flag, forwards nothing, watch mode starts
npm run test -- --run # correct
```

This is the single likeliest way to hit the watch guard, so the flag before `--`
must **not** count as a one-shot marker. The guard computes what npm actually
forwards (everything after `-- `, or nothing at all) and looks for run markers
only there.

---

## 9. Constrain the agent, not the human

`git-safety.py` blocks the hook-bypass flag on commit and push. It is a Claude
Code hook, **not** a git hook — so it constrains the agent only. A human running
the same command in their own terminal is unaffected, and a contributor who has
never heard of this repo's agent setup notices nothing.

That asymmetry is the design. The escape hatch stays open for the person who can
judge when to use it, and closes for the process that reaches for it whenever a
gate is inconvenient.

Generalize: hooks are the right place for rules that should bind *this* actor in
*this* context. Rules that should bind everyone belong in git hooks or CI, where
they apply to everyone and are visible in the repo.

---

## 10. Test the hooks

Hooks are the least-tested code in most repos, and they have the worst possible
failure mode: **silence**. A guard that has been broken for a month looks
exactly like a guard with nothing to report.

`test-hooks.sh` runs in about two seconds, needs no network and no project
dependencies, and every assertion in it encodes a real bypass or false positive.

Three things make it worth trusting:

1. **A fixture config.** Tests exercise the engine, not whatever rules a given
   project has configured, so the suite means the same thing everywhere.
2. **No subshells around assertions.** `( cd X; expect ... )` discards the
   counter increments, so a failing assertion prints in red and still leaves the
   suite green — the exact silent failure the harness exists to catch. Set a
   `RUN_DIR` variable instead.
3. **Hermetic inputs.** `git-safety` reads the ambient branch, so its tests run
   against a throwaway repo on a known branch. Otherwise the suite passes or
   fails depending on which branch you are standing on.

Verify the harness itself occasionally by breaking a guard on purpose and
confirming the suite goes red. A test suite that has never failed has not been
shown to work.
