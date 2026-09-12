"""
Shared engine for the guardrail hooks.

Everything project-specific lives in guardrails.config.json. This module is the
part that does NOT change between repos: reading the PreToolUse envelope,
normalizing a shell command so that *mentioning* a dangerous invocation is not
mistaken for *making* one, and loading rules from config.

THE CONTRACT (every hook in this directory obeys it):
  - read the PreToolUse JSON envelope on stdin
  - write human-readable output to stderr (the model sees it)
  - exit 0 = allow, exit 2 = block
  - exit 1 on internal error -- NON-BLOCKING, so a bug in a guard can never
    wedge a tool call. A guard that breaks the agent is worse than no guard.
"""
import json
import os
import re
import sys
from pathlib import Path
from typing import Callable, Optional


# --------------------------------------------------------------------------
# Config loading
# --------------------------------------------------------------------------

CONFIG_ENV = "GUARDRAILS_CONFIG"
CONFIG_NAME = "guardrails.config.json"


def config_path() -> Optional[Path]:
    """Locate guardrails.config.json.

    Order: explicit env override, then CLAUDE_PROJECT_DIR (set by Claude Code),
    then walk up from this file. The walk matters for git worktrees, where cwd
    is the worktree root but the hook may be the main checkout's copy.
    """
    override = os.environ.get(CONFIG_ENV)
    if override:
        candidate = Path(override)
        return candidate if candidate.is_file() else None

    project_dir = os.environ.get("CLAUDE_PROJECT_DIR")
    if project_dir:
        candidate = Path(project_dir) / ".claude" / CONFIG_NAME
        if candidate.is_file():
            return candidate

    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / CONFIG_NAME
        if candidate.is_file():
            return candidate
        candidate = parent / ".claude" / CONFIG_NAME
        if candidate.is_file():
            return candidate
    return None


def load_config(section: str) -> dict:
    """Return one top-level section of the config, or {} when absent.

    A missing or malformed config is NOT an error: it means "no rules", and the
    guard allows everything. Fail open, loudly enough to debug but quietly
    enough not to spam every tool call.
    """
    path = config_path()
    if path is None:
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"[guardrails] could not read {path}: {exc}", file=sys.stderr)
        return {}
    value = data.get(section, {})
    return value if isinstance(value, dict) else {}


def compile_optional(pattern: Optional[str], flags: int = 0) -> Optional[re.Pattern]:
    """Compile a pattern from config, tolerating None and bad regex.

    A rule with an invalid regex is dropped rather than crashing the hook --
    one typo in config must not disable the entire guard.
    """
    if not pattern:
        return None
    try:
        return re.compile(pattern, flags)
    except re.error as exc:
        print(f"[guardrails] bad regex {pattern!r}: {exc}", file=sys.stderr)
        return None


def rule_flags(rule: dict) -> int:
    """Translate the config's `flags` list into re module flags."""
    names = rule.get("flags") or []
    value = 0
    for name in names:
        value |= getattr(re, str(name).upper(), 0)
    return value


# --------------------------------------------------------------------------
# Envelope reading
# --------------------------------------------------------------------------

EDIT_TOOLS = ("Write", "Edit", "MultiEdit")


def read_envelope() -> tuple[str, dict]:
    """Parse the PreToolUse envelope from stdin -> (tool_name, tool_input)."""
    data = json.load(sys.stdin)
    return data.get("tool_name", ""), data.get("tool_input", {}) or {}


def changed_text(tool_name: str, tool_input: dict) -> str:
    """The text being written or edited, per the tool's input shape.

    old_string is included alongside new_string so a rule can still fire when a
    triggering line is being REMOVED -- deleting a CSP entry is as interesting
    as adding one.
    """
    if tool_name == "Write":
        return tool_input.get("content", "") or ""
    if tool_name == "Edit":
        return (tool_input.get("new_string", "") or "") + "\n" + (
            tool_input.get("old_string", "") or ""
        )
    if tool_name == "MultiEdit":
        return "\n".join(
            (edit.get("new_string", "") or "") + "\n" + (edit.get("old_string", "") or "")
            for edit in tool_input.get("edits", []) or []
        )
    return ""


