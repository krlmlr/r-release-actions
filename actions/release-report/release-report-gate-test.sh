#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Check release-report.sh's `gate` mode offline, against a `gh` stub: nothing reaches GitHub.
# Kept apart from release-report-test.sh, which covers the other modes.
#
#   1. The release gate's comment is posted, then updated in place; one with the marker by someone else is left alone.
#   2. The verdict follows the hard checks' job: ready, not ready, or not checked; a missing report says so.
#   3. A report too long for a comment is cut at a line, with its fence and collapsed blocks closed.
#   4. Comments that cannot be read, or a comment that cannot be written, fail with GitHub's error.
#
# Usage:
#   actions/release-report/release-report-gate-test.sh

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../cran-lib/test-lib.sh
. "$HERE/../cran-lib/test-lib.sh"
gh_stub

export GH_REPO=owner/fakepkg GITHUB_SERVER_URL=https://github.example GITHUB_RUN_ID=99 GITHUB_RUN_NUMBER=5 \
  GITHUB_RUN_ATTEMPT=1 GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_NAME=release-1.0.1
SUMMARY=$SCRATCH/summary.md
COMMENTS="repos/owner/fakepkg/issues/7/comments?per_page=100"
MARK='<!-- release-report: release-gate -->'

run() {
  local rc=0 out
  : >"$SUMMARY"
  : >"$SCRATCH/writes"
  out=$(GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY=$SUMMARY "$HERE/release-report.sh" "$@" 2>&1) || rc=$?
  printf '%s\nexit %s\n' "$out" "$rc"
}
comment() { # <id> <login> <body>
  printf '{"id": %s, "html_url": "https://github.example/comment/%s", "user": {"login": "%s"}, "body": "%s"}' "$1" "$1" "$2" "$3"
}

section "the comment is posted, then updated"
answer "$COMMENTS" "[$(comment 50 someone "$MARK\nmine"), $(comment 51 'github-actions[bot]' '<!-- release-report: cran-submission -->')]"
out=$(RESULTS=$'hard=success\nchecks=success' GATE_HARD='- ✅ **Version:** fine.' GATE_REPORT='- ⚠️ **URLs:** one.' \
  run gate 7 fakepkg 1.0.1)
has "it succeeds" "$out" "exit 0"
w=$(cat "$SCRATCH/writes")
has "it posts a comment, leaving someone else's and another workflow's alone" "$w" "POST repos/owner/fakepkg/issues/7/comments"
has "with the marker and the verdict" "$w" "$MARK
### ✅ Release gate: fakepkg 1.0.1 is ready"
has "the run" "$w" "Run [#5](https://github.example/owner/fakepkg/actions/runs/99)"
has "the hard checks" "$w" "#### Required

- ✅ **Version:** fine."
has "and the reported ones" "$w" "#### Reported, not enforced

- ⚠️ **URLs:** one."
answer "$COMMENTS" "[$(comment 50 someone "$MARK"), $(comment 52 'github-actions[bot]' "$MARK\nold")]"
out=$(RESULTS=$'hard=failure\nchecks=success' GATE_HARD='- ❌ **Remotes:** there.' run gate 7 fakepkg 1.0.1)
w=$(cat "$SCRATCH/writes")
has "a later run updates the bot's comment" "$w" "PATCH repos/owner/fakepkg/issues/comments/52"
hasnt "and posts none" "$w" "POST"
has "a failed hard check is not ready" "$w" "### ❌ Release gate: fakepkg 1.0.1 is not ready"
has "a missing report says so" "$w" "These checks wrote no report (\`checks\`: success)"

section "a gate that did not run"
out=$(RESULTS=$'hard=cancelled\nchecks=skipped' run gate 7 fakepkg 1.0.1)
w=$(cat "$SCRATCH/writes")
has "is not checked" "$w" "### ⚠️ Release gate: fakepkg 1.0.1 was not checked (cancelled)"
has "and says the hard checks wrote nothing" "$w" "The hard checks wrote no report"
has "nor the others" "$w" "These checks wrote no report (\`checks\`: skipped)"

section "a long report is cut"
long=$(
  printf -- '- ⚠️ **Spelling:** words.\n\n<details><summary>Spelling</summary>\n\n````text\n'
  for i in $(seq 3000); do echo "word$i  file.Rd:$i"; done
  printf '````\n\n</details>\n'
)
out=$(RESULTS='hard=success' GATE_REPORT=$long run gate 7 fakepkg 1.0.1)
w=$(cat "$SCRATCH/writes")
has "it succeeds" "$out" "exit 0"
is "within GitHub's limit" "$(($(wc -c <"$SCRATCH/writes") < 65536))" 1
has "cut at a line, closing the fence and the block" "$w" "
\`\`\`\`

[Cut to fit a comment: the run's summary page has the rest.]

</details>"
hasnt "the end is gone" "$w" "word3000"

section "failures"
out=$(RESULTS='hard=success' run gate 8 fakepkg 1.0.1)
has "comments that cannot be read fail, with GitHub's error" "$out" \
  "::error title=The checklist pull request's comments cannot be read::Reading the comments of #8 failed: gh: Not Found (HTTP 404)."
out=$(GH_STUB_FAIL_WRITES=1 RESULTS='hard=success' run gate 7 fakepkg 1.0.1)
has "a comment that cannot be written fails" "$out" \
  "::error title=The release gate's comment cannot be written::Writing the comment on #7 failed: gh: Forbidden (HTTP 403)."
has "a bad pull request number is a usage error" "$(run gate x fakepkg 1.0.1)" "exit 2"

done_testing
