#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Adapted from krlmlr/duckplyr's .github/actions/release-report/release-report.sh at f98ad13 (MIT).
# Report to the release's checklist pull request.
#
#   find <package> <version>
#     The checklist pull request is the open pull request whose body's first line, without a byte order mark
#     and surrounding whitespace, is `<!-- release-checklist: <package> <version> -->` and whose author is either a bot account
#     with the head branch in this repository, other than a dependency updater's, or a person with write access,
#     or, where the token cannot read that, an owner, member or collaborator.
#     One carrying the marker elsewhere in its body, by a dependency updater, by a bot from a fork,
#     or by anyone else is named in a warning and ignored.
#     Writes `pr` to GITHUB_OUTPUT. None, or more than one, fails when REQUIRE is `true`, and warns otherwise.
#   submitted <pr> <package> <version>
#     Refuses a version that an earlier attempt comment records, whatever its commit or tarball,
#     because an upload whose confirmation link was never followed does not show in CRAN's queue.
#     RESUBMIT `true` lets it through with a warning; DRY_RUN `true` turns the refusal into a warning.
#   status <pr> <key> <title>
#     The workflow's one comment, found by `<!-- release-report: <key> -->` among github-actions[bot]'s comments,
#     created or updated in place with the job results in RESULTS and the Markdown in DETAILS.
#   builders <pr> <package> <version>
#     The builder uploads' one comment, found by `<!-- release-builders: <package> <version> -->`
#     among github-actions[bot]'s comments, created or updated in place:
#     each win-builder flavor's upload from WINBUILDER_RESULTS, and macbuilder's result.
#     DRY_RUN `true` prints the comment to the log and the step summary, writes nothing, and takes an empty <pr>.
#   attempt <pr> <package> <version> <sha> <sha256> <tarball name>
#     A new comment for a submission attempt, which nothing edits afterwards:
#     the attempt's number, the submitted commit, the tarball's SHA-256, and links to the run and the draft release.
#     The number counts github-actions[bot]'s earlier comments carrying
#     `<!-- cran-submission-attempt: <package> <version> -->` on the pull request.
#   sync <package> <version> <sha> <branch> [<pr>]
#     In a fork only: prints the commands that bring the parent repository, read from the repository's `parent`,
#     in line with the submission, to be run by hand from a clone with push access to the parent,
#     where the remote `upstream` is the parent and `origin` the fork. Outside a fork it prints nothing.
#     The commands go to the log and to the step summary; nothing here runs them.
#
# Environment:
#   GH_TOKEN, GH_REPO    a token with `pull-requests: write` (`read` for `find`), and the repository, owner/name
#   GH                   the gh command, default `gh`; release-report-test.sh stubs it
#   REQUIRE              `find`: `true` fails without exactly one checklist pull request
#   RESUBMIT, DRY_RUN    `submitted`: `true` lets a version submitted before through, or only warns about it
#   RESULTS              `status`: one `<job>=<result>` per line, as `needs.<job>.result` gives it
#   DETAILS              `status`: Markdown appended below the job results, may be empty
#   WINBUILDER_RESULTS   `builders`: `<flavor>=<uploaded|failed|dry-run>`, separated by spaces; WINBUILDER_JOB its job's result
#   MACBUILDER_FLAVOR, MACBUILDER_URL, MACBUILDER_OUTCOME, MACBUILDER_STATUS, MACBUILDER_JOB
#                        `builders`: macbuilder's flavor, result page, outcome (`ok`, `note`, `warning`, `error`, `timeout`),
#                        `Status:` line, and its job's result
#   SHA, SHA256          `builders`: the commit and the tarball's SHA-256, may be empty
#   DRAFT_URL            `attempt`: the draft release
#   DRY_RUN              `sync`: `true` says the commands apply after a real run
#   GITHUB_SERVER_URL, GITHUB_RUN_ID, GITHUB_RUN_NUMBER, GITHUB_RUN_ATTEMPT, GITHUB_REF_NAME, GITHUB_EVENT_NAME
#                        the run that is reported
#   GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, GITHUB_ACTIONS
#
# Exit status: 0 on success, 1 on a failure, 2 on a usage error.

