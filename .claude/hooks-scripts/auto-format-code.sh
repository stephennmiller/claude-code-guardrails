#!/bin/bash
# Auto-format after an edit (PostToolUse hook for Write|Edit|MultiEdit).
#
# Formatting on PostToolUse rather than at commit time keeps the model's mental
# model of the file in sync with what is on disk. If formatting only happens at
# commit, every subsequent Edit is computed against stale text and string
# matches start failing for no visible reason.
#
# EVERY FORMATTER CALL IS BEST-EFFORT (`|| true`). A formatter that is missing,
# or that fails on a file mid-edit, must never fail the tool call -- the edit
# already succeeded, and reporting a formatting failure as a tool error sends
# the agent chasing a problem that does not exist.
#
# Formatters are auto-detected. Project-local binaries win over global ones so
# the repo's pinned version is what runs.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

json_input=$(cat)
tool_name=$(echo "$json_input" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
file_path=$(echo "$json_input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || echo "")

[[ "$tool_name" =~ ^(Write|Edit|MultiEdit)$ ]] || exit 0
[[ -n "$file_path" ]] || exit 0
[[ -f "$file_path" ]] || exit 0

PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# Run a project-local binary if present, else a global one, else nothing.
run_fmt() {
    local bin="$1"; shift
    if [[ -x "node_modules/.bin/$bin" ]]; then
        "node_modules/.bin/$bin" "$@" >/dev/null 2>&1 || true
    elif command -v "$bin" >/dev/null 2>&1; then
        "$bin" "$@" >/dev/null 2>&1 || true
    fi
}

case "${file_path##*.}" in
    ts|tsx|js|jsx|mjs|cjs)
        # Biome does format + safe lint autofix in one pass; Prettier is the
        # fallback for repos that have not migrated.
        if [[ -x "node_modules/.bin/biome" ]]; then
            run_fmt biome check --write --no-errors-on-unmatched "$file_path"
        else
            run_fmt prettier --write "$file_path"
        fi
        run_fmt eslint --fix --no-error-on-unmatched-pattern "$file_path"
        ;;
    py)
        if command -v ruff >/dev/null 2>&1; then
            ruff format "$file_path" >/dev/null 2>&1 || true
            ruff check --fix "$file_path" >/dev/null 2>&1 || true
        else
            run_fmt black "$file_path"
            run_fmt isort "$file_path"
        fi
        ;;
    go)   run_fmt gofmt -w "$file_path" ;;
    rs)   run_fmt rustfmt "$file_path" ;;
    rb)   run_fmt rubocop -a "$file_path" ;;
    sh|bash) run_fmt shfmt -w "$file_path" ;;
    json)
        # Only rewrite when jq parses it: a half-edited JSON file must be left
        # exactly as the agent wrote it, so the error is visible.
        if command -v jq >/dev/null 2>&1 && jq empty "$file_path" >/dev/null 2>&1; then
            tmp="${file_path}.guardrails.tmp"
            if jq --indent 2 . "$file_path" > "$tmp" 2>/dev/null; then
                mv "$tmp" "$file_path"
            else
                rm -f "$tmp"
            fi
        fi
        ;;
esac

exit 0
