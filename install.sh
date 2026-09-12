#!/usr/bin/env bash
# Install the guardrail hooks into a target repo.
#
#   ./install.sh /path/to/repo [--dry-run] [--force]
#
# Copies hooks-scripts/, hooks/ and guardrails.config.json into <repo>/.claude/,
# then MERGES the hook wiring into <repo>/.claude/settings.json, preserving any
# hooks already configured there.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-}"
DRY_RUN=0
FORCE=0
for arg in "${@:2}"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --force)   FORCE=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# Tolerate a closed stdout. This script's output is routinely piped to `head`
# or `grep -q`, which exit on the first match and close the pipe; the next write
# then gets EPIPE and, under `set -e`, aborts an install that had in fact
# succeeded. Whether that happens is a race, so it shows up as a flaky failure.
trap '' PIPE

die() { echo "error: $*" >&2; exit 1; }
say() { echo "  $*" 2>/dev/null || true; }
out() { echo "$*" 2>/dev/null || true; }

[[ -n "$TARGET" ]] || die "usage: ./install.sh /path/to/repo [--dry-run] [--force]"
[[ -d "$TARGET" ]] || die "not a directory: $TARGET"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v jq      >/dev/null 2>&1 || die "jq is required"

TARGET="$(cd "$TARGET" && pwd)"
DEST="$TARGET/.claude"
[[ "$DEST" != "$SRC/.claude" ]] || die "refusing to install into myself"

out "Installing guardrails into $TARGET"
[[ $DRY_RUN -eq 1 ]] && out "(dry run -- nothing will be written)"

run() { [[ $DRY_RUN -eq 1 ]] || "$@"; }

# --- 1. scripts + harness --------------------------------------------------
say "-> .claude/hooks-scripts/  (6 guards + engine)"
run mkdir -p "$DEST/hooks-scripts"
# Named globs, not `*`: a stray __pycache__/ directory makes a plain `cp`
# fail, and under `set -e` that aborts the install before settings.json is
# merged -- leaving a half-installed repo.
for f in "$SRC/.claude/hooks-scripts/"*.py "$SRC/.claude/hooks-scripts/"*.sh; do
    [[ -f "$f" ]] && run cp "$f" "$DEST/hooks-scripts/"
done
run chmod +x "$DEST/hooks-scripts/"*.py "$DEST/hooks-scripts/"*.sh

say "-> .claude/hooks/          (test harness + fixtures)"
run mkdir -p "$DEST/hooks/fixtures"
run cp "$SRC/.claude/hooks/test-hooks.sh" "$DEST/hooks/"
run cp "$SRC/.claude/hooks/fixtures/guardrails.config.json" "$DEST/hooks/fixtures/"
run chmod +x "$DEST/hooks/test-hooks.sh"

# --- 2. config (never clobber an existing one without --force) -------------
if [[ -f "$DEST/guardrails.config.json" && $FORCE -eq 0 ]]; then
    say "-- .claude/guardrails.config.json exists, keeping it (--force to replace)"
else
    say "-> .claude/guardrails.config.json"
    run cp "$SRC/.claude/guardrails.config.json" "$DEST/"
fi

# --- 3. slash commands -----------------------------------------------------
say "-> .claude/commands/       (4 commands, skipping any that exist)"
run mkdir -p "$DEST/commands"
for cmd in "$SRC/.claude/commands/"*.md; do
    name="$(basename "$cmd")"
    if [[ -f "$DEST/commands/$name" && $FORCE -eq 0 ]]; then
        say "   -- $name exists, skipped"
    else
        run cp "$cmd" "$DEST/commands/$name"
    fi
done

# --- 4. merge settings.json ------------------------------------------------
# Deep-merged in Python rather than with `jq '. * .'`: jq's object-merge
# REPLACES arrays, so a target that already has a PreToolUse entry would lose it.
say "-> .claude/settings.json   (merging, existing hooks preserved)"
MERGE_SCRIPT="$(cat <<'PY'
import json, sys
from pathlib import Path

target_path, source_path, dry = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3] == "1"

target = {}
if target_path.is_file():
    try:
        target = json.loads(target_path.read_text(encoding="utf-8"))
    except ValueError:
        print("   !! existing settings.json is not valid JSON -- not touching it")
        sys.exit(1)

source = json.loads(source_path.read_text(encoding="utf-8"))
target.setdefault("hooks", {})

added = skipped = 0
for event, groups in source.get("hooks", {}).items():
    existing = target["hooks"].setdefault(event, [])
    for group in groups:
        commands = {
            h.get("command") for g in existing
            if g.get("matcher") == group.get("matcher")
            for h in g.get("hooks", [])
        }
        new = [h for h in group.get("hooks", []) if h.get("command") not in commands]
        skipped += len(group.get("hooks", [])) - len(new)
        if not new:
            continue
        slot = next(
            (g for g in existing if g.get("matcher") == group.get("matcher")), None
        )
        if slot is None:
            slot = {k: v for k, v in group.items() if k != "hooks"}
            slot["hooks"] = []
            existing.append(slot)
        slot["hooks"].extend(new)
        added += len(new)

print(f"   {added} hook(s) added, {skipped} already present")
if not dry:
    target_path.parent.mkdir(parents=True, exist_ok=True)
    target_path.write_text(json.dumps(target, indent=2) + "\n", encoding="utf-8")
PY
)"
# Captured rather than written straight to stdout: if the caller piped us into
# something that exits early, a direct write raises BrokenPipeError inside
# Python and the merge reports a failure that never happened.
if MERGE_OUT="$(python3 -c "$MERGE_SCRIPT" "$DEST/settings.json" "$SRC/.claude/settings.json" "$DRY_RUN")"; then
    [[ -n "$MERGE_OUT" ]] && out "$MERGE_OUT"
else
    [[ -n "$MERGE_OUT" ]] && out "$MERGE_OUT"
    die "settings.json merge failed"
fi

# --- 5. verify -------------------------------------------------------------
if [[ $DRY_RUN -eq 0 ]]; then
    out ""
    out "Verifying..."
    if bash "$DEST/hooks/test-hooks.sh" >/tmp/guardrails-verify.$$ 2>&1; then
        say "$(tail -1 /tmp/guardrails-verify.$$)"
    else
        echo "  harness FAILED -- see below" >&2
        cat /tmp/guardrails-verify.$$ >&2
        rm -f /tmp/guardrails-verify.$$
        exit 1
    fi
    rm -f /tmp/guardrails-verify.$$
fi

{ cat 2>/dev/null <<'EOF'

Done. Next, in order:

  1. Open .claude/guardrails.config.json and DELETE every rule that does not
     apply to you. The shipped rules are illustrative, not a starting set.
     A guard that fires on correct code gets the whole file disabled.

  2. Add your own. Start from your CLAUDE.md's "don't run this" list -- those
     lines are documentation until something enforces them.

  3. Wire the harness into pre-push or CI:
       bash .claude/hooks/test-hooks.sh

  4. Read docs/PATTERNS.md before writing a rule. Most of the sharp edges
     (matcher gaps, quote stripping, exemptions that fail open) are there.
EOF
} || true
