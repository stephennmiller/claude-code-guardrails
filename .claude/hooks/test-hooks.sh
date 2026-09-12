#!/bin/bash
# Regression harness for the guardrail hooks.
#
# WHY THIS EXISTS: hooks are the least-tested code in most repos. They run in a
# context you never see, their failure mode is SILENCE, and a broken guard looks
# exactly like a guard with nothing to report. Every assertion below encodes a
# real bypass or false positive -- the kind you only find once a guard has
# quietly been allowing something for a month.
#
# Runs in ~2s with no network and no project dependencies. Wire it into
# pre-push, or CI, or both.
#
# Usage:  bash .claude/hooks/test-hooks.sh [-v]

set -uo pipefail

GREEN='\033[0;32m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'
VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

if ! command -v jq >/dev/null 2>&1; then
    echo -e "${RED}jq is required${NC}: it builds the hook input envelopes, and"
    echo "the shell guards no-op without it (so every assertion would 'pass')."
    exit 2
fi

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HOOKS_DIR/../hooks-scripts" && pwd)"

# Tests exercise the ENGINE, so they run against a fixture config rather than
# whatever rules this project happens to have configured.
export GUARDRAILS_CONFIG="$HOOKS_DIR/fixtures/guardrails.config.json"

PASSED=0; FAILED=0; FAILURES=()

# Directory each hook is invoked from. Some rules resolve paths against the
# checkout, so a few groups need a different cwd.
#
# This is a variable rather than a `( cd X; ... )` subshell on purpose: counter
# updates inside a subshell are discarded, so a failing assertion in one would
# print in red and still leave the suite green. That is precisely the
# silent-failure mode this harness exists to catch.
ORIGIN="$PWD"
RUN_DIR="$PWD"

# Literals that guards elsewhere scan for, assembled at runtime. A test suite
# has to be able to name the thing it tests -- but this file is itself edited
# by agents whose own guards would fire on the whole string.
NOVERIFY="--no""-verify"
RELEASE_SUBJECT="chore(rel""ease): v2.1.0"

# A throwaway checkout so path-resolution rules (repo markers, manifests) have
# something real to resolve against.
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/.claude" "$SANDBOX/src/types" \
         "$SANDBOX/functions/declared" "$SANDBOX/functions/orphan"
echo '{}' > "$SANDBOX/package.json"
echo 'placeholder' > "$SANDBOX/src/types/generated.ts"
printf '[functions.declared]\nverify_jwt = true\n' > "$SANDBOX/config.toml"
touch "$SANDBOX/functions/declared/index.ts" "$SANDBOX/functions/orphan/index.ts"

# git-safety reads the AMBIENT branch, so its tests need their own repo on a
# known, non-protected branch. Without this the suite passes or fails depending
# on what branch you happen to be standing on -- which is how a guard regression
# hides for a week.
GITBOX="$SANDBOX/gitbox"
mkdir -p "$GITBOX"
git -C "$GITBOX" init -q -b feat/guardrails-test >/dev/null 2>&1 || true

# --- assertions ------------------------------------------------------------

# expect <expected-exit> <name> <script> <json-envelope> [substring]
expect() {
    local want="$1" name="$2" script="$3" envelope="$4" needle="${5:-}"
    local out got

    out=$(cd "$RUN_DIR" && printf '%s' "$envelope" | "$SCRIPTS/$script" 2>&1)
    got=$?

    if [[ "$got" -ne "$want" ]]; then
        echo -e "${RED}x${NC} $name ${DIM}(want exit $want, got $got)${NC}"
        FAILURES+=("$name: exit $got != $want")
        FAILED=$((FAILED + 1))
        [[ $VERBOSE -eq 1 ]] && echo "$out" | sed 's/^/    /'
        return
    fi
    if [[ -n "$needle" ]] && ! grep -qF -- "$needle" <<< "$out"; then
        echo -e "${RED}x${NC} $name ${DIM}(output missing '$needle')${NC}"
        FAILURES+=("$name: missing '$needle'")
        FAILED=$((FAILED + 1))
        [[ $VERBOSE -eq 1 ]] && echo "$out" | sed 's/^/    /'
        return
    fi
    echo -e "${GREEN}.${NC} $name"
    PASSED=$((PASSED + 1))
}

bash_envelope() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
write_envelope() {
    jq -nc --arg p "$1" --arg c "$2" \
        '{tool_name:"Write",tool_input:{file_path:$p,content:$c}}'
}
edit_envelope() {
    jq -nc --arg p "$1" --arg n "$2" \
        '{tool_name:"Edit",tool_input:{file_path:$p,old_string:"",new_string:$n}}'
}