set -euo pipefail

# shellcheck source=../cran-lib/cran-lib.sh
. "$(dirname "$0")/../cran-lib/cran-lib.sh"

# The first line of a pull request's body, without a byte order mark and surrounding whitespace, as a jq filter;
# an empty or missing body has an empty first line, as `"" | split("\n")` is empty.
first_line_jq='((.body // "") | split("\n")[0] // "") | sub("^[\\s\ufeff]+"; "") | sub("\\s+$"; "")'

usage() {
  sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
repo=${GH_REPO:?}
gh=${GH:-gh}
bot='github-actions[bot]'
run_url() { printf '%s' "${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/${GITHUB_RUN_ID:-0}"; }

# The IDs of the bot's comments on <pr> whose body starts with <marker>, oldest first.
bot_comments() { # <pr> <marker>
  "$gh" api --paginate "repos/$repo/issues/$1/comments?per_page=100" \
    --jq ".[] | select(.user.login == \"$bot\" and (.body | startswith(\"$2\"))) | .id"
}

# The builder uploads' one comment on <pr>: win-builder's uploads, whose results arrive by email,
# and macbuilder's check result, created or updated in place; DRY_RUN `true` prints it and writes nothing.
cmd_builders() {
  [ $# -eq 3 ] || usage
  local pr=$1 pkg=$2 version=$3
  { [[ $pr =~ ^[0-9]*$ ]] && valid_package "$pkg" && valid_version "$version"; } || usage
  [ -n "$pr" ] || [ "${DRY_RUN:-false}" = true ] || usage
  local marker="<!-- release-builders: $pkg $version -->" overall=success body errf id
  local wjob=${WINBUILDER_JOB:-} mjob=${MACBUILDER_JOB:-} flavor result line wlines='' mline
  body=$(mktemp)
  errf=$(mktemp)
  # shellcheck disable=SC2064  # expand now
  trap "rm -f '$body' '$errf'" EXIT
  for flavor in ${WINBUILDER_RESULTS:-}; do
    result=${flavor#*=}
    flavor=${flavor%%=*}
    case "$result" in
      uploaded) line="uploaded; the results arrive by email to the maintainer" ;;
      dry-run) line="not uploaded on a dry run" ;;
      failed) line="**upload failed**"; overall=failure ;;
      *) line="$result" ;;
    esac
    wlines+="- win-builder \`$flavor\`: $line"$'\n'
  done
  if [ -z "$wlines" ]; then
    wlines="- win-builder: no upload, job \`${wjob:-not run}\`"$'\n'
    [ "$wjob" = skipped ] || overall=failure
  fi
  local murl=${MACBUILDER_URL:-} mstatus=${MACBUILDER_STATUS:-}
  case "${MACBUILDER_OUTCOME:-}" in
    ok) mline="\`Status: $mstatus\`" ;;
    note | warning) mline="\`Status: $mstatus\`"; [ "$overall" = failure ] || overall=attention ;;
    error) mline="**\`Status: $mstatus\`**"; overall=failure ;;
    timeout) mline="no result yet when the run stopped waiting"; [ "$overall" = failure ] || overall=attention ;;
    *)
      if [ "${DRY_RUN:-false}" = true ] && [ "$mjob" = success ]; then
        mline="not uploaded on a dry run"
      else
        mline="**no result**, job \`${mjob:-not run}\`"
        [ "$mjob" = skipped ] || overall=failure
      fi
      ;;
  esac
  [ -z "$murl" ] || mline+=", [result page]($murl)"
  local icon
  case "$overall" in
    success) icon="✅" ;;
    failure) icon="❌" ;;
    *) icon="⚠️" ;;
  esac
  {
    echo "$marker"
    echo "### $icon Builder checks: $pkg $version"
    echo
    # shellcheck disable=SC2016  # Markdown backticks
    printf 'Run [#%s](%s) (attempt %s, %s) on `%s`, %s.\n' "${GITHUB_RUN_NUMBER:-0}" "$(run_url)" \
      "${GITHUB_RUN_ATTEMPT:-1}" "${GITHUB_EVENT_NAME:-}" "${GITHUB_REF_NAME:-}" "$(date -u '+%Y-%m-%d %H:%M UTC')"
    echo
    [ -z "${SHA:-}" ] || echo "- Commit: $SHA"
    [ -z "${SHA256:-}" ] || echo "- Tarball: \`${pkg}_$version.tar.gz\`, SHA-256 \`$SHA256\`"
    printf '%s' "$wlines"
    echo "- macbuilder \`${MACBUILDER_FLAVOR:-r-devel}\`: $mline"
    echo
    echo "These checks inform the release and do not gate it. Later runs of this workflow update this comment."
  } >"$body"
  if [ "${DRY_RUN:-false}" = true ]; then
    group "Dry run: the comment a real run writes${pr:+ on #$pr}"
    cat "$body"
    endgroup
    summary "### Report: dry run" "" "Nothing was written. A real run writes this comment${pr:+ on #$pr}:" "" '````markdown' "$(cat "$body")" '````' ""
    return 0
  fi
  id=$(bot_comments "$pr" "$marker" 2>"$errf") ||
    fail "Report" "The checklist pull request's comments cannot be read" \
      "Reading the comments of #$pr failed: $(head -n 1 "$errf"). The run's summary page has the results." -- \
      "Check that the calling job grants \`pull-requests: write\`; the uploads stand, and the next run updates the comment."
  id=$(printf '%s\n' "$id" | tail -n 1)
  if [ -n "$id" ]; then
    "$gh" api -X PATCH "repos/$repo/issues/comments/$id" -F "body=@$body" --jq .html_url
    say "Updated the builders' comment on #$pr."
  else
    "$gh" api -X POST "repos/$repo/issues/$pr/comments" -F "body=@$body" --jq .html_url
    say "Posted the builders' comment on #$pr."
  fi
}

