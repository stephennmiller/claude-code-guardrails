#!/usr/bin/env bash
# Print the CHANGELOG section for one version.
#
#   bash scripts/release-notes.sh 1.1.0
#
# Exists as a script rather than inline YAML so it can be run and tested
# locally, and so shellcheck sees it. The release workflow pipes its output
# straight into `gh release create`.
#
# Exits non-zero when the version has no section. That is the point: it makes
# an undocumented release fail loudly at tag time instead of publishing empty
# notes that nobody goes back to fill in.

set -uo pipefail

VERSION="${1:-}"
[ -n "$VERSION" ] || { echo "usage: $0 <version>   (e.g. 1.1.0)" >&2; exit 2; }
VERSION="${VERSION#v}"

CHANGELOG="$(dirname "${BASH_SOURCE[0]}")/../CHANGELOG.md"
[ -f "$CHANGELOG" ] || { echo "no CHANGELOG.md at $CHANGELOG" >&2; exit 1; }

# Everything between this version's heading and the next `## ` heading.
# Stops at the next `## ` heading, and also at the link-reference footer:
# the OLDEST version has no heading after it, so without that second guard it
# swallows every `[1.0.0]: https://...` definition at the end of the file.
section="$(awk -v want="## [$VERSION]" '
    index($0, want) == 1 { inside = 1; next }
    inside && /^## / { exit }
    inside && /^\[[^]]+\]: / { exit }
    inside { print }
' "$CHANGELOG")"

# Trim leading and trailing blank lines.
section="$(printf '%s\n' "$section" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"

if [ -z "$section" ]; then
    echo "CHANGELOG.md has no '## [$VERSION]' section." >&2
    echo "Add one before tagging, or the release ships with empty notes." >&2
    exit 1
fi

printf '%s\n' "$section"
