#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Check release-status.sh offline, against a fake P3M and CRAN served on 127.0.0.1 and a `gh` stub:
# nothing reaches GitHub, P3M or CRAN.
#
#   1. Without a draft, or with a version P3M does not list yet, the run is green and writes nothing.
#   2. On the default path, a real run compares the tarballs, writes the annotated tag with the NEWS.md section,
#      publishes the draft, merges the default branch into the release branch, commits the development bump,
#      merges the release pull request at that commit, and comments, in that order.
#   3. A dry run writes nothing and says what it would write.
#   4. A CRAN tarball that differs beyond what CRAN writes refuses the tag, and fails.
#   5. On the fast path, the bump goes to the default branch and the empty checklist pull request is closed;
#      where the branch refuses the push, the bump is handed over and the pull request stays open.
#   6. A merge of the default branch that conflicts is handed over after the tag and the release, and the run stays green.
#   7. A tag on the target is kept, a tag elsewhere fails, and a draft without its tarball fails.
#   8. A target that is no SHA or carries another version fails; a later version on P3M still finishes an older draft;
#      a release branch that does not reach the target, one from a fork, or one carrying another version is handed over;
#      the default branch or the open pull requests that cannot be read fail before any write.
#   9. A published release whose checklist pull request is open is finished by the next run, after a kill
#      between publishing and commenting or after a partial finish, and one whose pull request is closed is left alone.
#  10. `compare` ignores the MD5 file and the fields CRAN adds to DESCRIPTION, and counts executable bits.
#
# Usage:
#   actions/release-status/release-status-test.sh

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../cran-lib/test-lib.sh
. "$HERE/../cran-lib/test-lib.sh"
gh_stub

export GH_REPO=owner/fakepkg GITHUB_SERVER_URL=https://github.example GITHUB_REPOSITORY=owner/fakepkg GITHUB_RUN_ID=99
R=repos/owner/fakepkg
SHA=0123456789abcdef0123456789abcdef01234567
HEAD=1111111111111111111111111111111111111111
MAIN=2222222222222222222222222222222222222222
SUMMARY=$SCRATCH/summary.md

# --- the tarballs: the draft's, and CRAN's with what CRAN writes --------------

SRV=$SCRATCH/srv
mkdir -p "$SRV/p3m/src/contrib" "$SRV/cran/src/contrib" "$SCRATCH/pkg/fakepkg/R" "$SCRATCH/dl"
printf 'Package: fakepkg\nVersion: 1.0.1\nDescription: A fake package\n    for tests.\nPackaged: 2026-11-02 10:00:00 UTC; maint\n' \
  >"$SCRATCH/pkg/fakepkg/DESCRIPTION"
echo 'f <- function() 1' >"$SCRATCH/pkg/fakepkg/R/f.R"
DRAFT=$SCRATCH/dl/fakepkg_1.0.1.tar.gz
tar -czf "$DRAFT" -C "$SCRATCH/pkg" fakepkg
DSHA=$(sha256sum "$DRAFT" | cut -d' ' -f1)
cran_tarball() { # <R code>
  rm -rf "$SCRATCH/cranpkg"
  cp -r "$SCRATCH/pkg" "$SCRATCH/cranpkg"
  printf 'Repository: CRAN\nDate/Publication: 2026-11-05 12:00:00\n  UTC\n' >>"$SCRATCH/cranpkg/fakepkg/DESCRIPTION"
  echo "abc *R/f.R" >"$SCRATCH/cranpkg/fakepkg/MD5"
  echo "$1" >"$SCRATCH/cranpkg/fakepkg/R/f.R"
  touch -d '2026-11-05 12:00' "$SCRATCH/cranpkg/fakepkg/R/f.R"
  tar -czf "$SRV/cran/src/contrib/fakepkg_1.0.1.tar.gz" -C "$SCRATCH/cranpkg" fakepkg
}
cran_tarball 'f <- function() 1'
p3m_lists() { # <version>
  printf 'Package: other\nVersion: 1.0\n\nPackage: fakepkg\nVersion: %s\n' "$1" | gzip >"$SRV/p3m/src/contrib/PACKAGES.gz"
}
p3m_lists 1.0.0

