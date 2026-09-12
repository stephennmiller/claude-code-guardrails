#!/usr/bin/env python3
"""
Hardcoded-credential guard (BLOCKING PreToolUse hook for Write/Edit/MultiEdit).

Catches the one class of mistake that is genuinely expensive and genuinely
hard to undo: a real credential written into a tracked file. Once it is in a
commit, rotation is the only true fix, and the agent that wrote it will not
mention it.

DELIBERATELY NARROW. An earlier version of this hook also flagged `eval(`,
`../` and `innerHTML =`. Every one of those fires constantly on correct code
-- `../` matches every relative import in a JS codebase -- and a guard that
cries wolf gets disabled, taking the useful rules with it. Style and
vulnerability rules belong in a linter that can see the whole file and its
types. This hook does ONE thing.

Two signals must agree before it blocks:
  1. the ASSIGNMENT SHAPE looks like a credential (`api_key = "..."`), and
  2. the VALUE looks real -- long enough, mixed enough, and not an obvious
     placeholder.

Known provider token formats (which are unambiguous on their own) block on
shape alone.

Config: .claude/guardrails.config.json -> "secret_scan"

Contract:
  - reads the PreToolUse JSON envelope on stdin
  - exit 0 = allow, exit 2 = block
  - exit 1 on internal error (non-blocking)
"""
import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _guardrails import (  # noqa: E402
    EDIT_TOOLS,
    changed_text,
    load_config,
    read_envelope,
    run,
)

CONFIG = load_config("secret_scan")

MIN_LENGTH = int(CONFIG.get("min_secret_length", 16))
MIN_ENTROPY = float(CONFIG.get("min_entropy_bits", 3.0))

# Paths where a credential-shaped string is expected and harmless.
DEFAULT_SKIP = [
    r"\.(test|spec)\.[jt]sx?$",
    r"(^|/)__tests__/",
    r"(^|/)tests?/",
    r"(^|/)fixtures?/",
    r"\.example$",
    r"\.sample$",
    r"(^|/)\.env\.example$",
    r"(^|/)guardrails\.config\.json$",
    r"hooks-scripts/",
    r"test-hooks",
    r"\.lock$",
    r"(^|/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml)$",
]
SKIP = [
    re.compile(p) for p in (CONFIG.get("skip_paths") or []) + DEFAULT_SKIP
]

# An assignment whose NAME says credential. The value is captured for scoring.
ASSIGNMENT = re.compile(
    r"""(?ix)
    \b(
        api[_-]?key | api[_-]?secret | access[_-]?key | secret[_-]?key |
        client[_-]?secret | auth[_-]?token | access[_-]?token |
        refresh[_-]?token | private[_-]?key | encryption[_-]?key |
        password | passwd | credential | service[_-]?role[_-]?key
    )
    \s* [:=]{1,2} \s*
    ["'`]([^"'`\n]{8,})["'`]
    """
)

# Formats that are unambiguous on their own -- no value scoring needed.
PROVIDER_TOKENS = [
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}"), "GitHub token"),
    (re.compile(r"\bsk-[A-Za-z0-9]{20,}"), "OpenAI-style secret key"),
    (re.compile(r"\bsk-ant-[A-Za-z0-9_-]{20,}"), "Anthropic API key"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "AWS access key id"),
    (re.compile(r"\bASIA[0-9A-Z]{16}\b"), "AWS temporary access key id"),
    (re.compile(r"-----BEGIN (RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----"),
     "private key block"),
    (re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}"), "Slack token"),
    (re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"), "Google API key"),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
     "JWT"),
]

# Values that are shaped like secrets but are obviously not.
PLACEHOLDER = re.compile(
    r"""(?ix)
    ^( x{3,} | \.{3,} | -{3,} | \*{3,} | \s* )$
    | your[_-]? | my[_-]? | example | placeholder | changeme | change[_-]?me
    | dummy | sample | redacted | insert[_-]? | replace[_-]?
    | ^(test|fake|mock|foo|bar|baz|abc|123)
    | ^(true|false|null|none|undefined)$
    | ^\$\{ | ^\$[A-Z_]+$ | ^process\.env | ^import\.meta\.env
    | ^<.*>$ | ^\{\{.*\}\}$
    """
)


def shannon_entropy(value: str) -> float:
    """Bits of entropy per character. Real keys sit well above 3.0; English
    words and repeated characters sit below it."""
    if not value:
        return 0.0
    counts = {ch: value.count(ch) for ch in set(value)}
    length = len(value)
    return -sum(
        (c / length) * math.log2(c / length) for c in counts.values()
    )


def looks_real(value: str) -> bool:
    if len(value) < MIN_LENGTH:
        return False
    if PLACEHOLDER.search(value):
        return False
    # A value with no digits AND no case mixing is probably a sentence.
    has_digit = any(ch.isdigit() for ch in value)
    has_mixed_case = value != value.lower() and value != value.upper()
    if not (has_digit or has_mixed_case):
        return False
    return shannon_entropy(value) >= MIN_ENTROPY


def findings(text: str) -> list[str]:
    found = []
    for pattern, label in PROVIDER_TOKENS:
        if pattern.search(text):
            found.append(f"{label} written literally into the file")
    for match in ASSIGNMENT.finditer(text):
        name, value = match.group(1), match.group(2)
        if looks_real(value):
            found.append(
                f"`{name}` assigned a literal value that looks like a real"
                f" credential ({len(value)} chars,"
                f" entropy {shannon_entropy(value):.1f})"
            )
    # De-duplicate, preserve order.
    return list(dict.fromkeys(found))


def main() -> int:
    tool_name, tool_input = read_envelope()
    if tool_name not in EDIT_TOOLS:
        return 0

    file_path = tool_input.get("file_path", "")
    if not file_path or any(pattern.search(file_path) for pattern in SKIP):
        return 0

    found = findings(changed_text(tool_name, tool_input))
    if not found:
        return 0

    print(f"Blocked: possible hardcoded credential in {Path(file_path).name}",
          file=sys.stderr)
    for item in found:
        print(f"  - {item}", file=sys.stderr)
    print(
        "\nMove the value to an environment variable and read it at runtime."
        "\nIf this is a public/publishable key or test fixture, say so and"
        " re-run -- or add the path to secret_scan.skip_paths in"
        " guardrails.config.json.",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    run(main)
