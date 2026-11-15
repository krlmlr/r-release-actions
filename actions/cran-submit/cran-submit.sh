#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Adapted from duckdb/duckdb-r's scripts/cran-submit.sh at ca768a9 (MIT): the upload stage only,
# because the submission uploads the tarball the check workflow built and builds none of its own.
# Copyright (c) 2018 Stichting DuckDB Foundation; used under the MIT License, whose terms are in LICENSE.
# Upload a source tarball to CRAN the way `devtools:::upload_cran()` does.
#
#   upload [--dry-run] <tarball>
#     Post the tarball to CRAN's submission form, then confirm it, as
#     `devtools:::upload_cran()` does (devtools 2.4.5 for the 404 path, 2.5.2 otherwise):
#     the upload sends `pkg_id` (empty), `name`, `email`, `uploaded_file`,
#     `comment` and `upload`, follows the redirects, and reads `pkg_id` from the final URL;
#     the confirmation sends `pkg_id`, `name`, `email`, `policy_check` and `submit`,
#     and succeeds when the final URL carries `submit=1`.
#     CRAN then mails a confirmation link to the maintainer, and the submission counts once it is clicked.
#     The comment is the single line `<package> <version>`;
#     the maintainer's name and email come from the `Maintainer:` field
#     that `R CMD build` writes from the `cre` person in `Authors@R`.
#     A 404 means CRAN is closed for maintenance: the message on its index page is shown.
#     With --dry-run, nothing is sent: the stage checks the tarball as for a real run,
#     then prints and reports every field the two POSTs would carry.
#
# The stage prints what it does and the values it uses, folded into groups
# and annotated with `::error::` or `::notice::` when GITHUB_ACTIONS is true.
# With GITHUB_STEP_SUMMARY set, it also writes a Markdown report there,
# and every failure writes how to resolve it; the same advice goes to stderr either way.
# Exit status: 0 on success, 1 on a failed stage, 2 on a usage error.
#
# Usage:
#   actions/cran-submit/cran-submit.sh upload "$RUNNER_TEMP/tarball/fakepkg_1.0.1.tar.gz"
#   actions/cran-submit/cran-submit.sh upload --dry-run "$RUNNER_TEMP/tarball/fakepkg_1.0.1.tar.gz"
#
# Environment:
#   CRAN_SUBMISSION_URL  the form to post to, default https://xmpalantir.wu.ac.at/cransubmit/index2.php
#                        (`devtools:::cran_submission_url`); cran-submit-test.sh points it at a local server
#   SUBMIT_SHA           the commit the tarball was built from, named and linked in the report
#   GITHUB_ACTIONS       `true` turns on the workflow commands (groups, annotations)
#   GITHUB_STEP_SUMMARY  the file the Markdown report is appended to; unset, no report is written
#   GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_REF_NAME
#                        link the commit in the report

set -euo pipefail

default_submission_url=https://xmpalantir.wu.ac.at/cransubmit/index2.php
cran_submit_page=https://cran.r-project.org/submit.html

# shellcheck source=../cran-lib/cran-lib.sh
. "$(dirname "$0")/../cran-lib/cran-lib.sh"

# What a page from CRAN says, in a few lines of text: devtools' extract_cran_msg(),
# which drops the page titles, the tags and the tabs, plus a cap on the length.
page_text() { # <html file>
  [ -s "$1" ] || return 0
  sed -e 's/CRAN package Submission//g; s/Submit package to CRAN//g' \
    -e 's/<[^>]*>//g' -e 's/\t//g' -e 's/[[:space:]]*$//' \
    -e 's/&nbsp;/ /g; s/&#39;/'"'"'/g; s/&quot;/"/g; s/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g' "$1" |
    awk 'NF && n < 40 { print; n++ }' | cut -c 1-300
}

# --- reading a tarball ----------------------------------------------------

