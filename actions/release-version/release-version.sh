#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Read the release a package's checkout describes, and stop on anything that is no release ready to submit.
#
# From DESCRIPTION and NEWS.md in <package dir>:
#   - `Package:` and `Version:`; a version with more than three components is a development version, and fails.
#   - the dates: NEWS.md has exactly one section headed `# <package> <version> (YYYY-MM-DD)`,
#     DESCRIPTION's `Date:` is that same date, and the date is within one day of today (UTC),
#     which allows for the maintainer's time zone.
#     The date commit before the checks sets both; this only verifies them, and changes nothing.
#     A date that is not today's fails a real run and warns on a dry run, which may precede the submission by a day or more.
#   - the release notes: that section without its heading, followed by the marker
#     `<!-- cran-submission: <package> <version> -->`, written to <out dir>/notes.md.
#
# Usage:
#   release-version.sh <package dir> <out dir>
#
# Environment:
#   DRY_RUN              `true` turns a stale date into a warning
#   TODAY                the date to compare with, YYYY-MM-DD; default today in UTC (the tests set it)
#   GITHUB_OUTPUT        receives `package`, `version`, `date`, `notes`
#   GITHUB_STEP_SUMMARY  receives the report
#   GITHUB_ACTIONS       `true` turns on the workflow commands
#
# Exit status: 0 on success, 1 on a failed check, 2 on a usage error.

set -euo pipefail

# shellcheck source=../cran-lib/cran-lib.sh
. "$(dirname "$0")/../cran-lib/cran-lib.sh"

[ $# -eq 2 ] || {
  sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
pkgdir=$1
out=$2
mkdir -p "$out"
today=${TODAY:-$(date -u +%Y-%m-%d)}

summary "## Release version" ""
group "Version: DESCRIPTION"
[ -f "$pkgdir/DESCRIPTION" ] ||
  fail "Version" "No DESCRIPTION" "The checkout has no \`DESCRIPTION\` at its root." -- \
    "Dispatch the submission in the package's own repository, on the commit to submit."
pkg=$(dcf_field Package "$pkgdir/DESCRIPTION")
version=$(dcf_field Version "$pkgdir/DESCRIPTION")
desc_date=$(dcf_field Date "$pkgdir/DESCRIPTION")
val "package" "$pkg"
val "version" "$version"
val "Date" "${desc_date:-(none)}"
valid_package "$pkg" ||
  fail "Version" "No valid package name" "\`DESCRIPTION\` gives the package name \`$pkg\`." -- \
    "Fix \`Package:\` in \`DESCRIPTION\`."
valid_version "$version" ||
  fail "Version" "No valid version" "\`DESCRIPTION\` gives the version \`$version\`." -- \
    "Set \`Version:\` in \`DESCRIPTION\` to a release version such as \`1.2.3\`."
components=$(printf '%s\n' "$version" | awk -F '[.-]' '{ print NF }')
if [ "$components" -gt 3 ]; then
  fail "Version" "Development version" \
    "\`DESCRIPTION\` carries \`$version\`, which has $components components: a development version, which CRAN does not take. Nothing was drafted or uploaded." -- \
    "Submit the commit that sets the release version, the release branch's head or, on the fast path, \`main\`'s."
fi
endgroup
summary "Package **$pkg** version **$version**." ""

group "Dates: NEWS.md heading and DESCRIPTION"
[ -f "$pkgdir/NEWS.md" ] ||
  fail "Dates" "No NEWS.md" "The checkout has no \`NEWS.md\`, so the release has no notes." -- \
    "Write the version's section in \`NEWS.md\`, headed \`# $pkg $version (YYYY-MM-DD)\`."
# The headings of the version's sections, with or without a date.
awk -v h="# $pkg $version" '
  { sub(/[ \t\r]+$/, "") }
  $0 == h { print NR ": " $0; next }
  index($0, h " (") == 1 && substr($0, length(h) + 1) ~ /^ \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/ { print NR ": " $0 }
' "$pkgdir/NEWS.md" >"$out/headings"
n=$(wc -l <"$out/headings" | tr -d ' ')
if [ "$n" -ne 1 ]; then
  fail "Dates" "No single NEWS.md section for $pkg $version" \
    "\`NEWS.md\` has $n sections headed \`# $pkg $version\`, and the release needs exactly one." "$out/headings" -- \
    "Head the version's section \`# $pkg $version (YYYY-MM-DD)\` with the submission date, once."
fi
heading=$(cut -d' ' -f2- "$out/headings")
line=$(cut -d: -f1 "$out/headings")
news_date=$(printf '%s\n' "$heading" | sed -n 's/^.* (\([0-9-]*\))$/\1/p')
val "NEWS.md heading" "$heading (line $line)"
val "today (UTC)" "$today"
[ -n "$news_date" ] ||
  fail "Dates" "The NEWS.md heading has no date" "The section is headed \`$heading\`, without the submission date." -- \
    "The date commit sets both dates before the checks: head the section \`# $pkg $version ($today)\` and set \`Date: $today\` in \`DESCRIPTION\`, then check that commit again."
[ "$news_date" = "$desc_date" ] ||
  fail "Dates" "The dates differ" \
    "\`NEWS.md\` dates the release \`$news_date\`, and \`DESCRIPTION\`'s \`Date:\` is \`${desc_date:-(none)}\`." -- \
    "The date commit sets both to the submission date: make it, check that commit, and dispatch the submission on it."
days=$((($(date -u -d "$today" +%s) - $(date -u -d "$news_date" +%s)) / 86400))
if [ "$days" -gt 1 ] || [ "$days" -lt -1 ]; then
  if [ "${DRY_RUN:-false}" = true ]; then
    warn "Stale dates" "The release is dated $news_date, $days days from today ($today); a real run on this commit fails."
    summary "- **Dates:** \`$news_date\` in both, $days days from today; a real run on this commit fails until a date commit updates them."
  else
    fail "Dates" "The dates are not the submission date" \
      "Both dates are \`$news_date\`, $days days from today (\`$today\`), and a release carries its submission date." -- \
      "Take the path again from the date commit: set both dates to the submission date, run the checks on that commit, and dispatch the submission on it."
  fi
else
  summary "- **Dates:** \`$news_date\` in the \`NEWS.md\` heading and in \`DESCRIPTION\`."
fi
endgroup

# The section without its heading, and without blank lines around it, then the marker.
marker="<!-- cran-submission: $pkg $version -->"
awk -v start="$line" '
  NR == start { found = 1; next }
  found && /^# / { exit }
  found { print }
' "$pkgdir/NEWS.md" | sed '/./,$!d' | awk 'NF { for (; blank > 0; blank--) print ""; print; next } { blank++ }' >"$out/notes.md"
{
  echo
  echo "$marker"
} >>"$out/notes.md"
if [ "$(wc -l <"$out/notes.md")" -le 2 ]; then
  fail "Notes" "The NEWS.md section is empty" "The section \`$heading\` has no text." -- \
    "Write the version's release notes under its heading."
fi
group "Release notes"
cat "$out/notes.md"
endgroup
summary "- **Notes:** $(($(wc -l <"$out/notes.md") - 2)) lines from \`NEWS.md\`, ending with the marker \`$marker\`." ""

output package "$pkg" version "$version" date "$news_date" notes "$out/notes.md"
notice "Release version" "$pkg $version, dated $news_date"