section() { echo; echo "$1"; printf '%.0s-' $(seq 1 ${#1}); echo; }

# ===========================================================================
section "blast-radius-guard.py -- blocking Bash rules"

expect 2 "blocks a remote schema push" blast-radius-guard.py \
    "$(bash_envelope 'testcli db push')" "Blocked"

expect 0 "allows an unrelated command" blast-radius-guard.py \
    "$(bash_envelope 'npm run build')"

# A guard that greps the raw string blocks its own documentation.
expect 0 "allows a MENTION inside double quotes" blast-radius-guard.py \
    "$(bash_envelope 'echo "never run testcli db push"')"

expect 0 "allows a MENTION inside single quotes" blast-radius-guard.py \
    "$(bash_envelope "grep -r 'testcli db push' docs/")"

# The ordering bug that costs you a blocked `gh pr create`: stripping quotes
# before heredocs eats the quoted delimiter and leaves the body looking like
# ordinary command text.
expect 0 "allows a heredoc BODY that mentions a blocked command" blast-radius-guard.py \
    "$(bash_envelope "$(printf 'gh pr create --body-file - <<%s\nDo not run testcli db push here.\nEOF\n' "'EOF'")")"

expect 0 "allows an unquoted heredoc body too" blast-radius-guard.py \
    "$(bash_envelope "$(printf 'git commit -F - <<MSG\nrestore: testcli db push notes\nMSG\n')")"

section "blast-radius-guard.py -- the override"

expect 0 "override in the command allows it" blast-radius-guard.py \
    "$(bash_envelope 'ALLOW_BLAST_RADIUS=1 testcli db push')"

# \b sees a word boundary at a quote, so a naive check reads this as consent.
expect 2 "a QUOTED mention of the override does NOT grant it" blast-radius-guard.py \
    "$(bash_envelope 'echo "ALLOW_BLAST_RADIUS=1"; testcli db push')" "Blocked"

expect 2 "the override named in a heredoc does NOT grant it" blast-radius-guard.py \
    "$(bash_envelope "$(printf 'git commit -F - <<MSG\nSet ALLOW_BLAST_RADIUS=1 to override.\nMSG\ntestcli db push\n')")" \
    "Blocked"

section "blast-radius-guard.py -- shell wrappers (bypass class)"

# If quoted spans were stripped here, `bash -c "..."` would be a one-word bypass
# of every rule in the file.
expect 2 "blocks through bash -c" blast-radius-guard.py \
    "$(bash_envelope 'bash -c "testcli db push"')" "Blocked"

expect 2 "blocks through bash with separated flags (-eux -c)" blast-radius-guard.py \
    "$(bash_envelope 'bash -eux -c "testcli db push"')" "Blocked"

expect 2 "blocks through the combined -euxc spelling" blast-radius-guard.py \
    "$(bash_envelope 'bash -euxc "testcli db push"')" "Blocked"

expect 0 "override still works inside a wrapper" blast-radius-guard.py \
    "$(bash_envelope 'bash -c "ALLOW_BLAST_RADIUS=1 testcli db push"')"

section "blast-radius-guard.py -- scan_raw and DOTALL"

# The trigger IS the commit message, which lives exactly where normalization
# strips. This rule is the sole reason normalization is opt-out.
expect 2 "blocks a hand-authored release commit (-m)" blast-radius-guard.py \
    "$(bash_envelope "git commit -m \"$RELEASE_SUBJECT\"")" "Blocked"

expect 2 "blocks a release commit written as a heredoc" blast-radius-guard.py \
    "$(bash_envelope "$(printf 'git commit -F - <<MSG\n%s\nMSG\n' "$RELEASE_SUBJECT")")" "Blocked"

# Without re.DOTALL the lookahead stops at the newline and the flag escapes.
expect 2 "blocks a remote reset with the flag on a continuation line" blast-radius-guard.py \
    "$(bash_envelope "$(printf 'testcli db reset \\\n  --linked\n')")" "Blocked"

expect 0 "allows a LOCAL reset (no --linked)" blast-radius-guard.py \
    "$(bash_envelope 'testcli db reset')"

section "blast-radius-guard.py -- exemptions must fail closed"

expect 0 "allows local typegen into a temp file" blast-radius-guard.py \
    "$(bash_envelope 'testcli gen types --db-url postgresql://localhost:54322/db > /tmp/t.ts')"

expect 2 "blocks remote typegen" blast-radius-guard.py \
    "$(bash_envelope 'testcli gen types --project-ref abc123')" "Blocked"

# The exemption is judged on the RAW command for exactly this case: against the
# normalized one the quoted target is erased, the clobber check finds nothing,
# and the dangerous write sails straight through.
RUN_DIR="$SANDBOX"
expect 2 "blocks local typegen redirected ONTO the real file" blast-radius-guard.py \
    "$(bash_envelope 'testcli gen types --db-url postgresql://localhost/db > src/types/generated.ts')" \
    "Blocked"

expect 2 "blocks it when the redirect target is QUOTED" blast-radius-guard.py \
    "$(bash_envelope 'testcli gen types --db-url postgresql://localhost/db > "src/types/generated.ts"')" \
    "Blocked"

# A bare `>` matched the first bracket of `>>` and the capture swallowed the
# second, resolving the target to Path(">") -- no match, append went through.
expect 2 "blocks an APPEND redirect onto the real file" blast-radius-guard.py \
    "$(bash_envelope 'testcli gen types --db-url postgresql://localhost/db >> src/types/generated.ts')" \
    "Blocked"

# Ends with the same segments, but has no repo root above it.
expect 0 "allows a redirect to a LOOK-ALIKE path outside the repo" blast-radius-guard.py \
    "$(bash_envelope 'testcli gen types --db-url postgresql://localhost/db > /tmp/backup/src/types/generated.ts')"
RUN_DIR="$ORIGIN"

section "blast-radius-guard.py -- Edit rules are advisory"

expect 0 "warns (never blocks) on a coverage-threshold edit" blast-radius-guard.py \
    "$(edit_envelope 'vitest.config.ts' 'statements: 70,')" "blast-radius"

expect 0 "stays silent on an unrelated edit" blast-radius-guard.py \
    "$(edit_envelope 'src/app.ts' 'const x = 1')"

expect 0 "never warns about edits to its own tests" blast-radius-guard.py \
    "$(edit_envelope '.claude/hooks/test-hooks.sh' 'statements: 70,')"

# ===========================================================================
section "watch-mode-guard.py"

expect 2 "blocks the bare test script (watch by default)" watch-mode-guard.py \
    "$(bash_envelope 'npm run test')" "WATCH mode"

expect 0 "allows the one-shot form after --" watch-mode-guard.py \
    "$(bash_envelope 'npm run test -- src/a.test.ts --run')"

# npm swallows a flag that is not after `--`, forwards nothing, and the runner
# starts watch mode anyway. This typo is the likeliest way to hit the guard.
expect 2 "blocks the flag placed before -- (npm swallows it)" watch-mode-guard.py \
    "$(bash_envelope 'npm run test --run')" "WATCH mode"

# Anchoring: listing "test" must not capture every test:* sibling.
expect 0 "allows test:e2e" watch-mode-guard.py "$(bash_envelope 'npm run test:e2e')"
expect 0 "allows test:coverage" watch-mode-guard.py "$(bash_envelope 'npm run test:coverage')"
expect 0 "allows test:run" watch-mode-guard.py "$(bash_envelope 'npm run test:run')"

# ...but a sibling that genuinely hangs has to be named explicitly.
expect 2 "blocks test:ui (listed in hangs_anyway)" watch-mode-guard.py \
    "$(bash_envelope 'npm run test:ui')" "hang"

expect 2 "blocks the --ui flag" watch-mode-guard.py \
    "$(bash_envelope 'npx vitest --ui')" "hang"

expect 0 "allows the 'run' subcommand" watch-mode-guard.py \
    "$(bash_envelope 'npx vitest run src/a.test.ts')"

expect 0 "allows --watch=false" watch-mode-guard.py \
    "$(bash_envelope 'npx vitest --watch=false')"

expect 2 "blocks a bare binary call after &&" watch-mode-guard.py \
    "$(bash_envelope 'cd app && vitest')" "WATCH mode"

expect 0 "allows a MENTION of a watch invocation" watch-mode-guard.py \
    "$(bash_envelope 'echo "do not start the test script without the run flag"')"

expect 0 "ignores non-Bash tools" watch-mode-guard.py \
    "$(write_envelope 'README.md' 'npm run test')"

# ===========================================================================
section "git-safety.sh"

RUN_DIR="$GITBOX"

expect 2 "blocks the hook-bypass flag on commit" git-safety.sh \
    "$(bash_envelope "git commit $NOVERIFY -m \"fix: thing\"")" "verify"

expect 2 "blocks the hook-bypass flag on push" git-safety.sh \
    "$(bash_envelope "git push $NOVERIFY")" "verify"

# The message is stripped before matching, so documenting the flag is fine.
expect 0 "allows a commit MESSAGE that mentions the bypass flag" git-safety.sh \
    "$(bash_envelope "git commit -m \"docs: explain why $NOVERIFY is blocked\"")"

