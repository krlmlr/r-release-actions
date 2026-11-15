#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Adapted from krlmlr/duckplyr's .github/actions/release-report/release-report.sh at f98ad13 (MIT).
# Report to the release's checklist pull request.
#
#   find <package> <version>
#     The checklist pull request is the open pull request whose body carries
#     `<!-- release-checklist: <package> <version> -->` and whose author has write access to the repository,
#     or, where the token cannot read that, is an owner, member or collaborator;
#     one carrying the marker by anyone else is named in a warning and ignored.
#     Writes `pr` to GITHUB_OUTPUT. None, or more than one, fails when REQUIRE is `true`, and warns otherwise.
#   submitted <pr> <package> <version>
#     Refuses a version that an earlier attempt comment records, whatever its commit or tarball,
#     because an upload whose confirmation link was never followed does not show in CRAN's queue.
#     RESUBMIT `true` lets it through with a warning; DRY_RUN `true` turns the refusal into a warning.
#   status <pr> <key> <title>
#     The workflow's one comment, found by `<!-- release-report: <key> -->` among github-actions[bot]'s comments,
#     created or updated in place with the job results in RESULTS and the Markdown in DETAILS.
#   attempt <pr> <package> <version> <sha> <sha256> <tarball name>
#     A new comment for a submission attempt, which nothing edits afterwards:
#     the attempt's number, the submitted commit, the tarball's SHA-256, and links to the run and the draft release.
#     The number counts github-actions[bot]'s earlier comments carrying
#     `<!-- cran-submission-attempt: <package> <version> -->` on the pull request.
#
# Environment:
#   GH_TOKEN, GH_REPO    a token with `pull-requests: write` (`read` for `find`), and the repository, owner/name
#   GH                   the gh command, default `gh`; release-report-test.sh stubs it
#   REQUIRE              `find`: `true` fails without exactly one checklist pull request
#   RESUBMIT, DRY_RUN    `submitted`: `true` lets a version submitted before through, or only warns about it
#   RESULTS              `status`: one `<job>=<result>` per line, as `needs.<job>.result` gives it
#   DETAILS              `status`: Markdown appended below the job results, may be empty
#   DRAFT_URL            `attempt`: the draft release
#   GITHUB_SERVER_URL, GITHUB_RUN_ID, GITHUB_RUN_NUMBER, GITHUB_RUN_ATTEMPT, GITHUB_REF_NAME, GITHUB_EVENT_NAME
#                        the run that is reported
#   GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, GITHUB_ACTIONS
#
# Exit status: 0 on success, 1 on a failure, 2 on a usage error.

set -euo pipefail

# shellcheck source=../cran-lib/cran-lib.sh
. "$(dirname "$0")/../cran-lib/cran-lib.sh"

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

cmd_find() {
  [ $# -eq 2 ] || usage
  local pkg=$1 version=$2
  { valid_package "$pkg" && valid_version "$version"; } || usage
  local marker="<!-- release-checklist: $pkg $version -->" found trusted others n
  found=$("$gh" api --paginate "repos/$repo/pulls?state=open&per_page=100" \
    --jq ".[] | select((.body // \"\") | contains(\"$marker\")) | [.number, .author_association, .user.login] | @tsv")
  # The author needs write access, read from `collaborators/<login>/permission` (admin, maintain and write read as
  # `admin` or `write`). Where the token cannot read it, the author's association with the repository stands in:
  # owner, member or collaborator.
  local number assoc login perm trusted='' others=''
  while IFS=$'\t' read -r number assoc login; do
    [ -n "$number" ] || continue
    if [[ $login =~ ^[A-Za-z0-9-]+(\[bot\])?$ ]] &&
      perm=$("$gh" api "repos/$repo/collaborators/$login/permission" --jq .permission 2>/dev/null); then
      case "$perm" in
        admin | write) trusted+="$number"$'\n' ;;
        *) others+="#$number by $login ($perm access) " ;;
      esac
    else
      warn "Permission unknown" \
        "The access of $login, who opened #$number, cannot be read; their association with the repository, $assoc, decides."
      case "$assoc" in
        OWNER | MEMBER | COLLABORATOR) trusted+="$number"$'\n' ;;
        *) others+="#$number by $login ($assoc) " ;;
      esac
    fi
  done <<<"$found"
  trusted=${trusted%$'\n'}
  [ -z "$others" ] ||
    warn "Checklist pull request ignored" "Ignored ${others}: the checklist pull request must be opened by someone with write access."
  n=$(printf '%s' "$trusted" | grep -c . || true)
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
      "There is $what by someone with write access whose body carries \`$marker\`; the submission records each attempt there. Nothing was drafted or uploaded." -- \
      "Put the marker \`$marker\` into the body of the release's checklist pull request, and only of that one, then dispatch the submission again."
  fi
  warn "No single checklist pull request" "There is $what whose body carries $marker; a real run fails."
  summary "- Checklist pull request: $what carries \`$marker\`; a real run fails." ""
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
  id=$(bot_comments "$pr" "$marker" | tail -n 1)
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
  local marker="<!-- cran-submission-attempt: $pkg $version -->" n body
  n=$(bot_comments "$pr" "$marker" | grep -c . || true)
  n=$((n + 1))
  body=$(mktemp)
  # shellcheck disable=SC2064  # expand now
  trap "rm -f '$body'" EXIT
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
  "$gh" api -X POST "repos/$repo/issues/$pr/comments" -F "body=@$body" --jq .html_url
  say "Recorded attempt $n on #$pr."
  summary "- Recorded attempt $n of $pkg $version on #$pr." ""
}

case "${1:-}" in
  find) shift; cmd_find "$@" ;;
  submitted) shift; cmd_submitted "$@" ;;
  status) shift; cmd_status "$@" ;;
  attempt) shift; cmd_attempt "$@" ;;
  *) usage ;;
esac