python3 -I -u -m http.server --bind 127.0.0.1 --directory "$SRV" 0 >"$SCRATCH/server.log" 2>&1 &
# shellcheck disable=SC2034  # read at exit, through CLEANUP
SERVER_PID=$!
# shellcheck disable=SC2016  # evaluated at exit
CLEANUP+=('kill "$SERVER_PID" 2>/dev/null')
PORT=
for _ in $(seq 100); do
  PORT=$(sed -n 's/.*port \([0-9]*\).*/\1/p' "$SCRATCH/server.log" | head -n 1)
  [ -z "$PORT" ] || break
  sleep 0.1
done
[ -n "$PORT" ] || {
  echo "the fake P3M did not start" >&2
  exit 1
}
export no_proxy=127.0.0.1 NO_PROXY=127.0.0.1
export P3M_REPO_URL=http://127.0.0.1:$PORT/p3m CRAN_URL=http://127.0.0.1:$PORT/cran

run() {
  local rc=0 out
  : >"$SUMMARY"
  : >"$SCRATCH/output"
  : >"$SCRATCH/writes"
  out=$(GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY=$SUMMARY GITHUB_OUTPUT=$SCRATCH/output "$HERE/release-status.sh" "$@" 2>&1) || rc=$?
  printf '%s\nexit %s\n' "$out" "$rc"
}
b64() { printf '%s' "$1" | base64 -w0; }
draft() { # <id> <tag> <asset> <digest>
  printf '{"id": %s, "tag_name": "%s", "draft": true, "target_commitish": "%s", "html_url": "https://github.example/owner/fakepkg/releases/%s", "body": "- Fix.\\n\\n<!-- cran-submission: fakepkg %s -->", "assets": [%s]}' \
    "$1" "$2" "$SHA" "$1" "${2#v}" "$([ -z "$3" ] || printf '{"id": 70, "name": "%s", "digest": "%s"}' "$3" "$4")"
}
# The order of the writes, one method and path per line.
order() { grep -E '^(POST|PATCH|PUT|DELETE) ' "$SCRATCH/writes" | cut -d' ' -f1-2 | paste -s -d '|' -; }

NEWS_REL=$'# fakepkg 1.0.1 (2026-11-02)\n\n- Fix.\n\n# fakepkg 1.0.0\n\n- First.\n'
answer "$R/releases?per_page=100" "[{\"id\": 3, \"tag_name\": \"v1.0.0\", \"draft\": false, \"body\": \"<!-- cran-submission: fakepkg 1.0.0 -->\"}]"
answer "$R/pulls?state=open&per_page=100" '[]'
answer "$R" '{"default_branch": "main"}'

section "no draft"
out=$(run)
has "it succeeds" "$out" "exit 0"
has "it says there is nothing to do" "$(cat "$SUMMARY")" "No draft release of a CRAN submission"
is "it writes nothing" "$(cat "$SCRATCH/writes")" ""

answer "$R/releases?per_page=100" "[$(draft 7 v1.0.1 fakepkg_1.0.1.tar.gz "sha256:$DSHA"), $(draft 8 v9 fakepkg_9.tar.gz '')]"
answer_raw "$R/releases/assets/70" "$DRAFT"

section "a version P3M does not list yet"
out=$(run)
has "it succeeds" "$out" "exit 0"
has "it reports the version P3M lists" "$(cat "$SUMMARY")" "fakepkg 1.0.1 is not on P3M yet"
has "and which version that is" "$(cat "$SUMMARY")" "lists fakepkg 1.0.0"
is "it writes nothing" "$(cat "$SCRATCH/writes")" ""
has "a draft whose tag name is not its marker's is skipped" "$out" "skipped: https://github.example/owner/fakepkg/releases/8"

