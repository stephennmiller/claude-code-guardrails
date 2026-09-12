#!/usr/bin/env python3
"""
Watch-mode guard (BLOCKING PreToolUse hook for Bash).

Several test runners are watch-by-default: `vitest`, `jest --watch`, `cargo
watch`, `pytest-watch`. In an agent shell there is no TTY to press "q" in, so a
forgotten one-shot flag hangs the tool call until it times out -- burning
minutes and returning nothing. Telling the agent "always pass --run" in
CLAUDE.md works most of the time; this makes it work every time.

MATCHING IS ANCHORED TO EXACT SCRIPT NAMES. A substring match on
"npm run test" also catches test:e2e, test:coverage and test:integration --
none of which are watch-mode, several of which are not even the same runner.
Requiring whitespace/quote/end after the script name keeps every `test:*`
script out of scope, because ':' is none of those. Scripts that genuinely hang
(`test:ui`) must be listed explicitly in `hangs_anyway`.

Config lives in .claude/guardrails.config.json under "watch_mode".

Contract:
  - reads the PreToolUse JSON envelope on stdin
  - exit 0 = allow, exit 2 = block
  - exit 1 on internal error (non-blocking: a guard bug must never wedge the
    shell)
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _guardrails import load_config, normalize, read_envelope, run  # noqa: E402

CONFIG = load_config("watch_mode")

# Trailing delimiter shared by every anchored match below. Quotes are included
# because inside a shell wrapper (`bash -c "npx vitest"`) the payload is
# adjacent to a quote rather than whitespace.
END = r"([\s\"']|$)"


def _alternation(values) -> str:
    return "|".join(re.escape(str(v)) for v in values if str(v))


def _check(runner: dict, raw_command: str, scan: str) -> int:
    npm_scripts = runner.get("npm_scripts") or []
    binaries = runner.get("binaries") or []
    hangs_anyway = runner.get("hangs_anyway") or []

    via_npm = False
    forced_hang = False

    # 1. Scripts that hang no matter what (a UI server, a REPL). Named
    #    explicitly because the anchored matcher below skips every `name:*`
    #    script, so these would otherwise slip through the carve-out meant for
    #    unrelated siblings.
    if hangs_anyway and re.search(
        rf"npm\s+(run\s+)?({_alternation(hangs_anyway)}){END}", scan
    ):
        forced_hang = True
    # 2. The bare npm script (and its aliases). The trailing END is what
    #    excludes every `name:*` sibling.
    elif npm_scripts and re.search(
        rf"npm\s+(run\s+)?({_alternation(npm_scripts)}){END}", scan
    ):
        via_npm = True
    # 3. A direct binary call, at the start or after a separator so
    #    `cd app && vitest` still matches.
    elif binaries and re.search(
        rf"(^|[;&|\"'(]\s*|\s)(npx\s+|pnpm\s+exec\s+|yarn\s+)?"
        rf"({_alternation(binaries)}){END}",
        scan,
    ):
        pass
    else:
        return 0

    # --- Does it already avoid watch mode? ---------------------------------
    # Through npm the flag must come AFTER `--`, or npm swallows it and
    # forwards nothing: `npm run test --run` reaches the runner with an empty
    # argv and starts watch mode anyway. That typo is the single most likely
    # way to hit this guard, so it must NOT count as a run marker.
    args = raw_command
    if via_npm:
        args = raw_command.split(" -- ", 1)[1] if " -- " in raw_command else ""

    if not forced_hang:
        markers = runner.get("run_markers") or []
        if markers and re.search(rf"(^|\s)({_alternation(markers)})([\s=\"']|$)", args):
            return 0
        subcommand = runner.get("run_subcommand")
        if subcommand and binaries and re.search(
            rf"({_alternation(binaries)})\s+{re.escape(str(subcommand))}{END}",
            raw_command,
        ):
            return 0

        # Flags that hang despite being "intentional" (`--ui` starts a
        # long-lived server). Not exempt: the contract is "never hang the tool
        # call", so these block and defer to a human terminal.
        hang_flags = runner.get("hang_flags") or []
        if hang_flags and re.search(
            rf"(^|\s)({_alternation(hang_flags)}){END}", args
        ):
            forced_hang = True

    name = runner.get("name", "the test runner")
    if forced_hang:
        message = runner.get("hang_message") or (
            f"Blocked: this starts a long-lived {name} server and will hang the"
            " tool call.\nThere is no TTY here to quit it. Ask the user to run"
            " it in a real terminal."
        )
    else:
        message = runner.get("message") or (
            f"Blocked: this starts {name} in WATCH mode and will hang the tool"
            " call.\nThere is no TTY here to quit it -- pass a one-shot flag."
        )
    print(message, file=sys.stderr)
    return 2


def main() -> int:
    tool_name, tool_input = read_envelope()
    if tool_name != "Bash":
        return 0
    command = tool_input.get("command", "")
    if not command:
        return 0

    # Normalization matters here for the same reason it does in the blast
    # guard: a PR body that documents this guard must not trip it.
    scan = normalize(command)

    for runner in CONFIG.get("runners", []) or []:
        status = _check(runner, command, scan)
        if status != 0:
            return status
    return 0


if __name__ == "__main__":
    run(main)
