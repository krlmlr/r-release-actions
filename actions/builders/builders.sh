#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Upload a source tarball to win-builder and to macbuilder, and wait for macbuilder's result.
# These checks inform the release and never gate it: a check result is reported, never turned into a failure.
#
#   winbuilder [--dry-run] <tarball> <flavor>...
#     Upload the tarball by anonymous FTP to `<WINBUILDER_URL>/<flavor>/<file name>` for each flavor,
#     `R-devel`, `R-release` or `R-oldrelease`, as `devtools:::submit_winbuilder_ftp()` and `upload_ftp()` do
#     (devtools 2.5.2, R/check-win.R). Win-builder emails the results to the maintainer named in the tarball.
#     A flavor given twice is uploaded once. Every flavor is tried, each with two retries on a transient error;
#     any failed upload fails the stage after the others.
#     Writes `results`, `<flavor>=<uploaded|failed|dry-run>` separated by spaces, to GITHUB_OUTPUT after each flavor,
#     so that a job cancelled during a later upload still reports the earlier ones.
#   macbuilder [--dry-run] <tarball> <flavor>
#     Post the tarball to MACBUILDER_URL as `devtools:::check_mac()` does (devtools 2.5.2, R/check-mac.R),
#     which `check_mac_devel()` calls for `r-devel` and `check_mac_release()` for `r-release`:
#     multipart fields `pkgfile` (the file) and `rflavor` (`r-devel` or `r-release`), with `Accept: application/json`,
#     and read the result page's URL from the answer's `url`.
#     The URL must be `<the submission URL's origin>/macbuilder/results/<job>/`: the same scheme, host and port, no user info.
#     Writes `url` to GITHUB_OUTPUT.
#   macbuilder-poll <url>
#     Fetch the result page every MACBUILDER_POLL_SECONDS until it is finished,
#     or until MACBUILDER_TIMEOUT_SECONDS have passed. Macbuilder documents no states, and only finished pages were observed:
#     their check log, in a `<pre>` element, ends in `R CMD check`'s `Status: OK` or a count such as `Status: 1 NOTE`,
#     followed by `* result classification: ...` and then the element's end, `</pre>`.
#     A page is finished when it holds that sequence; the status is the last `Status:` line before the classification,
#     so that a `Status:` line in a test's output or a partly written log does not end the wait.
#     A page that answers 404, another error, or lacks the sequence counts as running. Carriage returns are dropped.
#     The outcome is the worst of ERROR, WARNING and NOTE the status names, `ok` for `OK`, and `unknown` for anything else.
#     Writes `outcome` (`ok`, `note`, `warning`, `error`, `unknown` or `timeout`) and `status`
#     (the `Status:` line without control characters and backticks, at most 200 characters) to GITHUB_OUTPUT.
#     A check that does not end in OK, and a timeout, warn; neither fails the stage.
#
# With --dry-run, nothing is sent: the stage checks the tarball as for a real run and reports what it would send.
#
# Environment:
#   WINBUILDER_URL             default ftp://win-builder.r-project.org (`devtools:::submit_winbuilder_ftp()`)
#   MACBUILDER_URL             default https://mac.r-project.org/macbuilder/v1/submit (`devtools:::check_mac()`)
#   MACBUILDER_POLL_SECONDS    default 60
#   MACBUILDER_TIMEOUT_SECONDS default 3600
#                              builders-test.sh points the URLs at local servers and shortens the times
#   GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, GITHUB_ACTIONS
#
# Exit status: 0 on success, 1 on a failed stage, 2 on a usage error.

set -euo pipefail

# shellcheck source=../cran-lib/cran-lib.sh
. "$(dirname "$0")/../cran-lib/cran-lib.sh"