p3m_lists 1.0.1
MARK='<!-- release-checklist: fakepkg 1.0.1 -->'
answer "$R/pulls?state=open&per_page=100" "[{\"number\": 12, \"author_association\": \"OWNER\", \"user\": {\"login\": \"maint\", \"type\": \"User\"}, \"head\": {\"repo\": {\"full_name\": \"owner/fakepkg\"}}, \"body\": \"$MARK\\n# Release\"}]"
answer "$R/collaborators/maint/permission" '{"permission": "admin"}'
answer "$R/git/matching-refs/tags/v1.0.1" '[{"ref": "refs/tags/v1.0.10"}]'
answer "$R/contents/NEWS.md?ref=$SHA" "{\"content\": \"$(b64 "$NEWS_REL")\"}"
answer "$R/contents/DESCRIPTION?ref=$SHA" "{\"content\": \"$(b64 $'Package: fakepkg\nVersion: 1.0.1\nDate: 2026-11-02\n')\"}"
answer "POST $R/git/tags" '{"sha": "7a67a67a67a67a67a67a67a67a67a67a67a67a67"}'
answer "POST $R/git/refs" '{"ref": "refs/tags/v1.0.1"}'
answer "$R/pulls/12" '{"changed_files": 3, "head": {"ref": "release-1.0.1", "repo": {"full_name": "owner/fakepkg"}}, "base": {"ref": "main"}}'
answer "$R/compare/$SHA...release-1.0.1" '{"status": "ahead"}'
answer "$R/compare/$SHA...main" '{"status": "ahead"}'
answer "POST $R/merges" "{\"sha\": \"$MAIN\"}"
answer "$R/git/ref/heads/release-1.0.1" "{\"object\": {\"sha\": \"$HEAD\"}}"
answer "$R/git/ref/heads/main" "{\"object\": {\"sha\": \"$MAIN\"}}"
for c in "$HEAD" "$MAIN"; do
  answer "$R/contents/DESCRIPTION?ref=$c" "{\"content\": \"$(b64 $'Package: fakepkg\nVersion: 1.0.1\nDate: 2026-11-02\n')\"}"
  answer "$R/contents/NEWS.md?ref=$c" "{\"content\": \"$(b64 "$NEWS_REL")\"}"
  answer "$R/git/commits/$c" '{"tree": {"sha": "7777777777777777777777777777777777777777"}}'
done
answer "POST $R/git/blobs" '{"sha": "b10b"}'
answer "POST $R/git/trees" '{"sha": "7ee"}'
answer "POST $R/git/commits" '{"sha": "3333333333333333333333333333333333333333"}'
answer "PUT $R/pulls/12/merge" '{"sha": "4444444444444444444444444444444444444444"}'
answer "$R/issues/12/comments?per_page=100" '[]'

section "the default path"
out=$(run)
has "it succeeds" "$out" "exit 0"
is "it tags, publishes, merges, bumps, merges the pull request and comments, in that order" "$(order)" \
  "POST $R/git/tags|POST $R/git/refs|PATCH $R/releases/7|POST $R/merges|POST $R/git/blobs|POST $R/git/blobs|POST $R/git/trees|POST $R/git/commits|PATCH $R/git/refs/heads/release-1.0.1|PUT $R/pulls/12/merge|POST $R/issues/12/comments"
w=$(cat "$SCRATCH/writes")
has "the tag is annotated with the NEWS.md section, on the target" "$w" "POST $R/git/tags
  tag=v1.0.1
  message=fakepkg 1.0.1

- Fix.
  object=$SHA
  type=commit"
has "the release is published as the latest" "$w" "PATCH $R/releases/7
  draft=false
  make_latest=true"
has "the default branch is merged into the release branch" "$w" "POST $R/merges
  base=release-1.0.1
  head=main"
has "the bump sets the development version" "$w" "Version: 1.0.1.9000"
has "and writes the development section" "$w" "Changes since v1.0.1: <https://github.com/owner/fakepkg/compare/v1.0.1...main>"
has "the bump's commit has the release branch's head as its parent" "$w" "  message=Bump version to 1.0.1.9000
  tree=7ee
  parents[]=$HEAD"
