#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Create the version's draft release, or update it on a resubmission, and attach the checked tarball.
#
# One draft per version, titled `<package> <version>`, for the tag name `v<version>`,
# which GitHub writes only when the draft is published; the submission itself writes no tag.
# Its target is the full SHA of the submitted commit, its notes the version's NEWS.md section
# ending with the marker `<!-- cran-submission: <package> <version> -->`,
# and its one asset the tarball being submitted, which replaces an earlier attempt's.
# The draft is found by its tag name or by the marker in its notes.
# It stops instead, writing nothing, when:
#   - the tag `v<version>` exists, because it is written once, at acceptance;
#   - a release of the version is published already;
#   - more than one draft is found, which needs a person to decide which to keep.
# A dry run reports what a real run would write, and writes nothing.
#
# Usage:
#   cran-draft.sh <package> <version> <sha> <notes file> <tarball>
#
# Environment:
#   GH_REPO, GH_TOKEN    the repository, owner/name, and a token with `contents: write`
#   GH                   the gh command, default `gh`; cran-draft-test.sh stubs it
#   DRY_RUN              `true` writes nothing
#   GITHUB_OUTPUT        receives `release-id`, `release-url` and `action` (`create` or `update`)
#   GITHUB_STEP_SUMMARY, GITHUB_ACTIONS, GITHUB_SERVER_URL, GITHUB_REPOSITORY
#
# Exit status: 0 on success, 1 on a refusal or a failed write, 2 on a usage error.

set -euo pipefail

# shellcheck source=../cran-lib/cran-lib.sh
. "$(dirname "$0")/../cran-lib/cran-lib.sh"

