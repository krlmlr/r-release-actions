#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Adapted from krlmlr/duckplyr's .github/actions/release-report/release-report-test.sh at f98ad13 (MIT).
# Check release-report.sh offline, against a `gh` stub: nothing reaches GitHub.
#
#   1. `find` takes the open pull request carrying the version's marker by an App's bot from a branch of the repository,
#      or by a person with write access, falling back to an owner, member or collaborator;
#      it ignores one by anyone else, or by a bot from a fork, with a warning, and fails without exactly one when required.
#   2. `status` posts the workflow's comment, then updates it; a comment with the marker by someone else is left alone;
#      the overall result is failure when any job failed.
#      `builders` does the same for the builder uploads' comment, with each upload and macbuilder's result;
#      a dry run only shows it.
#   3. `attempt` posts a new comment numbered after the earlier attempts of the version, and edits none;
#      unreadable comments fail with GitHub's error.
#   4. `sync` prints, in a fork only, the commands that bring the parent in line, against the remotes `upstream` and `origin`.
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
pull() { # <number> <association> <login> <body> [<user type> [<head repository>]]
  local head='null'
  [ "${6-owner/fakepkg}" = null ] || head="{\"full_name\": \"${6-owner/fakepkg}\"}"
  printf '{"number": %s, "author_association": "%s", "user": {"login": "%s", "type": "%s"}, "head": {"repo": %s}, "body": "%s"}' \
    "$1" "$2" "$3" "${5:-User}" "$head" "$4"
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
answer "$PULLS" "[$(pull 4 CONTRIBUTOR stranger "$MARK"), $(pull 7 NONE maint "$MARK\n\nChecklist"),
  $(pull 8 OWNER maint '<!-- release-checklist: fakepkg 1.0.10 -->')]"
out=$(REQUIRE=true run find fakepkg 1.0.1)
has "it succeeds" "$out" "exit 0"
is "with the pull request of the author with write access" "$(cat "$SCRATCH/output")" "pr=7"
has "and a warning about the one without" "$out" "::warning title=Checklist pull request ignored::Ignored #4 by stranger (read access)"
hasnt "the association does not decide where the permission is known" "$out" "Permission unknown"
answer "$PULLS" "[$(pull 5 MEMBER member "$MARK"), $(pull 6 NONE nobody "$MARK")]"
out=$(REQUIRE=true run find fakepkg 1.0.1)
has "where the permission cannot be read, a real run fails with GitHub's error" "$out" \
  "::error title=The access of the checklist pull request's author cannot be read::Reading the access of member (MEMBER), who opened #5, failed: gh: Not Found (HTTP 404)."
out=$(run find fakepkg 1.0.1)
has "a dry run lets a member's stand in" "$(cat "$SCRATCH/output")" "pr=5"
has "with a warning" "$out" "::warning title=Permission unknown::The access of member"
has "and someone else's is ignored" "$out" "Ignored #6 by nobody (NONE, access unreadable)"
# A stray marker by a bot from a fork or an outsider, whose access the endpoint does not answer, must not block the release.
answer "$PULLS" "[$(pull 3 NONE 'some-app[bot]' "$MARK" Bot someone/fakepkg),
  $(pull 1 NONE 'gone-app[bot]' "$MARK" Bot null), $(pull 2 CONTRIBUTOR outsider "$MARK"), $(pull 7 NONE maint "$MARK")]"