cmd_find() {
  [ $# -eq 2 ] || usage
  local pkg=$1 version=$2
  { valid_package "$pkg" && valid_version "$version"; } || usage
  local marker="<!-- release-checklist: $pkg $version -->" found trusted others n errf
  errf=$(mktemp)
  # shellcheck disable=SC2064  # expand now
  trap "rm -f '$errf'" EXIT
  found=$("$gh" api --paginate "repos/$repo/pulls?state=open&per_page=100" \
    --jq ".[] | select((.body // \"\") | contains(\"$marker\"))
      | [.number, .author_association, .user.login, .user.type, (.head.repo.full_name // \"-\"), (($first_line_jq) == \"$marker\")]
      | @tsv" 2>"$errf") ||
    fail "Checklist" "The open pull requests cannot be read" "Listing the open pull requests of $repo failed: $(head -n 1 "$errf")." -- \
      "Check that the calling job grants \`pull-requests: read\`, then dispatch the submission again."
  # The marker counts only as the body's first line: a body that quotes text from elsewhere, such as release notes,
  # must not make a pull request the checklist.
  # A bot account (type `Bot`, login `<app>[bot]`) has no collaborator permission to read. Its pull request counts
  # when its head branch is in this repository, which needs `pull-requests: write` on it: an App installed with that,
  # or any workflow of the repository through its token, as github-actions[bot]. So the marker must start the body,
  # and more than one such pull request fails a real run rather than letting one of them be chosen.
  # Dependabot's and Renovate's pull requests quote dependencies' release notes, and are ignored with a warning,
  # as is a bot's pull request from a fork.
  # A person needs write access, read from `collaborators/<login>/permission` (admin, maintain and write read as
  # `admin` or `write`). That endpoint answers 404 for an App's bot account and may for someone outside the repository,
  # so an unreadable permission falls back to the author's association with the repository:
  # anyone but an owner, member or collaborator is ignored with a warning, as a stray marker must not block a release;
  # an owner, member or collaborator whose access cannot be verified fails a real run with GitHub's error,
  # and a dry run warns and accepts them.
  local number assoc login type head first perm trusted='' others=''
  while IFS=$'\t' read -r number assoc login type head first; do
    [ -n "$number" ] || continue
    if [ "$first" != true ]; then
      others+="#$number by $login (the marker is not the body's first line) "
      continue
    fi
    case "$login" in
      'dependabot[bot]' | 'renovate[bot]')
        others+="#$number by $login (a dependency update) "
        continue
        ;;
    esac
    if [ "$type" = Bot ] && [[ $login =~ ^[A-Za-z0-9-]+\[bot\]$ ]]; then
      if [ "$head" = "$repo" ]; then
        trusted+="$number"$'\n'
      else
        others+="#$number by $login (a bot, from $head) "
      fi
      continue
    fi
    if [[ $login =~ ^[A-Za-z0-9-]+(\[bot\])?$ ]]; then
      perm=$("$gh" api "repos/$repo/collaborators/$login/permission" --jq .permission 2>"$errf") || perm=''
    else
      perm=''
      echo "the login is not a GitHub login" >"$errf"
    fi
    if [ -n "$perm" ]; then
      case "$perm" in
        admin | write) trusted+="$number"$'\n' ;;
        *) others+="#$number by $login ($perm access) " ;;
      esac
      continue
    fi
    case "$assoc" in
      OWNER | MEMBER | COLLABORATOR)
        [ "${REQUIRE:-false}" != true ] ||
          fail "Checklist" "The access of the checklist pull request's author cannot be read" \
            "Reading the access of $login ($assoc), who opened #$number, failed: $(head -n 1 "$errf"). Nothing was drafted or uploaded." -- \
            "Check that the calling job's token can read \`repos/$repo/collaborators/$login/permission\`, then dispatch the submission again."
        warn "Permission unknown" \
          "The access of $login, who opened #$number, cannot be read ($(head -n 1 "$errf")); as $assoc they are accepted on a dry run, and a real run fails."
        trusted+="$number"$'\n'
        ;;
      *) others+="#$number by $login ($assoc, access unreadable) " ;;
    esac
  done <<<"$found"
  trusted=${trusted%$'\n'}
  [ -z "$others" ] ||
    warn "Checklist pull request ignored" "Ignored ${others}: the checklist pull request starts its body with the marker \
and is opened by someone with write access or by an App from a branch of $repo."
  n=$(count_lines "$trusted")
  if [ "$n" -eq 1 ]; then
    say "Checklist pull request: #$trusted"
    summary "- Checklist pull request: #$trusted" ""
    output pr "$trusted"
    return 0
  fi
  local what="no open pull request"
  [ "$n" -eq 0 ] || what="$n open pull requests ($(printf '%s' "$trusted" | sed 's/^/#/' | paste -s -d ' ' -))"
  if [ "${REQUIRE:-false}" = true ]; then
    fail "Checklist" "No single checklist pull request" \
      "There is $what by someone with write access or an App whose body starts with \`$marker\`; the submission records each attempt there. Nothing was drafted or uploaded." -- \
      "Start the body of the release's checklist pull request, and only of that one, with the line \`$marker\`, then dispatch the submission again."
  fi
  warn "No single checklist pull request" "There is $what whose body starts with $marker; a real run fails."
  summary "- Checklist pull request: $what starts with \`$marker\`; a real run fails." ""
  output pr ""
}