size_of() { wc -c <"$1" | tr -d ' '; }
mib() { awk -v b="$1" 'BEGIN { printf "%.2f MiB", b / 1048576 }'; }
# Sets pkg, version, maint_name, maint_email from the DESCRIPTION inside a tarball.
read_description() { # <tarball> <scratch dir>
  local listing=$2/listing top
  tar -tzf "$1" >"$listing"
  top=$(head -n 1 "$listing")
  top=${top%%/*}
  tar -xzOf "$1" "$top/DESCRIPTION" >"$2/DESCRIPTION"
  pkg=$(dcf_field Package "$2/DESCRIPTION")
  version=$(dcf_field Version "$2/DESCRIPTION")
  local maintainer
  maintainer=$(dcf_field Maintainer "$2/DESCRIPTION")
  maint_name=$(printf '%s' "$maintainer" | sed -e 's/[[:space:]]*<.*$//')
  maint_email=$(printf '%s' "$maintainer" | sed -n -e 's/^.*<\([^>]*\)>.*$/\1/p')
}

# --- upload ---------------------------------------------------------------

# One value of a URL's query, percent-decoded as httr::parse_url() does.
query_param() { # <url> <name>
  local q=${1#*\?} kv parts=()
  [ "$q" != "$1" ] || return 0
  q=${q%%#*}
  IFS='&' read -r -a parts <<<"$q"
  for kv in "${parts[@]}"; do
    if [ "${kv%%=*}" = "$2" ]; then
      kv=${kv#*=}
      printf '%b' "${kv//%/\\x}"
      return 0
    fi
  done
}

# POST a multipart form to the submission URL, following redirects as httr does.
# Sets http_code and final_url; returns curl's exit status.
post() { # <response file> <curl form arguments>...
  local response=$1 wo rc=0
  shift
  wo=$(curl --silent --show-error --location --connect-timeout 30 --max-time 900 \
    --output "$response" --write-out '%{http_code} %{url_effective}' "$@" "$url" 2>"$response.err") || rc=$?
  http_code=${wo%% *}
  final_url=${wo#* }
  [ -n "$http_code" ] || http_code=000
  return "$rc"
}

# Fail on what every POST can return: no answer, a 404, any other non-2xx.
check_response() { # <stage> <response file> <curl status>
  local stage=$1 response=$2 rc=$3
  if [ "$rc" -ne 0 ]; then
    cat "$response.err" >&2
    fail "$stage" "CRAN could not be reached" \
      "curl exited with status $rc posting to $url: $(head -n 1 "$response.err")" "$response.err" -- \
      "Check the network and CRAN's status, then rerun this workflow." \
      "If the connection broke after the upload, CRAN may have the package anyway: if the maintainer got CRAN's confirmation email, follow it instead of resubmitting."
  fi
  if [ "$http_code" = 404 ]; then
    local index=${url/index2/index}
    say "HTTP 404: CRAN is likely closed for maintenance; reading $index"
    curl --silent --show-error --location --connect-timeout 30 --max-time 60 --output "$response.index" "$index" ||
      echo "(could not read $index)" >"$response.index"
    page_text "$response.index" >"$response.msg"
    cat "$response.msg"
    fail "$stage" "CRAN submissions are closed" \
      "The submission form answered HTTP 404, which is what it does while CRAN is closed for maintenance. CRAN's message: $(tr '\n' ' ' <"$response.msg")" "$response.msg" -- \
      "Wait until CRAN reopens; its message, under Details here and in the log, usually says when." \
      "Then rerun this workflow; nothing was submitted."
  fi
  case "$http_code" in
    2??) ;;
    *)
      page_text "$response" >"$response.msg"
      cat "$response.msg"
      fail "$stage" "CRAN rejected the request" "The submission form answered HTTP $http_code at $final_url." "$response.msg" -- \
        "Read CRAN's response, under Details here and in the log." \
        "Check the tarball: its name must be \`<package>_<version>.tar.gz\`, and its size within CRAN's limit." \
        "Check the maintainer fields, \`$maint_name\` and \`$maint_email\`, taken from the \`cre\` person in \`Authors@R\`." \
        "If all of that is right, compare the fields this script sends with \`devtools:::upload_cran()\` (\`Rscript -e 'print(devtools:::upload_cran)'\`) and the form at $cran_submit_page."
      ;;
  esac
}

cmd_upload() {
  local dry_run='' tarball=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1 ;;
      -*) usage ;;
      *)
        [ -z "$tarball" ] || usage
        tarball=$1
        ;;
    esac
    shift
  done
  [ -n "$tarball" ] || usage
  [ -f "$tarball" ] || {
    echo "No such tarball: $tarball" >&2
    exit 2
  }
  url=${CRAN_SUBMISSION_URL:-$default_submission_url}
  local work dir base
  work=$(mktemp -d)
  # shellcheck disable=SC2064  # expand now: the trap outlives this function's locals
  trap "rm -rf '$work'" EXIT
  dir=$(cd "$(dirname "$tarball")" && pwd)
  base=$(basename "$tarball")

  # The tarball names no commit; the workflow passes the one whose check built it.
  local commit_sha=${SUBMIT_SHA:-} commit_md=''
  [ -z "$commit_sha" ] || commit_md="Commit $(commit_link "$commit_sha")."

  group "Upload: what is submitted"
  if ! gzip -t "$tarball" 2>"$work/gzip.err" || ! tar -tzf "$tarball" >/dev/null 2>>"$work/gzip.err"; then
    fail "Upload" "The tarball cannot be read" "\`$base\` is no gzip-compressed tar archive." "$work/gzip.err" -- \
      "Upload the tarball the check workflow built and kept as an artifact, which the submission downloads and verifies."
  fi
  read_description "$tarball" "$work"
  local comment="$pkg $version" size sha
  size=$(size_of "$tarball")
  sha=$(sha256_of "$tarball")
  val "package" "$pkg"
  val "version" "$version"
  val "maintainer name" "$maint_name"
  val "maintainer email" "$maint_email"
  val "tarball" "$base"
  val "size" "$size bytes ($(mib "$size"))"
  val "sha256" "$sha"
  val "comment" "$comment"
  val "submission URL" "$url"
  [ -z "$commit_sha" ] || val "commit" "$commit_sha${GITHUB_REF_NAME:+ ($GITHUB_REF_NAME)}"
  endgroup
  summary "" "### Upload to CRAN${dry_run:+: dry run}" ""
  [ -z "$commit_md" ] || summary "- $commit_md"
  summary "- Tarball: \`$base\`, $size bytes, sha256 \`$sha\`" \
    "- Maintainer: $maint_name <$maint_email>" \
    "- Comment: \`$comment\`" \
    "- Submission form: $url"

  if [ "$base" != "${pkg}_${version}.tar.gz" ]; then
    fail "Upload" "The tarball is misnamed" \
      "CRAN expects \`${pkg}_${version}.tar.gz\` for the package inside, and the file is \`$base\`." -- \
      "Upload the tarball the check workflow built, under the name \`R CMD build\` gave it."
  fi
  if [ -z "$pkg" ] || [ -z "$version" ] || [ -z "$maint_name" ] || [ -z "$maint_email" ]; then
    fail "Upload" "DESCRIPTION is incomplete" \
      "The tarball's DESCRIPTION gives package \`$pkg\`, version \`$version\`, maintainer \`$maint_name\` <\`$maint_email\`>, and all four are needed." -- \
      "Check \`Authors@R\` in DESCRIPTION: exactly one person needs the role \`cre\` and an email address; \`R CMD build\` writes the \`Maintainer:\` field from it."
  fi

  if [ -n "$dry_run" ]; then
    dry_run_report
    return 0
  fi

  group "Upload: POST the package"
  # From the tarball's directory, so that curl sends its base name as the file name
  # and the path cannot reach curl's parsing of `@file;type=`.
  local rc
  (
    cd "$dir"
    rc=0
    post "$work/upload.html" \
      --form-string pkg_id= \
      --form-string "name=$maint_name" \
      --form-string "email=$maint_email" \
      --form "uploaded_file=@$base;type=application/x-gzip" \
      --form-string "comment=$comment" \
      --form-string "upload=Upload package" || rc=$?
    printf '%s\n' "$rc" "$http_code" "$final_url" >"$work/upload.result"
  )
  { read -r rc; read -r http_code; read -r final_url; } <"$work/upload.result"
  val "HTTP status" "$http_code"
  val "final URL" "$final_url"
  check_response "Upload" "$work/upload.html" "$rc"
  local pkg_id
  pkg_id=$(query_param "$final_url" pkg_id)
  val "pkg_id" "${pkg_id:-(none)}"
  page_text "$work/upload.html" >"$work/upload.msg"
  if [ -z "$pkg_id" ]; then
    cat "$work/upload.msg"
    fail "Upload" "No pkg_id from CRAN" \
      "The upload answered HTTP $http_code at $final_url, which carries no \`pkg_id\`; CRAN did not accept the upload." "$work/upload.msg" -- \
      "Read CRAN's page, under Details here and in the log: when CRAN refuses the package, the maintainer or the tarball, it says why there." \
      "Otherwise CRAN's form may have changed: compare the fields this script sends with \`devtools:::upload_cran()\` (\`Rscript -e 'print(devtools:::upload_cran)'\`) and with the form at $cran_submit_page." \
      "Nothing reached the confirmation step, so CRAN has sent no email; rerun this workflow once the cause is fixed."
  fi
  endgroup
  summary "- Upload: HTTP $http_code, final URL $final_url, \`pkg_id\` \`$pkg_id\`"

  group "Confirm: POST the submission"
  val "pkg_id" "$pkg_id"
  rc=0
  post "$work/submit.html" \
    --form-string "pkg_id=$pkg_id" \
    --form-string "name=$maint_name" \
    --form-string "email=$maint_email" \
    --form-string "policy_check=1/" \
    --form-string "submit=Submit package" || rc=$?
  val "HTTP status" "$http_code"
  val "final URL" "$final_url"
  check_response "Confirm" "$work/submit.html" "$rc"
  if [ "$(query_param "$final_url" submit)" != 1 ]; then
    page_text "$work/submit.html" >"$work/submit.msg"
    cat "$work/submit.msg"
    fail "Confirm" "CRAN did not confirm the submission" \
      "The package was uploaded as \`pkg_id\` $pkg_id, but the confirmation answered HTTP $http_code at $final_url, without \`submit=1\`; CRAN has not emailed the maintainer." "$work/submit.msg" -- \
      "Read CRAN's page, under Details here and in the log, for the reason." \
      "Rerun this workflow, which uploads the package again; or submit the tarball kept as this run's artifact by hand at $cran_submit_page, with the comment \`$comment\`." \
      "If this keeps happening, CRAN's form may have changed: compare with \`devtools:::upload_cran()\`."
  fi
  endgroup
  summary "- Confirmation: HTTP $http_code, final URL $final_url" "" \
    "**Next step:** CRAN emailed $maint_email; click the confirmation link in that email to finish the submission." ""
  notice "Submitted to CRAN" "$pkg $version (pkg_id $pkg_id). CRAN emailed $maint_email; click the confirmation link in that email to finish the submission."
}

# What a real run would post, printed and reported; sends nothing.
dry_run_report() {
  group "Dry run: what a real run would post to $url"
  say "POST 1, the upload, multipart:"
  val "pkg_id" "(empty)"
  val "name" "$maint_name"
  val "email" "$maint_email"
  val "uploaded_file" "$base (application/x-gzip, $size bytes, sha256 $sha)"
  val "comment" "$comment"
  val "upload" "Upload package"
  say "  then: follow the redirects and read pkg_id from the final URL" \
    "POST 2, the confirmation, multipart:"
  val "pkg_id" "(the pkg_id from POST 1)"
  val "name" "$maint_name"
  val "email" "$maint_email"
  val "policy_check" "1/"
  val "submit" "Submit package"
  say "  then: succeed when the final URL carries submit=1" \
    "Nothing was sent."
  endgroup
  summary "" "Nothing was sent to CRAN. A real run posts this to $url:" "" \
    "1. The upload, as \`multipart/form-data\`:" \
    "   - \`pkg_id\`: empty" \
    "   - \`name\`: \`$maint_name\`" \
    "   - \`email\`: \`$maint_email\`" \
    "   - \`uploaded_file\`: \`$base\`, \`application/x-gzip\`, $size bytes, sha256 \`$sha\`" \
    "   - \`comment\`: \`$comment\`" \
    "   - \`upload\`: \`Upload package\`" \
    "" \
    "   It follows the redirects and reads \`pkg_id\` from the final URL." \
    "2. The confirmation, as \`multipart/form-data\`:" \
    "   - \`pkg_id\`: the one from the upload" \
    "   - \`name\`: \`$maint_name\`" \
    "   - \`email\`: \`$maint_email\`" \
    "   - \`policy_check\`: \`1/\`" \
    "   - \`submit\`: \`Submit package\`" \
    "" \
    "   It succeeds when the final URL carries \`submit=1\`." \
    "" \
    "**Next step:** to submit, dispatch the submission again on the same commit with \`dry-run\` off. CRAN then emails $maint_email, and the submission counts once the link in that email is clicked." ""
  notice "Dry run" "Nothing was sent to CRAN. A real run uploads $base ($size bytes, sha256 $sha) for $pkg $version, maintainer $maint_name <$maint_email>, with the comment \"$comment\"."
}

usage() {
  sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

case "${1:-}" in
  upload)
    shift
    cmd_upload "$@"
    ;;
  -h | --help) usage ;;
  *) usage ;;
esac
