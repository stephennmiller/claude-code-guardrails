#!/usr/bin/env python3
"""
High-blast-radius guard (PreToolUse hook: Bash + Edit/Write/MultiEdit).

Most CLAUDE.md files keep some version of a "don't run this without asking"
list. It is documentation with no enforcement -- the agent reads it, then runs
the command anyway three hours later. This hook makes that table executable.

TWO SEVERITIES, DELIBERATELY:

  BASH  -> BLOCK (exit 2). Irreversible, or destroys signal: overwrites a
           generated file, writes a remote database, re-baselines snapshots,
           moves a ratchet. Override by prefixing the command with
           ALLOW_BLAST_RADIUS=1, which is named in the block message -- the
           point is to force a deliberate second call, not to make the action
           impossible.

  EDIT  -> ADVISORY (stderr, exit 0). An Edit tool call has nowhere to carry an
           env override, so blocking would be a wall with no escape hatch.
           Everything on the edit list is plain text and recoverable from git,
           so a warning in the model's context is the right weight.

KNOWN AND ACCEPTED GAP: `sed -i` on a watched file via Bash sails past the edit
rules. This is a speed bump against agent slips, not an adversarial sandbox. If
you need the latter, use permissions.deny, not a hook.

Rules live in .claude/guardrails.config.json under "blast_radius".
"""
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable, NamedTuple, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _guardrails import (  # noqa: E402
    EDIT_TOOLS,
    changed_text,
    compile_optional,
    get_predicate,
    load_config,
    normalize,
    predicate,
    read_envelope,
    rule_flags,
    run,
)

CONFIG = load_config("blast_radius")
OVERRIDE_ENV = CONFIG.get("override_env", "ALLOW_BLAST_RADIUS")

# A directory is a checkout root if it carries all of these. Cheap, and it
# avoids treating an unrelated look-alike elsewhere on disk as ours.
REPO_MARKERS = tuple(CONFIG.get("repo_markers", ["package.json", ".claude"]))

# `>>?` so an APPEND redirect is caught too. With a bare `>`, the first angle
# bracket of `>>` matches and the capture group swallows the second one, so
# `... >> generated.ts` resolves to Path(">") -- no match, the exemption fires,
# and the append onto the real file goes through. `>` is excluded from the
# target character class for the same reason.
REDIRECT_TARGET = re.compile(r">>?\s*[\"']?([^\s\"'|;&>]+)")


def _is_repo_file(path: Path, suffix: tuple[str, ...]) -> bool:
    """True when `path` is SOME checkout's copy of the protected file.

    Anchoring to one absolute path breaks across git worktrees: cwd is the
    worktree root while the hook may be the main checkout's copy, so the
    comparison fails and the exemption waves through a real clobber. Instead,
    match the trailing path segments AND require a repo root above them.
    """
    if len(suffix) == 0 or path.parts[-len(suffix):] != suffix:
        return False
    root = path
    for _ in suffix:
        root = root.parent
    return all((root / marker).exists() for marker in REPO_MARKERS)


def _redirects_onto(command: str, protected: str) -> bool:
    """True when a redirect in `command` targets this repo's `protected` file.

    Resolves each target and asks whether it IS a checkout's copy, so
    `src/types/x.ts`, `./src/...`, an absolute path and a worktree copy all
    match -- while `/tmp/backup/src/types/x.ts`, which merely ends with the same
    segments and has no repo root above it, does not.
    """
    suffix = tuple(part for part in protected.split("/") if part)
    for target in REDIRECT_TARGET.findall(command):
        try:
            candidate = Path(target)
            if not candidate.is_absolute():
                candidate = Path.cwd() / candidate
            if _is_repo_file(candidate.resolve(strict=False), suffix):
                return True
        except (OSError, ValueError):
            # An unresolvable path is not a match.
            continue
    return False


CHECKOUT = re.compile(r"(?:^|[\s;&|])git\s+checkout\s+(?P<args>[^;&|]*)")
NEW_BRANCH_FLAG = re.compile(r"^-[bB]$")
FORCE_FLAG = re.compile(r"^(-f|--force)$")