expect 0 "allows an ordinary commit" git-safety.sh \
    "$(bash_envelope 'git commit -m "feat: add the thing"')"

expect 2 "blocks a too-short commit message" git-safety.sh \
    "$(bash_envelope 'git commit -m "wip"')" "too short"

expect 0 "ignores non-git Bash commands" git-safety.sh \
    "$(bash_envelope 'npm run build')"
RUN_DIR="$ORIGIN"

# ===========================================================================
section "config-sync-guard.py -- advisory, never blocks"

expect 0 "reminds on a CSP edit" config-sync-guard.py \
    "$(edit_envelope 'csp.json' '"connect-src": "self"')" "config-sync"

expect 0 "stays silent on an unrelated file" config-sync-guard.py \
    "$(edit_envelope 'src/app.ts' 'const x = 1')"

RUN_DIR="$SANDBOX"
expect 0 "reminds when a component is missing from the manifest" config-sync-guard.py \
    "$(edit_envelope 'functions/orphan/index.ts' 'export default handler')" "manifest"

expect 0 "stays silent when it IS declared" config-sync-guard.py \
    "$(edit_envelope 'functions/declared/index.ts' 'export default handler')"
RUN_DIR="$ORIGIN"

# ===========================================================================
section "secret-scan-guard.py"