usage() {
  sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Sets pkg, version, maint, base and sha from a tarball named `<package>_<version>.tar.gz`
# whose DESCRIPTION holds that package and version, or fails.
read_tarball() { # <tarball> <stage>
  local tarball=$1 stage=$2
  [ -f "$tarball" ] || fail "$stage" "No tarball" "There is no file \`$tarball\`." -- \
    "Pass the tarball that the checked-tarball action downloaded and verified."
  base=$(basename "$tarball")
  if ! [[ $base =~ ^([A-Za-z][A-Za-z0-9.]*[A-Za-z0-9])_([0-9]+[.-][0-9]+([.-][0-9]+)*)\.tar\.gz$ ]]; then
    fail "$stage" "The tarball is misnamed" "\`$base\` is not named \`<package>_<version>.tar.gz\`." -- \
      "Upload the tarball the check workflow built, under the name \`R CMD build\` gave it."
  fi
  pkg=${BASH_REMATCH[1]}
  version=${BASH_REMATCH[2]}
  if ! tar -xzOf "$tarball" "$pkg/DESCRIPTION" >"$work/DESCRIPTION" 2>"$work/tar.err"; then
    fail "$stage" "The tarball cannot be read" "\`$base\` is no gzip-compressed tar archive holding \`$pkg/DESCRIPTION\`." "$work/tar.err" -- \
      "Upload the tarball the check workflow built and kept as an artifact, which the checked-tarball action verifies."
  fi
  local tp tv
  tp=$(dcf_field Package "$work/DESCRIPTION")
  tv=$(dcf_field Version "$work/DESCRIPTION")
  { [ "$tp" = "$pkg" ] && [ "$tv" = "$version" ]; } ||
    fail "$stage" "The tarball is of another release" "\`$base\` holds $tp $tv." -- \
      "Upload the tarball the check workflow built, under the name \`R CMD build\` gave it."
  maint=$(dcf_field Maintainer "$work/DESCRIPTION")
  sha=$(sha256_of "$tarball")
}

# --- win-builder ----------------------------------------------------------

cmd_winbuilder() {
  local dry_run='' tarball='' flavors=() f
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1 ;;
      -*) usage ;;
      *) if [ -z "$tarball" ]; then tarball=$1; else flavors+=("$1"); fi ;;
    esac
    shift
  done
  [ -n "$tarball" ] || usage
  [ ${#flavors[@]} -gt 0 ] ||
    fail "Win-builder" "No win-builder flavor" "No flavor was given, so there is nothing to upload." -- \
      "Pass at least one of \`R-devel\`, \`R-release\` and \`R-oldrelease\`, separated by spaces, in \`winbuilder-flavors\`."
  local unique=() u seen
  for f in "${flavors[@]}"; do
    seen=''
    for u in "${unique[@]+"${unique[@]}"}"; do [ "$u" != "$f" ] || seen=1; done
    [ -n "$seen" ] || unique+=("$f")
  done
  flavors=("${unique[@]}")
  for f in "${flavors[@]}"; do
    case "$f" in
      R-devel | R-release | R-oldrelease) ;;
      *) fail "Win-builder" "No win-builder flavor" "\`$f\` is none of \`R-devel\`, \`R-release\` and \`R-oldrelease\`." -- \
        "Pass win-builder's flavors as its upload directories name them." ;;
    esac
  done
  local base_url=${WINBUILDER_URL:-ftp://win-builder.r-project.org}
  read_tarball "$tarball" "Win-builder"
  group "Win-builder: $base"
  val "tarball" "$base"
  val "sha256" "$sha"
  val "maintainer" "$maint"
  val "flavors" "${flavors[*]}"
  endgroup
  summary "### Win-builder${dry_run:+: dry run}" "" "- Tarball: \`$base\`, sha256 \`$sha\`"

  local results='' failed='' url rc
  for f in "${flavors[@]}"; do
    url="$base_url/$f/$base"
    if [ -n "$dry_run" ]; then
      say "Dry run: would upload $base to $url"
      summary "- $f: would upload to $url"
      results+="$f=dry-run "
      output results "${results% }"
      continue
    fi
    group "Win-builder: upload to $f"
    val "url" "$url"
    rc=0
    # Anonymous FTP upload, as devtools' upload_ftp() does with curl's `upload = TRUE`;
    # at most three attempts of five minutes each, which the workflow's job timeout covers for three flavors.
    curl --silent --show-error --connect-timeout 30 --max-time 300 --retry 2 --retry-connrefused \
      --upload-file "$tarball" "$url" \
      >"$work/ftp.out" 2>"$work/ftp.err" || rc=$?
    endgroup
    if [ "$rc" -eq 0 ]; then
      say "Uploaded $base to $url"
      summary "- $f: uploaded to $url"
      results+="$f=uploaded "
    else
      failure "Win-builder" "The upload to win-builder failed" \
        "curl exited with status $rc uploading \`$base\` to $url: $(head -n 1 "$work/ftp.err")" "$work/ftp.err" -- \
        "Check win-builder's status at https://win-builder.r-project.org/, then dispatch this workflow again." \
        "Win-builder checks inform the release and do not gate it; the CRAN submission does not wait for them."
      results+="$f=failed "
      failed=1
    fi
    output results "${results% }"
  done
  if [ -n "$dry_run" ]; then
    summary "" "Nothing was sent. A real run uploads the file by anonymous FTP; win-builder emails the results to $maint." ""
    notice "Dry run" "Nothing was sent to win-builder. A real run uploads $base for ${flavors[*]}."
    return 0
  fi
  summary "" "Win-builder emails the results to $maint, usually within 30 minutes." ""
  [ -z "$failed" ] || exit 1
  notice "Uploaded to win-builder" "$base for ${flavors[*]}; the results arrive by email to the maintainer."
}