has "the branch moves without force" "$w" "force=false"
has "the release pull request is merged with a merge commit at the bump" "$w" "PUT $R/pulls/12/merge
  merge_method=merge
  sha=3333333333333333333333333333333333333333"
has "the comment carries its marker" "$w" "body=<!-- release-status: fakepkg 1.0.1 -->"
has "and says it is done" "$w" "Release status: fakepkg 1.0.1 ✅"
has "it writes the published release" "$(cat "$SCRATCH/output")" $'published<<EOF_PUBLISHED\nfakepkg 1.0.1\nEOF_PUBLISHED'

section "a dry run"
out=$(run --dry-run)
has "it succeeds" "$out" "exit 0"
is "it writes nothing" "$(cat "$SCRATCH/writes")" ""
s=$(cat "$SUMMARY")
has "it says it would tag" "$s" "Would write the annotated tag \`v1.0.1\`"
has "publish" "$s" "Would publish the draft as the latest release."
has "merge the default branch" "$s" "Would merge \`main\` into \`release-1.0.1\`."
has "bump" "$s" "Would commit the development bump, fakepkg 1.0.1.9000, to \`release-1.0.1\`"
has "and merge the pull request" "$s" "Would merge #12 into \`main\` with a merge commit."
hasnt "it publishes nothing" "$(cat "$SCRATCH/output")" "published"

section "a comment already there is updated"
answer "$R/issues/12/comments?per_page=100" '[{"id": 55, "user": {"login": "github-actions[bot]"}, "body": "<!-- release-status: fakepkg 1.0.1 -->\nold"}]'
out=$(run)
has "it updates the comment in place" "$(order)" "PATCH $R/issues/comments/55"
answer "$R/issues/12/comments?per_page=100" '[]'

section "CRAN's tarball differs"
cran_tarball 'f <- function() 2'
out=$(run)
has "it fails" "$out" "exit 1"
has "refusing the tag" "$out" "::error title=CRAN's tarball differs from the draft's::"
has "the summary shows the difference" "$(cat "$SUMMARY")" "f <- function() 2"
is "it writes only the comment" "$(order)" "POST $R/issues/12/comments"
has "which says the tag was refused" "$(cat "$SCRATCH/writes")" "so the tag was refused"
cran_tarball 'f <- function() 1'

section "a conflicting merge of the default branch"
answer_fail "POST $R/merges" "gh: Merge conflict (HTTP 409)"
out=$(run)
has "the run stays green" "$out" "exit 0"
has "it warns about the handover" "$out" "::warning title=Handed over::"
is "it tags, publishes and comments, and merges nothing" "$(order)" \
  "POST $R/git/tags|POST $R/git/refs|PATCH $R/releases/7|POST $R/merges|POST $R/issues/12/comments"
w=$(cat "$SCRATCH/writes")
has "the comment names the conflict" "$w" "conflicts, as a hotfix's merge does"
has "and hands over the commands" "$w" "git merge origin/main"
has "including the bump" "$w" "bash -s -- . owner/fakepkg main"
answer_fail "POST $R/merges" ""

section "a release pull request that cannot be merged"
answer_fail "PUT $R/pulls/12/merge" "gh: Required status check is expected (HTTP 405)"
out=$(run)
has "the run stays green" "$out" "exit 0"
has "the bump is committed" "$(order)" "PATCH $R/git/refs/heads/release-1.0.1"
has "the merge is handed over" "$(cat "$SCRATCH/writes")" "gh pr merge 12 --merge"
answer_fail "PUT $R/pulls/12/merge" ""