usage() {
  sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
[ $# -eq 5 ] || usage
pkg=$1 version=$2 sha=$3 notes=$4 tarball=$5
{ valid_package "$pkg" && valid_version "$version" && valid_sha "$sha"; } || usage
{ [ -f "$notes" ] && [ -f "$tarball" ]; } || usage
repo=${GH_REPO:?}
gh=${GH:-gh}
dry_run=${DRY_RUN:-false}
tag=v$version
title="$pkg $version"
marker="<!-- cran-submission: $pkg $version -->"
base=$(basename "$tarball")
sha256=$(sha256_of "$tarball")

summary "## Draft release" ""
group "Release: $title"
val "tag name" "$tag"
val "target" "$sha"
val "asset" "$base (sha256 $sha256)"

existing=$("$gh" api "repos/$repo/git/matching-refs/tags/$tag" --jq ".[] | select(.ref == \"refs/tags/$tag\") | .object.sha")
if [ -n "$existing" ]; then
  fail "Release" "The tag $tag exists" \
    "The tag \`$tag\` points to \`$existing\`. It is written once, when CRAN has accepted the version, so this version cannot be submitted again. Nothing was drafted or uploaded." -- \
    "If CRAN has accepted $title, a new submission needs a new version." \
    "If the tag was written by mistake and never left this repository's clones, a maintainer deletes it, then dispatches the submission again."
fi

"$gh" api --paginate "repos/$repo/releases?per_page=100" \
  --jq ".[] | select(.tag_name == \"$tag\" or ((.body // \"\") | contains(\"$marker\"))) | [.id, (if .draft then \"draft\" else \"published\" end), .html_url, .upload_url] | @tsv" \
  >"${TMPDIR:-/tmp}/cran-draft.$$"
releases=$(cat "${TMPDIR:-/tmp}/cran-draft.$$")
rm -f "${TMPDIR:-/tmp}/cran-draft.$$"
published=$(printf '%s\n' "$releases" | awk -F '\t' '$2 == "published" { print $3 }')
drafts=$(printf '%s\n' "$releases" | awk -F '\t' '$2 == "draft"')
ndrafts=$(printf '%s' "$drafts" | grep -c . || true)
if [ -n "$published" ]; then
  fail "Release" "$title is published" \
    "The release of $title is published at $published, and a published release is never changed. Nothing was drafted or uploaded." -- \
    "If CRAN has accepted $title, a new submission needs a new version." \
    "If it was published by mistake, a maintainer turns it back into a draft, then dispatches the submission again."
fi
if [ "$ndrafts" -gt 1 ]; then
  printf '%s\n' "$drafts" | cut -f3 >"${TMPDIR:-/tmp}/cran-draft-urls.$$"
  failure "Release" "Several drafts of $title" \
    "$ndrafts draft releases carry the tag name \`$tag\` or the marker, and there is one per version. Nothing was drafted or uploaded." \
    "${TMPDIR:-/tmp}/cran-draft-urls.$$" -- \
    "Delete the drafts that are not this version's record, keeping the one with the earlier attempts' notes, then dispatch the submission again."
  rm -f "${TMPDIR:-/tmp}/cran-draft-urls.$$"
  exit 1
fi
if [ "$ndrafts" -eq 1 ]; then
  action=update
  IFS=$'\t' read -r id _ url upload_url <<<"$drafts"
  val "draft" "$url (updated)"
else
  action=create
  val "draft" "(created)"
fi
endgroup
group "Release notes"
cat "$notes"
endgroup

if [ "$dry_run" = true ]; then
  replacing=''
  [ -z "${url:-}" ] || replacing=", replacing the earlier attempt's"
  summary "Nothing was written. A real run would ${action} the draft release \`$title\`${url:+ at $url}:" "" \
    "- Tag name: \`$tag\`, written only when the draft is published at acceptance" \
    "- Target: \`$sha\`" \
    "- Asset: \`$base\`, sha256 \`$sha256\`$replacing" "" \
    "<details><summary>Release notes</summary>" "" '````markdown' "$(cat "$notes")" '````' "" "</details>" ""
  notice "Dry run" "Would $action the draft release '$title' for $tag at $sha, with $base; nothing was written."
  output action "$action" release-url "${url:-}"
  exit 0
fi

group "Release: write"
fields=(-f "tag_name=$tag" -f "target_commitish=$sha" -f "name=$title" -F "body=@$notes" -F draft=true)
if [ "$action" = update ]; then
  "$gh" api -X PATCH "repos/$repo/releases/$id" "${fields[@]}" --jq .id >/dev/null ||
    fail "Release" "The draft could not be updated" "Updating the draft $url failed." -- \
      "Check that the calling job grants \`contents: write\`, then dispatch the submission again."
else
  created=$("$gh" api -X POST "repos/$repo/releases" "${fields[@]}" --jq '[.id, .html_url, .upload_url] | @tsv') ||
    fail "Release" "The draft could not be created" "Creating the draft release $title failed." -- \
      "Check that the calling job grants \`contents: write\`, then dispatch the submission again."
  IFS=$'\t' read -r id url upload_url <<<"$created"
fi
val "release" "$url"

# A draft holds one asset, the tarball of the attempt it targets.
"$gh" api --paginate "repos/$repo/releases/$id/assets?per_page=100" --jq '.[] | [.id, .name] | @tsv' |
  while IFS=$'\t' read -r aid aname; do
    [ -n "$aid" ] || continue
    val "replaced asset" "$aname"
    "$gh" api -X DELETE "repos/$repo/releases/assets/$aid" >/dev/null ||
      fail "Release" "The earlier tarball could not be removed" "Deleting \`$aname\` from the draft $url failed. Nothing was sent to CRAN." -- \
        "Dispatch the submission again; it updates the same draft."
  done
asset=$("$gh" api -X POST "${upload_url%%\{*}?name=$base" -H "Content-Type: application/gzip" --input "$tarball" \
  --jq '[.name, (.digest // "")] | @tsv') ||
  fail "Release" "The tarball could not be attached" "Uploading \`$base\` to the draft $url failed. Nothing was sent to CRAN." -- \
    "Dispatch the submission again; it updates the same draft."
IFS=$'\t' read -r aname adigest <<<"$asset"
if [ -n "$adigest" ] && [ "$adigest" != "sha256:$sha256" ]; then
  fail "Release" "The attached tarball differs" "GitHub records the asset's digest \`$adigest\`, and the tarball's is \`sha256:$sha256\`. Nothing was sent to CRAN." -- \
    "Dispatch the submission again; it replaces the asset."
fi
val "asset" "$aname${adigest:+ ($adigest)}"
endgroup

summary "$([ "$action" = create ] && echo Created || echo Updated) the draft release [$title]($url):" "" \
  "- Tag name: \`$tag\`, written only when the draft is published at acceptance" \
  "- Target: $(commit_link "$sha")" \
  "- Asset: \`$base\`, sha256 \`$sha256\`" ""
notice "Draft release" "$([ "$action" = create ] && echo Created || echo Updated) $title at $url, targeting $sha, with $base."
output action "$action" release-id "$id" release-url "$url"
