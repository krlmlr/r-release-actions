#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Adapted from krlmlr/duckplyr's .github/actions/release-report/release-report.sh at f98ad13 (MIT).
# Report to the release's checklist pull request.
#
#   find <package> <version>
#     The checklist pull request is the open pull request whose body carries
#     `<!-- release-checklist: <package> <version> -->` and whose author is an owner, member or collaborator
#     of the repository; one carrying the marker by anyone else is named in a warning and ignored.
#     Writes `pr` to GITHUB_OUTPUT. None, or more than one, fails when REQUIRE is `true`, and warns otherwise.
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
  trusted=$(printf '%s\n' "$found" | awk -F '\t' '$2 == "OWNER" || $2 == "MEMBER" || $2 == "COLLABORATOR" { print $1 }')
  others=$(printf '%s\n' "$found" | awk -F '\t' 'NF && !($2 == "OWNER" || $2 == "MEMBER" || $2 == "COLLABORATOR") { printf "#%s by %s (%s) ", $1, $3, $2 }')
  [ -z "$others" ] ||
    warn "Checklist pull request ignored" "Ignored ${others}: the checklist pull request must be opened by an owner, member or collaborator."
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
      "There is $what by an owner, member or collaborator whose body carries \`$marker\`; the submission records each attempt there. Nothing was drafted or uploaded." -- \
      "Put the marker \`$marker\` into the body of the release's checklist pull request, and only of that one, then dispatch the submission again."
  fi
  warn "No single checklist pull request" "There is $what whose body carries $marker; a real run fails."
  summary "- Checklist pull request: $what carries \`$marker\`; a real run fails." ""
  output pr ""
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
    echo "Run [#${GITHUB_RUN_NUMBER:-0}]($(run_url)) (attempt ${GITHUB_RUN_ATTEMPT:-1}, ${GITHUB_EVENT_NAME:-}) on \`${GITHUB_REF_NAME:-}\`, $(date -u '+%Y-%m-%d %H:%M UTC')."
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
  { [[ $pr =~ ^[0-9]+$ ]] && valid_package "$pkg" && valid_version "$version" && valid_sha "$sha" && [[ $sha256 =~ ^[0-9a-f]{64}$ ]]; } || usage
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
    echo "CRAN has e-mailed the maintainer; the submission counts once the link in that e-mail is followed."
    echo "Nothing edits this comment: reply to it with CRAN's answer and what fixed it."
  } >"$body"
  "$gh" api -X POST "repos/$repo/issues/$pr/comments" -F "body=@$body" --jq .html_url
  say "Recorded attempt $n on #$pr."
  summary "- Recorded attempt $n of $pkg $version on #$pr." ""
}

case "${1:-}" in
  find) shift; cmd_find "$@" ;;
  status) shift; cmd_status "$@" ;;
  attempt) shift; cmd_attempt "$@" ;;
  *) usage ;;
esac