# --- macbuilder -----------------------------------------------------------

cmd_macbuilder() {
  local dry_run='' tarball='' flavor='' given=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1 ;;
      -*) usage ;;
      *)
        if [ -z "$tarball" ]; then tarball=$1; elif [ -z "$given" ]; then flavor=$1 given=1; else usage; fi
        ;;
    esac
    shift
  done
  [ -n "$tarball" ] || usage
  [ -n "$flavor" ] ||
    fail "Macbuilder" "No macbuilder flavor" "No flavor was given." -- \
      "Pass \`r-devel\` or \`r-release\` in \`macbuilder-flavor\`."
  case "$flavor" in
    r-devel | r-release) ;;
    *) fail "Macbuilder" "No macbuilder flavor" "\`$flavor\` is neither \`r-devel\` nor \`r-release\`." -- \
      "Pass the flavor as macbuilder's form names it, \`r-devel\` or \`r-release\`." ;;
  esac
  local url=${MACBUILDER_URL:-https://mac.r-project.org/macbuilder/v1/submit}
  read_tarball "$tarball" "Macbuilder"
  group "Macbuilder: $base"
  val "tarball" "$base"
  val "sha256" "$sha"
  val "rflavor" "$flavor"
  val "submission URL" "$url"
  endgroup
  summary "### Macbuilder${dry_run:+: dry run}" "" "- Tarball: \`$base\`, sha256 \`$sha\`" "- Flavor: \`$flavor\`"
  if [ -n "$dry_run" ]; then
    say "Dry run: would POST to $url, as multipart/form-data with Accept: application/json:" \
      "  pkgfile: $base" "  rflavor: $flavor" \
      "then read the result page's URL from the answer's url, and poll it."
    summary "" "Nothing was sent. A real run posts this to $url, with \`Accept: application/json\`:" "" \
      "- \`pkgfile\`: \`$base\`" "- \`rflavor\`: \`$flavor\`" "" \
      "It reads the result page's URL from the answer's \`url\`, and polls that page until the check ends." ""
    notice "Dry run" "Nothing was sent to macbuilder. A real run uploads $base for $flavor."
    return 0
  fi

  local wo rc=0 code
  # From the tarball's directory, so that curl sends its base name as the file name.
  wo=$(cd "$(dirname "$tarball")" && curl --silent --show-error --connect-timeout 30 --max-time 900 \
    --header 'Accept: application/json' --form "pkgfile=@$base" --form-string "rflavor=$flavor" \
    --output "$work/submit.json" --write-out '%{http_code}' "$url" 2>"$work/submit.err") || rc=$?
  code=${wo:-000}
  if [ "$rc" -ne 0 ]; then
    fail "Macbuilder" "Macbuilder could not be reached" \
      "curl exited with status $rc posting to $url: $(head -n 1 "$work/submit.err")" "$work/submit.err" -- \
      "Check the network and macbuilder's status at https://mac.r-project.org/macbuilder/submit.html, then dispatch this workflow again."
  fi
  case "$code" in
    2??) ;;
    *)
      sed -e 's/<[^>]*>//g' "$work/submit.json" | awk 'NF && n < 20 { print; n++ }' | cut -c 1-300 >"$work/submit.msg"
      fail "Macbuilder" "Macbuilder refused the upload" "The submission answered HTTP $code at $url." "$work/submit.msg" -- \
        "HTTP 502 is what macbuilder answers while its service is down: check https://mac.r-project.org/macbuilder/submit.html and dispatch this workflow again later." \
        "Otherwise compare the fields sent, \`pkgfile\` and \`rflavor\`, with \`devtools:::check_mac()\` and the form at https://mac.r-project.org/macbuilder/submit.html."
      ;;
  esac
  local result origin
  result=$(jq -r '.url // empty' "$work/submit.json" 2>/dev/null) || result=''
  origin=$(sed -E 's#^([a-z]+://[^/]+)/.*$#\1#' <<<"$url")
  if ! [[ $result =~ ^[a-z]+://[^/@]+/macbuilder/results/[A-Za-z0-9_-]+/$ ]] || [ "${result#"$origin"/}" = "$result" ]; then
    head -c 2000 "$work/submit.json" >"$work/submit.msg"
    fail "Macbuilder" "No result URL from macbuilder" \
      "The submission answered HTTP $code, without a \`url\` of the form $origin/macbuilder/results/<job>/ in its JSON." "$work/submit.msg" -- \
      "Read the answer, under Details here and in the log." \
      "Macbuilder's API may have changed: compare with \`devtools:::check_mac()\`, which reads \`url\` from the JSON answer."
  fi
  val "result page" "$result"
  summary "- Result page: $result" ""
  output url "$result"
  notice "Uploaded to macbuilder" "$base for $flavor: $result"
}

# A finished result page's status and classification, separated by a tab; nothing for a page still running.
# The check log ends in `Status: ...`, `* result classification: ...` and `</pre>`, in that order.
page_result() { # <page>
  awk '
    /^Status: / { st = substr($0, 9); seen = 1; cls = ""; next }
    seen && /^\* result classification: / { cls = substr($0, 26); next }
    /<\/pre>/ && cls != "" { print st "\t" cls; exit }
    /<\/pre>/ { seen = 0 }' "$1"
}

cmd_macbuilder_poll() {
  [ $# -eq 1 ] || usage
  local url=$1 interval=${MACBUILDER_POLL_SECONDS:-60} timeout=${MACBUILDER_TIMEOUT_SECONDS:-3600}
  [[ $url =~ ^[a-z]+://[^/@]+/macbuilder/results/[A-Za-z0-9_-]+/$ ]] || usage
  { [[ $interval =~ ^[0-9]+$ ]] && [[ $timeout =~ ^[0-9]+$ ]]; } || usage
  local start=$SECONDS polls=0 code rc status='' outcome classification='' finished
  group "Macbuilder: wait for $url"
  while :; do
    polls=$((polls + 1))
    rc=0
    code=$(curl --silent --show-error --connect-timeout 30 --max-time 120 --output "$work/page.html" \
      --write-out '%{http_code}' "$url" 2>"$work/poll.err") || rc=$?
    if [ "$rc" -ne 0 ]; then
      say "  poll $polls: curl exited with status $rc: $(head -n 1 "$work/poll.err")"
    elif [ "$code" = 200 ]; then
      tr -d '\r' <"$work/page.html" >"$work/page.txt"
      finished=$(page_result "$work/page.txt")
      if [ -n "$finished" ]; then
        status=${finished%%$'\t'*}
        classification=${finished#*$'\t'}
        break
      fi
      say "  poll $polls: the page shows no finished check yet"
    elif [ "$code" = 404 ]; then
      say "  poll $polls: no result page yet (HTTP 404)"
    else
      say "  poll $polls: HTTP $code"
    fi
    if [ $((SECONDS - start + interval)) -gt "$timeout" ]; then
      endgroup
      warn "Macbuilder result pending" \
        "No check result at $url after $((SECONDS - start)) seconds; the page has it once the check ends. This does not gate the release."
      summary "### Macbuilder result" "" "- No check result after $((SECONDS - start)) seconds; it appears at $url once the check ends." ""
      output outcome timeout status ""
      return 0
    fi
    sleep "$interval"
  done
  endgroup
  case "$status" in
    *ERROR*) outcome=error ;;
    *WARNING*) outcome=warning ;;
    *NOTE*) outcome=note ;;
    OK) outcome=ok ;;
    *) outcome=unknown ;;
  esac
  status=$(printf '%s' "$status" | tr -d '\000-\037\177`' | cut -c 1-200)
  val "status" "$status"
  [ -z "$classification" ] || val "classification" "$classification"
  summary "### Macbuilder result" "" "- Status: \`$status\` after $polls polls" "- Result page: $url" ""
  output outcome "$outcome" status "$status"
  case "$outcome" in
    ok) notice "Macbuilder status OK" "$url" ;;
    unknown) warn "Macbuilder result not understood" \
      "The check on macbuilder ended in \`$status\`, which is no status of \`R CMD check\`: read the check log at $url. This does not gate the release." ;;
    *) warn "Macbuilder status $status" "The check on macbuilder ended in \`$status\`: $url. This does not gate the release; read the check log there." ;;
  esac
}

case "${1:-}" in
  winbuilder) shift; cmd_winbuilder "$@" ;;
  macbuilder) shift; cmd_macbuilder "$@" ;;
  macbuilder-poll) shift; cmd_macbuilder_poll "$@" ;;
  *) usage ;;
esac
