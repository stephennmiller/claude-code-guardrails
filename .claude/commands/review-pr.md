---
description: Pull the automated review off a PR and address it in-session
argument-hint: "[PR_NUMBER] [--summary|--resolve-only|--wait]"
allowed-tools: "Bash(gh:*), Bash(git:*), Bash(grep:*), Bash(jq:*), Bash(npm:*), Bash(sleep:*), Read, Edit, Write, Grep, Glob, TodoWrite"
---

# /review-pr

Fetch the automated review (and any human feedback) from a PR and work through
it in this session. No copy-pasting from the browser.

Assumes an automated reviewer that posts a **sticky comment** — one bot comment
rewritten in place on each push (the default for `anthropics/claude-code-action`
with `use_sticky_comment: true`). Adjust the bot login and the completion marker
below if yours differs.

## Usage

```text
/review-pr            # current branch's PR
/review-pr 1444       # explicit PR
/review-pr --summary  # print findings, fix nothing
/review-pr --wait     # poll until the review is newer than the head commit
```

## Step 1 — Resolve the PR number

Requested: **$ARGUMENTS**

Current branch's PR, resolved before this prompt reached you:
!`gh pr view --json number,title,headRefName -q '"#\(.number) \(.title) [\(.headRefName)]"' 2>/dev/null || echo "no PR for current branch"`

If `$ARGUMENTS` contains a PR number, prefer it. Otherwise use the number above.
If neither yields one, stop and say so — do not guess.

**Substitute the literal number into every command below.** Each Bash call gets
a fresh shell, so a `PR=...` assignment does not survive to the next call. Write
`/issues/1444/comments`, never `/issues/$PR/comments`.

## Step 2 — Fetch the review (never ask the user to paste it)

**Gate before you fetch.** A sticky comment is edited in place, so a stale
review is byte-indistinguishable from a fresh one. Run this first — if it exits
non-zero there is nothing worth reading, and you have spent one round-trip
instead of four:

```bash
PAYLOAD=$(gh api repos/{owner}/{repo}/issues/<PR>/comments \
  --jq '[.[] | select(.user.login=="claude[bot]")] | last | {ts: .updated_at, body: .body}')
HEAD_TS=$(gh pr view <PR> --json commits -q '.commits[-1].committedDate')
REVIEW_TS=$(jq -r '.ts // empty' <<<"$PAYLOAD")

[[ -n "$REVIEW_TS" && "$REVIEW_TS" > "$HEAD_TS" ]] \
  || { echo "STALE or missing — review predates the head commit"; exit 1; }
jq -r '.body // empty' <<<"$PAYLOAD" | grep -q "finished" \
  || { echo "IN-FLIGHT — review has not finished"; exit 1; }
echo "READY"
```

Both gates run in one pass on purpose: there is no way to check the timestamp,
see it pass, and proceed without the completion check.

A newer timestamp is necessary but **not sufficient**. A reviewer that reports
progress posts its comment when the run *starts*, so it can be newer than the
head commit while still holding an unfinished checklist. Match on whatever
completion marker your reviewer emits (for `claude-code-action` it is a
`Claude finished @<user>'s task in Xm Ys` line) and treat its absence as
in-flight.

Once it prints `READY`, **`$PAYLOAD` already holds the review body** — print it
from there rather than re-fetching the same endpoint:

```bash
jq -r '.body // empty' <<<"$PAYLOAD"
```

Then collect what the sticky comment does not carry:

```bash
# Inline file-anchored comments, if any
gh api repos/{owner}/{repo}/pulls/<PR>/comments --paginate \
  --jq '.[] | "\(.user.login) \(.path):\(.line // .original_line) [id=\(.id)]\n\(.body)\n---"'

# Human reviews
gh api repos/{owner}/{repo}/pulls/<PR>/reviews \
  --jq '.[] | select(.body != "") | "\(.user.login) [\(.state)]\n\(.body)\n---"'

# Red checks are feedback too
gh pr checks <PR>
```

### `--wait`

Poll until both gates pass. Use this loop verbatim — bounded, not `while true`,
because the Bash tool caps a single call at 10 minutes and an unbounded wait on
a failed workflow would burn the whole budget.

**Run it with `timeout: 400000`.** The loop waits 11 x 30s = 330s (the last pass
exits without sleeping); the Bash tool's default is 120s, so at the default it
is killed after 4 passes and reports no `READY` for a review that simply had not
landed yet. If you change the iteration count, change this number with it
((bound - 1) x 30000, plus headroom).

Trust the exit status, not the printed words: the loop exits **1** on timeout
and **0** only after printing `READY`. The obvious `&&` form gets this exactly
backwards — it returns 0 on the timeout pass and 1 on every other one.

