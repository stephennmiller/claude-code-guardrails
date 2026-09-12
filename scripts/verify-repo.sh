#!/usr/bin/env bash
# Repo self-checks that the hook harness does not cover.
#
# test-hooks.sh proves the guards behave. This proves the things AROUND them
# are consistent: that the docs describe files which exist, that every rule in
# config actually compiles, and that every guard is wired to a matcher.
#
# All three failure modes here are silent. A rule with a bad regex is dropped
# with a warning nobody reads. A guard missing from settings.json protects
# nothing. A doc naming a moved file sends the next reader somewhere useless.
#
# Runs locally: bash scripts/verify-repo.sh

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
FAILED=0
ok()   { echo -e "  ${GREEN}.${NC} $*"; }
bad()  { echo -e "  ${RED}x${NC} $*"; FAILED=1; }

# Filenames the docs cite as EXAMPLES of a user's repo, not files of this one.
# Keep this list short and explicit: the alternative is loosening the check
# until it stops catching real broken references.
ILLUSTRATIVE="package.json config.toml vercel.json csp.json"

echo "== docs name files that exist =="
# Backticked paths in markdown, minus prose fragments that only look like paths.
while read -r ref; do
    [ -e "$ref" ] && continue
    case " $ILLUSTRATIVE " in *" $ref "*) continue ;; esac
    # A bare filename is fine if it exists anywhere in the tree.
    if [[ "$ref" != */* ]] && find . -name "$ref" -not -path './.git/*' | grep -q .; then
        continue
    fi
    bad "doc references a missing path: $ref"
done < <(grep -rhoE '`[A-Za-z0-9_./-]+\.(sh|py|json|md|yml|template)`' -- *.md docs/*.md 2>/dev/null \
         | tr -d '`' | sort -u)
[ $FAILED -eq 0 ] && ok "every referenced path resolves"

echo
echo "== every regex in config compiles =="
python3 - <<'PY' || FAILED=1
import json, re, sys
bad = 0
for path in (".claude/guardrails.config.json", ".claude/hooks/fixtures/guardrails.config.json"):
    def walk(node):
        global bad
        if isinstance(node, dict):
            for key, value in node.items():
                if key in ("pattern", "path", "content", "matches", "capture_name_from") \
                   and isinstance(value, str):
                    try:
                        re.compile(value)
                    except re.error as exc:
                        print(f"  x {path} -> {key}: {value!r}: {exc}"); bad += 1
                else:
                    walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)
    walk(json.load(open(path)))
# A rule whose regex does not compile is DROPPED at runtime, not reported --
# the guard keeps running and silently stops enforcing that rule.
print("  . all rule regexes compile" if not bad else f"  x {bad} rule(s) will be silently dropped")
sys.exit(1 if bad else 0)
PY

echo
echo "== every guard is wired, and every wired path exists =="
python3 - <<'PY' || FAILED=1
import json, pathlib, sys
settings = json.load(open(".claude/settings.json"))
wired = set()
for groups in settings.get("hooks", {}).values():
    for group in groups:
        for hook in group.get("hooks", []):
            cmd = hook.get("command", "").strip('"')
            name = cmd.rsplit("/", 1)[-1]
            if name:
                wired.add(name)
                path = pathlib.Path(".claude/hooks-scripts") / name
                if not path.exists():
                    print(f"  x settings.json wires a missing script: {name}")
                    sys.exit(1)

on_disk = {
    p.name for p in pathlib.Path(".claude/hooks-scripts").iterdir()
    if p.suffix in (".py", ".sh") and not p.name.startswith("_")
}
orphans = on_disk - wired
if orphans:
    # A guard on disk but absent from settings.json runs for nothing. This is
    # the same class as a matcher gap: present, plausible, enforcing nothing.
    print(f"  x guard(s) not wired to any matcher: {', '.join(sorted(orphans))}")
    sys.exit(1)
print(f"  . all {len(on_disk)} guards wired, all wired paths exist")
PY

echo
echo "== blast-radius guard is registered under BOTH matchers =="
python3 - <<'PY' || FAILED=1
import json, sys
settings = json.load(open(".claude/settings.json"))
matchers = [
    group.get("matcher", "")
    for group in settings["hooks"].get("PreToolUse", [])
    for hook in group.get("hooks", [])
    if "blast-radius-guard" in hook.get("command", "")
]
# PATTERNS.md #1: a file-subject guard registered only for Write|Edit does
# nothing about `sed -i` through Bash. This repo makes that argument, so it
# should fail its own CI if it stops following it.
has_bash = any("Bash" in m for m in matchers)
has_edit = any("Edit" in m or "Write" in m for m in matchers)
if has_bash and has_edit:
    print("  . registered under Bash and Write|Edit")
else:
    print(f"  x matcher gap: blast-radius-guard is only under {matchers}")
    sys.exit(1)
PY

echo
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}verify-repo: all checks passed${NC}"; exit 0
fi
echo -e "${RED}verify-repo: FAILED${NC}"; exit 1
