#!/usr/bin/env python3
"""
Git safety guard (PreToolUse hook for Bash).

Blocks three things agents do by reflex and humans rarely mean:
  1. skipping the pre-commit hooks on commit/push/merge/rebase -- they are
     often the only local gate on secrets and lint.
  2. committing directly to a protected branch.
  3. force-pushing to a protected branch.

THE HOOK-SKIPPING RULE IS THE INTERESTING ONE. This is a Claude Code hook, not
a git hook, so it constrains the AGENT only -- a human contributor passing that
flag in their own terminal is unaffected. That asymmetry is the point: the
escape hatch stays open for the person who can judge when to use it, and closes
for the process that reaches for it whenever a gate is inconvenient.

WHY THIS IS PYTHON. It was bash, and matched against the RAW command. That is
PATTERNS.md section 2: a Bash call that merely CONTAINS the text of a git
command -- a heredoc writing a test fixture, a doc edit describing this hook --
was blocked outright while on a protected branch. The workaround was to
assemble those literals at runtime wherever they appeared, a tax paid forever
by every file that needs to name the thing it tests. normalize() already solves
this correctly, and it lives on this side of the fence.

WHICH TEXT EACH CHECK READS is the load-bearing decision:
  - The three BLOCKING checks read normalized text. Their subject is the
    command, so prose that merely mentions a command must not trigger them.
  - The commit-message advisory reads RAW. Its subject IS the message, which
    lives exactly where normalization strips. Same reason blast-radius exposes
    `scan_raw`.

Contract:
  - reads the PreToolUse JSON envelope on stdin
  - exit 0 = allow, exit 2 = block
  - exit 1 on internal error (non-blocking: a guard bug must never wedge the
    shell)

Config: .claude/guardrails.config.json -> "git_safety"
"""
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _guardrails import load_config, normalize, read_envelope, run  # noqa: E402

CONFIG = load_config("git_safety")

PROTECTED = CONFIG.get("protected_branches") or ["main", "master"]
MAX_STAGED = CONFIG.get("max_staged_files", 25)
COMMIT_TYPES = CONFIG.get("conventional_commit_types") or [
    "feat", "fix", "docs", "style", "refactor",
    "test", "chore", "perf", "build", "ci", "revert",
]

# A bare `git` somewhere in the command is the cheap gate. Anchored so that
# `legit` or a stray `--git-dir` does not wake the guard up.
INVOKES_GIT = re.compile(r"(^|[\s;&|])git\s")

WRITES_HISTORY = re.compile(r"\bgit\s+(commit|push|merge|rebase)\b")
SKIP_FLAG = re.compile(r"(^|\s)--no-verify(\s|$)")
COMMITS = re.compile(r"\bgit\s+commit\b")
PUSHES = re.compile(r"\bgit\s+push\b")
FORCE = re.compile(r"--force(\s|=|$)|--force-with-lease|\s-f(\s|$)")
AMENDS = re.compile(r"--amend\b")

# Read against the RAW command: the message is the subject here, and it exists
# only inside quotes, which normalize() removes.
MESSAGE = re.compile(r"""-m\s+"([^"]+)"|-m\s+'([^']+)'""")

MIN_MESSAGE_LEN = 10


def _git(args: list[str]) -> str:
    """Run a read-only git command, returning stdout or '' on any failure."""
    try:
        out = subprocess.run(
            ["git", *args], capture_output=True, text=True, timeout=5,
        )
        return out.stdout if out.returncode == 0 else ""
    except Exception:
        # Not a checkout, or git is unavailable. Nothing to protect.
        return ""


def current_branch() -> str:
    """The branch a commit would land on, or '' if there is no such branch.

    `symbolic-ref`, not `rev-parse --abbrev-ref`: on an UNBORN head -- a fresh
    checkout with no commits yet -- rev-parse fails, the branch reads as empty,
    and the very first commit lands on the protected branch unguarded. Detached
    HEAD still yields '' here, which is right: there is no branch to protect.
    """
    return _git(["symbolic-ref", "--short", "HEAD"]).strip()


def staged_count() -> int:
    lines = _git(["diff", "--cached", "--name-only"]).splitlines()
    return len([ln for ln in lines if ln.strip()])


def main() -> int:
    tool_name, tool_input = read_envelope()
    if tool_name != "Bash":
        return 0

    raw = tool_input.get("command", "")
    if not raw:
        return 0

    command = normalize(raw)
    if not INVOKES_GIT.search(command):
        return 0

    branch = current_branch()

    # --- 1. skipping the pre-commit gates ----------------------------------
    if WRITES_HISTORY.search(command) and SKIP_FLAG.search(command):
        print(
            "Blocked: --no-verify skips the pre-commit gates (lint-staged, "
            "secret scan).\n\n"
            "Fix the underlying failure rather than bypassing the gate. If the "
            "user has\nexplicitly asked you to skip, confirm with them and "
            "re-run.",
            file=sys.stderr,
        )
        return 2

    # --- 2. direct commit to a protected branch ----------------------------
    if COMMITS.search(command) and branch in PROTECTED:
        print(
            f"Blocked: direct commits to '{branch}' are not allowed.\n"
            "  Create a branch first:  git switch -c feat/your-change",
            file=sys.stderr,
        )
        return 2

    # --- 3. force push to a protected branch -------------------------------
    if (
        PUSHES.search(command)
        and FORCE.search(command)
        and any(re.search(rf"\b{re.escape(b)}\b", command) for b in PROTECTED)
    ):
        print(
            "Blocked: force-pushing to a protected branch rewrites shared "
            "history.",
            file=sys.stderr,
        )
        return 2

    # --- advisory: commit message shape ------------------------------------
    if COMMITS.search(command):
        found = MESSAGE.search(raw)
        message = (found.group(1) or found.group(2)) if found else ""

        if message and len(message) < MIN_MESSAGE_LEN:
            print(
                "Blocked: commit message is too short to be useful "
                f"(<{MIN_MESSAGE_LEN} chars).",
                file=sys.stderr,
            )
            return 2

        types = "|".join(re.escape(t) for t in COMMIT_TYPES)
        if message and not re.match(rf"^({types})(\(.+\))?!?:", message):
            # Advisory only -- some repos do not enforce this.
            print(
                "Note: message does not match Conventional Commits\n"
                f"  expected one of: {'|'.join(COMMIT_TYPES)}",
                file=sys.stderr,
            )

    # --- advisory: oversized commit ----------------------------------------
    if COMMITS.search(command) and not AMENDS.search(command):
        count = staged_count()
        if count > MAX_STAGED:
            print(
                f"Note: large commit ({count} files, soft limit {MAX_STAGED}).\n"
                "  Consider splitting into focused commits.",
                file=sys.stderr,
            )

    return 0


if __name__ == "__main__":
    run(main)