cmd_submitted() {
  [ $# -eq 3 ] || usage
  local pr=$1 pkg=$2 version=$3
  { [[ $pr =~ ^[0-9]+$ ]] && valid_package "$pkg" && valid_version "$version"; } || usage
  local marker="<!-- cran-submission-attempt: $pkg $version -->" earlier errf
  errf=$(mktemp)
  # An upload whose confirmation link nobody followed does not show in CRAN's queue; the attempt comment does.
  # Any earlier attempt of the version counts, whatever its commit or tarball: a rebuilt tarball differs in its digest.
  earlier=$("$gh" api --paginate "repos/$repo/issues/$pr/comments?per_page=100" \
    --jq ".[] | select(.user.login == \"$bot\" and (.body | startswith(\"$marker\"))) | .html_url" 2>"$errf") || {
    local err
    err=$(head -n 1 "$errf")
    rm -f "$errf"
    fail "Attempt" "The checklist pull request's comments cannot be read" \
      "Reading the comments of #$pr failed: $err. Nothing was drafted or uploaded." -- \
      "Check that the calling job grants \`pull-requests: read\`, then dispatch the submission again."
  }
  rm -f "$errf"
  earlier=$(printf '%s\n' "$earlier" | paste -s -d ' ' -)
  if [ -z "$earlier" ]; then
    summary "- No earlier attempt of $pkg $version." ""
    return 0
  fi
  if [ "${RESUBMIT:-false}" = true ]; then
    warn "Resubmission" "$pkg $version was submitted before ($earlier); \`resubmit\` submits it again."
    summary "- **Resubmission:** $pkg $version was submitted before ($earlier), and \`resubmit\` submits it again." ""
    return 0
  fi
  if [ "${DRY_RUN:-false}" = true ]; then
    warn "Submitted before" "$pkg $version was submitted before ($earlier); a real run refuses unless \`resubmit\` is on."
    summary "- **Submitted before:** $earlier; a real run refuses unless \`resubmit\` is on." ""
    return 0
  fi
  fail "Attempt" "$pkg $version was submitted before" \
    "An earlier attempt of $pkg $version is recorded: $earlier. Nothing was drafted or uploaded." -- \
    "If CRAN's confirmation email of that attempt arrived and nobody followed its link, follow it instead of submitting again." \
    "After a rejection and its fix, or if CRAN never received the upload, dispatch the submission with \`resubmit\` on."
}

cmd_status() {
  [ $# -eq 3 ] || usage
  local pr=$1 key=$2 title=$3
  { [[ $pr =~ ^[0-9]+$ ]] && [[ $key =~ ^[A-Za-z0-9._-]+$ ]]; } || usage
  local overall=success job result icon body id marker="<!-- release-report: $key -->"
  while IFS='=' read -r job result; do
    [ -n "$job" ] || continue
    case "$result" in
      failure) overall=failure ;;
      cancelled) [ "$overall" = failure ] || overall=cancelled ;;
    esac
  done <<<"${RESULTS:-}"
  case "$overall" in
    success) icon="✅" ;;
    failure) icon="❌" ;;
    *) icon="⚠️" ;;
  esac
  body=$(mktemp)
  # shellcheck disable=SC2064  # expand now
  trap "rm -f '$body'" EXIT
  {
    echo "$marker"
    echo "### $icon $title: $overall"
    echo
    # shellcheck disable=SC2016  # Markdown backticks
    printf 'Run [#%s](%s) (attempt %s, %s) on `%s`, %s.\n' "${GITHUB_RUN_NUMBER:-0}" "$(run_url)" \
      "${GITHUB_RUN_ATTEMPT:-1}" "${GITHUB_EVENT_NAME:-}" "${GITHUB_REF_NAME:-}" "$(date -u '+%Y-%m-%d %H:%M UTC')"
    echo
    while IFS='=' read -r job result; do
      [ -n "$job" ] || continue
      echo "- \`$job\`: $result"
    done <<<"${RESULTS:-}"
    if [ -n "${DETAILS:-}" ]; then
      echo
      printf '%s\n' "$DETAILS"
    fi
    echo
    echo "The run's summary page has the details. Later runs of this workflow update this comment."
  } >"$body"
  local errf
  errf=$(mktemp)
  # shellcheck disable=SC2064  # expand now
  trap "rm -f '$body' '$errf'" EXIT
  id=$(bot_comments "$pr" "$marker" 2>"$errf") ||
    fail "Report" "The checklist pull request's comments cannot be read" \
      "Reading the comments of #$pr failed: $(head -n 1 "$errf"). The run's summary page has the results." -- \
      "Check that the calling job grants \`pull-requests: write\`; the run's results stand, and the next run updates the comment."
  id=$(printf '%s\n' "$id" | tail -n 1)
  if [ -n "$id" ]; then
    "$gh" api -X PATCH "repos/$repo/issues/comments/$id" -F "body=@$body" --jq .html_url
    say "Updated the comment on #$pr."
  else
    "$gh" api -X POST "repos/$repo/issues/$pr/comments" -F "body=@$body" --jq .html_url
    say "Posted a comment on #$pr."
  fi
}

