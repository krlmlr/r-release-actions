#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Check checked-tarball.sh offline, against a `gh` stub: nothing reaches GitHub.
#
#   1. `find` takes the newest run of the check workflow on the commit that holds the artifact,
#      skipping runs without it, and outputs the run, the artifact and its digest.
#   2. A given run must be of the commit; a commit without a checked tarball fails, as does an artifact without a digest.
#   3. A run that is not green, finished or not, fails, naming the run, its conclusion and its URL;
#      a run with several artifacts of the name fails.
#   4. `verify` accepts the file whose SHA-256 is the digest and which holds the release,
#      and rejects another digest, another release, and a file that is no tarball.
#
# Usage:
#   actions/checked-tarball/checked-tarball-test.sh

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../cran-lib/test-lib.sh
. "$HERE/../cran-lib/test-lib.sh"
gh_stub

export GH_REPO=owner/fakepkg GITHUB_SERVER_URL=https://github.example
SHA=0123456789abcdef0123456789abcdef01234567
OTHER=89abcdef0123456789abcdef0123456789abcdef
NAME=fakepkg_1.0.1.tar.gz
SUMMARY=$SCRATCH/summary.md

run() {
  local rc=0 out
  : >"$SUMMARY"
  : >"$SCRATCH/output"
  out=$(GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY=$SUMMARY GITHUB_OUTPUT=$SCRATCH/output \
    "$HERE/checked-tarball.sh" "$@" 2>&1) || rc=$?
  printf '%s\nexit %s\n' "$out" "$rc"
}

DIGEST=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# A run: <id> <created at> <event> <repository> <head sha> <conclusion>
runj() {
  printf '{"id": %s, "created_at": "%s", "event": "%s", "head_repository": {"full_name": "%s"}, "head_sha": "%s",
    "status": "completed", "conclusion": "%s"}' "$@"
}
artifact() { # <run> <artifact id> <created at> <digest>
  answer "repos/owner/fakepkg/actions/runs/$1/artifacts?name=$NAME&per_page=100" \
    "{\"artifacts\": [{\"id\": $2, \"expired\": false, \"created_at\": \"$3\", \"digest\": \"$4\"}]}"
}
R10=$(runj 10 2026-11-14T10:00:00Z push owner/fakepkg "$SHA" success)
R11=$(runj 11 2026-11-14T12:00:00Z workflow_dispatch owner/fakepkg "$SHA" success)
R12=$(runj 12 2026-11-15T10:00:00Z push owner/fakepkg "$SHA" failure)
# Newer, with the tarball, and never to be taken: a pull request run, and a run of a fork's branch.
R13=$(runj 13 2026-11-15T11:00:00Z pull_request owner/fakepkg "$SHA" success)
R14=$(runj 14 2026-11-15T12:00:00Z push fork/fakepkg "$SHA" success)
answer "repos/owner/fakepkg/actions/workflows/R-CMD-check.yaml/runs?head_sha=$SHA&per_page=100" \
  "{\"workflow_runs\": [$R10, $R12, $R11, $R13, $R14]}"
answer "repos/owner/fakepkg/actions/runs/12/artifacts?name=$NAME&per_page=100" '{"artifacts": []}'
artifact 11 501 2026-11-14T12:30:00Z "sha256:$DIGEST"
artifact 10 401 2026-11-14T10:30:00Z sha256:bbbb
artifact 13 1301 2026-11-15T11:30:00Z "sha256:$DIGEST"
artifact 14 1401 2026-11-15T12:30:00Z "sha256:$DIGEST"
for r in R10 R11 R12 R13 R14; do answer "repos/owner/fakepkg/actions/runs/${r#R}" "${!r}"; done
answer "repos/owner/fakepkg/actions/runs/20" "$(runj 20 2026-11-15T10:00:00Z push owner/fakepkg "$OTHER" success)"