section "the fast path"
answer "$R/pulls/12" '{"changed_files": 0, "head": {"ref": "empty-1.0.1", "repo": {"full_name": "owner/fakepkg"}}, "base": {"ref": "main"}}'
out=$(run)
has "it succeeds" "$out" "exit 0"
is "it bumps the default branch, comments and closes the checklist pull request" "$(order)" \
  "POST $R/git/tags|POST $R/git/refs|PATCH $R/releases/7|POST $R/git/blobs|POST $R/git/blobs|POST $R/git/trees|POST $R/git/commits|PATCH $R/git/refs/heads/main|POST $R/issues/12/comments|PATCH $R/pulls/12"
has "the bump's parent is the default branch's head" "$(cat "$SCRATCH/writes")" "parents[]=$MAIN"
has "the pull request is closed" "$(cat "$SCRATCH/writes")" "PATCH $R/pulls/12
  state=closed"

section "the fast path on a protected default branch"
answer_fail "PATCH $R/git/refs/heads/main" "gh: Protected branch update failed (HTTP 422)"
out=$(run)
has "the run stays green" "$out" "exit 0"
hasnt "the checklist pull request stays open" "$(order)" "PATCH $R/pulls/12"
has "the bump is handed over as a pull request" "$(cat "$SCRATCH/writes")" "git switch -c dev-bump-1.0.1 origin/main"
answer_fail "PATCH $R/git/refs/heads/main" ""
answer "$R/pulls/12" '{"changed_files": 3, "head": {"ref": "release-1.0.1", "repo": {"full_name": "owner/fakepkg"}}, "base": {"ref": "main"}}'

section "tags"
answer "$R/git/matching-refs/tags/v1.0.1" '[{"ref": "refs/tags/v1.0.1"}]'
answer "$R/commits/refs/tags/v1.0.1" "{\"sha\": \"$SHA\"}"
out=$(run)
has "a tag on the target is kept" "$out" "exit 0"
hasnt "and not written again" "$(order)" "git/tags"
answer "$R/commits/refs/tags/v1.0.1" "{\"sha\": \"$HEAD\"}"
out=$(run)
has "a tag elsewhere fails" "$out" "::error title=The tag v1.0.1 points elsewhere::"
has "and publishes nothing" "$(order)" "POST $R/issues/12/comments"
hasnt "nothing is published" "$(order)" "releases/7"
answer "$R/git/matching-refs/tags/v1.0.1" '[]'

section "a draft without its tarball"
answer "$R/releases?per_page=100" "[$(draft 7 v1.0.1 '' '')]"
out=$(run)
has "it fails" "$out" "::error title=The draft has no tarball::"
hasnt "and tags nothing" "$(order)" "git/tags"

section "several drafts of the version"
answer "$R/releases?per_page=100" "[$(draft 7 v1.0.1 fakepkg_1.0.1.tar.gz "sha256:$DSHA"), $(draft 9 v1.0.1 fakepkg_1.0.1.tar.gz "sha256:$DSHA")]"
out=$(run)
has "they fail" "$out" "::error title=Several drafts of fakepkg 1.0.1::"
hasnt "and nothing is tagged" "$(order)" "git/tags"

answer "$R/releases?per_page=100" "[$(draft 7 v1.0.1 fakepkg_1.0.1.tar.gz "sha256:$DSHA")]"
DESC_REL=$(b64 $'Package: fakepkg\nVersion: 1.0.1\nDate: 2026-11-02\n')

section "a draft whose target is no SHA"
answer "$R/releases?per_page=100" "[$(draft 7 v1.0.1 fakepkg_1.0.1.tar.gz "sha256:$DSHA" | sed "s/$SHA/main/")]"
out=$(run)
has "it fails" "$out" "::error title=The draft's target is no commit::"
is "it writes only the comment" "$(order)" "POST $R/issues/12/comments"
answer "$R/releases?per_page=100" "[$(draft 7 v1.0.1 fakepkg_1.0.1.tar.gz "sha256:$DSHA")]"

