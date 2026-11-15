#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Find the source tarball a check run built for a commit, and verify the downloaded file.
#
# The submission builds nothing: it uploads the file the check workflow built and checked.
# That workflow keeps the file as a raw (unzipped) artifact named `<package>_<version>.tar.gz`,
# uploaded with `actions/upload-artifact` and `archive: false`, so that the artifact's digest is the file's SHA-256.
#
#   commit <sha>
#     The commit is the head of a branch of GH_REPO (`commits/<sha>/branches-where-head`),
#     so a commit that exists only in a fork, or one a later push superseded, is refused.
#   find <sha> <package> <version>
#     The run is CHECK_RUN_ID when set, otherwise the newest run of the workflow CHECK_WORKFLOW on <sha> that holds the artifact.
#     Either way it is a push or dispatch run of <sha> in GH_REPO: a pull request run checks a merge commit,
#     and a run of a fork's branch is the fork's.
#     Writes `run-id`, `run-url`, `artifact-id` and `sha256` (from the artifact's digest) to GITHUB_OUTPUT.
#     That run must have completed with success, or the submission fails, naming the run, its conclusion and its URL.
#     Of several unexpired artifacts of that name in the run, which re-runs leave, the newest is taken,
#     and the log names the one chosen and the ones skipped.
#   verify <tarball> <sha256> <package> <version>
#     The file's SHA-256 is the artifact's digest, it is a gzip-compressed tar archive,
#     its name is `<package>_<version>.tar.gz`, and its DESCRIPTION names that package and version.
#     Writes `tarball` and `sha256` to GITHUB_OUTPUT.
#
# Environment:
#   GH_REPO          owner/name of the package's repository; GH_TOKEN a token with `actions: read`
#   GH               the gh command, default `gh`; checked-tarball-test.sh stubs it
#   CHECK_WORKFLOW   the check workflow's file name, default R-CMD-check.yaml
#   CHECK_RUN_ID     a run to take the tarball from, instead of searching
#   GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, GITHUB_ACTIONS, GITHUB_SERVER_URL
#
# Exit status: 0 on success, 1 on a failed check, 2 on a usage error.

set -euo pipefail

# shellcheck source=../cran-lib/cran-lib.sh
. "$(dirname "$0")/../cran-lib/cran-lib.sh"

