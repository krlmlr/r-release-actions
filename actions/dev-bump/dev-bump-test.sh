#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Check dev-bump.sh offline, on scratch checkouts.
#
#   1. A release version becomes `X.Y.Z.9000`, or `X.Y.Z.W.9000` for four components, and only the `Version:` line of DESCRIPTION changes.
#   2. NEWS.md gains the development section with the compare link above the release's section,
#      keeping a preamble, or replaces a development section already at the top, ignoring headings in code fences.
#   3. A second run changes nothing.
#   4. A development version without the `.9000` bump, a missing release section and a bad repository fail.
#
# Usage:
#   actions/dev-bump/dev-bump-test.sh

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../cran-lib/test-lib.sh
. "$HERE/../cran-lib/test-lib.sh"

P=$SCRATCH/pkg
fixture() { # <version> <NEWS.md text>
  rm -rf "$P"
  mkdir -p "$P"
  printf 'Package: fakepkg\nTitle: A Fake Package\nVersion: %s\nDate: 2026-11-02\nAuthors@R: person("A", "B")\n' "$1" >"$P/DESCRIPTION"
  printf '%s' "$2" >"$P/NEWS.md"
}
run() {
  local rc=0 out
  : >"$SCRATCH/output"
  out=$(GITHUB_OUTPUT=$SCRATCH/output "$HERE/dev-bump.sh" "$P" owner/fakepkg main 2>&1) || rc=$?
  printf '%s\nexit %s\n' "$out" "$rc"
}

section "a release without a development section"
fixture 1.3.0 $'<!-- a preamble -->\n\n# fakepkg 1.3.0 (2026-11-02)\n\n- New `foo()`.\n'
out=$(run)
has "it succeeds" "$out" "exit 0"
is "DESCRIPTION carries the development version, and nothing else changes" "$(cat "$P/DESCRIPTION")" \
  "$(printf 'Package: fakepkg\nTitle: A Fake Package\nVersion: 1.3.0.9000\nDate: 2026-11-02\nAuthors@R: person("A", "B")')"
# shellcheck disable=SC2016  # Markdown backticks
is "NEWS.md gains the development section below the preamble" "$(cat "$P/NEWS.md")" \
  "$(printf '%s\n' '<!-- a preamble -->' '' '# fakepkg (development version)' '' \
    'Changes since v1.3.0: <https://github.com/owner/fakepkg/compare/v1.3.0...main>' '' \
    '# fakepkg 1.3.0 (2026-11-02)' '' '- New `foo()`.')"
has "it writes the outputs" "$(cat "$SCRATCH/output")" $'version=1.3.0.9000\nchanged=true'

section "a second run"
before=$(cat "$P/NEWS.md" "$P/DESCRIPTION")
out=$(run)
has "it succeeds" "$out" "exit 0"
has "it says there is nothing to do" "$out" "already the development version"
is "it changes nothing" "$(cat "$P/NEWS.md" "$P/DESCRIPTION")" "$before"
has "it says so in the outputs" "$(cat "$SCRATCH/output")" "changed=false"

section "a development section already at the top"
fixture 1.3-1 $'# fakepkg (development version)\n\n- A stray entry.\n\n```r\n# fakepkg 1.3-1 is a comment, not a heading\n```\n\n# fakepkg 1.3-1\n\n- Fix.\n\n# fakepkg 1.3-0\n\n- Old.\n'
out=$(run)
has "it succeeds" "$out" "exit 0"
is "the section is replaced up to the next heading outside a fence" "$(cat "$P/NEWS.md")" \
  "$(printf '%s\n' '# fakepkg (development version)' '' \
    'Changes since v1.3-1: <https://github.com/owner/fakepkg/compare/v1.3-1...main>' '' \
    '# fakepkg 1.3-1' '' '- Fix.' '' '# fakepkg 1.3-0' '' '- Old.')"
has "the version keeps its separator" "$(cat "$P/DESCRIPTION")" "Version: 1.3-1.9000"

section "a four-component release"
fixture 1.4.2.1 $'# fakepkg 1.4.2.1\n\n- Patch.\n'
out=$(run)
has "it succeeds" "$out" "exit 0"
has "the bump appends a fifth component" "$(cat "$P/DESCRIPTION")" "Version: 1.4.2.1.9000"
has "the compare link starts at the four-component tag" "$(cat "$P/NEWS.md")" \
  "Changes since v1.4.2.1: <https://github.com/owner/fakepkg/compare/v1.4.2.1...main>"
out=$(run)
has "a second run says there is nothing to do" "$out" "already the development version"
has "and changes nothing" "$(cat "$SCRATCH/output")" "changed=false"

section "refusals"
refused() { # <version> <description>
  fixture "$1" "# fakepkg $1"$'\n'
  local out
  out=$(run)
  has "$2" "$out" "DESCRIPTION gives fakepkg $1, which is no release version"
  has "and fails" "$out" "exit 1"
  is "and changes nothing" "$(grep Version "$P/DESCRIPTION")" "Version: $1"
}
refused 1.4.2.1.2 "five components are no release"
refused 1.4.2.9000.9000 "nor is a bumped development version"
refused 1.4.2.9001 "nor four components with the last 9000 or more"
refused 1.0 "nor two components"

section "the boundary of the fourth component"
fixture 1.4.2.8999 $'# fakepkg 1.4.2.8999\n'
out=$(run)
has "8999 is a release" "$out" "exit 0"
has "and is bumped" "$(cat "$P/DESCRIPTION")" "Version: 1.4.2.8999.9000"
fixture 1.4.2.9000 $'# fakepkg 1.4.2\n'
out=$(run)
has "9000 is the development version of 1.4.2" "$out" "already the development version"
fixture 1.4.2-1 $'# fakepkg 1.4.2-1\n'
out=$(run)
has "a dash before the fourth component works too" "$out" "exit 0"
has "keeping its separator" "$(cat "$P/DESCRIPTION")" "Version: 1.4.2-1.9000"
has "and the tag" "$(cat "$P/NEWS.md")" "Changes since v1.4.2-1:"

section "more refusals"
fixture 1.3.0.9001 $'# fakepkg 1.3.0\n'
out=$(run)
has "a checkpoint version is no release" "$out" "exit 1"
fixture 1.3.0 $'# fakepkg 1.2.0\n\n```\n# fakepkg 1.3.0\n```\n'
out=$(run)
has "a release section only inside a fence does not count" "$out" "no section headed '# fakepkg 1.3.0'"
has "and fails" "$out" "exit 1"
is "nothing changed" "$(grep Version "$P/DESCRIPTION")" "Version: 1.3.0"
rc=0
"$HERE/dev-bump.sh" "$P" 'not a repo' main >/dev/null 2>&1 || rc=$?
is "a bad repository is a usage error" "$rc" 2

done_testing
