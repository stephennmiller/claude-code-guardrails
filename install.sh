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

# Guards that SHIPPED in an earlier version under a different name. A merge
# preserves whatever is already wired, which is right for a user's own hooks and
# wrong for one of ours that has been renamed: the stale entry keeps pointing at
# the old file, which is still on disk, so an upgraded repo runs BOTH the old
# guard and its replacement. Listed explicitly rather than inferred -- a user may
# legitimately add their own script to hooks-scripts/, and guessing would delete
# it.
RETIRED_GUARDS="git-safety.sh"

# Provenance, so a reinstall can tell "the user edited this" from "this is an
# older copy of ours." Comparing the installed file against the CURRENT shipped
# one cannot distinguish those: both just differ. So record what we wrote, and
# on the next run only refresh a file that still matches that record.
#
# guardrails.config.json is deliberately NOT managed this way. Step 1 of the
# closing instructions tells you to gut it, so it is yours from that moment and
# only --force replaces it.
MANIFEST="$DEST/.guardrails-manifest"
MANIFEST_NEW="$(mktemp)"

hash_file() {
    python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null
}
manifest_hash() {
    [[ -f "$MANIFEST" ]] || return 0
    awk -F'\t' -v k="$1" '$1 == k { print $2 }' "$MANIFEST"
}
manifest_record() { printf '%s\t%s\n' "$1" "$2" >> "$MANIFEST_NEW"; }

# sync_file <source> <dest> <manifest key> <label>
sync_file() {
    local src="$1" dst="$2" key="$3" label="$4"
    local shipped recorded current
    shipped="$(hash_file "$src")"

    if [[ ! -f "$dst" ]]; then
        say "-> $label"
        run cp "$src" "$dst"
        manifest_record "$key" "$shipped"
        return
    fi
    if [[ $FORCE -eq 1 ]]; then
        say "-> $label  (--force, replaced)"
        run cp "$src" "$dst"
        manifest_record "$key" "$shipped"
        return
    fi

    current="$(hash_file "$dst")"
    if [[ "$current" == "$shipped" ]]; then
        say "-- $label already current"
        manifest_record "$key" "$shipped"
        return
    fi

    recorded="$(manifest_hash "$key")"
    if [[ -n "$recorded" && "$current" == "$recorded" ]]; then
        say "-> $label  (updated -- unmodified since install)"
        run cp "$src" "$dst"
        manifest_record "$key" "$shipped"
    else
        # Edited locally, or installed before the manifest existed. Unknown
        # provenance is treated as edited: never overwrite someone's work to
        # deliver a newer default.
        say "-- $label modified locally, keeping it (--force to replace)"
        [[ -n "$recorded" ]] && manifest_record "$key" "$recorded"
    fi
}

finalize_manifest() {
    if [[ $DRY_RUN -eq 1 ]]; then
        rm -f "$MANIFEST_NEW"
        return 0
    fi
    # Carry forward entries for files this run did not touch.
    if [[ -f "$MANIFEST" ]]; then
        while IFS="$(printf '\t')" read -r k h; do
            [[ -n "$k" ]] || continue
            if ! awk -F'\t' -v k="$k" '$1 == k { f = 1 } END { exit !f }' "$MANIFEST_NEW"; then
                printf '%s\t%s\n' "$k" "$h" >> "$MANIFEST_NEW"
            fi
        done < "$MANIFEST"
    fi
    LC_ALL=C sort -o "$MANIFEST_NEW" "$MANIFEST_NEW"
    mv "$MANIFEST_NEW" "$MANIFEST"
}

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

# --- 3. the CLAUDE.md template ---------------------------------------------
# Shipped, not just linked from the README. Step 2 of the closing instructions
# tells you to start from your CLAUDE.md's "don't run this" list; a user who has
# never written one needs the template in the repo, not a URL they will not open.
# Not named CLAUDE.md: that would be auto-loaded as real project memory.
say "   what to write in a CLAUDE.md, and what to leave out"
sync_file "$SRC/templates/CLAUDE.md.template" "$DEST/CLAUDE.md.template" \
    "CLAUDE.md.template" ".claude/CLAUDE.md.template"

# --- 4. slash commands -----------------------------------------------------
say "-> .claude/commands/       (4 commands; yours are kept)"
run mkdir -p "$DEST/commands"
for cmd in "$SRC/.claude/commands/"*.md; do
    name="$(basename "$cmd")"
    sync_file "$cmd" "$DEST/commands/$name" "commands/$name" "   commands/$name"
done

# --- 5. merge settings.json ------------------------------------------------
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

# permissions.deny is merged as a UNION, and only ever grows. Entries the
# target already has are untouched, and `allow` is never read or written:
# quietly widening what an agent may do would be the opposite of the point.
# Without this the shipped deny list is copied into the repo and never
# reaches settings.json -- present on disk, enforcing nothing.
source_deny = (source.get("permissions") or {}).get("deny") or []
if source_deny:
    permissions = target.setdefault("permissions", {})
    existing_deny = permissions.setdefault("deny", [])
    fresh = [rule for rule in source_deny if rule not in existing_deny]
    existing_deny.extend(fresh)
    if fresh:
        print(f"   {len(fresh)} deny rule(s) added: {', '.join(fresh)}")
    else:
        print("   deny rules already present")

retired = [name for name in (sys.argv[4] if len(sys.argv) > 4 else "").split() if name]
pruned = 0
if retired:
    for event, groups in list(target["hooks"].items()):
        for group in list(groups):
            keep = [
                h for h in group.get("hooks", [])
                if not any(f"hooks-scripts/{name}" in (h.get("command") or "")
                           for name in retired)
            ]
            pruned += len(group.get("hooks", [])) - len(keep)
            group["hooks"] = keep
            if not keep:
                groups.remove(group)
        if not groups:
            del target["hooks"][event]
if pruned:
    print(f"   {pruned} stale hook(s) pruned: {', '.join(retired)}")

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
if MERGE_OUT="$(python3 -c "$MERGE_SCRIPT" "$DEST/settings.json" "$SRC/.claude/settings.json" "$DRY_RUN" "$RETIRED_GUARDS")"; then
    [[ -n "$MERGE_OUT" ]] && out "$MERGE_OUT"
else
    [[ -n "$MERGE_OUT" ]] && out "$MERGE_OUT"
    die "settings.json merge failed"
fi

# The file too, not just the wiring: left on disk it is a loaded gun for anyone
# who re-adds the entry by hand or copies settings.json from an older repo.
for retired in $RETIRED_GUARDS; do
    if [[ -f "$DEST/hooks-scripts/$retired" ]]; then
        say "-- removing retired guard hooks-scripts/$retired"
        run rm -f "$DEST/hooks-scripts/$retired"
    fi
done

finalize_manifest

# --- 6. verify -------------------------------------------------------------
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
     lines are documentation until something enforces them. No such list yet?
     .claude/CLAUDE.md.template is the shape of one, and says which sections
     become which rules.

  3. Wire the harness into pre-push or CI:
       bash .claude/hooks/test-hooks.sh

  4. Read docs/PATTERNS.md before writing a rule. Most of the sharp edges
     (matcher gaps, quote stripping, exemptions that fail open) are there.

Re-running this is safe: the template and commands are refreshed only while
they still match what was installed, and your edits are kept. The one
exception is --force, which replaces guardrails.config.json, the template and
the commands outright -- including the rules you deleted in step 1. Commit
before using it.
EOF
} || true
