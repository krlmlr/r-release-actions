#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Finish the releases CRAN has accepted: tag, publish, and merge or close the checklist pull request.
#
#   release-status.sh [--dry-run]
#     Lists the draft releases whose notes end with the submission marker `<!-- cran-submission: <package> <version> -->`
#     and whose tag name is `v<version>`, and does nothing when there is none.
#     Otherwise it reads the source index of Posit's package manager once, P3M_REPO_URL/src/contrib/PACKAGES.gz,
#     as `fledge:::release_after_cran_built_binaries()` did; a listing there also means the binaries are on their way.
#     A version that index does not list yet is a line in the report, and success.
#     For a draft whose version it lists, in this order, stopping at the first step that fails:
#       1. compare  CRAN's tarball of the version, from CRAN_URL/src/contrib/ or its Archive/<package>/,
#                   with the draft's asset `<package>_<version>.tar.gz`, ignoring the `MD5` file
#                   and the fields CRAN adds to DESCRIPTION, `Repository` and `Date/Publication`;
#                   a difference, a missing asset, or several drafts of the version fail, and nothing is tagged.
#       2. tag      writes the annotated tag `v<version>` on the draft's target, with `<package> <version>`,
#                   a blank line and the version's NEWS.md section at that commit as its message;
#                   a tag that exists on the target is kept, and one on another commit fails.
#       3. publish  publishes the draft, by its ID, as the latest release.
#       4. finish   finds the checklist pull request as `release-report.sh find` does, and tells the paths apart by it:
#                   a pull request that changes no file is the fast path's empty checklist pull request.
#                   Default path: checks that the release branch, the pull request's head, reaches the draft's target,
#                   merges the default branch into it, commits the development bump on it (dev-bump.sh),
#                   and merges the pull request with a merge commit, at the head it just wrote.
#                   Fast path: checks that the default branch reaches the target, commits the development bump there,
#                   and closes the empty checklist pull request.
#                   A write it cannot make, such as a merge that conflicts, as a hotfix's does, or a protected branch,
#                   is handed over: the comment says what is left, with the commands, and the run stays green.
#                   Without a checklist pull request, the run warns and leaves step 4 to the maintainer.
#     Each accepted version gets one comment on its checklist pull request, `<!-- release-status: <package> <version> -->`,
#     created or updated in place, which says what was done and what is left; a version not listed yet gets none.
#     Running it again is safe: an existing tag on the target, a branch that holds the bump, and a merged
#     default branch are taken as done; a published release is no draft and is not listed again.
#   release-status.sh compare <CRAN tarball> <draft tarball>
#     Step 1 alone, on two local files: exit 0 when they match, 1 with the differences otherwise.
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
# Exit status: 0 when nothing failed, 1 when a version could not be tagged or published, 2 on a usage error.

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
    [ -f "$d/DESCRIPTION" ] || continue
    awk '
      /^[^ \t]/ { skip = ($0 ~ /^(Repository|Date\/Publication):/) }
      !skip { print }' "$d/DESCRIPTION" >"$d/DESCRIPTION.tmp"
    mv "$d/DESCRIPTION.tmp" "$d/DESCRIPTION"
  done
}

# Exit 0 when the tarballs hold the same files with the same contents, but for what CRAN writes;
# the differences go to <diff file>.
compare_tarballs() { # <CRAN tarball> <draft tarball> <diff file>
  local dir
  dir=$(mktemp -d "$work/compare.XXXXXX")
  if ! normalized "$1" "$dir/cran"; then
    cat "$dir/cran.err" >"$3"
    return 1
  fi
  if ! normalized "$2" "$dir/draft"; then
    cat "$dir/draft.err" >"$3"
    return 1
  fi
  diff -r "$dir/cran" "$dir/draft" | sed "s#$dir/##g" | head -n 60 >"$3" || true
  [ ! -s "$3" ]
}