```bash
# The head commit does not move while you wait, so resolve it once, not per pass.
HEAD_TS=$(gh pr view <PR> --json commits -q '.commits[-1].committedDate')

for i in $(seq 1 12); do   # 12 passes, 11 sleeps x 30s = 330s; lands in 2-3 min
  PAYLOAD=$(gh api repos/{owner}/{repo}/issues/<PR>/comments \
    --jq '[.[] | select(.user.login=="claude[bot]")] | last | {ts: .updated_at, body: .body}')
  REVIEW_TS=$(jq -r '.ts // empty' <<<"$PAYLOAD")
  DONE=$(jq -r '.body // empty' <<<"$PAYLOAD" | grep -q "finished" && echo yes || echo no)
  if [[ -n "$REVIEW_TS" && "$REVIEW_TS" > "$HEAD_TS" && "$DONE" == "yes" ]]; then
    echo "READY"; break
  fi
  echo "attempt $i: IN-FLIGHT (review=${REVIEW_TS:-none} head=$HEAD_TS done=$DONE)"
  # Check before sleeping: on the last pass there is nothing left to wait for,
  # and exiting here rather than after the sleep saves a pointless 30s.
  if [[ $i -eq 12 ]]; then
    echo "TIMED OUT after 12 attempts — review did not complete. Do not proceed."
    exit 1
  fi
  sleep 30
done
```

Two things in that loop are load-bearing and look like decoration:

- Inside `[[ ]]`, `>` is a **lexicographic string comparison**, not a redirect.
  ISO-8601 UTC timestamps are fixed-width and zero-padded, so it orders them
  correctly.
- `// empty` prevents a false `READY`. `last` on an empty match yields `null`,
  and a bare `jq -r '.ts'` prints that as the four-character string `null` —
  non-empty, so it survives the `-n` guard, and it sorts *above* every ISO-8601
  stamp because `n` (0x6e) exceeds `2` (0x32). The loop would then announce
  `READY` for a review that does not exist. (`gh api --jq` happens to suppress
  null to empty output, so only the piped `jq -r` strictly needs the guard —
  apply it to both rather than relying on that asymmetry.)

## Step 3 — Triage before fixing

Classify every finding:

- **Fix** — a genuine defect, or a cheap correctness/clarity win.
- **Decline** — wrong, or contradicts project convention. Say why in the PR
  reply; do not silently ignore it.
- **Defer** — real but out of scope for this PR. File an issue instead.

**Verify the load-bearing claim of any finding against the actual code before
acting.** Automated reviewers cite stale line numbers, files that have since
moved, and conventions the repo does not have. A finding is a hypothesis.

Keep a short list of known false positives for your repo here, so you decline
them without re-verifying each time.

## Step 4 — Fix

Two flags skip this step:

- **`--summary`** — print the step 3 triage and stop. Change nothing, and do not
  continue to steps 5 or 6.
- **`--resolve-only`** — skip steps 4 and 5, go straight to step 6.

Build a todo per accepted item, then work them in order following repo
conventions. After each change, run the project's fast checks — targeted tests
for the changed files, typecheck, format. Never the full suite. For behavior
changes, write the failing test first.

## Step 5 — Commit and push

Group related fixes into logical Conventional Commits referencing the PR
(`fix(scope): subject (#<PR>)`). Push, which re-triggers the review workflow.

## Step 6 — Reply and resolve

Summarize what was fixed, declined (with reasoning), and deferred:

```bash
gh pr comment <PR> --body "..."
```

Resolve addressed inline threads. Thread ids come from
`pullRequest.reviewThreads`, **not** the REST comment ids in step 2 — they are
different id spaces and the REST ids will fail the mutation.

```bash
# List threads (PRT_* ids, resolution state, and the opening comment)
gh api graphql -f query='
  query($owner:String!, $repo:String!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: <PR>) { reviewThreads(first: 50) {
        nodes { id isResolved path line comments(first: 1) { nodes { body } } }
      }}
    }}' -F owner='{owner}' -F repo='{repo}'

# Resolve one thread
gh api graphql -f query='
  mutation { resolveReviewThread(input: { threadId: "PRT_..." }) {
    thread { isResolved }
  }}'
```

**The `{owner}`/`{repo}` braces must not go inside the GraphQL document.** `gh`
expands them where it parses the value — REST paths (step 2) and `-F` field
values (above) — but the `-f query=` body is passed through untouched, so braces
placed there arrive literally and the call fails with `Could not resolve to a
Repository with the name '{owner}/{repo}'`. Hence the GraphQL *variables*:
`$owner`/`$repo` are declared in the query and supplied via `-F`, where the
braces do expand. That also keeps the command working from a fork.

**With a sticky-comment reviewer this step is usually a no-op** — everything
arrives in one issue comment and **zero** inline threads are opened. Expect
threads only from human reviewers. Only resolve threads you actually addressed.

## Flags

- `--summary`: run steps 1-3, print the triage, change nothing.
- `--resolve-only`: skip step 4; reply to and resolve threads already fixed.
- `--wait`: poll in step 2 until the review is newer than the head commit.