cmd_attempt() {
  [ $# -eq 6 ] || usage
  local pr=$1 pkg=$2 version=$3 sha=$4 sha256=$5 name=$6
  { [[ $pr =~ ^[0-9]+$ ]] && valid_package "$pkg" && valid_version "$version" && valid_sha "$sha" &&
    [[ $sha256 =~ ^[0-9a-f]{64}$ ]]; } || usage
  local marker="<!-- cran-submission-attempt: $pkg $version -->" earlier n body errf
  body=$(mktemp)
  errf=$(mktemp)
  # shellcheck disable=SC2064  # expand now
  trap "rm -f '$body' '$errf'" EXIT
  # A failed read fails here with GitHub's error; no earlier attempt is an empty answer, and makes this attempt 1.
  earlier=$(bot_comments "$pr" "$marker" 2>"$errf") ||
    fail "Attempt" "The earlier attempts cannot be read" \
      "Reading the comments of #$pr failed: $(head -n 1 "$errf"). The attempt cannot be numbered; the upload went through." -- \
      "Post the attempt's comment by hand from this run's summary: commit \`$sha\`, tarball SHA-256 \`$sha256\`, run $(run_url)."
  n=$(($(count_lines "$earlier") + 1))
  {
    echo "$marker"
    echo "### CRAN submission: $pkg $version, attempt $n"
    echo
    echo "- Commit: $sha"
    echo "- Tarball: \`$name\`, SHA-256 \`$sha256\`"
    echo "- Run: $(run_url)"
    [ -z "${DRAFT_URL:-}" ] || echo "- Draft release: $DRAFT_URL"
    echo
    echo "CRAN has emailed the maintainer; the submission counts once the link in that email is followed."
    echo "Nothing edits this comment: reply to it with CRAN's answer and what fixed it."
  } >"$body"
  "$gh" api -X POST "repos/$repo/issues/$pr/comments" -F "body=@$body" --jq .html_url ||
    fail "Attempt" "The attempt could not be recorded" \
      "Posting attempt $n of $pkg $version to #$pr failed; the upload went through, and the next submission of this version is not refused." -- \
      "Post the attempt's comment by hand from this run's summary: commit \`$sha\`, tarball SHA-256 \`$sha256\`, run $(run_url)."
  say "Recorded attempt $n on #$pr."
  summary "- Recorded attempt $n of $pkg $version on #$pr." ""
}

cmd_sync() {
  [ $# -eq 4 ] || [ $# -eq 5 ] || usage
  local pkg=$1 version=$2 sha=$3 branch=$4 pr=${5:-}
  { valid_package "$pkg" && valid_version "$version" && valid_sha "$sha" && [[ $pr =~ ^[0-9]*$ ]] &&
    git check-ref-format --branch "$branch" >/dev/null 2>&1; } || usage
  local info errf fork parent tag="v$version" tarball="${pkg}_$version.tar.gz" when block qbranch
  errf=$(mktemp)
  block=$(mktemp)
  # shellcheck disable=SC2064  # expand now
  trap "rm -f '$errf' '$block'" EXIT
  info=$("$gh" api "repos/$repo" --jq '[.fork, (.parent.full_name // "")] | @tsv' 2>"$errf") ||
    fail "Synchronization" "The repository cannot be read" \
      "Reading $repo failed: $(head -n 1 "$errf"), so whether it is a fork, and of which repository, is unknown." -- \
      "If $repo is a fork, bring its parent in line by hand: push \`$sha\` to \`$branch\` there and copy the draft release of $pkg $version."
  IFS=$'\t' read -r fork parent <<<"$info"
  [ "$fork" = true ] || return 0
  valid_repo "$parent" ||
    fail "Synchronization" "The fork's parent cannot be read" \
      "$repo is a fork, but its parent reads as '$parent'." -- \
      "Bring the parent in line by hand: push \`$sha\` to \`$branch\` there and copy the draft release of $pkg $version."
  when="after this submission"
  [ "${DRY_RUN:-false}" != true ] || when="after a real run of this submission"
  local checklist="<!-- release-checklist: $pkg $version -->" ref="the fork's checklist pull request"
  [ -z "$pr" ] || ref="${GITHUB_SERVER_URL:-https://github.com}/$repo/pull/$pr"
  # The branch passed `git check-ref-format`, which still allows characters the shell interprets.
  qbranch=$(printf '%q' "$branch")
  # The parent's checklist pull request, chosen as `find` chooses one, except that a person's access is not read:
  # a bot's from a branch of the parent, or an owner's, member's or collaborator's.
  local select_pr
  select_pr=".[]
  | select(($first_line_jq) == \"$checklist\")
  | select(.user.login != \"dependabot[bot]\" and .user.login != \"renovate[bot]\")
  | select(if .user.type == \"Bot\" then .head.repo.full_name == \"$parent\"
      else .author_association == \"OWNER\" or .author_association == \"MEMBER\" or .author_association == \"COLLABORATOR\" end)
  | .number"
  cat >"$block" <<EOF
# $repo is a fork of $parent. Run $when, from a clone with push access to $parent,
# with the remotes \`upstream\` ($parent) and \`origin\` ($repo).
# The commands run in their own shell, which stops at the first failure and leaves the terminal open.
bash -euo pipefail <<'SYNC'
# The submitted commit, onto the same branch of the parent; the push fails rather than overwrite it.
git fetch origin $sha
git push upstream $sha:refs/heads/$qbranch
# The draft release, with its notes and the submitted tarball; the tag is written at acceptance, not now.
mkdir -p cran-sync
gh release download $tag --repo $repo --pattern '$tarball' --dir cran-sync --clobber
gh release view $tag --repo $repo --json body --jq .body >cran-sync/notes.md
# A parent without a draft of the version answers no release; \`gh release create\` then fails if one is published.
if [ "\$(gh release view $tag --repo $parent --json isDraft --jq .isDraft 2>/dev/null)" = true ]; then
  gh release edit $tag --repo $parent --target $sha --notes-file cran-sync/notes.md
  gh release upload $tag --repo $parent --clobber cran-sync/$tarball
else
  gh release create $tag --repo $parent --draft --target $sha --title '$pkg $version' \\
    --notes-file cran-sync/notes.md cran-sync/$tarball
fi
# The parent's checklist pull request, pointed at the attempts recorded in the fork; exactly one must match.
prs=\$(gh api --paginate 'repos/$parent/pulls?state=open&per_page=100' --jq '$select_pr')
if [ "\$(printf '%s\\n' "\$prs" | awk 'NF { n++ } END { print n + 0 }')" -ne 1 ]; then
  echo "Expected one checklist pull request in $parent, found: \$(paste -s -d ' ' - <<<"\${prs:-none}")" >&2
  exit 1
fi
gh pr comment "\$prs" --repo $parent \\
  --body 'CRAN submission of $pkg $version from $repo at $sha: $(run_url); attempts are recorded in $ref.'
SYNC
EOF
  group "Manual synchronization with $parent"
  cat "$block"
  endgroup
  notice "Manual synchronization" "$repo is a fork of $parent: the run's summary has the commands to run by hand $when."
  summary "## Manual synchronization with $parent" "" \
    "$repo is a fork of $parent. Nothing here changes $parent: run these commands by hand $when." "" \
    '```sh' "$(cat "$block")" '```' ""
}

case "${1:-}" in
  builders) shift; cmd_builders "$@" ;;
  find) shift; cmd_find "$@" ;;
  submitted) shift; cmd_submitted "$@" ;;
  status) shift; cmd_status "$@" ;;
  attempt) shift; cmd_attempt "$@" ;;
  sync) shift; cmd_sync "$@" ;;
  *) usage ;;
esac
