---
description: Implement a feature from a written spec, test-first
argument-hint: "[feature-name]"
allowed-tools: "Bash(git:*), Bash(npm:*), Read, Edit, Write, Grep, Glob, TodoWrite"
---

# Implement: $ARGUMENTS

## 1. Locate the spec

Find the spec for "$ARGUMENTS" in the project's spec location (commonly
`.claude/feature-specs.md`, `docs/specs/`, or an issue).

**If no spec exists, STOP and ask for one.** Do not infer requirements from the
feature name — that produces a plausible implementation of the wrong thing, and
the mismatch only surfaces at review.

## 2. Extract requirements

From the spec, list:

- Acceptance criteria, as individually testable statements
- The existing pattern this should follow (name the file to imitate)
- Dependencies and constraints
- Edge cases, and what should happen at each

Anything the spec does not settle, raise now — not after the code is written.

## 3. Plan

Break it into incremental steps, each independently verifiable. Name the files
to create or modify. Flag risks. Present the plan before writing code.

## 4. Implement, test-first

Per step: write the failing test, confirm it fails **for the right reason**
(asserting missing behavior, not an import error), write the minimal code to
pass, then refactor.

## 5. Verify against the spec

- Walk the acceptance criteria one by one and state how each is met
- Confirm the feature is reachable end to end, not merely present in the source
- Run the project's checks: targeted tests, typecheck, lint

## 6. Close the loop

Mark the spec complete, and note anything deliberately deferred, with why.