def _is_ref(token: str) -> bool:
    """Does this name resolve to a commit in the repo we are standing in?"""
    try:
        done = subprocess.run(
            ["git", "rev-parse", "--verify", "--quiet", f"{token}^{{commit}}"],
            capture_output=True, text=True, timeout=5,
        )
        return done.returncode == 0
    except Exception:
        return False


@predicate("git_checkout_cannot_lose_work")
def _checkout_cannot_lose_work(raw_command: str) -> bool:
    """True when `git checkout ...` moves HEAD rather than overwriting files.

    Regex cannot answer this: `git checkout main` and `git checkout main.py`
    differ only in what the REPOSITORY says the word means. So ask git, in its
    own resolution order -- a name that resolves to a commit is a branch switch,
    which git refuses rather than performs when it would lose changes. A name
    that does not resolve but exists on disk is a pathspec, and that silently
    overwrites the working tree with no reflog and nothing to recover from.

    Reads the RAW command, per PATTERNS.md section 3. An exemption that read
    normalized text could have its own evidence stripped out from under it and
    would then wave the dangerous form straight through.

    Deliberately NOT exempt, whatever the arguments resolve to:
      `--`      an explicit pathspec separator -- the user has already said
                "these are files"
      -f        discards local modifications even on an ordinary branch switch
    A name that is neither a ref nor a path IS exempt: git errors out, which is
    harmless. The residual false negative is a branch and a file sharing a name,
    where git itself prefers the branch -- so agreeing with git is correct.
    """
    found = CHECKOUT.search(raw_command)
    if not found:
        # The rule matched something this predicate cannot parse. Do not exempt.
        return False

    tokens = found.group("args").split()
    if any(tok == "--" for tok in tokens):
        return False
    if any(FORCE_FLAG.match(tok) for tok in tokens):
        return False

    skip_next = False
    for tok in tokens:
        if skip_next:
            skip_next = False
            continue
        if NEW_BRANCH_FLAG.match(tok):
            # The name after -b is a branch being CREATED; it need not exist.
            skip_next = True
            continue
        if tok.startswith("-"):
            continue
        if _is_ref(tok):
            continue
        if Path(tok).exists():
            return False
    return True


class BashRule(NamedTuple):
    name: str
    pattern: re.Pattern
    message: str
    # Scan the RAW command rather than the normalized one. Only for rules whose
    # trigger legitimately lives inside a quoted string or heredoc body: a
    # hand-authored release commit's giveaway IS its message text, so the very
    # normalization that prevents false positives elsewhere would blind it.
    scan_raw: bool = False
    # Carve-out for a documented safe variant: the rule does NOT fire when
    # `exempt_matches` matches, unless the command also redirects onto
    # `exempt_unless_redirects_to`.
    #
    # Always evaluated against the RAW command. Against the normalized one, a
    # quoted redirect target (`> "src/types/x.ts"`) is erased before this runs,
    # the clobber check finds nothing, and the exemption waves the dangerous
    # write straight through. Exemptions must fail CLOSED, so they only ever
    # look at text that cannot have been stripped.
    exempt_matches: Optional[re.Pattern] = None
    exempt_unless_redirects_to: Optional[str] = None
    # Named carve-out from the predicate registry, for what regex cannot decide.
    # "Is this argument a branch or a file?" is answered by the repository, not
    # by the shape of the string. Config references it by name.
    exempt_predicate: Optional[Callable[[str], bool]] = None

    def exempt(self, raw_command: str) -> bool:
        if self.exempt_predicate is not None and self.exempt_predicate(raw_command):
            return True
        if self.exempt_matches is None:
            return False
        if not self.exempt_matches.search(raw_command):
            return False
        if self.exempt_unless_redirects_to and _redirects_onto(
            raw_command, self.exempt_unless_redirects_to
        ):
            return False
        return True