expect 2 "blocks a high-entropy assigned credential" secret-scan-guard.py \
    "$(write_envelope 'src/config.ts' 'const apiKey = "9f3Kx7QpLm2Zv8Nw4Rt6Yb1Hc5Jd0Ae"')" \
    "credential"

expect 2 "blocks a recognizable provider token" secret-scan-guard.py \
    "$(write_envelope 'src/config.ts' 'const t = "ghp_aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5"')" \
    "GitHub"

expect 2 "blocks an AWS access key id" secret-scan-guard.py \
    "$(write_envelope 'src/config.ts' 'AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE')" "AWS"

# False positives are what kill a guard like this. These must all pass.
expect 0 "allows an env-var reference" secret-scan-guard.py \
    "$(write_envelope 'src/config.ts' 'const apiKey = process.env.API_KEY')"

expect 0 "allows an obvious placeholder" secret-scan-guard.py \
    "$(write_envelope 'src/config.ts' 'const apiKey = "your-api-key-here"')"

expect 0 "allows a short non-secret value" secret-scan-guard.py \
    "$(write_envelope 'src/config.ts' 'const password = "hunter2"')"

expect 0 "allows a prose sentence assigned to a matching name" secret-scan-guard.py \
    "$(write_envelope 'src/i18n.ts' 'const password = "Please enter your password below"')"

expect 0 "allows credentials in a test file" secret-scan-guard.py \
    "$(write_envelope 'src/auth.test.ts' 'const apiKey = "9f3Kx7QpLm2Zv8Nw4Rt6Yb1Hc5Jd0Ae"')"

expect 0 "allows an example env file" secret-scan-guard.py \
    "$(write_envelope '.env.example' 'API_KEY=9f3Kx7QpLm2Zv8Nw4Rt6Yb1Hc5Jd0Ae')"

expect 0 "ignores Bash tool calls" secret-scan-guard.py \
    "$(bash_envelope 'export API_KEY=9f3Kx7QpLm2Zv8Nw4Rt6Yb1Hc5Jd0Ae')"

# ===========================================================================
section "the contract itself"

# A hook that crashes must never wedge a tool call. Exit 1, not 2.
for script in blast-radius-guard.py config-sync-guard.py watch-mode-guard.py \
              secret-scan-guard.py; do
    expect 1 "$script survives malformed JSON (non-blocking)" "$script" 'not json at all'
done

for script in git-safety.sh auto-format-code.sh; do
    out=$(printf 'not json' | "$SCRIPTS/$script" 2>&1); got=$?
    if [[ $got -eq 2 ]]; then
        echo -e "${RED}x${NC} $script must not BLOCK on malformed input"
        FAILURES+=("$script blocks on malformed input"); FAILED=$((FAILED + 1))
    else
        echo -e "${GREEN}.${NC} $script survives malformed JSON (non-blocking)"
        PASSED=$((PASSED + 1))
    fi
done

# With no config at all, every guard must allow.
REAL_CONFIG="$GUARDRAILS_CONFIG"
export GUARDRAILS_CONFIG="$SANDBOX/does-not-exist.json"
expect 0 "blast-radius allows everything with no config" blast-radius-guard.py \
    "$(bash_envelope 'testcli db push')"
expect 0 "watch-mode allows everything with no config" watch-mode-guard.py \
    "$(bash_envelope 'npm run test')"
export GUARDRAILS_CONFIG="$REAL_CONFIG"

# ===========================================================================
echo
echo "==============================="
if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}$PASSED passed, 0 failed${NC}"
    exit 0
fi
echo -e "${RED}$PASSED passed, $FAILED FAILED${NC}"
for failure in "${FAILURES[@]}"; do echo "  - $failure"; done
exit 1
