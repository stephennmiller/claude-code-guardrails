#!/bin/bash
# Git safety guard (PreToolUse hook for Bash).
#
# Blocks three things agents do by reflex and humans rarely mean:
#   1. --no-verify on commit/push/merge/rebase -- skipping the pre-commit hooks
#      that are often the only local gate on secrets and lint.
#   2. committing directly to a protected branch.
#   3. force-pushing to a protected branch.
#
# THE --no-verify RULE IS THE INTERESTING ONE. This is a Claude Code hook, not
# a git hook, so it constrains the AGENT only -- a human contributor running
# `git commit --no-verify` in their own terminal is unaffected. That asymmetry
# is the point: the escape hatch stays open for the person who can judge when
# to use it, and closes for the process that reaches for it whenever a gate is
# inconvenient.
#
# Contract:
#   - reads the PreToolUse JSON envelope on stdin
#   - exit 0 = allow, exit 2 = block
#   - anything unexpected falls through to allow
#
# Config: .claude/guardrails.config.json -> "git_safety"

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

json_input=$(cat)
tool_name=$(echo "$json_input" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
command=$(echo "$json_input" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

[[ "$tool_name" == "Bash" ]] || exit 0
[[ -n "$command" ]] || exit 0
[[ "$command" =~ (^|[[:space:];&|])git[[:space:]] ]] || exit 0

# --- config ----------------------------------------------------------------
CONFIG="${GUARDRAILS_CONFIG:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/.claude/guardrails.config.json}"
cfg() {
    # cfg <jq-path> <default>
    local value=""
    if [[ -f "$CONFIG" ]]; then
        value=$(jq -r "$1 // empty" "$CONFIG" 2>/dev/null || echo "")
    fi
    [[ -n "$value" ]] && echo "$value" || echo "$2"
}

protected=$(cfg '.git_safety.protected_branches | join("|")' 'main|master')
max_staged=$(cfg '.git_safety.max_staged_files' '25')
commit_types=$(cfg '.git_safety.conventional_commit_types | join("|")' \
    'feat|fix|docs|style|refactor|test|chore|perf|build|ci|revert')

current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

# --- 1. --no-verify --------------------------------------------------------
# Strip everything from " -m " onward first, so a commit message that MENTIONS
# --no-verify (a doc change describing this very hook) does not false-positive.
pre_message_args="${command%% -m *}"
if [[ "$pre_message_args" =~ git[[:space:]]+(commit|push|merge|rebase) ]] && \
   [[ "$pre_message_args" =~ [[:space:]]--no-verify([[:space:]]|$) ]]; then
    cat >&2 << 'EOF'
Blocked: --no-verify skips the pre-commit gates (lint-staged, secret scan).

Fix the underlying failure rather than bypassing the gate. If the user has
explicitly asked you to skip, confirm with them and re-run.
EOF
    exit 2
fi

# --- 2. direct commit to a protected branch --------------------------------
if [[ "$command" =~ git[[:space:]]+commit ]] && [[ "$current_branch" =~ ^($protected)$ ]]; then
    echo "Blocked: direct commits to '$current_branch' are not allowed." >&2
    echo "  Create a branch first:  git checkout -b feat/your-change" >&2
    exit 2
fi

# --- 3. force push to a protected branch -----------------------------------
if [[ "$command" =~ git[[:space:]]+push ]] && \
   [[ "$command" =~ --force([[:space:]]|=|$)|--force-with-lease|[[:space:]]-f([[:space:]]|$) ]] && \
   [[ "$command" =~ ($protected) ]]; then
    echo "Blocked: force-pushing to a protected branch rewrites shared history." >&2
    exit 2
fi

# --- advisory: commit message shape ----------------------------------------
if [[ "$command" =~ git[[:space:]]+commit.*-m ]]; then
    message=""
    if [[ "$command" =~ -m[[:space:]]+\"([^\"]+)\" ]]; then
        message="${BASH_REMATCH[1]}"
    elif [[ "$command" =~ -m[[:space:]]+\'([^\']+)\' ]]; then
        message="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$message" ]] && [[ ${#message} -lt 10 ]]; then
        echo "Blocked: commit message is too short to be useful (<10 chars)." >&2
        exit 2
    fi

    if [[ -n "$message" ]] && [[ ! "$message" =~ ^($commit_types)(\(.+\))?!?: ]]; then
        echo "Note: message does not match Conventional Commits" >&2
        echo "  expected one of: $commit_types" >&2
        # Advisory only -- some repos do not enforce this.
    fi
fi

# --- advisory: oversized commit --------------------------------------------
if [[ "$command" =~ git[[:space:]]+commit ]] && [[ ! "$command" =~ --amend ]]; then
    staged_count=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${staged_count:-0}" -gt "$max_staged" ]]; then
        echo "Note: large commit ($staged_count files, soft limit $max_staged)." >&2
        echo "  Consider splitting into focused commits." >&2
    fi
fi

exit 0