class EditRule(NamedTuple):
    """Fires when `path` matches the edited file and, if `content` is not None,
    `content` matches the changed text. No scan_raw/exempt analogue: an Edit
    envelope carries a path and a diff, not a shell string, so there is nothing
    to normalize and nothing an override could ride in on."""

    name: str
    path: re.Pattern
    content: Optional[re.Pattern]
    message: str


def _bash_rules() -> list[BashRule]:
    rules = []
    for raw in CONFIG.get("bash_rules", []) or []:
        pattern = compile_optional(raw.get("pattern"), rule_flags(raw))
        if pattern is None:
            continue
        exempt = raw.get("exempt") or {}
        rules.append(
            BashRule(
                name=raw.get("name", "unnamed rule"),
                pattern=pattern,
                message=raw.get("message", ""),
                scan_raw=bool(raw.get("scan_raw")),
                exempt_matches=compile_optional(exempt.get("matches")),
                exempt_unless_redirects_to=exempt.get("unless_redirects_to"),
                exempt_predicate=get_predicate(exempt.get("predicate")),
            )
        )
    return rules


def _edit_rules() -> list[EditRule]:
    rules = []
    for raw in CONFIG.get("edit_rules", []) or []:
        path = compile_optional(raw.get("path"), rule_flags(raw))
        if path is None:
            continue
        rules.append(
            EditRule(
                name=raw.get("name", "unnamed rule"),
                path=path,
                content=compile_optional(raw.get("content"), rule_flags(raw)),
                message=raw.get("message", ""),
            )
        )
    return rules


def check_bash(command: str) -> int:
    if not command:
        return 0

    scan = normalize(command)

    # An explicit override in the COMMAND means the user already decided.
    #
    # Checked against the NORMALIZED command, not the raw one: `\b` sees a word
    # boundary at a quote, so `echo "ALLOW_BLAST_RADIUS=1"; <dangerous>` would
    # read as an override and disable every rule. A mention is not a decision.
    #
    # Deliberately NOT os.environ: an exported ALLOW_BLAST_RADIUS=1 in a shell
    # profile would silently disable every rule for the whole session, invisibly
    # and permanently. The override must be written into the command itself.
    if re.search(rf"\b{re.escape(OVERRIDE_ENV)}=1\b", scan):
        return 0

    for rule in _bash_rules():
        target = command if rule.scan_raw else scan
        if not rule.pattern.search(target):
            continue
        if rule.exempt(command):
            continue

        print(f"Blocked: {rule.name} -- high blast radius.\n", file=sys.stderr)
        print(f"  {rule.message}\n", file=sys.stderr)
        print(
            "If this is genuinely what you want, confirm with the user first,"
            f" then re-run prefixed with {OVERRIDE_ENV}=1.",
            file=sys.stderr,
        )
        return 2

    return 0


def check_edit(tool_name: str, tool_input: dict) -> int:
    file_path = tool_input.get("file_path", "")
    if not file_path:
        return 0

    # Never warn about edits to the guard itself or its tests.
    if "blast-radius-guard" in file_path or "test-hooks" in file_path:
        return 0

    text = changed_text(tool_name, tool_input)

    fired = [
        rule
        for rule in _edit_rules()
        if rule.path.search(file_path)
        and (rule.content is None or rule.content.search(text))
    ]
    if not fired:
        return 0

    print(f"[blast-radius] {Path(file_path).name} touches a protected surface:",
          file=sys.stderr)
    for rule in fired:
        print(f"\n- {rule.name}:", file=sys.stderr)
        print(f"  {rule.message}", file=sys.stderr)

    # Advisory: recoverable from git, and an Edit call can't carry an override.
    return 0


def main() -> int:
    tool_name, tool_input = read_envelope()
    if tool_name == "Bash":
        return check_bash(tool_input.get("command", ""))
    if tool_name in EDIT_TOOLS:
        return check_edit(tool_name, tool_input)
    return 0


if __name__ == "__main__":
    run(main)
