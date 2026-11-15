#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Adapted from krlmlr/duckplyr's .github/actions/release-report/release-report-test.sh at f98ad13 (MIT).
# Copyright (c) 2023 duckplyr authors; used under the MIT License, whose terms are in LICENSE.
# Check release-report.sh offline, against a `gh` stub: nothing reaches GitHub.
#
#   1. `find` takes the open pull request carrying the version's marker by an owner, member or collaborator,
#      ignores one by anyone else with a warning, and fails without exactly one when required.
#   2. `status` posts the workflow's comment, then updates it; a comment with the marker by someone else is left alone;
#      the overall result is failure when any job failed.
#   3. `attempt` posts a new comment numbered after the earlier attempts of the version, and edits none.
#
# Usage:
#   actions/release-report/release-report-test.sh

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../cran-lib/test-lib.sh
. "$HERE/../cran-lib/test-lib.sh"
gh_stub

export GH_REPO=owner/fakepkg GITHUB_SERVER_URL=https://github.example GITHUB_RUN_ID=99 GITHUB_RUN_NUMBER=5 \
  GITHUB_RUN_ATTEMPT=1 GITHUB_EVENT_NAME=workflow_dispatch GITHUB_REF_NAME=release-1.0.1
SHA=0123456789abcdef0123456789abcdef01234567
TSHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SUMMARY=$SCRATCH/summary.md

run() {
  local rc=0 out
  : >"$SUMMARY"
  : >"$SCRATCH/output"
  : >"$SCRATCH/writes"
  out=$(GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY=$SUMMARY GITHUB_OUTPUT=$SCRATCH/output \
    "$HERE/release-report.sh" "$@" 2>&1) || rc=$?
  printf '%s\nexit %s\n' "$out" "$rc"
}
pull() { # <number> <association> <login> <body>
  printf '{"number": %s, "author_association": "%s", "user": {"login": "%s"}, "body": "%s"}' "$1" "$2" "$3" "$4"
}
comment() { # <id> <login> <body>
  printf '{"id": %s, "html_url": "https://github.example/comment/%s", "user": {"login": "%s"}, "body": "%s"}' "$1" "$1" "$2" "$3"
}
PULLS="repos/owner/fakepkg/pulls?state=open&per_page=100"
MARK='<!-- release-checklist: fakepkg 1.0.1 -->'

section "find"
answer "repos/owner/fakepkg/collaborators/maint/permission" '{"permission": "write"}'
answer "repos/owner/fakepkg/collaborators/stranger/permission" '{"permission": "read"}'
answer "repos/owner/fakepkg/collaborators/other/permission" '{"permission": "admin"}'
answer "$PULLS" "[$(pull 4 CONTRIBUTOR stranger "$MARK"), $(pull 7 NONE maint "Checklist\n\n$MARK"), $(pull 8 OWNER maint '<!-- release-checklist: fakepkg 1.0.10 -->')]"
out=$(REQUIRE=true run find fakepkg 1.0.1)
has "it succeeds" "$out" "exit 0"
is "with the pull request of the author with write access" "$(cat "$SCRATCH/output")" "pr=7"
has "and a warning about the one without" "$out" "::warning title=Checklist pull request ignored::Ignored #4 by stranger (read access)"
hasnt "the association does not decide where the permission is known" "$out" "Permission unknown"
answer "$PULLS" "[$(pull 5 MEMBER member "$MARK"), $(pull 6 NONE nobody "$MARK")]"
out=$(REQUIRE=true run find fakepkg 1.0.1)
has "where the permission cannot be read, a member's is taken" "$(cat "$SCRATCH/output")" "pr=5"
has "with a warning" "$out" "::warning title=Permission unknown::The access of member"
has "and someone else's is ignored" "$out" "Ignored #6 by nobody (NONE)"
answer "$PULLS" "[$(pull 4 MEMBER stranger "$MARK")]"
out=$(REQUIRE=true run find fakepkg 1.0.1)
has "only a stranger's fails when required, whatever the association" "$out" "::error title=No single checklist pull request::"
out=$(run find fakepkg 1.0.1)
has "and warns otherwise" "$out" "::warning title=No single checklist pull request::"
has "with an empty output" "$(cat "$SCRATCH/output")" "pr="
answer "$PULLS" "[$(pull 7 NONE maint "$MARK"), $(pull 9 NONE other "$MARK")]"
out=$(REQUIRE=true run find fakepkg 1.0.1)
has "two fail when required" "$out" "2 open pull requests (#7 #9)"
is "and nothing is written" "$(cat "$SCRATCH/writes")" ""

section "status"
answer "repos/owner/fakepkg/issues/7/comments?per_page=100" \
  "[$(comment 50 someone '<!-- release-report: cran-submission -->\nmine')]"