section "a draft whose target carries another version"
answer "$R/contents/DESCRIPTION?ref=$SHA" "{\"content\": \"$(b64 $'Package: fakepkg\nVersion: 1.0.0\n')\"}"
out=$(run)
has "it fails" "$out" "::error title=The draft's target is not fakepkg 1.0.1::"
is "it writes only the comment" "$(order)" "POST $R/issues/12/comments"
answer "$R/contents/DESCRIPTION?ref=$SHA" "{\"content\": \"$DESC_REL\"}"

section "P3M lists a later version"
p3m_lists 1.0.2
out=$(run --dry-run)
has "an older draft still finishes" "$out" "exit 0"
has "saying so" "$(cat "$SUMMARY")" "P3M lists fakepkg 1.0.2, later than 1.0.1"
has "and it would publish" "$(cat "$SUMMARY")" "Would publish the draft"
p3m_lists 1.0.1

section "a release branch that does not reach the released commit"
answer "$R/compare/$SHA...release-1.0.1" '{"status": "diverged"}'
out=$(run)
has "the run stays green" "$out" "exit 0"
is "it tags, publishes and comments, and merges nothing" "$(order)" \
  "POST $R/git/tags|POST $R/git/refs|PATCH $R/releases/7|POST $R/issues/12/comments"
has "the comment hands the merge over" "$(cat "$SCRATCH/writes")" "does not reach the released commit"
answer "$R/compare/$SHA...release-1.0.1" '{"status": "ahead"}'

section "a release pull request from a fork"
answer "$R/pulls/12" '{"changed_files": 3, "head": {"ref": "release-1.0.1", "repo": {"full_name": "fork/fakepkg"}}, "base": {"ref": "main"}}'
out=$(run)
has "the run stays green" "$out" "exit 0"
is "it merges nothing" "$(order)" "POST $R/git/tags|POST $R/git/refs|PATCH $R/releases/7|POST $R/issues/12/comments"
has "the comment says why" "$(cat "$SCRATCH/writes")" "merges \`fork/fakepkg:release-1.0.1\` into \`main\`"
answer "$R/pulls/12" '{"changed_files": 3, "head": {"ref": "release-1.0.1", "repo": {"full_name": "owner/fakepkg"}}, "base": {"ref": "main"}}'

section "a release branch that carries another version"
answer "$R/contents/DESCRIPTION?ref=$HEAD" "{\"content\": \"$(b64 $'Package: fakepkg\nVersion: 1.0.2.9000\n')\"}"
out=$(run)
has "the run stays green" "$out" "exit 0"
hasnt "nothing is bumped or merged" "$(order)" "pulls/12/merge"
has "the comment says why" "$(cat "$SCRATCH/writes")" "carries fakepkg 1.0.2.9000, not 1.0.1 or 1.0.1.9000"
answer "$R/contents/DESCRIPTION?ref=$HEAD" "{\"content\": \"$DESC_REL\"}"

section "the default branch cannot be read"
answer_fail "$R" "gh: Server Error (HTTP 500)"
out=$(run)
has "it fails" "$out" "::error title=The default branch cannot be read::"
is "it writes nothing" "$(cat "$SCRATCH/writes")" ""
answer_fail "$R" ""

section "the open pull requests cannot be read"
answer_fail "$R/pulls?state=open&per_page=100" "gh: Server Error (HTTP 500)"
out=$(run)
has "it fails" "$out" "::error title=The open pull requests cannot be listed::"
is "it writes nothing" "$(cat "$SCRATCH/writes")" ""
answer_fail "$R/pulls?state=open&per_page=100" ""

published() { # <id> <tag>
  printf '{"id": %s, "tag_name": "%s", "draft": false, "target_commitish": "%s", "html_url": "https://github.example/owner/fakepkg/releases/%s", "body": "- Fix.\\n\\n<!-- cran-submission: fakepkg %s -->", "assets": []}' \
    "$1" "$2" "$SHA" "$1" "${2#v}"
}
answer "$R/releases?per_page=100" "[$(published 7 v1.0.1)]"
answer "$R/git/matching-refs/tags/v1.0.1" '[{"ref": "refs/tags/v1.0.1"}]'
answer "$R/commits/refs/tags/v1.0.1" "{\"sha\": \"$SHA\"}"

