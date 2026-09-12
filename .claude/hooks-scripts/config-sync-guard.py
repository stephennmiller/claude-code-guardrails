#!/usr/bin/env python3
"""
Cross-surface config-sync guard (ADVISORY PreToolUse hook).

Some configuration must stay coordinated across surfaces that no single file
reveals -- a CSP allowlist and the code that fetches a new origin; an env
schema, the .env.example, and the deploy platform's env settings; a function's
source and the manifest entry that makes it deploy. Changing one side without
the others produces a failure that is invisible locally and only appears in
production.

When an edit touches a known trigger surface, this hook prints a reminder
naming the sibling surfaces that must move in lockstep.

IT NEVER BLOCKS, AND THAT IS THE DESIGN. Several siblings live OUTSIDE the
repo -- a hosting platform's env vars, a third-party dashboard setting -- so
the hook can remind but cannot verify. A blocking version would be false
positives all the way down, and would be disabled within a week.

Rules live in .claude/guardrails.config.json under "config_sync".

Contract:
  - reads the PreToolUse JSON envelope on stdin
  - writes reminders to stderr
  - exit 0 ALWAYS (advisory)
  - exit 1 on internal error (non-blocking)
"""
import re
import sys
from pathlib import Path
from typing import NamedTuple, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _guardrails import (  # noqa: E402
    changed_text,
    compile_optional,
    load_config,
    read_envelope,
    rule_flags,
    run,
)

CONFIG = load_config("config_sync")


class Declaration(NamedTuple):
    """A 'this component must be registered in a manifest' check.

    Generalizes a common and nasty class of bug: a component that exists on
    disk, looks complete, and is never built/deployed/loaded because nothing
    added it to the manifest. The symptom always appears somewhere far away
    from the cause.
    """

    capture: re.Pattern      # must capture the component name as group 1
    manifest: str            # repo-relative path to the manifest
    must_contain: str        # literal with {name} substituted

    def missing(self, file_path: str) -> bool:
        match = self.capture.search(file_path)
        if not match:
            return False
        name = match.group(1)

        # Resolve the manifest relative to the matched prefix of the edited
        # file, so this works from a git worktree as well as the main checkout.
        root = Path(file_path[: match.start()])
        try:
            declared = (root / self.manifest).read_text(encoding="utf-8")
        except OSError:
            # Can't read the manifest -> stay silent rather than cry wolf.
            return False
        return self.must_contain.replace("{name}", name) not in declared


class Rule(NamedTuple):
    name: str
    path: re.Pattern
    content: Optional[re.Pattern]
    message: str
    declaration: Optional[Declaration] = None

    def fires(self, file_path: str, text: str) -> bool:
        if not self.path.search(file_path):
            return False
        if self.content is not None and not self.content.search(text):
            return False
        if self.declaration is not None and not self.declaration.missing(file_path):
            return False
        return True


def _rules() -> list[Rule]:
    rules = []
    for raw in CONFIG.get("rules", []) or []:
        flags = rule_flags(raw)
        path = compile_optional(raw.get("path"), flags)
        if path is None:
            continue

        declaration = None
        spec = raw.get("requires_declaration")
        if spec:
            capture = compile_optional(spec.get("capture_name_from"))
            if capture is not None and spec.get("manifest"):
                declaration = Declaration(
                    capture=capture,
                    manifest=spec["manifest"],
                    must_contain=spec.get("must_contain", "{name}"),
                )

        rules.append(
            Rule(
                name=raw.get("name", "unnamed rule"),
                path=path,
                content=compile_optional(raw.get("content"), flags),
                message=raw.get("message", ""),
                declaration=declaration,
            )
        )
    return rules


def main() -> int:
    tool_name, tool_input = read_envelope()

    file_path = tool_input.get("file_path", "")
    if not file_path:
        return 0

    # Never warn about edits to the guard itself or its tests.
    if "config-sync-guard" in file_path or "test-hooks" in file_path:
        return 0

    text = changed_text(tool_name, tool_input)
    fired = [rule for rule in _rules() if rule.fires(file_path, text)]
    if not fired:
        return 0

    print(
        f"[config-sync] {Path(file_path).name} touches coordinated config."
        " Confirm the sibling surfaces stay in sync:",
        file=sys.stderr,
    )
    seen = set()
    for rule in fired:
        if rule.message in seen:
            continue
        seen.add(rule.message)
        print(f"\n- {rule.name}:", file=sys.stderr)
        print(f"  {rule.message}", file=sys.stderr)

    # Advisory only -- never block. Siblings are often out-of-repo.
    return 0


if __name__ == "__main__":
    run(main)