out=$(REQUIRE=true run find fakepkg 1.0.1)
has "stray marker pull requests by a bot from a fork or an outsider do not block a real run" "$out" "exit 0"
is "which takes the valid checklist pull request" "$(cat "$SCRATCH/output")" "pr=7"
has "naming the bot's from a fork in the warning" "$out" "#3 by some-app[bot] (a bot, from someone/fakepkg)"
has "and the bot's whose fork is gone" "$out" "#1 by gone-app[bot] (a bot, from -)"
has "and the outsider's" "$out" "#2 by outsider (CONTRIBUTOR, access unreadable)"
hasnt "a bot's access is not read" "$(cat "$SCRATCH/gh.log")" "collaborators/some-app[bot]"
section "find: a checklist pull request opened by an App"
: >"$SCRATCH/gh.log"
answer "$PULLS" "[$(pull 4 CONTRIBUTOR stranger "$MARK"), $(pull 11 NONE 'release-app[bot]' "$MARK\r\nChecklist" Bot)]"
out=$(REQUIRE=true run find fakepkg 1.0.1)
has "an App's from a branch of the repository is found on a real run" "$out" "exit 0"
is "as the checklist pull request" "$(cat "$SCRATCH/output")" "pr=11"
hasnt "without reading the bot's access" "$(cat "$SCRATCH/gh.log")" "collaborators/release-app[bot]"
answer "$PULLS" "[$(pull 11 NONE 'release-app[bot]' "$MARK" Bot), $(pull 7 NONE maint "$MARK")]"
out=$(REQUIRE=true run find fakepkg 1.0.1)
has "an App's and a person's fail as no single one" "$out" "::error title=No single checklist pull request::"
has "naming both" "$out" "2 open pull requests (#11 #7)"
answer "$PULLS" "[$(pull 11 NONE 'release-app[bot]' "$MARK" Bot), $(pull 12 NONE 'other-app[bot]' "$MARK" Bot)]"
out=$(REQUIRE=true run find fakepkg 1.0.1)
has "as do two Apps'" "$out" "2 open pull requests (#11 #12)"
answer "$PULLS" "[$(pull 13 NONE 'not-a-bot[bot]' "$MARK" User)]"
out=$(REQUIRE=true run find fakepkg 1.0.1)
has "a login ending in [bot] that is no bot account takes the person's path" "$out" "#13 by not-a-bot[bot] (NONE, access unreadable)"
section "find: where the marker stands, and dependency updates"
answer "$PULLS" "[$(pull 7 NONE maint "Checklist\n\n$MARK"), $(pull 14 NONE 'dependabot[bot]' "$MARK\n\nBumps x." Bot),
  $(pull 15 NONE 'renovate[bot]' "$MARK" Bot)]"
out=$(REQUIRE=true run find fakepkg 1.0.1)
has "a marker later in the body does not count, even by someone with write access" "$out" \
  "#7 by maint (the marker is not the body's first line)"
has "a Dependabot pull request with the marker is ignored" "$out" "#14 by dependabot[bot] (a dependency update)"
has "as is Renovate's" "$out" "#15 by renovate[bot] (a dependency update)"
has "so none is the checklist pull request" "$out" "::error title=No single checklist pull request::There is no open pull request"
answer "$PULLS" "[$(pull 7 NONE maint "\ufeff$MARK \r\nChecklist")]"
out=$(REQUIRE=true run find fakepkg 1.0.1)
is "a byte order mark before the marker and whitespace after it do not matter" "$(cat "$SCRATCH/output")" "pr=7"
answer "$PULLS" "[$(pull 7 NONE maint "  $MARK\t\nChecklist")]"
out=$(REQUIRE=true run find fakepkg 1.0.1)
is "nor does leading whitespace" "$(cat "$SCRATCH/output")" "pr=7"
section "find: more"
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

rm "$API/repos_owner_fakepkg_pulls_state_open_per_page_100.json"
out=$(run find fakepkg 1.0.1)
has "unreadable pull requests fail with GitHub's error" "$out" \
  "::error title=The open pull requests cannot be read::Listing the open pull requests of owner/fakepkg failed: gh: Not Found (HTTP 404)."

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
out=$(RESULTS='version=success' run status 8 cran-submission "CRAN submission")
has "comments that cannot be read fail, with GitHub's error" "$out" \
  "::error title=The checklist pull request's comments cannot be read::Reading the comments of #8 failed: gh: Not Found (HTTP 404)."
is "and post nothing" "$(cat "$SCRATCH/writes")" ""

section "builders"
answer "repos/owner/fakepkg/issues/7/comments?per_page=100" \
  "[$(comment 60 someone '<!-- release-builders: fakepkg 1.0.1 -->\nmine')]"
