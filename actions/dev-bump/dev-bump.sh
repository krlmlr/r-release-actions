#!/usr/bin/env bash
# Write the development bump that follows a CRAN release into a package's checkout.
#
# In <package dir>, for the release `<package> X.Y.Z` that DESCRIPTION carries:
#   - DESCRIPTION: `Version: X.Y.Z` becomes `Version: X.Y.Z.9000`; nothing else changes.
#   - NEWS.md: a development section at the top, the heading `# <package> (development version)`
#     and one line, the compare link from the release's tag to the default branch:
#
#       # <package> (development version)
#
#       Changes since vX.Y.Z: <https://github.com/<owner>/<repo>/compare/vX.Y.Z...<branch>>
#
#     It replaces a development section already at the top, and goes above the first heading otherwise;
#     lines before the first heading, such as a marker, stay where they are.
#     NEWS.md must hold the release's section, headed `# <package> X.Y.Z` with or without ` (YYYY-MM-DD)`.
#     Headings inside code fences are not headings.
# A checkout that already carries `X.Y.Z.9000` is left alone, so running it twice changes nothing.
# It writes no commit: the release status workflow commits the two files, and a maintainer commits them by hand.
#
# Usage:
#   dev-bump.sh <package dir> <owner/repo> <branch>
#
# It stands alone and sources nothing, so that a maintainer can run it from a download:
#   curl -fsSL https://raw.githubusercontent.com/krlmlr/r-release-actions/main/actions/dev-bump/dev-bump.sh |
#     bash -s -- . <owner/repo> main
#
# Writes `version`, the new version, and `changed`, `true` or `false`, to GITHUB_OUTPUT when it is set.
# Exit status: 0 on success or when there is nothing to do, 1 when the checkout is no release, 2 on a usage error.

set -euo pipefail

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
[ $# -eq 3 ] || usage
dir=$1 repo=$2 branch=$3
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || usage
[[ $branch =~ ^[A-Za-z0-9._/-]+$ ]] || usage

die() {
  printf 'dev-bump: %s\n' "$1" >&2
  exit 1
}
[ -f "$dir/DESCRIPTION" ] || die "no DESCRIPTION in $dir"
[ -f "$dir/NEWS.md" ] || die "no NEWS.md in $dir"

field() { # <field> <file>
  awk -v f="$1" '{ sub(/[ \t\r]+$/, "") } index($0, f ":") == 1 { v = substr($0, length(f) + 2); sub(/^[ \t]+/, "", v); print v; exit }' "$2"
}
pkg=$(field Package "$dir/DESCRIPTION")
version=$(field Version "$dir/DESCRIPTION")
[[ $pkg =~ ^[A-Za-z][A-Za-z0-9.]*[A-Za-z0-9]$ ]] || die "DESCRIPTION gives no valid package name: '$pkg'"

out() {
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  printf 'version=%s\nchanged=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
}

if [[ $version =~ ^[0-9]+[.-][0-9]+[.-][0-9]+\.9000$ ]]; then
  echo "$pkg $version is already the development version: nothing to do."
  out "$version" false
  exit 0
fi
[[ $version =~ ^[0-9]+[.-][0-9]+[.-][0-9]+$ ]] ||
  die "DESCRIPTION gives $pkg $version, which is no three-component release version"
dev=$version.9000
tag=v$version

# The release's own section must be there: the bump follows that release, and no other.
awk -v h="# $pkg $version" '
  /^(```|~~~)/ { fence = !fence; next }
  fence { next }
  { sub(/[ \t\r]+$/, "") }
  $0 == h || (index($0, h " (") == 1 && substr($0, length(h) + 1) ~ /^ \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/) { found = 1 }
  END { exit !found }' "$dir/NEWS.md" ||
  die "NEWS.md has no section headed '# $pkg $version'"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# The awk program reads the tag and the link from its environment.
TAG=$tag COMPARE="https://github.com/$repo/compare/$tag...$branch" awk -v pkg="$pkg" '
  BEGIN { dev_heading = "# " pkg " (development version)" }
  { line = $0; sub(/[ \t\r]+$/, "", line) }
  !fence && line ~ /^# / {
    headings++
    if (headings == 1) {
      print dev_heading
      print ""
      print "Changes since " ENVIRON["TAG"] ": <" ENVIRON["COMPARE"] ">"
      print ""
      if (line == dev_heading) { skipping = 1; next }
    }
    skipping = 0
  }
  /^(```|~~~)/ { fence = !fence }
  !skipping { print }
  END { if (!headings) exit 1 }' "$dir/NEWS.md" >"$tmp" ||
  die "NEWS.md has no heading"
cat "$tmp" >"$dir/NEWS.md"

awk -v dev="$dev" '
  !done && /^Version:/ { sub(/^Version:[ \t]*[^ \t\r]+/, "Version: " dev); done = 1 }
  { print }' "$dir/DESCRIPTION" >"$tmp"
cat "$tmp" >"$dir/DESCRIPTION"

echo "Bumped $pkg $version to $dev, with the development section of NEWS.md comparing $tag with $branch."
out "$dev" true
