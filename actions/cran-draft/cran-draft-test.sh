#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Check cran-draft.sh offline, against a `gh` stub: nothing reaches GitHub.
#
#   1. Without a draft, a real run creates one for the tag name, targeting the commit,
#      with the notes and the marker, and attaches the tarball; it writes no tag.
#   2. With a draft found by its marker, a real run updates it and replaces its asset.
#   3. An existing tag, a published release and several drafts stop the run before any write.
#   4. A dry run writes nothing and reports what it would write.
#   5. An asset whose recorded digest differs fails.
#
# Usage:
#   actions/cran-draft/cran-draft-test.sh

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../cran-lib/test-lib.sh
. "$HERE/../cran-lib/test-lib.sh"
gh_stub

export GH_REPO=owner/fakepkg GITHUB_SERVER_URL=https://github.example GITHUB_REPOSITORY=owner/fakepkg
SHA=0123456789abcdef0123456789abcdef01234567
SUMMARY=$SCRATCH/summary.md
NOTES=$SCRATCH/notes.md
printf -- '- New feature.\n\n<!-- cran-submission: fakepkg 1.0.1 -->\n' >"$NOTES"
mkdir -p "$SCRATCH/pkg/fakepkg" "$SCRATCH/dl"
printf 'Package: fakepkg\nVersion: 1.0.1\n' >"$SCRATCH/pkg/fakepkg/DESCRIPTION"
T=$SCRATCH/dl/fakepkg_1.0.1.tar.gz
tar -czf "$T" -C "$SCRATCH/pkg" fakepkg
TSHA=$(sha256sum "$T" | cut -d' ' -f1)
UPLOAD="https://uploads.github.example/repos/owner/fakepkg/releases/7/assets?name=fakepkg_1.0.1.tar.gz"

run() {
  local rc=0 out
  : >"$SUMMARY"
  : >"$SCRATCH/output"
  : >"$SCRATCH/writes"
  out=$(GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY=$SUMMARY GITHUB_OUTPUT=$SCRATCH/output \
    "$HERE/cran-draft.sh" fakepkg 1.0.1 "$SHA" "$NOTES" "$T" 2>&1) || rc=$?
  printf '%s\nexit %s\n' "$out" "$rc"
}
release() { # <id> <tag> <draft> <body>
  printf '{"id": %s, "tag_name": "%s", "draft": %s, "html_url": "https://github.example/owner/fakepkg/releases/%s", "upload_url": "https://uploads.github.example/repos/owner/fakepkg/releases/%s/assets{?name,label}", "body": "%s"}' \
    "$1" "$2" "$3" "$1" "$1" "$4"
}

answer "repos/owner/fakepkg/git/matching-refs/tags/v1.0.1" '[{"ref": "refs/tags/v1.0.10", "object": {"sha": "ffff"}}]'
answer "repos/owner/fakepkg/releases?per_page=100" "[$(release 3 v1.0.0 false 'old <!-- cran-submission: fakepkg 1.0.0 -->')]"
answer "POST repos/owner/fakepkg/releases" "$(release 7 v1.0.1 true '')"
answer "repos/owner/fakepkg/releases/7/assets?per_page=100" '[]'
answer "POST $UPLOAD" "{\"name\": \"fakepkg_1.0.1.tar.gz\", \"digest\": \"sha256:$TSHA\"}"

section "a first submission creates the draft"
out=$(run)
has "it succeeds" "$out" "exit 0"
w=$(cat "$SCRATCH/writes")
has "it creates a draft for the tag name, targeting the commit" "$w" "POST repos/owner/fakepkg/releases
  tag_name=v1.0.1
  target_commitish=$SHA
  name=fakepkg 1.0.1
  body=- New feature.

<!-- cran-submission: fakepkg 1.0.1 -->
  draft=true"
has "and attaches the tarball" "$w" "POST $UPLOAD
  input=sha256:$TSHA"