section "find takes the newest push or dispatch run on the commit in the repository that holds the tarball"
out=$(run find "$SHA" fakepkg 1.0.1)
has "it succeeds" "$out" "exit 0"
hasnt "skipping the pull request run and the fork's" "$(cat "$SCRATCH/gh.log")" "runs/14/artifacts"
is "the outputs" "$(cat "$SCRATCH/output")" "run-id=11
run-url=https://github.example/owner/fakepkg/actions/runs/11
artifact-id=501
sha256=$DIGEST"
hasnt "a green run does not warn" "$out" "::warning"
has "the summary links the run" "$(cat "$SUMMARY")" "- Check run: [11](https://github.example/owner/fakepkg/actions/runs/11), completed success"

section "a given run"
out=$(CHECK_RUN_ID=11 run find "$SHA" fakepkg 1.0.1)
has "of the commit is taken" "$out" "exit 0"
has "with its artifact" "$(cat "$SCRATCH/output")" "artifact-id=501"
out=$(CHECK_RUN_ID=20 run find "$SHA" fakepkg 1.0.1)
has "of another commit fails" "$out" "::error title=The check run is not of the commit::"
out=$(CHECK_RUN_ID=13 run find "$SHA" fakepkg 1.0.1)
has "a pull request run fails" "$out" "::error title=The check run is not of the commit::The run 13 is a \`pull_request\` run"
out=$(CHECK_RUN_ID=14 run find "$SHA" fakepkg 1.0.1)
has "a fork's run fails" "$out" "in fork/fakepkg; the submission takes a push or dispatch run"
out=$(CHECK_RUN_ID='1; x' run find "$SHA" fakepkg 1.0.1)
has "that is no number fails" "$out" "::error title=No valid run ID::"

section "no checked tarball"
out=$(run find "$OTHER" fakepkg 1.0.1)
has "check runs that cannot be read fail, with GitHub's error" "$out" "::error title=The check runs cannot be read::"
has "naming it" "$out" "gh: Not Found (HTTP 404)"
answer "repos/owner/fakepkg/actions/workflows/R-CMD-check.yaml/runs?head_sha=$OTHER&per_page=100" \
  "{\"workflow_runs\": [$(runj 21 2026-11-15T10:00:00Z push owner/fakepkg "$OTHER" success)]}"
out=$(run find "$OTHER" fakepkg 1.0.1)
has "artifacts that cannot be read fail, with GitHub's error" "$out" \
  "::error title=The artifacts cannot be read::The artifacts of the run 21 cannot be read from owner/fakepkg: gh: Not Found (HTTP 404)."
answer "repos/owner/fakepkg/actions/runs/21/artifacts?name=$NAME&per_page=100" '{"artifacts": []}'
out=$(run find "$OTHER" fakepkg 1.0.1)
has "a commit whose runs hold no tarball fails" "$out" "::error title=No checked tarball::"
has "saying to dispatch the check" "$(cat "$SUMMARY")" "Dispatch the check workflow on this commit"
out=$(run find 0123456789 fakepkg 1.0.1)
has "a short SHA fails" "$out" "::error title=No full commit SHA::"
out=$(CHECK_RUN_ID=10 run find "$SHA" fakepkg 1.0.1)
has "an artifact without a SHA-256 digest fails" "$out" "::error title=The artifact has no SHA-256 digest::"

section "a run that is not green fails"
artifact 12 601 2026-11-15T10:30:00Z "sha256:$DIGEST"
out=$(run find "$SHA" fakepkg 1.0.1)
has "the newest run with the tarball failed: the submission fails" "$out" "exit 1"
has "naming the run, its conclusion and its URL" "$out" \
  "::error title=The check run is not green::The run 12 of \`R-CMD-check.yaml\` that built \`$NAME\` is \`completed failure\`, not \`completed success\`: https://github.example/owner/fakepkg/actions/runs/12."
is "and outputs nothing" "$(cat "$SCRATCH/output")" ""
answer "repos/owner/fakepkg/actions/runs/12" '{"id": 12, "event": "push", "head_repository": {"full_name": "owner/fakepkg"},
  "head_sha": "'"$SHA"'", "status": "in_progress", "conclusion": null}'
out=$(CHECK_RUN_ID=12 run find "$SHA" fakepkg 1.0.1)
has "a given run still in progress fails too" "$out" "is \`in_progress\`, not \`completed success\`"