section "a run killed between publishing and commenting"
out=$(run)
has "the next run succeeds" "$out" "exit 0"
is "it finishes the release without tagging or publishing again" "$(order)" \
  "POST $R/merges|POST $R/git/blobs|POST $R/git/blobs|POST $R/git/trees|POST $R/git/commits|PATCH $R/git/refs/heads/release-1.0.1|PUT $R/pulls/12/merge|POST $R/issues/12/comments"
has "the comment says it resumed" "$(cat "$SCRATCH/writes")" "is published already, and its checklist pull request is still open"
hasnt "and publishes nothing" "$(cat "$SCRATCH/output")" "published"

section "a rerun after a partial finish"
answer "POST $R/merges" '{}'
answer "$R/contents/DESCRIPTION?ref=$HEAD" "{\"content\": \"$(b64 $'Package: fakepkg\nVersion: 1.0.1.9000\n')\"}"
answer "$R/contents/NEWS.md?ref=$HEAD" "{\"content\": \"$(b64 $'# fakepkg (development version)\n\nChanges since v1.0.1: <x>\n\n'"$NEWS_REL")\"}"
out=$(run)
has "it succeeds" "$out" "exit 0"
is "it only merges the pull request and comments" "$(order)" "POST $R/merges|PUT $R/pulls/12/merge|POST $R/issues/12/comments"
has "at the branch's head" "$(cat "$SCRATCH/writes")" "sha=$HEAD"
has "saying what was done before" "$(cat "$SCRATCH/writes")" "\`release-1.0.1\` carries the development bump already"

section "a published release whose tag is elsewhere"
answer "$R/commits/refs/tags/v1.0.1" "{\"sha\": \"$HEAD\"}"
out=$(run)
has "it fails" "$out" "::error title=The tag v1.0.1 is not on the release's target::"
is "it writes only the comment" "$(order)" "POST $R/issues/12/comments"

section "a published release whose checklist pull request is closed"
answer "$R/pulls?state=open&per_page=100" '[]'
out=$(run)
has "is done" "$out" "nothing to do"
is "it writes nothing" "$(cat "$SCRATCH/writes")" ""

section "compare"
cran_tarball 'f <- function() 1'
succeeds "the tarballs match but for what CRAN writes" "$HERE/release-status.sh" compare "$SRV/cran/src/contrib/fakepkg_1.0.1.tar.gz" "$DRAFT"
chmod +x "$SCRATCH/cranpkg/fakepkg/R/f.R"
tar -czf "$SCRATCH/other.tar.gz" -C "$SCRATCH/cranpkg" fakepkg
out=$("$HERE/release-status.sh" compare "$SCRATCH/other.tar.gz" "$DRAFT" || echo "exit $?")
has "an executable bit counts" "$out" "fakepkg/R/f.R	f x"
has "as a difference" "$out" "exit 1"
echo 'not a tarball' >"$SCRATCH/broken.tar.gz"
out=$("$HERE/release-status.sh" compare "$SCRATCH/broken.tar.gz" "$DRAFT" 2>&1 || echo "exit $?")
has "a tarball that cannot be unpacked is an error" "$out" "exit 2"
cran_tarball 'f <- function() 1'
printf 'Packaged: another day\n' >>"$SCRATCH/cranpkg/fakepkg/DESCRIPTION"
tar -czf "$SCRATCH/other.tar.gz" -C "$SCRATCH/cranpkg" fakepkg
fails "a field CRAN does not write counts" "$HERE/release-status.sh" compare "$SCRATCH/other.tar.gz" "$DRAFT"
cran_tarball 'f <- function() 1'
rm "$SCRATCH/cranpkg/fakepkg/R/f.R"
tar -czf "$SCRATCH/other.tar.gz" -C "$SCRATCH/cranpkg" fakepkg
fails "a missing file counts" "$HERE/release-status.sh" compare "$SCRATCH/other.tar.gz" "$DRAFT"

done_testing
