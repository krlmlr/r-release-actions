#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Finish the releases CRAN has accepted: tag, publish, and merge or close the checklist pull request.
#
#   release-status.sh [--dry-run]
#     Lists the releases whose notes carry the submission marker `<!-- cran-submission: <package> <version> -->`
#     and whose tag name is `v<version>`: every draft, and every published one whose checklist pull request is still open,
#     a release whose finish (step 4) did not complete. It does nothing when there is none.
#     It reads the source index of Posit's package manager once, P3M_REPO_URL/src/contrib/PACKAGES.gz,
#     as `fledge:::release_after_cran_built_binaries()` did; a listing there also means the binaries are on their way.
#     A version that index does not list yet, nor a later one, is a line in the report, and success.
#     A run finishes at most one release whose version is listed, and leaves the others for the next run.
#     For a draft whose version is listed, in this order, stopping at the first step that fails:
#       1. compare  checks that the draft's target is a full SHA whose DESCRIPTION carries the package and version,
#                   then compares CRAN's tarball of the version, from CRAN_URL/src/contrib/ or its Archive/<package>/,
#                   with the draft's asset `<package>_<version>.tar.gz`: the same files, types, executable bits and contents,
#                   but for the `MD5` file and the fields CRAN adds to DESCRIPTION, `Repository` and `Date/Publication`;
#                   a difference, a missing asset, or several drafts of the version fail, and nothing is tagged.
#       2. tag      writes the annotated tag `v<version>` on the draft's target, with `<package> <version>`,
#                   a blank line and the version's NEWS.md section at that commit as its message;
#                   a tag that exists on the target is kept, and one on another commit fails.
#       3. publish  publishes the draft, by its ID, as the latest release when P3M lists this version,
#                   and not as the latest when it lists a later one.
#       4. finish   finds the checklist pull request as `release-report.sh find` does, and tells the paths apart by it:
#                   a pull request that changes no file is the fast path's empty checklist pull request.
#                   Default path: checks that the release branch, the pull request's head, reaches the target,
#                   merges the default branch into it unless it carries the bump, commits the development bump on it (dev-bump.sh),
#                   and merges the pull request with a merge commit, at the head it just wrote.
#                   Fast path: checks that the default branch reaches the target, commits the development bump there,
#                   and closes the empty checklist pull request.
#                   A write it cannot make, such as a merge that conflicts, as a hotfix's does, or a protected branch,
#                   is handed over: the comment says what is left, with the commands, and the run stays green.
#                   Without a checklist pull request, the run warns and leaves step 4 to the maintainer.
#     A published release with an open checklist pull request whose version P3M lists takes step 1 against its asset,
#     then step 4, once its tag is found on its target; one that P3M does not list yet warns, and nothing is written.
#     Each accepted version gets one comment on its checklist pull request, `<!-- release-status: <package> <version> -->`,
#     created or updated in place, which says what was done and what is left; a version not listed yet gets none.
#     Every step takes what an earlier run did as done: a tag on the target, a published release,
#     a release branch that holds the default branch, and a branch that carries the bump.
#   release-status.sh compare <CRAN tarball> <draft tarball>
#     The comparison of step 1 alone, on two local files: exit 0 when they match, 1 with the differences, 2 on an error.
#
# --dry-run (or DRY_RUN `true`) reads and checks everything, writes nothing, and reports what a real run would write.
#
# Environment:
#   GH_REPO, GH_TOKEN    the repository, owner/name, and a token with `contents: write` and `pull-requests: write`
#   GH                   the gh command, default `gh`; release-status-test.sh stubs it
#   P3M_REPO_URL         default https://packagemanager.posit.co/cran/latest
#   CRAN_URL             default https://cran.r-project.org; release-status-test.sh points both at a local server
#   GITHUB_OUTPUT        receives `published`, one `<package> <version>` per line for each release this run published
#   GITHUB_STEP_SUMMARY, GITHUB_ACTIONS, GITHUB_SERVER_URL, GITHUB_RUN_ID
#
# Downloads are bounded, so that a run fits the workflow's job timeout:
# the P3M index takes at most 3 attempts of 2 minutes, CRAN's tarball at most 2 attempts of 2 minutes at each of its 2 URLs,
# and the draft's asset at most 5 minutes.
#
# Exit status: 0 when nothing failed, 1 when a version could not be checked, tagged, published or looked up, 2 on a usage error.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../cran-lib/cran-lib.sh
. "$here/../cran-lib/cran-lib.sh"