if [ "${1:-}" = compare ]; then
  [ $# -eq 3 ] || usage
  if compare_tarballs "$2" "$3" "$work/diff"; then
    say "The tarballs match, but for the MD5 file and the fields CRAN adds to DESCRIPTION."
    exit 0
  fi
  cat "$work/diff"
  exit 1
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

# --- the drafts -------------------------------------------------------------

group "Drafts: the releases the CRAN submission drafted in $repo"
# One line per draft with the marker: tag, package, version, target, URL, ID, and the ID and digest of its tarball asset.
# shellcheck disable=SC2016  # a jq program, with jq's own $r and $m
if ! "$gh" api --paginate "repos/$repo/releases?per_page=100" --jq '
  .[] | select(.draft) | . as $r
  | ($r.body // "") | capture("<!-- cran-submission: (?<pkg>[^ ]+) (?<ver>[^ ]+) -->") | . as $m
  | ([$r.assets[]? | select(.name == "\($m.pkg)_\($m.ver).tar.gz")] | first) as $a
  | [$r.tag_name, $m.pkg, $m.ver, $r.target_commitish, $r.html_url, $r.id, ($a.id // ""), ($a.digest // "")] | @tsv' \
  >"$work/drafts" 2>"$work/gh.err"; then
  fail "Drafts" "The releases cannot be listed" "Listing the releases of $repo failed: $(head -n 1 "$work/gh.err")" "$work/gh.err" -- \
    "Check that the calling job grants \`contents: write\`: without it, the token does not see draft releases." \
    "Dispatch the workflow again; the next scheduled run tries again in any case."
fi
: >"$work/matching"
while IFS=$'\t' read -r tag pkg version target url id aid digest; do
  [ -n "$tag$pkg" ] || continue
  if ! valid_package "$pkg" || ! valid_version "$version" || [ "$tag" != "v$version" ]; then
    say "  skipped: $url, tag $tag, marker $pkg $version"
    continue
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$tag" "$pkg" "$version" "$target" "$url" "$id" "$aid" "$digest" >>"$work/matching"
  val "draft" "$pkg $version, target $target, $url"
done <"$work/drafts"
endgroup
cut -f 1 "$work/matching" | sort | uniq -d >"$work/duplicates"

if [ ! -s "$work/matching" ]; then
  say "No draft release of a CRAN submission in $repo: nothing to do."
  summary "No draft release of a CRAN submission: nothing to do."
  exit 0
fi

# --- P3M --------------------------------------------------------------------

group "P3M: the source index of $p3m"
val "index" "$index_url"
if ! curl --fail --silent --show-error --location --retry 3 --connect-timeout 30 --max-time 300 \
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

# --- GitHub helpers ---------------------------------------------------------

default_branch=''
get_default_branch() {
  [ -z "$default_branch" ] || return 0
  default_branch=$("$gh" api "repos/$repo" --jq .default_branch 2>"$work/gh.err") || default_branch=''
  [ -n "$default_branch" ] || default_branch=main
}

# The commit a tag points to, peeled; empty when there is no such tag.
tag_commit() { # <tag>
  local ref
  ref=$("$gh" api "repos/$repo/git/matching-refs/tags/$1" --jq ".[] | select(.ref == \"refs/tags/$1\") | .ref") || return 1
  [ -n "$ref" ] || return 0
  "$gh" api "repos/$repo/commits/refs/tags/$1" --jq .sha
}

# A full SHA for a commit-ish.
resolve() { # <commit-ish>
  if valid_sha "$1"; then printf '%s\n' "$1"; else "$gh" api "repos/$repo/commits/$1" --jq .sha; fi
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

# The checklist pull request of a release, as the submission finds it; empty when there is not exactly one.
checklist_pr() { # <package> <version>
  local out
  out=$(mktemp "$work/find.XXXXXX")
  REQUIRE=false GITHUB_OUTPUT=$out GITHUB_STEP_SUMMARY='' "$here/../release-report/release-report.sh" find "$1" "$2" >&2 || true
  sed -n 's/^pr=//p' "$out" | tail -n 1
}

# Commits the development bump to <branch>, unless its head carries it already; sets `bumped` to the new head,
# or to the unchanged head. A dry run computes the bump and writes nothing. Fails with GitHub's error in <errors>.
commit_bump() { # <branch> <package> <version>
  local branch=$1 pkg=$2 version=$3 head tree dir b1 b2 newtree commit changed
  bumped=''
  head=$("$gh" api "repos/$repo/git/ref/heads/$branch" --jq .object.sha 2>>"$work/gh.err") || return 1
  dir=$(mktemp -d "$work/bump.XXXXXX")
  file_at DESCRIPTION "$head" "$dir/DESCRIPTION" || return 1
  file_at NEWS.md "$head" "$dir/NEWS.md" || return 1
  : >"$dir/out"
  GITHUB_OUTPUT=$dir/out "$here/../dev-bump/dev-bump.sh" "$dir" "$repo" "$default_branch" >>"$work/gh.err" 2>&1 || return 1
  changed=$(sed -n 's/^changed=//p' "$dir/out")
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

# --- one accepted version ---------------------------------------------------

# State for the comment of the version at hand.
done_lines=()
left=''
commands=''
handover() { # <what is left> <commands>
  left=$1
  commands=$2
  warn "Handed over" "$title: $1"
}
did() { done_lines+=("$1"); }

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

process() { # <tag> <package> <version> <target> <url> <id> <asset id> <digest>
  local tag=$1 pkg=$2 version=$3 target=$4 url=$5 id=$6 aid=$7 digest=$8
  local base="${pkg}_${version}.tar.gz" pr sha tagged tagsha msg info changed head hrepo hbase merged
  title="$pkg $version"
  done_lines=()
  left=''
  commands=''
  : >"$work/gh.err"

  group "Release: $title"
  val "draft" "$url, id $id"
  val "target" "$target"
  local served
  served=$(p3m_version "$pkg")
  val "P3M lists" "${served:-(not listed)}"
  if [ "$served" != "$version" ]; then
    endgroup
    say "$title is not on P3M yet: $index_url lists ${served:+$pkg $served}${served:-no $pkg}."
    summary "- $title is not on P3M yet: $index_url lists ${served:+$pkg $served}${served:-no $pkg}." ""
    return 0
  fi
  summary "### $title" "" "- Draft release: [$title]($url), tag name \`$tag\`" "- P3M lists $pkg $served." ""
  did "P3M lists $title, so CRAN has accepted it."

  pr=$(checklist_pr "$pkg" "$version")
  val "checklist pull request" "${pr:-(none)}"

  # 1. compare
  if grep -qxF "$tag" "$work/duplicates"; then
    failure "$title" "Several drafts of $title" \
      "More than one draft release with the submission marker carries the tag name $tag; nothing was tagged or published." -- \
      "Keep the draft of the submission CRAN accepted, the one whose asset and target the attempt comments on the checklist pull request record, and delete the others." \
      "The next scheduled run then finishes the release, or dispatch the workflow."
    did "**Stopped:** several drafts carry the tag name \`$tag\`; nothing was tagged or published."
    handover "keep the draft CRAN accepted and delete the others; the next run finishes the release." ""
    report "$pr" "❌"
    return 1
  fi
  if [ -z "$aid" ]; then
    failure "$title" "The draft has no tarball" \
      "The draft release $url carries no asset \`$base\`, so what CRAN accepted cannot be checked; nothing was tagged or published." -- \
      "Attach the tarball the accepted submission uploaded, recorded in its attempt comment, to the draft, then dispatch the workflow."
    did "**Stopped:** the draft carries no \`$base\`; nothing was tagged or published."
    handover "attach the submitted tarball to the draft; the next run compares it and finishes the release." ""
    report "$pr" "❌"
    return 1
  fi
  mkdir -p "$work/$pkg-$version/cran" "$work/$pkg-$version/draft"
  if ! curl --fail --silent --show-error --location --retry 3 --connect-timeout 30 --max-time 300 \
    --output "$work/$pkg-$version/cran/$base" "$cran/src/contrib/$base" 2>"$work/curl.err" &&
    ! curl --fail --silent --show-error --location --retry 3 --connect-timeout 30 --max-time 300 \
      --output "$work/$pkg-$version/cran/$base" "$cran/src/contrib/Archive/$pkg/$base" 2>>"$work/curl.err"; then
    failure "$title" "CRAN's tarball cannot be read" \
      "Neither $cran/src/contrib/$base nor the archive could be downloaded: $(tail -n 1 "$work/curl.err"); nothing was tagged or published." "$work/curl.err" -- \
      "CRAN's mirrors may lag behind P3M by a few hours: the next scheduled run tries again, or dispatch the workflow later."
    return 1
  fi
  if ! "$gh" api "repos/$repo/releases/assets/$aid" -H 'Accept: application/octet-stream' >"$work/$pkg-$version/draft/$base" 2>"$work/gh.err"; then
    failure "$title" "The draft's tarball cannot be read" \
      "Downloading \`$base\` from $url failed: $(head -n 1 "$work/gh.err"); nothing was tagged or published." "$work/gh.err" -- \
      "Check that the calling job grants \`contents: write\`, then dispatch the workflow again."
    return 1
  fi
  sha=$(sha256_of "$work/$pkg-$version/draft/$base")
  if [ -n "$digest" ] && [ "$digest" != "sha256:$sha" ]; then
    failure "$title" "The draft's tarball is not the one GitHub recorded" \
      "GitHub records the digest \`$digest\` for \`$base\`, and the download's is \`sha256:$sha\`; nothing was tagged or published." -- \
      "Dispatch the workflow again; if it persists, compare the asset with the attempt comment's SHA-256."
    return 1
  fi
  val "draft tarball" "$base, sha256 $sha"
  val "CRAN tarball" "$base, sha256 $(sha256_of "$work/$pkg-$version/cran/$base")"
  if ! compare_tarballs "$work/$pkg-$version/cran/$base" "$work/$pkg-$version/draft/$base" "$work/$pkg-$version/diff"; then
    failure "$title" "CRAN's tarball differs from the draft's" \
      "CRAN publishes a $base that differs from the draft's asset beyond the MD5 file and the fields CRAN adds to DESCRIPTION, so CRAN accepted another upload than the one the draft records. The tag was refused; nothing was tagged or published." \
      "$work/$pkg-$version/diff" -- \
      "Find the upload CRAN accepted: a confirmation link from an earlier attempt may have been followed. The attempt comments on the checklist pull request record each attempt's commit and SHA-256." \
      "Tag the commit of the upload CRAN accepted by hand, attach that tarball to the draft and set its target to that commit, then dispatch the workflow."
    did "**Stopped:** CRAN's \`$base\` differs from the draft's asset (sha256 \`$sha\`) beyond what CRAN writes, so the tag was refused; nothing was tagged or published. The run's summary shows the differences."
    handover "find the upload CRAN accepted, tag its commit, and make the draft match it; the next run then publishes the release." ""
    report "$pr" "❌"
    return 1
  fi
  did "CRAN's \`$base\` matches the draft's asset (sha256 \`$sha\`), but for what CRAN writes."

  # 2. tag
  if ! target=$(resolve "$target" 2>"$work/gh.err") || ! tagged=$(tag_commit "$tag" 2>"$work/gh.err"); then
    failure "$title" "The tag or the target cannot be read" "Reading the tag $tag or the draft's target failed: $(head -n 1 "$work/gh.err")." "$work/gh.err" -- \
      "Dispatch the workflow again; nothing was tagged or published."
    return 1
  fi
  if [ -n "$tagged" ] && [ "$tagged" != "$target" ]; then
    failure "$title" "The tag $tag points elsewhere" \
      "The tag $tag points to $tagged, and the draft targets $target; a tag is never moved, so nothing was published." -- \
      "Find out which commit CRAN accepted from the attempt comments on the checklist pull request." \
      "If the tag is right, set the draft's target to it; if not, the tag was written by mistake: a maintainer decides about deleting it, since a tag cannot be recalled from clones."
    did "**Stopped:** the tag \`$tag\` points to $(commit_link "$tagged"), not to the draft's target $(commit_link "$target"); nothing was published."
    handover "decide which commit CRAN accepted, and make the draft's target and the tag agree." ""
    report "$pr" "❌"
    return 1
  fi
  if [ -n "$tagged" ]; then
    did "The tag \`$tag\` exists on $(commit_link "$target") already."
  else
    if ! file_at NEWS.md "$target" "$work/$pkg-$version/NEWS.md" || ! news_section "$work/$pkg-$version/NEWS.md" "$pkg" "$version" >"$work/$pkg-$version/section"; then
      failure "$title" "No NEWS.md section for the tag" \
        "NEWS.md at $target has no section headed \`# $pkg $version\`, or cannot be read: $(head -n 1 "$work/gh.err"); nothing was tagged or published." "$work/gh.err" -- \
        "Check the draft's target: the submission drafted it from a commit with that section."
      return 1
    fi
    msg=$work/$pkg-$version/message
    { printf '%s\n\n' "$title"; cat "$work/$pkg-$version/section"; } >"$msg"
    if dry; then
      did "Would write the annotated tag \`$tag\` on $(commit_link "$target"), with the version's NEWS.md section as its message."
    else
      if ! tagsha=$("$gh" api -X POST "repos/$repo/git/tags" -f "tag=$tag" -F "message=@$msg" -f "object=$target" -f type=commit \
        --jq .sha 2>"$work/gh.err") ||
        ! "$gh" api -X POST "repos/$repo/git/refs" -f "ref=refs/tags/$tag" -f "sha=$tagsha" --jq .ref >/dev/null 2>>"$work/gh.err"; then
        failure "$title" "The tag could not be written" "Writing the tag $tag failed: $(head -n 1 "$work/gh.err"); nothing was published." "$work/gh.err" -- \
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
    did "Would publish the draft as the latest release."
  else
    if ! "$gh" api -X PATCH "repos/$repo/releases/$id" -F draft=false -f make_latest=true --jq .html_url >/dev/null 2>"$work/gh.err"; then
      failure "$title" "The release could not be published" "Publishing $url failed: $(head -n 1 "$work/gh.err")." "$work/gh.err" -- \
        "Check that the calling job grants \`contents: write\`, then dispatch the workflow again; the tag stays."
      did "**Stopped:** publishing the draft failed; the tag stays, and the next run publishes it."
      report "$pr" "❌"
      return 1
    fi
    did "Published [$title]($url) as the latest release."
    printf '%s\n' "$title" >>"$work/published"
  fi

  # 4. finish
  get_default_branch
  val "default branch" "$default_branch"
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
    endgroup
    handover "the checklist pull request #$pr could not be read ($(head -n 1 "$work/gh.err")): merge it or close it as its path asks, and commit the development bump." ""
    report "$pr" "⚠️"
    return 0
  fi
  IFS=$'\t' read -r changed head hrepo hbase <<<"$info"

  if [ "$changed" = 0 ]; then
    # The fast path: the release was made from the default branch.
    val "path" "fast: #$pr changes no file"
    if ! reaches "$default_branch" "$target"; then
      endgroup
      handover "\`$default_branch\` does not reach the released commit $(commit_link "$target"), so the bump is not the workflow's to write: bring the release onto \`$default_branch\`, commit the bump there, and close #$pr." ""
      report "$pr" "⚠️"
      return 0
    fi
    if ! commit_bump "$default_branch" "$pkg" "$version"; then
      endgroup
      handover "the development bump could not be committed to \`$default_branch\` ($(grep -m 1 . "$work/gh.err" || true)), as where the branch is protected. Land it through a pull request, then close #$pr, which stays open until then." \
        "git fetch origin
git switch -c dev-bump-$version origin/$default_branch
curl -fsSL $bump_url | bash -s -- . $repo $default_branch
git commit -am 'Bump version to $version.9000'
git push origin dev-bump-$version"
      report "$pr" "⚠️"
      return 0
    fi
    did "$(capitalize "$bump_note")."
    if dry; then
      did "Would close the empty checklist pull request #$pr."
    else
      did "Closed the empty checklist pull request #$pr. A push with the workflow's token starts no workflows on \`$default_branch\`; they run at its next push."
      report "$pr" "✅"
      if ! "$gh" api -X PATCH "repos/$repo/pulls/$pr" -f state=closed --jq .state >/dev/null 2>"$work/gh.err"; then
        endgroup
        warn "Not closed" "Closing #$pr failed: $(head -n 1 "$work/gh.err"); close it by hand."
        return 0
      fi
      endgroup
      notice "Released" "$title is tagged, published and bumped on $default_branch; #$pr is closed."
      return 0
    fi
    endgroup
    report "$pr" "(dry run)"
    return 0
  fi

  # The default path: the checklist pull request is the release pull request.
  val "path" "default: #$pr from $head into $hbase"
  local hint="git fetch origin
git switch $head
git merge origin/$default_branch
# Resolve the conflicts, taking $default_branch's side except for the release's fixes and its NEWS.md section,
# then \`git add\` the resolved files and:
git commit --no-edit
curl -fsSL $bump_url | bash -s -- . $repo $default_branch
git commit -am 'Bump version to $version.9000'
git push origin $head
gh pr merge $pr --merge"
  if [ "$hrepo" != "$repo" ] || [ "$hbase" != "$default_branch" ]; then
    endgroup
    handover "#$pr merges \`$hrepo:$head\` into \`$hbase\`, not a branch of $repo into \`$default_branch\`, so its merge is not the workflow's to make: merge \`$default_branch\` into the release branch, commit the development bump there, and merge #$pr with a merge commit." ""
    report "$pr" "⚠️"
    return 0
  fi
  if ! reaches "$head" "$target"; then
    endgroup
    handover "the release branch \`$head\` does not reach the released commit $(commit_link "$target"), so it is not merged by the workflow: check the branch, then merge \`$default_branch\` into it, commit the development bump, and merge #$pr with a merge commit." "$hint"
    report "$pr" "⚠️"
    return 0
  fi
  if dry; then
    did "Would merge \`$default_branch\` into \`$head\`."
  else
    if ! merged=$("$gh" api -X POST "repos/$repo/merges" -f "base=$head" -f "head=$default_branch" \
      -f "commit_message=Merge branch '$default_branch' into $head" --jq '.sha // ""' 2>"$work/gh.err"); then
      endgroup
      if grep -q 'HTTP 409' "$work/gh.err"; then
        handover "merging \`$default_branch\` into \`$head\` conflicts, as a hotfix's merge does by construction. Resolve it, commit the development bump, and merge #$pr with a merge commit." "$hint"
      else
        handover "merging \`$default_branch\` into \`$head\` failed ($(head -n 1 "$work/gh.err")). Merge it, commit the development bump, and merge #$pr with a merge commit." "$hint"
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
    handover "the development bump could not be committed to \`$head\` ($(grep -m 1 . "$work/gh.err" || true)). Commit it there and merge #$pr with a merge commit." \
      "git fetch origin
git switch $head
git pull --ff-only
curl -fsSL $bump_url | bash -s -- . $repo $default_branch
git commit -am 'Bump version to $version.9000'
git push origin $head
gh pr merge $pr --merge"
    report "$pr" "⚠️"
    return 0
  fi
  did "$(capitalize "$bump_note")."
  if dry; then
    did "Would merge #$pr into \`$default_branch\` with a merge commit."
    endgroup
    report "$pr" "(dry run)"
    return 0
  fi
  if ! "$gh" api -X PUT "repos/$repo/pulls/$pr/merge" -f merge_method=merge -f "sha=$bumped" --jq .sha >"$work/merge.out" 2>"$work/gh.err"; then
    endgroup
    handover "merging #$pr into \`$default_branch\` failed ($(head -n 1 "$work/gh.err")), as where \`$default_branch\` is protected. Merge it with a merge commit once its checks pass." \
      "gh pr merge $pr --merge"
    report "$pr" "⚠️"
    return 0
  fi
  did "Merged #$pr into \`$default_branch\` with a merge commit, $(commit_link "$(cat "$work/merge.out")"). A merge with the workflow's token starts no workflows on \`$default_branch\`; they run at its next push."
  endgroup
  notice "Released" "$title is tagged and published, and #$pr is merged with the development bump."
  report "$pr" "✅"
  return 0
}

capitalize() { printf '%s' "${1^}"; }

failed=0
: >"$work/published"
while IFS=$'\t' read -r tag pkg version target url id aid digest <&3; do
  process "$tag" "$pkg" "$version" "$target" "$url" "$id" "$aid" "$digest" || failed=1
done 3<"$work/matching"

if [ -n "${GITHUB_OUTPUT:-}" ] && [ -s "$work/published" ]; then
  { echo "published<<EOF_PUBLISHED"; cat "$work/published"; echo "EOF_PUBLISHED"; } >>"$GITHUB_OUTPUT"
fi
exit "$failed"
