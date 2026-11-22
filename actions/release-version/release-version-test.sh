#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Check release-version.sh offline, against package checkouts written here.
#
#   1. A release version dated today in both places passes, with its outputs and notes ending in the marker.
#   2. A development version fails before the dates are read; four components with the last below 9000 are a release.
#   3. A heading without a date, dates that differ, and a missing or doubled section fail.
#   4. A date more than a day from today fails a real run and warns on a dry run; a day off passes.
#
# Usage:
#   actions/release-version/release-version-test.sh

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../cran-lib/test-lib.sh
. "$HERE/../cran-lib/test-lib.sh"

export TODAY=2026-11-15
SUMMARY=$SCRATCH/summary.md
PKG=$SCRATCH/pkg

# A checkout: <version> <DESCRIPTION Date or empty> <NEWS.md heading line>...
checkout() {
  local version=$1 date=$2
  shift 2
  rm -rf "$PKG"
  mkdir -p "$PKG"
  {
    echo "Package: fakepkg"
    echo "Version: $version"
    echo "Title: A Package That Is Never Submitted"
    [ -z "$date" ] || echo "Date: $date"
  } >"$PKG/DESCRIPTION"
  {
    local h
    for h in "$@"; do
      # shellcheck disable=SC2016  # the backticks are Markdown
      printf '%s\n\n## Features\n\n- New `foo()` (#12).\n\n' "$h"
    done
    printf '# fakepkg 0.9.0 (2026-01-02)\n\n- Old news.\n'
  } >"$PKG/NEWS.md"
}

run() {
  local rc=0 out
  : >"$SUMMARY"
  : >"$SCRATCH/output"
  out=$(GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY=$SUMMARY GITHUB_OUTPUT=$SCRATCH/output \
    "$HERE/release-version.sh" "$PKG" "$SCRATCH/out" 2>&1) || rc=$?
  printf '%s\nexit %s\n' "$out" "$rc"
}

section "a release version dated today"
checkout 1.0.1 2026-11-15 "# fakepkg 1.0.1 (2026-11-15)"
out=$(run)
has "it succeeds" "$out" "exit 0"
is "the outputs" "$(cat "$SCRATCH/output")" "package=fakepkg
version=1.0.1
date=2026-11-15
notes=$SCRATCH/out/notes.md"
is "the notes are the section without its heading, then the marker" "$(cat "$SCRATCH/out/notes.md")" "## Features

- New \`foo()\` (#12).

<!-- cran-submission: fakepkg 1.0.1 -->"
has "the summary names the dates" "$(cat "$SUMMARY")" "\`2026-11-15\` in the \`NEWS.md\` heading and in \`DESCRIPTION\`"

section "a development version stops the run"
checkout 1.0.1.9000 2026-11-15 "# fakepkg 1.0.1.9000 (2026-11-15)"
out=$(run)
has "it fails" "$out" "exit 1"
has "naming the development version" "$out" "::error title=Development version::"
hasnt "before the dates" "$out" "Dates: NEWS.md"
checkout 1.4.2.1.9000 2026-11-15 "# fakepkg 1.4.2.1.9000 (2026-11-15)"
out=$(run)
has "so does the development version of a four-component release" "$out" "::error title=Development version::"
checkout 1.4.2.1.2 2026-11-15 "# fakepkg 1.4.2.1.2 (2026-11-15)"
has "and five components" "$(run)" "::error title=Development version::"

section "a four-component release version"
checkout 1.4.2.1 2026-11-15 "# fakepkg 1.4.2.1 (2026-11-15)"
out=$(run)
has "it succeeds" "$out" "exit 0"
has "with its version" "$(cat "$SCRATCH/output")" "version=1.4.2.1"
has "and its marker" "$(cat "$SCRATCH/out/notes.md")" "<!-- cran-submission: fakepkg 1.4.2.1 -->"
checkout 1.4.2-8999 2026-11-15 "# fakepkg 1.4.2-8999 (2026-11-15)"
has "a dash separates the fourth component too" "$(run)" "exit 0"

section "the dates are verified, never set"
checkout 1.0.1 2026-11-15 "# fakepkg 1.0.1"
out=$(run)
has "a heading without a date fails" "$out" "::error title=The NEWS.md heading has no date::"
checkout 1.0.1 2026-11-14 "# fakepkg 1.0.1 (2026-11-15)"
out=$(run)
has "dates that differ fail" "$out" "::error title=The dates differ::"
checkout 1.0.1 "" "# fakepkg 1.0.1 (2026-11-15)"
out=$(run)
has "a missing Date fails as differing" "$out" "::error title=The dates differ::"
checkout 1.0.1 2026-11-15 "# fakepkg 1.0.2 (2026-11-15)"
out=$(run)
has "a missing section fails" "$out" "::error title=No single NEWS.md section for fakepkg 1.0.1::"
checkout 1.0.1 2026-11-15 "# fakepkg 1.0.1 (2026-11-15)" "# fakepkg 1.0.1 (2026-11-15)"
out=$(run)
has "a doubled section fails" "$out" "has 2 sections headed"
checkout 1.0.1 2026-11-15 "# fakepkg 1.0.10 (2026-11-15)" "# fakepkg 1.0.1 (2026-11-15)"
out=$(run)
has "a version that only starts the same is another" "$out" "exit 0"
is "and its notes are not taken" "$(head -n 1 "$SCRATCH/out/notes.md")" "## Features"
is "the right section is" "$(grep -c 'foo' "$SCRATCH/out/notes.md")" 1
fails "the next section ends it" grep -q '^# fakepkg 0.9.0' "$SCRATCH/out/notes.md"

section "a stale date"
checkout 1.0.1 2026-11-10 "# fakepkg 1.0.1 (2026-11-10)"
out=$(run)
has "fails a real run" "$out" "::error title=The dates are not the submission date::"
has "and says to take the path again from the date commit" "$(cat "$SUMMARY")" "Take the path again from the date commit"
out=$(DRY_RUN=true run)
has "warns on a dry run" "$out" "::warning title=Stale dates::"
has "which succeeds" "$out" "exit 0"
checkout 1.0.1 2026-11-14 "# fakepkg 1.0.1 (2026-11-14)"
out=$(run)
has "a day off passes, for the maintainer's time zone" "$out" "exit 0"
checkout 1.0.1 2026-11-16 "# fakepkg 1.0.1 (2026-11-16)"
out=$(run)
has "in either direction" "$out" "exit 0"

done_testing