usage() {
  sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- comparing the tarballs -------------------------------------------------

# Unpacks <tarball> into <dir>, drops the MD5 file and the fields CRAN adds to DESCRIPTION.
normalized() { # <tarball> <dir>
  mkdir -p "$2"
  tar -xzf "$1" -C "$2" 2>"$2.err" || return 1
  local d
  for d in "$2"/*/; do
    [ -d "$d" ] || continue
    rm -f "$d/MD5"
    { [ -f "$d/DESCRIPTION" ] && [ ! -L "$d/DESCRIPTION" ]; } || continue
    awk '
      /^[^ \t]/ { skip = ($0 ~ /^(Repository|Date\/Publication):/) }
      !skip { print }' "$d/DESCRIPTION" >"$d/DESCRIPTION.tmp"
    mv "$d/DESCRIPTION.tmp" "$d/DESCRIPTION"
  done
}

# Every path below <dir> with its type, and `x` for a regular file its owner may execute.
listing() { # <dir>
  (cd "$1" && find . -mindepth 1 \( -type f -perm -u+x -printf '%P\t%y x\n' \) -o -printf '%P\t%y\n') | LC_ALL=C sort
}

# Exit 0 when the tarballs hold the same files, of the same types and executable bits, with the same contents,
# but for what CRAN writes; 1 when they differ, and 2 when they cannot be compared. The differences go to <diff file>.
compare_tarballs() { # <CRAN tarball> <draft tarball> <diff file>
  local dir rc=0
  dir=$(mktemp -d "$work/compare.XXXXXX")
  if ! normalized "$1" "$dir/cran"; then
    cat "$dir/cran.err" >"$3"
    return 2
  fi
  if ! normalized "$2" "$dir/draft"; then
    cat "$dir/draft.err" >"$3"
    return 2
  fi
  listing "$dir/cran" >"$dir/cran.list"
  listing "$dir/draft" >"$dir/draft.list"
  diff "$dir/cran.list" "$dir/draft.list" >"$dir/list.diff" || rc=$?
  [ "$rc" -le 1 ] || return 2
  rc=0
  diff -r --no-dereference "$dir/cran" "$dir/draft" >"$dir/content.diff" 2>&1 || rc=$?
  [ "$rc" -le 1 ] || {
    sed "s#$dir/##g" "$dir/content.diff" | head -n 60 >"$3"
    return 2
  }
  {
    if [ -s "$dir/list.diff" ]; then
      echo "Paths, types and executable bits (< CRAN, > draft):"
      cat "$dir/list.diff"
    fi
    sed "s#$dir/##g" "$dir/content.diff"
  } | head -n 60 >"$3"
  [ ! -s "$3" ] || return 1
}

if [ "${1:-}" = compare ]; then
  [ $# -eq 3 ] || usage
  rc=0
  compare_tarballs "$2" "$3" "$work/diff" || rc=$?
  if [ "$rc" -eq 0 ]; then
    say "The tarballs match, but for the MD5 file and the fields CRAN adds to DESCRIPTION."
  else
    cat "$work/diff"
  fi
  exit "$rc"
fi

dry_run=${DRY_RUN:-false}
case "${1:-}" in
  '') ;;
  --dry-run) dry_run=true ;;
  *) usage ;;
esac
[ $# -le 1 ] || usage

repo=${GH_REPO:-${GITHUB_REPOSITORY:-}}
valid_repo "$repo" || usage
export GH_REPO=$repo
gh=${GH:-gh}
p3m=${P3M_REPO_URL:-https://packagemanager.posit.co/cran/latest}
p3m=${p3m%/}
cran=${CRAN_URL:-https://cran.r-project.org}
cran=${cran%/}
index_url=$p3m/src/contrib/PACKAGES.gz
bot='github-actions[bot]'
run_url="${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/${GITHUB_RUN_ID:-0}"
bump_url=https://raw.githubusercontent.com/krlmlr/r-release-actions/main/actions/dev-bump/dev-bump.sh

dry() { [ "$dry_run" = true ]; }

if dry; then
  summary "## Release status: dry run" "" "Nothing is tagged, published, committed, merged, closed or commented." ""
else
  summary "## Release status" ""
fi

# --- the releases -----------------------------------------------------------

group "Releases: the drafts the CRAN submission wrote in $repo, and the published ones not finished"
# One line per release with the marker: state, tag, package, version, target, URL, ID,
# and the ID and digest of its tarball asset.
# shellcheck disable=SC2016  # a jq program, with jq's own $r, $m and $a
if ! "$gh" api --paginate "repos/$repo/releases?per_page=100" --jq '
  .[] | . as $r
  | ($r.body // "") | capture("<!-- cran-submission: (?<pkg>[^ ]+) (?<ver>[^ ]+) -->") | . as $m
  | ([$r.assets[]? | select(.name == "\($m.pkg)_\($m.ver).tar.gz")] | first) as $a
  | [(if $r.draft then "draft" else "published" end), $r.tag_name, $m.pkg, $m.ver, ($r.target_commitish // ""),
     $r.html_url, $r.id, ($a.id // ""), ($a.digest // "")] | @tsv' \
  >"$work/releases" 2>"$work/gh.err"; then
  fail "Releases" "The releases cannot be listed" "Listing the releases of $repo failed: $(head -n 1 "$work/gh.err")" "$work/gh.err" -- \
    "Check that the calling job grants \`contents: write\`: without it, the token does not see draft releases." \
    "Dispatch the workflow again; the next scheduled run tries again in any case."
fi
# The releases with an open checklist pull request, as `<package> <version>`: a published one among them is not finished.
# Whether the pull request counts as the checklist is decided later, as the submission decides it.
if ! "$gh" api --paginate "repos/$repo/pulls?state=open&per_page=100" \
  --jq '.[] | (.body // "") | capture("<!-- release-checklist: (?<p>[^ ]+) (?<v>[^ ]+) -->") | "\(.p) \(.v)"' \
  >"$work/open" 2>"$work/gh.err"; then
  fail "Releases" "The open pull requests cannot be listed" "Listing the open pull requests of $repo failed: $(head -n 1 "$work/gh.err")" "$work/gh.err" -- \
    "Check that the calling job grants \`pull-requests: write\`, then dispatch the workflow again."
fi
: >"$work/matching"
while IFS=$'\t' read -r state tag pkg version target url id aid digest; do
  [ -n "$state" ] || continue
  if ! valid_package "$pkg" || ! valid_version "$version" || [ "$tag" != "v$version" ]; then
    [ "$state" = published ] || say "  skipped: $url, tag $tag, marker $pkg $version"
    continue
  fi
  [ "$state" = draft ] || grep -qxF "$pkg $version" "$work/open" || continue
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$state" "$tag" "$pkg" "$version" "$target" "$url" "$id" "$aid" "$digest" >>"$work/matching"
  val "$state" "$pkg $version, target $target, $url"
done <"$work/releases"
endgroup
awk -F '\t' '$1 == "draft" { print $2 }' "$work/matching" | sort | uniq -d >"$work/duplicates"

if [ ! -s "$work/matching" ]; then
  say "No draft release of a CRAN submission in $repo, and no published one whose checklist pull request is open: nothing to do."
  summary "No draft release of a CRAN submission, and no published one whose checklist pull request is open: nothing to do."
  exit 0
fi

default_branch=$("$gh" api "repos/$repo" --jq .default_branch 2>"$work/gh.err") || default_branch=''
[[ $default_branch =~ ^[A-Za-z0-9._/-]+$ ]] ||
  fail "Repository" "The default branch cannot be read" \
    "Reading the default branch of $repo failed: $(head -n 1 "$work/gh.err"). Nothing was written." "$work/gh.err" -- \
    "Dispatch the workflow again; the next scheduled run tries again in any case."

# --- P3M --------------------------------------------------------------------

group "P3M: the source index of $p3m"
val "index" "$index_url"
if ! curl --fail --silent --show-error --location --retry 2 --connect-timeout 30 --max-time 120 \
  --output "$work/PACKAGES.gz" "$index_url" 2>"$work/curl.err" ||
  ! gzip -dc "$work/PACKAGES.gz" >"$work/PACKAGES" 2>>"$work/curl.err"; then
  fail "P3M" "P3M cannot be read" "Reading $index_url failed: $(head -n 1 "$work/curl.err")" "$work/curl.err" -- \
    "Check that $index_url answers, for instance with \`curl -sSI $index_url\`." \
    "Nothing was written; the next scheduled run tries again, or dispatch the workflow once P3M answers."
fi
val "packages" "$(grep -c '^Package:' "$work/PACKAGES" || true)"
endgroup

# The version the index lists for a package, empty when it lists none.
p3m_version() { # <package>
  awk -v p="$1" '
    { sub(/[ \t\r]+$/, "") }
    /^Package:/ { this = ($2 == p) }
    this && /^Version:/ { print $2; exit }' "$work/PACKAGES"
}

# Exit 0 when version <a> is later than <b>, as R's package_version() orders them:
# components split at `.` or `-` and compared as numbers, and of two versions equal up to the shorter one's end, the longer is later.
version_gt() { # <a> <b>
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, /[.-]/); nb = split(b, y, /[.-]/)
    for (i = 1; i <= na && i <= nb; i++) {
      if (x[i] + 0 > y[i] + 0) exit 0
      if (x[i] + 0 < y[i] + 0) exit 1
    }
    exit !(na > nb)
  }'
}

# At most one accepted release is finished per run, so that a run fits its job's timeout; the next run takes the next one.
budget=1

# Sets `served` to the version P3M lists for <package>, and exit 0 when that is <version> or a later one,
# which means CRAN accepted <version>, and this run has not finished another release yet.
# Otherwise it reports the version as not on P3M yet, or left for the next run, and exits 1.
accepted() { # <package> <version>
  served=$(p3m_version "$1")
  val "P3M lists" "${served:-(not listed)}"
  if [ "$served" != "$2" ] && { [ -z "$served" ] || ! version_gt "$served" "$2"; }; then
    endgroup
    say "$1 $2 is not on P3M yet: $index_url lists ${served:+$1 $served}${served:-no $1}."
    summary "- $1 $2 is not on P3M yet: $index_url lists ${served:+$1 $served}${served:-no $1}." ""
    return 1
  fi
  if [ "$budget" -eq 0 ]; then
    endgroup
    say "$1 $2 is on P3M, and is left for the next run, which finishes one release at a time."
    summary "- $1 $2 is on P3M, and is left for the next run, which finishes one release at a time." ""
    return 1
  fi
  budget=0
  if [ "$served" = "$2" ]; then
    did "P3M lists $1 $2, so CRAN has accepted it."
  else
    did "P3M lists $1 $served, later than $2, so CRAN published $2 before, if it accepted it: its tarball must be in CRAN's archive."
  fi
}

# --- GitHub helpers ---------------------------------------------------------

# The commit a tag points to, peeled; empty when there is no such tag.
tag_commit() { # <tag>
  local ref
  ref=$("$gh" api "repos/$repo/git/matching-refs/tags/$1" --jq ".[] | select(.ref == \"refs/tags/$1\") | .ref") || return 1
  [ -n "$ref" ] || return 0
  "$gh" api "repos/$repo/commits/refs/tags/$1" --jq .sha
}

# Exit 0 when <branch> reaches <sha>: the comparison from <sha> to the branch is identical or ahead.
reaches() { # <branch> <sha>
  local status
  status=$("$gh" api "repos/$repo/compare/$2...$1" --jq .status 2>>"$work/gh.err") || return 1
  [ "$status" = identical ] || [ "$status" = ahead ]
}

# A file at a commit, decoded from the contents API, into <out>.
file_at() { # <path> <ref> <out>
  "$gh" api "repos/$repo/contents/$1?ref=$2" --jq .content 2>>"$work/gh.err" | base64 -d >"$3" 2>>"$work/gh.err"
}

# The section of NEWS.md headed `# <package> <version>`, with or without a date, outside code fences, without its heading.
news_section() { # <NEWS.md> <package> <version>
  awk -v h="# $2 $3" '
    { line = $0; sub(/[ \t\r]+$/, "", line) }
    /^(```|~~~)/ { fence = !fence }
    !fence && line ~ /^# / {
      if (found) exit
      if (line == h || (index(line, h " (") == 1 && substr(line, length(h) + 1) ~ /^ \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/)) { found = 1; next }
    }
    found { print }
    END { if (!found) exit 1 }' "$1" | sed '/./,$!d' | awk 'NF { for (; blank > 0; blank--) print ""; print; next } { blank++ }'
}

# Prints the checklist pull request of a release, as the submission finds it, or nothing when there is not exactly one.
# Fails when the pull requests cannot be read.
checklist_pr() { # <package> <version>
  local out log rc=0
  out=$(mktemp "$work/find.XXXXXX")
  log=$(mktemp "$work/find.XXXXXX")
  REQUIRE=false GITHUB_OUTPUT=$out GITHUB_STEP_SUMMARY='' "$here/../release-report/release-report.sh" find "$1" "$2" \
    >"$log" 2>&1 || rc=$?
  cat "$log" >&2
  if [ "$rc" -ne 0 ]; then
    grep -E '^(::error|ERROR)' "$log" >"$work/gh.err" || cp "$log" "$work/gh.err"
    return 1
  fi
  sed -n 's/^pr=//p' "$out" | tail -n 1
}

# Commits the development bump to <branch>, unless its head carries it already; sets `bumped` to the new head,
# or to the unchanged head. A dry run computes the bump and writes nothing. Fails with the cause in $work/gh.err.
commit_bump() { # <branch> <package> <version>
  local branch=$1 pkg=$2 version=$3 head tree dir b1 b2 newtree commit changed got
  bumped=''
  head=$("$gh" api "repos/$repo/git/ref/heads/$branch" --jq .object.sha 2>>"$work/gh.err") || return 1
  dir=$(mktemp -d "$work/bump.XXXXXX")
  file_at DESCRIPTION "$head" "$dir/DESCRIPTION" || return 1
  file_at NEWS.md "$head" "$dir/NEWS.md" || return 1
  : >"$dir/out"
  GITHUB_OUTPUT=$dir/out "$here/../dev-bump/dev-bump.sh" "$dir" "$repo" "$default_branch" >>"$work/gh.err" 2>&1 || return 1
  changed=$(sed -n 's/^changed=//p' "$dir/out")
  got=$(sed -n 's/^version=//p' "$dir/out")
  if [ "$got" != "$version.9000" ]; then
    echo "\`$branch\` carries $pkg $got, not $version or $version.9000" >"$work/gh.err"
    return 1
  fi
  if [ "$changed" != true ]; then
    bumped=$head
    bump_note="\`$branch\` carries the development bump already"
    return 0
  fi
  if dry; then
    bumped=$head
    bump_note="would commit the development bump, $pkg $version.9000, to \`$branch\`"
    return 0
  fi
  tree=$("$gh" api "repos/$repo/git/commits/$head" --jq .tree.sha 2>>"$work/gh.err") || return 1
  b1=$("$gh" api -X POST "repos/$repo/git/blobs" -F "content=@$dir/DESCRIPTION" -f encoding=utf-8 --jq .sha 2>>"$work/gh.err") || return 1
  b2=$("$gh" api -X POST "repos/$repo/git/blobs" -F "content=@$dir/NEWS.md" -f encoding=utf-8 --jq .sha 2>>"$work/gh.err") || return 1
  newtree=$("$gh" api -X POST "repos/$repo/git/trees" -f "base_tree=$tree" \
    -f 'tree[][path]=DESCRIPTION' -f 'tree[][mode]=100644' -f 'tree[][type]=blob' -f "tree[][sha]=$b1" \
    -f 'tree[][path]=NEWS.md' -f 'tree[][mode]=100644' -f 'tree[][type]=blob' -f "tree[][sha]=$b2" \
    --jq .sha 2>>"$work/gh.err") || return 1
  commit=$("$gh" api -X POST "repos/$repo/git/commits" -f "message=Bump version to $version.9000" -f "tree=$newtree" \
    -f "parents[]=$head" --jq .sha 2>>"$work/gh.err") || return 1
  "$gh" api -X PATCH "repos/$repo/git/refs/heads/$branch" -f "sha=$commit" -F force=false --jq .object.sha >/dev/null 2>>"$work/gh.err" ||
    return 1
  bumped=$commit
  bump_note="committed the development bump, $pkg $version.9000, to \`$branch\` as $(commit_link "$commit")"
}

# Creates or updates github-actions[bot]'s comment on <pr> that starts with <marker>, from <body file>.
upsert_comment() { # <pr> <marker> <body file>
  local id
  id=$("$gh" api --paginate "repos/$repo/issues/$1/comments?per_page=100" \
    --jq ".[] | select(.user.login == \"$bot\" and (.body | startswith(\"$2\"))) | .id" 2>>"$work/gh.err" | tail -n 1) || return 1
  if [ -n "$id" ]; then
    "$gh" api -X PATCH "repos/$repo/issues/comments/$id" -F "body=@$3" --jq .html_url 2>>"$work/gh.err"
  else
    "$gh" api -X POST "repos/$repo/issues/$1/comments" -F "body=@$3" --jq .html_url 2>>"$work/gh.err"
  fi
}

# --- the comment ------------------------------------------------------------

done_lines=()
left=''
commands=''
handover() { # <what is left> <commands>
  left=$1
  commands=$2
  warn "Handed over" "$title: $1"
}
did() { done_lines+=("$1"); }
first_err() { grep -m 1 . "$work/gh.err" || echo "no message"; }

# Writes the version's comment, or shows it on a dry run; without a checklist pull request, the summary has it.
report() { # <pr> <outcome>
  local pr=$1 outcome=$2 body l
  body=$(mktemp "$work/comment.XXXXXX")
  {
    echo "<!-- release-status: $title -->"
    echo "### Release status: $title $outcome"
    echo
    printf 'Run [%s](%s), %s.\n' "${GITHUB_RUN_ID:-0}" "$run_url" "$(date -u '+%Y-%m-%d %H:%M UTC')"
    echo
    for l in "${done_lines[@]+"${done_lines[@]}"}"; do echo "- $l"; done
    if [ -n "$left" ]; then
      echo
      echo "**Left to the maintainer:** $left"
      if [ -n "$commands" ]; then
        echo
        echo '```sh'
        printf '%s\n' "$commands"
        echo '```'
      fi
    fi
  } >"$body"
  summary "#### Comment${pr:+ on #$pr}" "" '````markdown' "$(cat "$body")" '````' ""
  if [ -z "$pr" ] || dry; then
    return 0
  fi
  upsert_comment "$pr" "<!-- release-status: $title -->" "$body" >/dev/null ||
    warn "Comment not written" "Writing the release status comment on #$pr failed: $(tail -n 1 "$work/gh.err"). The run's summary has it."
}

# Stops a version with a failure that is also reported on its checklist pull request.
stop() { # <pr> <title> <message> [<excerpt>] -- <advice>... ; the comment line and what is left come from STOP_DID and STOP_LEFT
  local pr=$1
  shift
  failure "$title" "$@"
  did "**Stopped:** $STOP_DID"
  handover "$STOP_LEFT" ""
  report "$pr" "❌"
}

# --- step 4: finish ---------------------------------------------------------

finish() { # <package> <version> <target> <pr>
  local pkg=$1 version=$2 target=$3 pr=$4 info changed head hrepo hbase merged
  local qdef qhead qrepo qbranch
  qdef=$(printf '%q' "$default_branch")
  qrepo=$(printf '%q' "$repo")
  if [ -z "$pr" ]; then
    endgroup
    warn "No checklist pull request" \
      "$title is tagged and published, but no single checklist pull request carries its marker, so the merge, the development bump and closing are left to the maintainer."
    did "No single checklist pull request carries \`<!-- release-checklist: $title -->\`."
    handover "merge the release branch into \`$default_branch\` and commit the development bump, or, on the fast path, commit the bump to \`$default_branch\`." ""
    report "" "⚠️"
    return 0
  fi
  if ! info=$("$gh" api "repos/$repo/pulls/$pr" \
    --jq '[.changed_files, .head.ref, (.head.repo.full_name // "-"), .base.ref] | @tsv' 2>"$work/gh.err"); then
    failure "$title" "The checklist pull request cannot be read" "Reading #$pr failed: $(first_err)." "$work/gh.err" -- \
      "Dispatch the workflow again: the release is tagged and published, and the next run finishes it while #$pr is open."
    return 1
  fi
  IFS=$'\t' read -r changed head hrepo hbase <<<"$info"
  qhead=$(printf '%q' "$head")

  if [ "$changed" = 0 ]; then
    # The fast path: the release was made from the default branch.
    val "path" "fast: #$pr changes no file"
    if ! reaches "$default_branch" "$target"; then
      endgroup
      handover "\`$default_branch\` does not reach the released commit $(commit_link "$target"), so the bump is not the workflow's to write: bring the release onto \`$default_branch\`, commit the bump there, and close #$pr." ""
      report "$pr" "⚠️"
      return 0
    fi
    qbranch=$(printf '%q' "dev-bump-$version")
    if ! commit_bump "$default_branch" "$pkg" "$version"; then
      endgroup
      handover "the development bump could not be committed to \`$default_branch\` ($(first_err)), as where the branch is protected. Land it through a pull request, then close #$pr, which stays open until then." \
        "git fetch origin
git switch -c $qbranch origin/$qdef
curl -fsSL $bump_url | bash -s -- . $qrepo $qdef
git commit -am 'Bump version to $version.9000'
git push origin $qbranch"
      report "$pr" "⚠️"
      return 0
    fi
    did "${bump_note^}."
    if dry; then
      did "Would close the empty checklist pull request #$pr."
      endgroup
      report "$pr" "(dry run)"
      return 0
    fi
    if ! "$gh" api -X PATCH "repos/$repo/pulls/$pr" -f state=closed --jq .state >/dev/null 2>"$work/gh.err"; then
      failure "$title" "The checklist pull request could not be closed" "Closing #$pr failed: $(first_err)." "$work/gh.err" -- \
        "Dispatch the workflow again, or close #$pr by hand; the bump is on \`$default_branch\`."
      handover "closing #$pr failed ($(first_err)); the next run closes it, or close it by hand." ""
      report "$pr" "⚠️"
      return 1
    fi
    did "Closed the empty checklist pull request #$pr. A push with the workflow's token starts no workflows on \`$default_branch\`; they run at its next push."
    report "$pr" "✅"
    endgroup
    notice "Released" "$title is tagged, published and bumped on $default_branch; #$pr is closed."
    return 0
  fi

  # The default path: the checklist pull request is the release pull request.
  val "path" "default: #$pr from $hrepo:$head into $hbase"
  local hint="git fetch origin
git switch $qhead
git merge origin/$qdef
# Resolve the conflicts, taking $default_branch's side except for the release's fixes and its NEWS.md section,
# then \`git add\` the resolved files and:
git commit --no-edit
curl -fsSL $bump_url | bash -s -- . $qrepo $qdef
git commit -am 'Bump version to $version.9000'
git push origin $qhead
gh pr merge $pr --merge"
  if [ "$hrepo" != "$repo" ] || [ "$hbase" != "$default_branch" ]; then
    endgroup
    handover "#$pr merges \`$hrepo:$head\` into \`$hbase\`, not a branch of $repo into \`$default_branch\`, so its merge is not the workflow's to make: merge \`$default_branch\` into the release branch, commit the development bump there, and merge #$pr with a merge commit." ""
    report "$pr" "⚠️"
    return 0
  fi
  if ! reaches "$head" "$target"; then
    endgroup
    handover "the release branch \`$head\` does not reach the released commit $(commit_link "$target"), so the workflow does not merge it: check the branch, then merge \`$default_branch\` into it, commit the development bump, and merge #$pr with a merge commit." "$hint"
    report "$pr" "⚠️"
    return 0
  fi
  local bumped_already='' hsha
  if hsha=$("$gh" api "repos/$repo/git/ref/heads/$head" --jq .object.sha 2>>"$work/gh.err") &&
    file_at DESCRIPTION "$hsha" "$work/head-DESCRIPTION" &&
    [ "$(dcf_field Version "$work/head-DESCRIPTION")" = "$version.9000" ]; then
    bumped_already=1
  fi
  if [ -n "$bumped_already" ]; then
    did "\`$head\` carries the development bump already, so \`$default_branch\` is not merged into it again."
  elif dry; then
    did "Would merge \`$default_branch\` into \`$head\`."
  else
    if ! merged=$("$gh" api -X POST "repos/$repo/merges" -f "base=$head" -f "head=$default_branch" \
      -f "commit_message=Merge branch '$default_branch' into $head" --jq '.sha // ""' 2>"$work/gh.err"); then
      endgroup
      if grep -q 'HTTP 409' "$work/gh.err"; then
        handover "merging \`$default_branch\` into \`$head\` conflicts, as a hotfix's merge does by construction. Resolve it, commit the development bump, and merge #$pr with a merge commit." "$hint"
      else
        handover "merging \`$default_branch\` into \`$head\` failed ($(first_err)). Merge it, commit the development bump, and merge #$pr with a merge commit." "$hint"
      fi
      report "$pr" "⚠️"
      return 0
    fi
    if [ -n "$merged" ]; then
      did "Merged \`$default_branch\` into \`$head\` as $(commit_link "$merged")."
    else
      did "\`$head\` holds \`$default_branch\` already."
    fi
  fi
  if ! commit_bump "$head" "$pkg" "$version"; then
    endgroup
    handover "the development bump could not be committed to \`$head\` ($(first_err)). Commit it there and merge #$pr with a merge commit." \
      "git fetch origin
git switch $qhead
git pull --ff-only
curl -fsSL $bump_url | bash -s -- . $qrepo $qdef
git commit -am 'Bump version to $version.9000'
git push origin $qhead
gh pr merge $pr --merge"
    report "$pr" "⚠️"
    return 0
  fi
  did "${bump_note^}."
  if dry; then
    did "Would merge #$pr into \`$default_branch\` with a merge commit."
    endgroup
    report "$pr" "(dry run)"
    return 0
  fi
  if ! "$gh" api -X PUT "repos/$repo/pulls/$pr/merge" -f merge_method=merge -f "sha=$bumped" --jq .sha >"$work/merge.out" 2>"$work/gh.err"; then
    endgroup
    handover "merging #$pr into \`$default_branch\` failed ($(first_err)), as where \`$default_branch\` is protected. Merge it with a merge commit once its checks pass." \
      "gh pr merge $pr --merge"
    report "$pr" "⚠️"
    return 0
  fi
  did "Merged #$pr into \`$default_branch\` with a merge commit, $(commit_link "$(cat "$work/merge.out")"). A merge with the workflow's token starts no workflows on \`$default_branch\`; they run at its next push."
  endgroup
  notice "Released" "$title is tagged and published, and #$pr is merged with the development bump."
  report "$pr" "✅"
}

# Step 1 for a draft, and again for a published release before its finish: the target is a full SHA
# whose DESCRIPTION carries the version, and CRAN's tarball matches the release's asset, but for what CRAN writes.
# <kind> is `draft` or `release`. Stops the version with a failure, reported on <pr>, and exit 1 otherwise; sets `sha`.
check_release() { # <kind> <package> <version> <target> <url> <asset id> <digest> <pr>
  local kind=$1 pkg=$2 version=$3 target=$4 url=$5 aid=$6 digest=$7 pr=$8 nothing refused rc
  local base="${pkg}_${version}.tar.gz" dir=$work/$pkg-$version
  mkdir -p "$dir/cran" "$dir/draft"
  nothing="nothing was tagged or published"
  refused="so the tag was refused"
  if [ "$kind" != draft ]; then
    nothing="nothing was merged or bumped"
    refused="so the release is not finished"
  fi
  if ! valid_sha "$target"; then
    STOP_DID="the $kind's target \`$target\` is no full commit SHA, so the submitted commit is unknown; $nothing." \
      STOP_LEFT="set the $kind's target to the full SHA of the commit the accepted submission uploaded, recorded in its attempt comment; the next run finishes the release." \
      stop "$pr" "The $kind's target is no commit" \
      "$url targets \`$target\`, not the full SHA the submission writes, and a branch's head may have moved since; $nothing." -- \
      "Set the $kind's target to the full SHA of the submitted commit, recorded in its attempt comment, then dispatch the workflow."
    return 1
  fi
  if ! file_at DESCRIPTION "$target" "$dir/DESCRIPTION"; then
    failure "$title" "DESCRIPTION cannot be read" "Reading DESCRIPTION at $target failed: $(first_err); $nothing." "$work/gh.err" -- \
      "Dispatch the workflow again; the next scheduled run tries again in any case."
    return 1
  fi
  if [ "$(dcf_field Package "$dir/DESCRIPTION")" != "$pkg" ] || [ "$(dcf_field Version "$dir/DESCRIPTION")" != "$version" ]; then
    STOP_DID="DESCRIPTION at the $kind's target $(commit_link "$target") carries $(dcf_field Package "$dir/DESCRIPTION") $(dcf_field Version "$dir/DESCRIPTION"), not $title; $nothing." \
      STOP_LEFT="set the $kind's target to the commit the accepted submission uploaded; the next run finishes the release." \
      stop "$pr" "The $kind's target is not $title" \
      "DESCRIPTION at $target carries $(dcf_field Package "$dir/DESCRIPTION") $(dcf_field Version "$dir/DESCRIPTION"); $nothing." -- \
      "Set the $kind's target to the commit of the accepted submission, recorded in its attempt comment, then dispatch the workflow."
    return 1
  fi
  if [ -z "$aid" ]; then
    STOP_DID="the $kind carries no \`$base\`; $nothing." \
      STOP_LEFT="attach the submitted tarball to the $kind; the next run compares it and finishes the release." \
      stop "$pr" "The $kind has no tarball" \
      "The $kind $url carries no asset \`$base\`, so what CRAN accepted cannot be checked; $nothing." -- \
      "Attach the tarball the accepted submission uploaded, recorded in its attempt comment, to the $kind, then dispatch the workflow."
    return 1
  fi
  if ! curl --fail --silent --show-error --location --retry 1 --connect-timeout 30 --max-time 120 \
    --output "$dir/cran/$base" "$cran/src/contrib/$base" 2>"$work/curl.err" &&
    ! curl --fail --silent --show-error --location --retry 1 --connect-timeout 30 --max-time 120 \
      --output "$dir/cran/$base" "$cran/src/contrib/Archive/$pkg/$base" 2>>"$work/curl.err"; then
    failure "$title" "CRAN's tarball cannot be read" \
      "Neither $cran/src/contrib/$base nor its archive copy could be downloaded: $(tail -n 1 "$work/curl.err"); $nothing." "$work/curl.err" -- \
      "CRAN's mirrors may lag behind P3M by a few hours: the next scheduled run tries again, or dispatch the workflow later." \
      "Where P3M lists a later version and CRAN's archive has no $base, CRAN never published $version: delete its draft, as for an abandoned version."
    return 1
  fi
  if ! timeout 300 "$gh" api "repos/$repo/releases/assets/$aid" -H 'Accept: application/octet-stream' >"$dir/draft/$base" 2>"$work/gh.err"; then
    failure "$title" "The $kind's tarball cannot be read" \
      "Downloading \`$base\` from $url failed: $(first_err); $nothing." "$work/gh.err" -- \
      "Check that the calling job grants \`contents: write\`, then dispatch the workflow again."
    return 1
  fi
  sha=$(sha256_of "$dir/draft/$base")
  if [ -n "$digest" ] && [ "$digest" != "sha256:$sha" ]; then
    failure "$title" "The $kind's tarball is not the one GitHub recorded" \
      "GitHub records the digest \`$digest\` for \`$base\`, and the download's is \`sha256:$sha\`; $nothing." -- \
      "Dispatch the workflow again; if it persists, compare the asset with the attempt comment's SHA-256."
    return 1
  fi
  val "draft tarball" "$base, sha256 $sha"
  val "CRAN tarball" "$base, sha256 $(sha256_of "$dir/cran/$base")"
  rc=0
  compare_tarballs "$dir/cran/$base" "$dir/draft/$base" "$dir/diff" || rc=$?
  if [ "$rc" -eq 2 ]; then
    failure "$title" "The tarballs cannot be compared" "Unpacking or comparing the two \`$base\` failed; $nothing." "$dir/diff" -- \
      "Read the details; dispatch the workflow again once CRAN's and the $kind's tarballs can be read."
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    STOP_DID="CRAN's \`$base\` differs from the $kind's asset (sha256 \`$sha\`) beyond what CRAN writes, $refused; $nothing. The run's summary shows the differences." \
      STOP_LEFT="find the upload CRAN accepted, tag its commit, and make the $kind match it; the next run then finishes the release." \
      stop "$pr" "CRAN's tarball differs from the $kind's" \
      "CRAN publishes a $base that differs from the $kind's asset beyond the MD5 file and the fields CRAN adds to DESCRIPTION, so CRAN accepted another upload than the one the $kind records, $refused; $nothing." \
      "$dir/diff" -- \
      "Find the upload CRAN accepted: a confirmation link from an earlier attempt may have been followed. The attempt comments on the checklist pull request record each attempt's commit and SHA-256." \
      "Tag the commit of the upload CRAN accepted by hand, attach that tarball to the $kind and set its target to that commit, then dispatch the workflow."
    return 1
  fi
  did "CRAN's \`$base\` matches the $kind's asset (sha256 \`$sha\`), but for what CRAN writes."
}

# --- a published release whose checklist pull request is open ---------------

resume() { # <tag> <package> <version> <target> <url> <asset id> <digest>
  local tag=$1 pkg=$2 version=$3 target=$4 url=$5 aid=$6 digest=$7 pr tagged
  group "Release: $title, published"
  val "release" "$url"
  if ! accepted "$pkg" "$version"; then
    [ "$budget" -eq 0 ] ||
      warn "Published before CRAN lists it" \
        "$url is published and its checklist pull request is open, but P3M does not list $title yet, so nothing is merged or bumped until it does."
    return 0
  fi
  summary "### $title" "" "- Release: [$title]($url), published, with its checklist pull request still open." "- P3M lists $pkg $served." ""
  if ! pr=$(checklist_pr "$pkg" "$version"); then
    failure "$title" "The checklist pull request cannot be found" "Reading the open pull requests failed: $(first_err)." "$work/gh.err" -- \
      "Dispatch the workflow again; the next scheduled run tries again in any case."
    return 1
  fi
  [ -n "$pr" ] || {
    endgroup
    say "$title: an open pull request carries its checklist marker, but none counts as its checklist pull request; nothing to finish."
    summary "- No open pull request counts as the checklist pull request of $title; nothing to finish." ""
    return 0
  }
  did "[$title]($url) is published already, and its checklist pull request is still open, so this run finishes it."
  check_release release "$pkg" "$version" "$target" "$url" "$aid" "$digest" "$pr" || return 1
  if ! tagged=$(tag_commit "$tag" 2>"$work/gh.err"); then
    failure "$title" "The tag cannot be read" "Reading the tag $tag failed: $(first_err)." "$work/gh.err" -- \
      "Dispatch the workflow again; nothing was written."
    return 1
  fi
  if [ "$tagged" != "$target" ]; then
    STOP_DID="the tag \`$tag\` points to \`${tagged:-nothing}\`, not to the release's target $(commit_link "$target"), so nothing was merged or bumped." \
      STOP_LEFT="decide which commit CRAN accepted, and make the tag and the release agree; the next run then finishes the release." \
      stop "$pr" "The tag $tag is not on the release's target" \
      "The release $url targets $target, and the tag $tag points to ${tagged:-nothing}; nothing was written." -- \
      "Find the commit CRAN accepted from the attempt comments on the checklist pull request."
    return 1
  fi
  did "The tag \`$tag\` is on $(commit_link "$target")."
  finish "$pkg" "$version" "$target" "$pr"
}

# --- a draft ----------------------------------------------------------------

process() { # <tag> <package> <version> <target> <url> <id> <asset id> <digest>
  local tag=$1 pkg=$2 version=$3 target=$4 url=$5 id=$6 aid=$7 digest=$8
  local pr tagged tagsha msg latest dir
  dir=$work/$pkg-$version
  mkdir -p "$dir"

  group "Release: $title"
  val "draft" "$url, id $id"
  val "target" "$target"
  accepted "$pkg" "$version" || return 0
  summary "### $title" "" "- Draft release: [$title]($url), tag name \`$tag\`" "- P3M lists $pkg $served." ""

  if ! pr=$(checklist_pr "$pkg" "$version"); then
    failure "$title" "The checklist pull request cannot be found" "Reading the open pull requests failed: $(first_err); nothing was written." "$work/gh.err" -- \
      "Dispatch the workflow again; the next scheduled run tries again in any case."
    return 1
  fi
  val "checklist pull request" "${pr:-(none)}"

  # 1. compare
  if grep -qxF "$tag" "$work/duplicates"; then
    STOP_DID="several drafts carry the tag name \`$tag\`; nothing was tagged or published." \
      STOP_LEFT="keep the draft CRAN accepted and delete the others; the next run finishes the release." \
      stop "$pr" "Several drafts of $title" \
      "More than one draft release with the submission marker carries the tag name $tag; nothing was tagged or published." -- \
      "Keep the draft of the submission CRAN accepted, the one whose asset and target the attempt comments on the checklist pull request record, and delete the others." \
      "The next scheduled run then finishes the release, or dispatch the workflow."
    return 1
  fi
  check_release draft "$pkg" "$version" "$target" "$url" "$aid" "$digest" "$pr" || return 1

  # 2. tag
  if ! tagged=$(tag_commit "$tag" 2>"$work/gh.err"); then
    failure "$title" "The tag cannot be read" "Reading the tag $tag failed: $(first_err); nothing was tagged or published." "$work/gh.err" -- \
      "Dispatch the workflow again; nothing was tagged or published."
    return 1
  fi
  if [ -n "$tagged" ] && [ "$tagged" != "$target" ]; then
    STOP_DID="the tag \`$tag\` points to $(commit_link "$tagged"), not to the draft's target $(commit_link "$target"); nothing was published." \
      STOP_LEFT="decide which commit CRAN accepted, and make the draft's target and the tag agree." \
      stop "$pr" "The tag $tag points elsewhere" \
      "The tag $tag points to $tagged, and the draft targets $target; a tag is never moved, so nothing was published." -- \
      "Find out which commit CRAN accepted from the attempt comments on the checklist pull request." \
      "If the tag is right, set the draft's target to it; if not, the tag was written by mistake: a maintainer decides about deleting it, since a tag cannot be recalled from clones."
    return 1
  fi
  if [ -n "$tagged" ]; then
    did "The tag \`$tag\` exists on $(commit_link "$target") already."
  else
    if ! file_at NEWS.md "$target" "$dir/NEWS.md" || ! news_section "$dir/NEWS.md" "$pkg" "$version" >"$dir/section"; then
      failure "$title" "No NEWS.md section for the tag" \
        "NEWS.md at $target has no section headed \`# $pkg $version\`, or cannot be read: $(first_err); nothing was tagged or published." "$work/gh.err" -- \
        "Check the draft's target: the submission drafted it from a commit with that section."
      return 1
    fi
    msg=$dir/message
    { printf '%s\n\n' "$title"; cat "$dir/section"; } >"$msg"
    if dry; then
      did "Would write the annotated tag \`$tag\` on $(commit_link "$target"), with the version's NEWS.md section as its message."
    else
      if ! tagsha=$("$gh" api -X POST "repos/$repo/git/tags" -f "tag=$tag" -F "message=@$msg" -f "object=$target" -f type=commit \
        --jq .sha 2>"$work/gh.err") ||
        ! "$gh" api -X POST "repos/$repo/git/refs" -f "ref=refs/tags/$tag" -f "sha=$tagsha" --jq .ref >/dev/null 2>>"$work/gh.err"; then
        failure "$title" "The tag could not be written" "Writing the tag $tag failed: $(first_err); nothing was published." "$work/gh.err" -- \
          "Check that the calling job grants \`contents: write\`, and that no ruleset protects tags against the workflow's token, then dispatch the workflow again."
        did "**Stopped:** writing the tag \`$tag\` failed; nothing was published."
        handover "write the tag, or let the workflow write it, then dispatch the workflow again." \
          "git fetch origin
git tag -a $tag $target -F - <<'EOF'
$(cat "$msg")
EOF
git push origin $tag"
        report "$pr" "❌"
        return 1
      fi
      did "Wrote the annotated tag \`$tag\` on $(commit_link "$target")."
    fi
  fi

  # 3. publish
  if dry; then
    if [ "$served" = "$version" ]; then
      did "Would publish the draft as the latest release."
    else
      did "Would publish the draft, not as the latest release, since P3M lists $pkg $served."
    fi
  else
    # Only the version P3M lists is the latest; an older one finished after it is published below it.
    latest=false
    [ "$served" != "$version" ] || latest=true
    if ! "$gh" api -X PATCH "repos/$repo/releases/$id" -F draft=false -f "make_latest=$latest" --jq .html_url >/dev/null 2>"$work/gh.err"; then
      STOP_DID="publishing the draft failed; the tag stays, and the next run publishes it." \
        STOP_LEFT="dispatch the workflow again once the token can publish releases." \
        stop "$pr" "The release could not be published" "Publishing $url failed: $(first_err)." "$work/gh.err" -- \
        "Check that the calling job grants \`contents: write\`, then dispatch the workflow again; the tag stays."
      return 1
    fi
    if [ "$latest" = true ]; then
      did "Published [$title]($url) as the latest release."
    else
      did "Published [$title]($url), not as the latest release, since P3M lists $pkg $served."
    fi
    printf '%s\n' "$title" >>"$work/published"
  fi

  # 4. finish
  finish "$pkg" "$version" "$target" "$pr"
}

failed=0
: >"$work/published"
while IFS=$'\t' read -r state tag pkg version target url id aid digest <&3; do
  title="$pkg $version"
  done_lines=()
  left=''
  commands=''
  : >"$work/gh.err"
  if [ "$state" = draft ]; then
    process "$tag" "$pkg" "$version" "$target" "$url" "$id" "$aid" "$digest" || failed=1
  else
    resume "$tag" "$pkg" "$version" "$target" "$url" "$aid" "$digest" || failed=1
  fi
done 3<"$work/matching"

if [ -n "${GITHUB_OUTPUT:-}" ] && [ -s "$work/published" ]; then
  { echo "published<<EOF_PUBLISHED"; cat "$work/published"; echo "EOF_PUBLISHED"; } >>"$GITHUB_OUTPUT"
fi
exit "$failed"