hasnt "and writes no tag" "$w" "git/refs"
is "the outputs" "$(cat "$SCRATCH/output")" "action=create
release-id=7
release-url=https://github.example/owner/fakepkg/releases/7"
has "the summary" "$(cat "$SUMMARY")" "Created the draft release [fakepkg 1.0.1](https://github.example/owner/fakepkg/releases/7)"

section "a resubmission updates the draft found by its marker"
answer "repos/owner/fakepkg/releases?per_page=100" \
  "[$(release 7 untagged-abc true '- Old.\n\n<!-- cran-submission: fakepkg 1.0.1 -->'), $(release 3 v1.0.0 false '')]"
answer "repos/owner/fakepkg/releases/7/assets?per_page=100" '[{"id": 70, "name": "fakepkg_1.0.1.tar.gz"}]'
out=$(run)
has "it succeeds" "$out" "exit 0"
w=$(cat "$SCRATCH/writes")
has "it updates the draft" "$w" "PATCH repos/owner/fakepkg/releases/7
  tag_name=v1.0.1
  target_commitish=$SHA"
hasnt "and creates none" "$w" "POST repos/owner/fakepkg/releases
"
has "it deletes the earlier attempt's tarball" "$w" "DELETE repos/owner/fakepkg/releases/assets/70"
has "and attaches this one" "$w" "POST $UPLOAD"
has "the outputs say so" "$(cat "$SCRATCH/output")" "action=update"

section "refusals write nothing"
answer "repos/owner/fakepkg/git/matching-refs/tags/v1.0.1" '[{"ref": "refs/tags/v1.0.1", "object": {"sha": "abcd"}}]'
out=$(run)
has "an existing tag stops the run" "$out" "::error title=The tag v1.0.1 exists::"
is "before any write" "$(cat "$SCRATCH/writes")" ""
answer "repos/owner/fakepkg/git/matching-refs/tags/v1.0.1" '[]'
answer "repos/owner/fakepkg/releases?per_page=100" "[$(release 8 v1.0.1 false '')]"
out=$(run)
has "a published release stops the run" "$out" "::error title=fakepkg 1.0.1 is published::"
is "before any write" "$(cat "$SCRATCH/writes")" ""
answer "repos/owner/fakepkg/releases?per_page=100" \
  "[$(release 7 v1.0.1 true ''), $(release 9 x true '<!-- cran-submission: fakepkg 1.0.1 -->')]"
out=$(run)
has "several drafts stop the run" "$out" "::error title=Several drafts of fakepkg 1.0.1::"
has "listing them" "$(cat "$SUMMARY")" "https://github.example/owner/fakepkg/releases/9"
is "before any write" "$(cat "$SCRATCH/writes")" ""

section "a dry run"
answer "repos/owner/fakepkg/releases?per_page=100" "[$(release 7 v1.0.1 true '')]"
out=$(DRY_RUN=true run)
has "succeeds" "$out" "exit 0"
is "and writes nothing" "$(cat "$SCRATCH/writes")" ""
s=$(cat "$SUMMARY")
has "it reports the update" "$s" "Nothing was written. A real run would update the draft release \`fakepkg 1.0.1\` at https://github.example/owner/fakepkg/releases/7"
has "the asset it would replace" "$s" "sha256 \`$TSHA\`, replacing the earlier attempt's"
has "and the notes" "$s" "<!-- cran-submission: fakepkg 1.0.1 -->"

section "an asset GitHub records differently"
answer "POST $UPLOAD" '{"name": "fakepkg_1.0.1.tar.gz", "digest": "sha256:0000"}'
out=$(run)
has "fails" "$out" "::error title=The attached tarball differs::"

section "reads that fail go through the failure report"
rm "$API/repos_owner_fakepkg_releases_per_page_100.json"
out=$(run)
has "unreadable releases fail with advice" "$out" "::error title=The releases cannot be read::"
has "in the summary too" "$(cat "$SUMMARY")" "### Release: failed"
rm "$API/repos_owner_fakepkg_git_matching-refs_tags_v1.0.1.json"
out=$(run)
has "unreadable tags fail with advice" "$out" "::error title=The tags cannot be read::"
is "and nothing is written" "$(cat "$SCRATCH/writes")" ""

done_testing
