---
description: Check an implementation against the project's specs and conventions
argument-hint: "[file-or-feature]"
allowed-tools: "Bash(git:*), Bash(npm:*), Read, Grep, Glob"
---

# Validate: $ARGUMENTS

Audit an implementation against what the project says it should be. Read-only —
report findings, do not fix them.

## 1. Spec compliance

If a written spec exists:

- [ ] Every acceptance criterion is met — quote the code that meets each
- [ ] The specified pattern was followed, not a parallel invention
- [ ] Edge cases from the spec are handled
- [ ] Deliberate deviations are documented with reasoning

## 2. Architecture compliance

Check against the project's CLAUDE.md and rules files. Fill this section in for
your project — the point is that it names *your* invariants, not generic ones.

- [ ] Layering respected (no reaching past an abstraction boundary)
- [ ] Errors handled in the project's idiom
- [ ] External calls have timeouts
- [ ] Data validated at boundaries
- [ ] State managed the way the project manages state

## 3. Reachability

- [ ] Wired end to end: data layer -> service -> state -> rendered UI -> route
- [ ] Config/flags the code depends on actually exist in every environment
- [ ] Schema changes applied, generated artifacts regenerated

A change that typechecks but is unreachable is the single most common way a
feature is "done" and still does nothing.

## 4. Tests

- [ ] Tests colocated per project convention
- [ ] New behavior has a test that fails without the implementation
- [ ] Edge cases from the spec are covered
- [ ] Coverage meets the project's gate

## 5. Report

For each violation give: `file_path:line`, the specific rule broken, and a
concrete fix. Rank by severity. If the implementation is clean, say so — do not
pad.