# --------------------------------------------------------------------------
# Command normalization
#
# The single most important idea in this repo. A guard that greps the raw
# command string fires on `echo "deploy-cli db push"` and on a commit message
# that documents the guard itself. Normalization strips the places where text
# is DATA rather than a command.
# --------------------------------------------------------------------------

# `bash -c "..."` puts the real command inside quotes, where strip_quoted would
# erase it -- turning every guard into a one-word bypass. Detect the wrapper and
# scan raw instead.
#
# Any number of intervening options: `-c` is frequently NOT adjacent to the
# shell name (`bash -eux -c`, `bash --norc -c`, `env bash -l -c`). Matching only
# `-[a-zA-Z]*c` catches the combined `-euxc` spelling and misses every separated
# one, which is the more common way to write it.
SHELL_WRAPPER = re.compile(
    r"\b(ba|z|k)?sh\s+(-{1,2}[a-zA-Z][\w-]*\s+)*(-[a-zA-Z]*c|--command)\b"
)

HEREDOC_START = re.compile(r"<<-?\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?")


def strip_heredocs(command: str) -> str:
    """Drop heredoc bodies, keeping the line that opens them.

    A heredoc body is prose fed to a command's stdin -- a commit message, a PR
    body, a file being written -- never a command itself. Without this, a
    legitimate `gh pr create --body-file - <<MSG` whose body *documents* a
    dangerous command is blocked by the rule for that command.

    The delimiter is captured from the opening line so only its own terminator
    closes the block; a prose body can otherwise contain a look-alike line.
    """
    kept = []
    tag = None
    for line in command.split("\n"):
        if tag is None:
            kept.append(line)
            match = HEREDOC_START.search(line)
            if match:
                tag = match.group(1)
        elif line.strip() == tag:
            tag = None
    return "\n".join(kept)


def strip_quoted(command: str) -> str:
    """Drop quoted spans so a command that merely MENTIONS an invocation
    (echo, a grep pattern, a commit message) is not mistaken for it."""
    if SHELL_WRAPPER.search(command):
        return command
    return re.sub(r'"[^"]*"', "", re.sub(r"'[^']*'", "", command))


def normalize(command: str) -> str:
    """Text to match rules against, unless a rule opts out via scan_raw.

    ORDER MATTERS: heredocs first. The quote strip would eat a quoted heredoc
    delimiter (`<<'MSG'` -> `<<`) and leave the body looking like ordinary
    command text.
    """
    return strip_quoted(strip_heredocs(command))


# --------------------------------------------------------------------------
# Exempt-predicate registry
#
# Most carve-outs are expressible as regex in config. Some are not -- "this
# redirect targets THIS checkout's generated file, not a look-alike elsewhere
# on disk" needs filesystem access. Those live here as named predicates that
# config references by name, so config stays declarative without capping power.
# --------------------------------------------------------------------------

_PREDICATES: dict[str, Callable[..., bool]] = {}


def predicate(name: str):
    """Register a named predicate referenceable from guardrails.config.json."""

    def wrap(fn):
        _PREDICATES[name] = fn
        return fn

    return wrap


def get_predicate(name: Optional[str]) -> Optional[Callable[..., bool]]:
    if not name:
        return None
    fn = _PREDICATES.get(name)
    if fn is None:
        print(f"[guardrails] unknown predicate {name!r} -- rule has no carve-out",
              file=sys.stderr)
    return fn


# --------------------------------------------------------------------------
# Entry-point wrapper
# --------------------------------------------------------------------------

def run(main: Callable[[], int]) -> None:
    """Run a hook's main(), converting any crash into a non-blocking exit 1."""
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 -- deliberate catch-all
        print(f"[guardrails] hook error: {exc}", file=sys.stderr)
        sys.exit(1)
