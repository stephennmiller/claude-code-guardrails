---
description: Review uncommitted changes for correctness and project standards
argument-hint: "[--staged-only]"
allowed-tools: "Bash(git:*), Bash(npm:*), Bash(npx:*), Read, Grep, Glob"
---

# /review-changes

Review uncommitted work before it becomes a commit — the cheapest place to
catch something, and the point at which you still have the full context of why
the change was made.

## Workflow

1. **Gather changes** — `git diff` (plus `git diff --cached`, or only that with
   `--staged-only`).
2. **Read each modified file in full.** Not just the diff. Most real defects are
   invisible in a hunk: a now-unreachable branch, a caller three functions up
   whose assumption you just broke, a second code path that needed the same fix.
3. **Run targeted tests** for the modified files only — never the full suite.
4. **Typecheck.**
5. **Report** against the criteria below.

## Review criteria

Work through each; skip what does not apply rather than padding the report.

### Correctness

- Does the change do what the commit intends, in every path — not just the one
  that was manually exercised?
- Off-by-one, null/undefined, empty-collection, and error paths.
- Concurrency: is shared state mutated without ordering guarantees?
- If there were several valid approaches, say which was taken and why.

### Reachability

- Is the new code actually wired to something a user can reach? A service with
  no caller, a component never routed, a flag never read, a migration never
  applied — all typecheck and all ship nothing.

### Conventions

- Matches the surrounding code's idiom, naming, and error handling.
- No new dependency where stdlib or an installed dep would do.
- Comments explain *why*, never *what*. No comments added to unchanged code.

### Security

- No credentials, keys, or tokens in source.
- Input validated at system boundaries (user input, external APIs, webhooks).
- No injection via string-built queries or commands.

### Error handling

- Every expected failure point handled; failures are not silently swallowed.
- Network and IO calls have timeouts.
- Retries only where the operation is idempotent.

### Tests

- Existing tests pass for the modified files.
- New behavior has a test that would fail without the change. A test that
  passes against the unfixed code is not a test.

### Frontend (when applicable)

- Keyboard reachable, visible focus, labelled controls.
- Loading, empty and error states exist, not just the happy path.

## Output

```markdown
## Review Summary

**Status**: Pass | Pass with Notes | Needs Changes
**Tests**: X passed (Y total)
**Typecheck**: Clean | N errors

### `path/to/file.ts` — what changed

**Rating**: Excellent | Good | Needs Work

- What the change does and why it is (in)correct
- Issues with specific references (file_path:line_number)

### Issues Found

**None**, or a numbered list with severity (Critical / Warning / Note) and a
concrete suggested fix for each.
```

Rank by severity, not by file order. If nothing is wrong, say so plainly and
stop — a review that manufactures findings to look thorough trains the reader
to ignore it.