section "several artifacts of the name in one run fail"
answer "repos/owner/fakepkg/actions/runs/11/artifacts?name=$NAME&per_page=100" \
  "{\"artifacts\": [{\"id\": 501, \"expired\": false, \"digest\": \"sha256:$DIGEST\"}, {\"id\": 502, \"expired\": false, \"digest\": \"sha256:$DIGEST\"}]}"
out=$(CHECK_RUN_ID=11 run find "$SHA" fakepkg 1.0.1)
has "with a message naming the run and the count" "$out" \
  "::error title=Several tarball artifacts in one run::The run 11 holds 2 unexpired artifacts named \`$NAME\`"
answer "repos/owner/fakepkg/actions/runs/11/artifacts?name=$NAME&per_page=100" \
  "{\"artifacts\": [{\"id\": 501, \"expired\": false, \"digest\": \"sha256:$DIGEST\"}, {\"id\": 502, \"expired\": true, \"digest\": \"sha256:$DIGEST\"}]}"
out=$(CHECK_RUN_ID=11 run find "$SHA" fakepkg 1.0.1)
has "an expired one does not count" "$out" "exit 0"

section "commit"
answer "repos/owner/fakepkg/commits/$SHA/branches-where-head" '[{"name": "release-1.0.1"}]'
out=$(run commit "$SHA")
has "the head of a branch passes" "$out" "exit 0"
has "naming it" "$(cat "$SUMMARY")" "the head of \`release-1.0.1\` in owner/fakepkg"
answer "repos/owner/fakepkg/commits/$OTHER/branches-where-head" '[]'
out=$(run commit "$OTHER")
has "a commit that heads no branch, a fork's or a superseded one, fails" "$out" "::error title=The commit is no branch head::"
out=$(run commit 89abcdef0123456789abcdef0123456789abcde0)
has "a failed call is no empty answer: it fails with GitHub's error" "$out" \
  "::error title=The commit's branches cannot be read::Asking owner/fakepkg which branches"
has "naming it" "$out" "gh: Not Found (HTTP 404)"

section "verify"
mkdir -p "$SCRATCH/pkg/fakepkg" "$SCRATCH/dl"
printf 'Package: fakepkg\nVersion: 1.0.1\nMaintainer: Jane Doe <jane@example.org>\n' >"$SCRATCH/pkg/fakepkg/DESCRIPTION"
tar -czf "$SCRATCH/dl/$NAME" -C "$SCRATCH/pkg" fakepkg
T=$SCRATCH/dl/$NAME
TSHA=$(sha256sum "$T" | cut -d' ' -f1)
out=$(run verify "$T" "$TSHA" fakepkg 1.0.1)
has "the checked file passes" "$out" "exit 0"
is "with its outputs" "$(cat "$SCRATCH/output")" "tarball=$T
sha256=$TSHA"
out=$(run verify "$T" "$DIGEST" fakepkg 1.0.1)
has "another digest fails" "$out" "::error title=The tarball is not the checked one::"
out=$(run verify "$T" "$TSHA" fakepkg 1.0.2)
has "another name fails" "$out" "::error title=The tarball is misnamed::"
printf 'Package: fakepkg\nVersion: 1.0.0\n' >"$SCRATCH/pkg/fakepkg/DESCRIPTION"
tar -czf "$SCRATCH/dl/$NAME" -C "$SCRATCH/pkg" fakepkg
out=$(run verify "$T" "$(sha256sum "$T" | cut -d' ' -f1)" fakepkg 1.0.1)
has "another release inside fails" "$out" "::error title=The tarball is of another release::"
printf 'not a tarball' >"$T"
out=$(run verify "$T" "$(sha256sum "$T" | cut -d' ' -f1)" fakepkg 1.0.1)
has "a file that is no tarball fails" "$out" "::error title=The tarball cannot be read::"
out=$(run verify "$SCRATCH/dl/missing_1.0.1.tar.gz" "$TSHA" missing 1.0.1)
has "no file fails" "$out" "::error title=No tarball downloaded::"

done_testing