out=$(RESULTS=$'version=success\nupload=failure' DETAILS='**Dry run.**' run status 7 cran-submission "CRAN submission")
has "it succeeds" "$out" "exit 0"
w=$(cat "$SCRATCH/writes")
has "it posts a comment, leaving someone else's alone" "$w" "POST repos/owner/fakepkg/issues/7/comments"
has "with the marker and the overall result" "$w" "<!-- release-report: cran-submission -->
### ❌ CRAN submission: failure"
has "every job" "$w" "- \`upload\`: failure"
has "the details" "$w" "**Dry run.**"
has "and the run" "$w" "Run [#5](https://github.example/owner/fakepkg/actions/runs/99)"
answer "repos/owner/fakepkg/issues/7/comments?per_page=100" \
  "[$(comment 50 someone '<!-- release-report: cran-submission -->'), $(comment 51 'github-actions[bot]' '<!-- release-report: cran-submission -->\nold')]"
out=$(RESULTS='version=success' run status 7 cran-submission "CRAN submission")
w=$(cat "$SCRATCH/writes")
has "a later run updates the bot's comment" "$w" "PATCH repos/owner/fakepkg/issues/comments/51"
has "as a success" "$w" "### ✅ CRAN submission: success"

section "attempt"
answer "repos/owner/fakepkg/issues/7/comments?per_page=100" \
  "[$(comment 51 'github-actions[bot]' '<!-- release-report: cran-submission -->'), $(comment 52 'github-actions[bot]' '<!-- cran-submission-attempt: fakepkg 1.0.1 -->\n1'), $(comment 53 'github-actions[bot]' '<!-- cran-submission-attempt: fakepkg 1.0.0 -->'), $(comment 54 someone '<!-- cran-submission-attempt: fakepkg 1.0.1 -->')]"
out=$(DRAFT_URL=https://github.example/owner/fakepkg/releases/7 run attempt 7 fakepkg 1.0.1 "$SHA" "$TSHA" fakepkg_1.0.1.tar.gz)
has "it succeeds" "$out" "exit 0"
w=$(cat "$SCRATCH/writes")
has "it posts a new comment" "$w" "POST repos/owner/fakepkg/issues/7/comments"
hasnt "and edits none" "$w" "PATCH"
has "numbered after the bot's earlier attempts of this version" "$w" "### CRAN submission: fakepkg 1.0.1, attempt 2"
has "with the commit" "$w" "- Commit: $SHA"
has "the tarball's SHA-256" "$w" "- Tarball: \`fakepkg_1.0.1.tar.gz\`, SHA-256 \`$TSHA\`"
has "the run" "$w" "- Run: https://github.example/owner/fakepkg/actions/runs/99"
has "and the draft" "$w" "- Draft release: https://github.example/owner/fakepkg/releases/7"
out=$(run attempt 7 fakepkg 1.0.1 "${SHA:0:10}" "$TSHA" fakepkg_1.0.1.tar.gz)
has "a short SHA is a usage error" "$out" "exit 2"

section "submitted"
answer "repos/owner/fakepkg/issues/7/comments?per_page=100" \
  "[$(comment 52 'github-actions[bot]' "<!-- cran-submission-attempt: fakepkg 1.0.1 -->\n- Tarball: SHA-256 $TSHA"), $(comment 54 someone "<!-- cran-submission-attempt: fakepkg 1.0.2 -->")]"
out=$(run submitted 7 fakepkg 1.0.1)
has "a version an attempt submitted is refused, whatever the tarball" "$out" "::error title=fakepkg 1.0.1 was submitted before::"
has "naming the attempt" "$out" "https://github.example/comment/52"
out=$(DRY_RUN=true run submitted 7 fakepkg 1.0.1)
has "a dry run warns" "$out" "::warning title=Submitted before::"
has "and passes" "$out" "exit 0"
out=$(RESUBMIT=true run submitted 7 fakepkg 1.0.1)
has "resubmit lets it through" "$out" "exit 0"
has "with a warning" "$out" "::warning title=Resubmission::"
out=$(run submitted 7 fakepkg 1.0.2)
has "someone else's comment with the marker does not count" "$out" "exit 0"
out=$(run submitted 7 fakepkg 1.0.0)
has "nor does another version" "$out" "exit 0"
is "and nothing is written" "$(cat "$SCRATCH/writes")" ""
out=$(run submitted 8 fakepkg 1.0.1)
has "comments that cannot be read fail, with GitHub's error" "$out" "Reading the comments of #8 failed: gh: Not Found (HTTP 404)"
has "under their own title" "$out" "::error title=The checklist pull request's comments cannot be read::"

done_testing