usage() {
  sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

gh=${GH:-gh}

# `gh api` with its error kept: a failed call fails the stage with GitHub's message,
# so that only an empty answer to a successful call reads as "nothing found".
apierr=$(mktemp)
trap 'rm -f "$apierr"' EXIT
api() { "$gh" api "$@" 2>"$apierr"; }
api_error() { head -n 1 "$apierr"; }

cmd_find() {
  [ $# -eq 3 ] || usage
  local sha=$1 pkg=$2 version=$3
  local repo=${GH_REPO:?} workflow=${CHECK_WORKFLOW:-R-CMD-check.yaml} run_id=${CHECK_RUN_ID:-}
  valid_repo "$repo" || usage
  valid_sha "$sha" || fail "Tarball" "No full commit SHA" "\`$sha\` is no full 40-character commit SHA." -- \
    "Pass the full SHA of the commit to submit, such as \`\${{ github.sha }}\`."
  { valid_package "$pkg" && valid_version "$version"; } || usage
  local name="${pkg}_${version}.tar.gz"
  [[ $workflow =~ ^[A-Za-z0-9._-]+$ ]] || fail "Tarball" "No valid workflow name" "\`$workflow\` is no workflow file name." -- \
    "Pass the check workflow's file name, such as \`R-CMD-check.yaml\`."

  summary "## Checked tarball" ""
  group "Tarball: the check run of $(printf '%s' "${sha:0:10}")"
  val "commit" "$sha"
  val "artifact" "$name"
  # Only runs on a branch of this repository check the commit itself:
  # a pull request run checks a merge commit, and a run in a fork belongs to the fork.
  local accept="select((.event == \"push\" or .event == \"workflow_dispatch\")
    and .head_sha == \"$sha\" and .head_repository.full_name == \"$repo\")"
  local runs
  if [ -n "$run_id" ]; then
    [[ $run_id =~ ^[0-9]+$ ]] || fail "Tarball" "No valid run ID" "\`$run_id\` is no workflow run ID." -- \
      "Pass the numeric ID of the check run, from its URL, or leave it empty to search."
    val "run (given)" "$run_id"
    local given
    given=$(api "repos/$repo/actions/runs/$run_id" --jq '"\(.event) \(.head_repository.full_name) \(.head_sha)"') ||
      fail "Tarball" "The check run cannot be read" "The run $run_id cannot be read from $repo: $(api_error)." -- \
        "Check the run ID, and that the job holds \`actions: read\`."
    runs=$(api "repos/$repo/actions/runs/$run_id" --jq "$accept | .id") ||
      fail "Tarball" "The check run cannot be read" "The run $run_id cannot be read from $repo: $(api_error)." -- \
        "Check the run ID, and that the job holds \`actions: read\`."
    local what
    what="The run $run_id is a \`${given%% *}\` run of \`$(cut -d' ' -f3 <<<"$given")\` in $(cut -d' ' -f2 <<<"$given")"
    [ -n "$runs" ] ||
      fail "Tarball" "The check run is not of the commit" "$what; the submission takes a push or dispatch run of \`$sha\` in $repo." -- \
        "Pass a push or dispatch run of the commit to submit on this repository, or leave the run ID empty to search for it."
  else
    val "workflow" "$workflow"
    runs=$(api "repos/$repo/actions/workflows/$workflow/runs?head_sha=$sha&per_page=100" \
      --jq "[.workflow_runs[] | $accept] | sort_by(.created_at) | reverse | .[].id") ||
      fail "Tarball" "The check runs cannot be read" "The runs of \`$workflow\` cannot be read from $repo: $(api_error)." -- \
        "Check that \`$workflow\` is the check workflow's file name, and that the job holds \`actions: read\`."
  fi

  local r found='' artifact=''
  for r in $runs; do
    # Newest first: a re-run of the check keeps the earlier attempts' artifacts of the same name in the run.
    artifact=$(api "repos/$repo/actions/runs/$r/artifacts?name=$name&per_page=100" \
      --jq '[.artifacts[] | select(.expired | not)] | sort_by(.created_at) | reverse | .[] | "\(.id) \(.digest // "") \(.created_at)"') ||
      fail "Tarball" "The artifacts cannot be read" "The artifacts of the run $r cannot be read from $repo: $(api_error)." -- \
        "Check that the job holds \`actions: read\`, then dispatch the submission again."
    if [ -n "$artifact" ]; then
      if [ "$(grep -c . <<<"$artifact")" -gt 1 ]; then
        say "  The run $r holds $(grep -c . <<<"$artifact") artifacts named $name, from re-runs; taking the newest:"
        sed -n '1s/^\([0-9]*\) [^ ]* \(.*\)$/    chosen:  \1 (created \2)/p; 2,$s/^\([0-9]*\) [^ ]* \(.*\)$/    skipped: \1 (created \2)/p' <<<"$artifact"
      fi
      artifact=$(head -n 1 <<<"$artifact")
      artifact=${artifact% *}
      found=$r
      break
    fi
  done
  [ -n "$found" ] ||
    fail "Tarball" "No checked tarball" \
      "No ${run_id:+given }push or dispatch run of \`$workflow\` on \`${sha:0:10}\` in $repo holds an unexpired artifact \`$name\`." -- \
      "Dispatch the check workflow on this commit, wait until it is green, and dispatch the submission again." \
      "An artifact expires after at most 90 days: a commit checked that long ago is checked again."
  local artifact_id=${artifact%% *} digest=${artifact#* }
  local sha256=${digest#sha256:}
  [[ $sha256 =~ ^[0-9a-f]{64}$ ]] ||
    fail "Tarball" "The artifact has no SHA-256 digest" "The artifact $artifact_id of run $found has the digest \`$digest\`." -- \
      "The check workflow uploads the tarball with \`actions/upload-artifact\` v7 or later and \`archive: false\`, which records the file's SHA-256."
  local conclusion run_url
  conclusion=$(api "repos/$repo/actions/runs/$found" --jq '"\(.status) \(.conclusion // "")" | rtrimstr(" ")') ||
    fail "Tarball" "The check run cannot be read" "The run $found cannot be read from $repo: $(api_error)." -- \
      "Check that the job holds \`actions: read\`, then dispatch the submission again."
  run_url=${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/$found
  val "run" "$found ($conclusion)"
  val "artifact id" "$artifact_id"
  val "sha256" "$sha256"
  endgroup
  if [ "$conclusion" != "completed success" ]; then
    fail "Tarball" "The check run is not green" \
      "The run $found of \`$workflow\` that built \`$name\` is \`$conclusion\`, not \`completed success\`: $run_url. Nothing was drafted or uploaded." -- \
      "Open $run_url, fix what failed or wait until it finishes, and dispatch the submission again once a run of this commit is green." \
      "Pass \`check-run-id\` only for a green run of this commit."
  fi
  summary "- Check run: [$found]($run_url), $conclusion" "- Artifact: \`$name\`, id $artifact_id, sha256 \`$sha256\`" ""
  output run-id "$found" run-url "$run_url" artifact-id "$artifact_id" sha256 "$sha256"
}

cmd_commit() {
  [ $# -eq 1 ] || usage
  local sha=$1 repo=${GH_REPO:?} branches
  { valid_sha "$sha" && valid_repo "$repo"; } || usage
  # GitHub resolves a commit of any fork in the repository's network, so resolving it proves nothing;
  # a branch of this repository whose head it is does.
  branches=$(api "repos/$repo/commits/$sha/branches-where-head" --jq '.[].name') ||
    fail "Commit" "The commit's branches cannot be read" "Asking $repo which branches \`$sha\` heads failed: $(api_error)." -- \
      "Check that the job holds \`contents: read\` and that \`sha\` is a commit of $repo, then dispatch the submission again."
  branches=$(printf '%s\n' "$branches" | paste -s -d ' ' -)
  [ -n "$branches" ] ||
    fail "Commit" "The commit is no branch head" \
      "\`$sha\` is the head of no branch of $repo, so it may be a fork's commit or one a later push superseded. Nothing was drafted or uploaded." -- \
      "Dispatch the submission on the release branch, or on \`main\` on the fast path, and pass its head, \`\${{ github.sha }}\`."
  val "commit" "$sha"
  val "head of" "$branches"
  summary "- Commit: $(commit_link "$sha"), the head of \`$branches\` in $repo" ""
}

cmd_verify() {
  [ $# -eq 4 ] || usage
  local tarball=$1 expected=$2 pkg=$3 version=$4
  local work base actual
  work=$(mktemp -d)
  # shellcheck disable=SC2064  # expand now
  trap "rm -rf '$work' '$apierr'" EXIT
  base=$(basename "$tarball")
  group "Verify: $base"
  [ -f "$tarball" ] || fail "Verify" "No tarball downloaded" "The download left no \`$base\`." -- \
    "The check workflow uploads the tarball as a raw file with \`archive: false\`, named \`${pkg}_${version}.tar.gz\`."
  actual=$(sha256_of "$tarball")
  val "sha256" "$actual"
  val "digest" "$expected"
  [ "$actual" = "$expected" ] ||
    fail "Verify" "The tarball is not the checked one" \
      "The downloaded file's SHA-256 is \`$actual\`, and the artifact's digest is \`$expected\`. Nothing was drafted or uploaded." -- \
      "Dispatch the submission again; if this persists, dispatch the check workflow on the commit again."
  [ "$base" = "${pkg}_${version}.tar.gz" ] ||
    fail "Verify" "The tarball is misnamed" "The checked tarball is \`$base\`, and the release is \`${pkg}_${version}.tar.gz\`." -- \
      "The check workflow keeps the file under the name \`R CMD build\` gave it."
  if ! gzip -t "$tarball" 2>"$work/err" || ! tar -tzf "$tarball" >"$work/listing" 2>>"$work/err"; then
    fail "Verify" "The tarball cannot be read" "\`$base\` is no gzip-compressed tar archive." "$work/err" -- \
      "Check the artifact the check workflow uploaded."
  fi
  tar -xzOf "$tarball" "$pkg/DESCRIPTION" >"$work/DESCRIPTION" 2>"$work/err" ||
    fail "Verify" "The tarball has no DESCRIPTION" "\`$base\` holds no \`$pkg/DESCRIPTION\`." "$work/err" -- \
      "Check the artifact the check workflow uploaded."
  local tp tv
  tp=$(dcf_field Package "$work/DESCRIPTION")
  tv=$(dcf_field Version "$work/DESCRIPTION")
  { [ "$tp" = "$pkg" ] && [ "$tv" = "$version" ]; } ||
    fail "Verify" "The tarball is of another release" "\`$base\` holds $tp $tv, and the commit describes $pkg $version." -- \
      "Dispatch the check workflow on the commit to submit, and the submission after it."
  endgroup
  summary "- Verified: \`$base\` has the artifact's SHA-256 and holds $pkg $version." ""
  output tarball "$tarball" sha256 "$actual"
}

case "${1:-}" in
  commit) shift; cmd_commit "$@" ;;
  find) shift; cmd_find "$@" ;;
  verify) shift; cmd_verify "$@" ;;
  *) usage ;;
esac