out=$(SHA=$SHA SHA256=$TSHA WINBUILDER_RESULTS='R-devel=uploaded R-release=uploaded' WINBUILDER_JOB=success \
  MACBUILDER_FLAVOR=r-devel MACBUILDER_URL=https://mac.example/macbuilder/results/1-a/ MACBUILDER_OUTCOME=ok \
  MACBUILDER_STATUS=OK MACBUILDER_JOB=success run builders 7 fakepkg 1.0.1)
has "it succeeds" "$out" "exit 0"
w=$(cat "$SCRATCH/writes")
has "it posts a comment, leaving someone else's alone" "$w" "POST repos/owner/fakepkg/issues/7/comments"
has "with the marker and the overall result" "$w" "<!-- release-builders: fakepkg 1.0.1 -->
### ✅ Builder checks: fakepkg 1.0.1"
has "the tarball" "$w" "- Tarball: \`fakepkg_1.0.1.tar.gz\`, SHA-256 \`$TSHA\`"
has "each win-builder flavor" "$w" "- win-builder \`R-devel\`: uploaded; the results arrive by email to the maintainer
- win-builder \`R-release\`: uploaded"
has "and macbuilder's status, linked" "$w" "- macbuilder \`r-devel\`: \`Status: OK\`, [result page](https://mac.example/macbuilder/results/1-a/)"
has "saying the checks do not gate" "$w" "These checks inform the release and do not gate it."
answer "repos/owner/fakepkg/issues/7/comments?per_page=100" \
  "[$(comment 60 someone '<!-- release-builders: fakepkg 1.0.1 -->'), $(comment 61 'github-actions[bot]' '<!-- release-builders: fakepkg 1.0.1 -->\nold'), $(comment 62 'github-actions[bot]' '<!-- release-builders: fakepkg 1.0.0 -->')]"
out=$(WINBUILDER_RESULTS='R-devel=uploaded' MACBUILDER_OUTCOME=note MACBUILDER_STATUS='1 NOTE' MACBUILDER_JOB=success \
  run builders 7 fakepkg 1.0.1)
w=$(cat "$SCRATCH/writes")
has "a later run updates the bot's comment of the version" "$w" "PATCH repos/owner/fakepkg/issues/comments/61"
has "a NOTE asks for attention" "$w" "### ⚠️ Builder checks: fakepkg 1.0.1"
out=$(WINBUILDER_RESULTS='R-devel=uploaded' MACBUILDER_OUTCOME=timeout MACBUILDER_JOB=success run builders 7 fakepkg 1.0.1)
has "so does a timeout" "$(cat "$SCRATCH/writes")" "- macbuilder \`r-devel\`: no result yet when the run stopped waiting"
out=$(WINBUILDER_RESULTS='R-devel=uploaded' MACBUILDER_OUTCOME=unknown MACBUILDER_STATUS=$'done `x`\a' \
  MACBUILDER_URL=https://mac.example/macbuilder/results/1-a/ MACBUILDER_JOB=success run builders 7 fakepkg 1.0.1)
w=$(cat "$SCRATCH/writes")
has "an unknown outcome asks for attention" "$w" "### ⚠️ Builder checks"
has "saying the page was not understood, with its link" "$w" \
  "- macbuilder \`r-devel\`: result page not understood (\`Status: done x\`), read it, [result page](https://mac.example/macbuilder/results/1-a/)"
out=$(WINBUILDER_RESULTS='R-devel=uploaded' MACBUILDER_OUTCOME=note MACBUILDER_STATUS="1 NOTE\`$(printf 'y%.0s' $(seq 300))" \
  MACBUILDER_JOB=success run builders 7 fakepkg 1.0.1)
has "the status loses its backticks and is cut to 200 characters" "$(cat "$SCRATCH/writes")" \
  "\`Status: 1 NOTE$(printf 'y%.0s' $(seq 194))\`"
out=$(WINBUILDER_RESULTS='R-devel=failed R-release=uploaded' WINBUILDER_JOB=failure MACBUILDER_OUTCOME=error \
  MACBUILDER_STATUS='1 ERROR' MACBUILDER_JOB=success run builders 7 fakepkg 1.0.1)
w=$(cat "$SCRATCH/writes")
has "a failed upload or an ERROR is a failure" "$w" "### ❌ Builder checks"
has "naming the upload" "$w" "- win-builder \`R-devel\`: **upload failed**"
has "and the status" "$w" "**\`Status: 1 ERROR\`**"
out=$(WINBUILDER_RESULTS='R-devel=uploaded' WINBUILDER_JOB=cancelled MACBUILDER_OUTCOME=ok MACBUILDER_STATUS=OK \
  MACBUILDER_JOB=success run builders 7 fakepkg 1.0.1)
w=$(cat "$SCRATCH/writes")
has "a win-builder job cancelled after an upload is a failure" "$w" "### ❌ Builder checks"
has "naming the job and the flavors it did not try" "$w" "- win-builder \`R-devel\`: uploaded; the results arrive by email to the maintainer
- win-builder: job \`cancelled\`, later flavors not tried"
out=$(WINBUILDER_RESULTS='R-devel=failed R-release=uploaded' WINBUILDER_JOB=failure MACBUILDER_OUTCOME=ok MACBUILDER_STATUS=OK \
  MACBUILDER_JOB=success run builders 7 fakepkg 1.0.1)
hasnt "a job failed by a failed upload tried every flavor" "$(cat "$SCRATCH/writes")" "later flavors not tried"
out=$(WINBUILDER_RESULTS='R-devel=uploaded' WINBUILDER_JOB=failure MACBUILDER_OUTCOME=ok MACBUILDER_STATUS=OK \
  MACBUILDER_JOB=success run builders 7 fakepkg 1.0.1)
w=$(cat "$SCRATCH/writes")
has "a job that failed without a failed upload may not have tried every flavor" "$w" "- win-builder: job \`failure\`, later flavors not tried"
has "and is a failure" "$w" "### ❌ Builder checks"
out=$(WINBUILDER_RESULTS='R-devel=uploaded' WINBUILDER_JOB=success MACBUILDER_OUTCOME=ok MACBUILDER_STATUS=OK \
  MACBUILDER_JOB=cancelled run builders 7 fakepkg 1.0.1)
w=$(cat "$SCRATCH/writes")
has "a macbuilder job that ends otherwise after its outcome is a failure" "$w" "### ❌ Builder checks"
has "naming the job" "$w" "- macbuilder \`r-devel\`: \`Status: OK\`, job \`cancelled\`"
out=$(WINBUILDER_JOB=failure MACBUILDER_JOB=failure run builders 7 fakepkg 1.0.1)
w=$(cat "$SCRATCH/writes")
has "jobs that failed before uploading are named" "$w" "- win-builder: no upload, job \`failure\`"
has "both" "$w" "- macbuilder \`r-devel\`: **no result**, job \`failure\`"
out=$(DRY_RUN=true WINBUILDER_RESULTS='R-devel=dry-run' WINBUILDER_JOB=success MACBUILDER_JOB=success run builders '' fakepkg 1.0.1)
has "a dry run succeeds without a pull request" "$out" "exit 0"
is "and writes nothing" "$(cat "$SCRATCH/writes")" ""
has "it shows the comment in the summary" "$(cat "$SUMMARY")" "- macbuilder \`r-devel\`: not uploaded on a dry run"
out=$(run builders '' fakepkg 1.0.1)
has "a real run needs the pull request" "$out" "exit 2"
out=$(MACBUILDER_JOB=success run builders 8 fakepkg 1.0.1)
has "comments that cannot be read fail, with GitHub's error" "$out" \
  "::error title=The checklist pull request's comments cannot be read::Reading the comments of #8 failed: gh: Not Found (HTTP 404)."
is "and post nothing" "$(cat "$SCRATCH/writes")" ""

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
out=$(GH_STUB_FAIL_WRITES=1 run attempt 7 fakepkg 1.0.1 "$SHA" "$TSHA" fakepkg_1.0.1.tar.gz)
has "a comment that cannot be posted fails, saying what to post by hand" "$out" "::error title=The attempt could not be recorded::"
has "with the commit and the SHA-256" "$(cat "$SUMMARY")" "commit \`$SHA\`, tarball SHA-256 \`$TSHA\`"
out=$(run attempt 8 fakepkg 1.0.1 "$SHA" "$TSHA" fakepkg_1.0.1.tar.gz)
has "earlier attempts that cannot be read fail" "$out" "::error title=The earlier attempts cannot be read::"
has "with GitHub's error" "$out" "Reading the comments of #8 failed: gh: Not Found (HTTP 404)."
is "and post nothing" "$(cat "$SCRATCH/writes")" ""
answer "repos/owner/fakepkg/issues/9/comments?per_page=100" "[]"
out=$(run attempt 9 fakepkg 1.0.1 "$SHA" "$TSHA" fakepkg_1.0.1.tar.gz)
has "no comments at all succeed" "$out" "exit 0"
has "as attempt 1" "$(cat "$SCRATCH/writes")" "### CRAN submission: fakepkg 1.0.1, attempt 1"
answer "repos/owner/fakepkg/issues/9/comments?per_page=100" \
  "[$(comment 60 'github-actions[bot]' '<!-- release-report: cran-submission -->')]"
out=$(run attempt 9 fakepkg 1.0.1 "$SHA" "$TSHA" fakepkg_1.0.1.tar.gz)
has "nor do comments without an attempt" "$(cat "$SCRATCH/writes")" "### CRAN submission: fakepkg 1.0.1, attempt 1"
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

section "sync"
answer "repos/owner/fakepkg" '{"fork": false, "parent": null}'
out=$(run sync fakepkg 1.0.1 "$SHA" release-1.0.1 7)
has "outside a fork it succeeds" "$out" "exit 0"
hasnt "and prints no synchronization" "$out" "synchronization"
is "nor summarizes one" "$(cat "$SUMMARY")" ""
answer "repos/owner/fakepkg" '{"fork": true, "parent": {"full_name": "upowner/fakepkg"}}'
out=$(run sync fakepkg 1.0.1 "$SHA" release-1.0.1 7)
has "in a fork it succeeds" "$out" "exit 0"
has "with a notice" "$out" "::notice title=Manual synchronization::owner/fakepkg is a fork of upowner/fakepkg"
s=$(cat "$SUMMARY")
has "the summary names the parent" "$s" "## Manual synchronization with upowner/fakepkg"
has "says nothing changes it" "$s" "Nothing here changes upowner/fakepkg: run these commands by hand after this submission."
has "names the remotes" "$s" "with the remotes \`upstream\` (upowner/fakepkg) and \`origin\` (owner/fakepkg)."
has "fetches the commit from origin" "$s" "git fetch origin $SHA"
has "and pushes it to the branch on upstream" "$s" "git push upstream $SHA:refs/heads/release-1.0.1"
has "copies the draft release to the parent, targeting the commit" "$s" \
  "gh release create v1.0.1 --repo upowner/fakepkg --draft --target $SHA --title 'fakepkg 1.0.1' \\
    --notes-file cran-sync/notes.md cran-sync/fakepkg_1.0.1.tar.gz"
has "and points the parent's checklist at the fork's" "$s" "attempts are recorded in https://github.example/owner/fakepkg/pull/7."
has "the log carries the commands too" "$out" "git push upstream $SHA:refs/heads/release-1.0.1"
is "and nothing is written" "$(cat "$SCRATCH/writes")" ""
out=$(DRY_RUN=true run sync fakepkg 1.0.1 "$SHA" release-1.0.1 7)
has "a dry run's apply after a real run" "$(cat "$SUMMARY")" "after a real run of this submission"
out=$(run sync fakepkg 1.0.1 "$SHA" 'a..b' 7)
has "a branch that is no branch name is a usage error" "$out" "exit 2"
# shellcheck disable=SC2016  # a literal $ in the branch name
out=$(run sync fakepkg 1.0.1 "$SHA" 'release-$x' 7)
has "a branch name the shell would expand is quoted" "$(cat "$SUMMARY")" "git push upstream $SHA:refs/heads/release-\\\$x"
out=$(run sync fakepkg 1.0.1 "$SHA" 'release 1' 7)
has "a branch name git refuses is a usage error" "$out" "exit 2"

# The printed lookup of the parent's checklist pull request, run against the stub with the parent's pull requests.
out=$(run sync fakepkg 1.0.1 "$SHA" release-1.0.1 7)
# shellcheck disable=SC2016  # sed addresses, not expansions
sed -n '/^```sh$/,/^```$/p' "$SUMMARY" | sed '1d;$d' >"$SCRATCH/sync.sh"
has "the commands run in their own shell, so a failure leaves the terminal open" "$(cat "$SCRATCH/sync.sh")" "bash -euo pipefail <<'SYNC'"
is "which the block ends" "$(tail -n 1 "$SCRATCH/sync.sh")" "SYNC"
mkdir -p "$SCRATCH/failgit"
printf '#!/bin/sh\necho "git: refused" >&2\nexit 1\n' >"$SCRATCH/failgit/git"
chmod +x "$SCRATCH/failgit/git"
# shellcheck disable=SC2016  # expanded by the pasting shell
out=$(PATH="$SCRATCH/failgit:$PATH" bash -c '. "$1"; echo "still open after $?"' _ "$SCRATCH/sync.sh" 2>&1)
has "pasted into a shell, a failing command stops the commands" "$out" "git: refused"
has "and leaves that shell running" "$out" "still open after 1"
succeeds "the block is valid shell" bash -n "$SCRATCH/sync.sh"
sed -n '/^prs=/,/^fi$/p' "$SUMMARY" >"$SCRATCH/lookup.sh"
# shellcheck disable=SC2016  # expanded by the printed script
echo 'echo "pr=$prs"' >>"$SCRATCH/lookup.sh"
UPULLS="repos/upowner/fakepkg/pulls?state=open&per_page=100"
lookup() { local rc=0; bash -euo pipefail "$SCRATCH/lookup.sh" 2>&1 || rc=$?; echo "exit $rc"; }
answer "$UPULLS" "[{\"number\": 27, \"user\": {\"login\": \"upmaint\", \"type\": \"User\"}, \"body\": null}, $(pull 28 MEMBER upmaint '' User upowner/fakepkg),
  $(pull 21 MEMBER upmaint "$MARK\nChecklist" User upowner/fakepkg), $(pull 26 NONE outsider "$MARK" User other/fakepkg),
  $(pull 22 NONE upmaint "Notes\n$MARK" User upowner/fakepkg),
  $(pull 23 NONE 'dependabot[bot]' "$MARK" Bot upowner/fakepkg), $(pull 24 NONE 'some-app[bot]' "$MARK" Bot someone/fakepkg)]"
out=$(lookup)
is "the printed lookup takes the parent's one checklist pull request, filtered as find filters, past bodiless ones" "$out" "pr=21
exit 0"
answer "$UPULLS" "[$(pull 22 NONE upmaint "Notes\n$MARK" User upowner/fakepkg)]"
out=$(lookup)
has "and fails without one" "$out" "Expected one checklist pull request in upowner/fakepkg, found: none"
has "with an error" "$out" "exit 1"
answer "$UPULLS" "[$(pull 21 OWNER upmaint "$MARK" User upowner/fakepkg), $(pull 25 NONE 'release-app[bot]' "$MARK" Bot upowner/fakepkg)]"
out=$(lookup)
has "or with two" "$out" "found: 21 25"

answer "repos/owner/fakepkg" '{"fork": true, "parent": null}'
out=$(run sync fakepkg 1.0.1 "$SHA" release-1.0.1 7)
has "a fork whose parent cannot be read fails" "$out" \
  "::error title=The fork's parent cannot be read::owner/fakepkg is a fork, but its parent reads as ''."
rm "$API/repos_owner_fakepkg.json"
out=$(run sync fakepkg 1.0.1 "$SHA" release-1.0.1 7)
has "an unreadable repository fails with GitHub's error" "$out" \
  "::error title=The repository cannot be read::Reading owner/fakepkg failed: gh: Not Found (HTTP 404)"

done_testing
