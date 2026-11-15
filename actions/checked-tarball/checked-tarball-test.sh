#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Check checked-tarball.sh offline, against a `gh` stub: nothing reaches GitHub.
#
#   1. `find` takes the newest run of the check workflow on the commit that holds the artifact,
#      skipping runs without it, and outputs the run, the artifact and its digest.
#   2. A given run must be of the commit; a commit without a checked tarball fails, as does an artifact without a digest.
#   3. A run that is not green warns and does not fail.
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
answer "repos/owner/fakepkg/actions/workflows/R-CMD-check.yaml/runs?head_sha=$SHA&per_page=100" \
  '{"workflow_runs": [{"id": 10, "created_at": "2026-11-14T10:00:00Z"}, {"id": 12, "created_at": "2026-11-15T10:00:00Z"}, {"id": 11, "created_at": "2026-11-14T12:00:00Z"}]}'
answer "repos/owner/fakepkg/actions/runs/12/artifacts?name=$NAME&per_page=100" '{"artifacts": []}'
answer "repos/owner/fakepkg/actions/runs/11/artifacts?name=$NAME&per_page=100" \
  "{\"artifacts\": [{\"id\": 501, \"expired\": false, \"created_at\": \"2026-11-14T12:30:00Z\", \"digest\": \"sha256:$DIGEST\"}]}"
answer "repos/owner/fakepkg/actions/runs/10/artifacts?name=$NAME&per_page=100" \
  '{"artifacts": [{"id": 401, "expired": false, "created_at": "2026-11-14T10:30:00Z", "digest": "sha256:bbbb"}]}'
answer "repos/owner/fakepkg/actions/runs/11" "{\"id\": 11, \"head_sha\": \"$SHA\", \"status\": \"completed\", \"conclusion\": \"success\"}"
answer "repos/owner/fakepkg/actions/runs/12" "{\"id\": 12, \"head_sha\": \"$SHA\", \"status\": \"completed\", \"conclusion\": \"failure\"}"
answer "repos/owner/fakepkg/actions/runs/10" "{\"id\": 10, \"head_sha\": \"$SHA\", \"status\": \"completed\", \"conclusion\": \"success\"}"
answer "repos/owner/fakepkg/actions/runs/20" "{\"id\": 20, \"head_sha\": \"$OTHER\", \"status\": \"completed\", \"conclusion\": \"success\"}"

section "find takes the newest run on the commit that holds the tarball"
out=$(run find "$SHA" fakepkg 1.0.1)
has "it succeeds" "$out" "exit 0"
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
has "of another commit fails" "$out" "::error title=The check run is of another commit::"
out=$(CHECK_RUN_ID='1; x' run find "$SHA" fakepkg 1.0.1)
has "that is no number fails" "$out" "::error title=No valid run ID::"

section "no checked tarball"
out=$(run find "$OTHER" fakepkg 1.0.1)
has "a commit without check runs fails" "$out" "::error title=The check runs cannot be read::"
answer "repos/owner/fakepkg/actions/workflows/R-CMD-check.yaml/runs?head_sha=$OTHER&per_page=100" '{"workflow_runs": [{"id": 12, "created_at": "2026-11-15T10:00:00Z"}]}'
out=$(run find "$OTHER" fakepkg 1.0.1)
has "a commit whose runs hold no tarball fails" "$out" "::error title=No checked tarball::"
has "saying to dispatch the check" "$(cat "$SUMMARY")" "Dispatch the check workflow on this commit"
out=$(run find 0123456789 fakepkg 1.0.1)
has "a short SHA fails" "$out" "::error title=No full commit SHA::"
out=$(CHECK_RUN_ID=10 run find "$SHA" fakepkg 1.0.1)
has "an artifact without a SHA-256 digest fails" "$out" "::error title=The artifact has no SHA-256 digest::"

section "a run that is not green warns"
answer "repos/owner/fakepkg/actions/runs/12/artifacts?name=$NAME&per_page=100" \
  "{\"artifacts\": [{\"id\": 601, \"expired\": false, \"created_at\": \"2026-11-15T10:30:00Z\", \"digest\": \"sha256:$DIGEST\"}]}"
out=$(run find "$SHA" fakepkg 1.0.1)
has "it succeeds" "$out" "exit 0"
has "with the newest run" "$(cat "$SCRATCH/output")" "run-id=12"
has "and a warning" "$out" "::warning title=Check run not green::"

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
