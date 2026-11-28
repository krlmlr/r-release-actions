#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Upload a source tarball to win-builder and to macbuilder, and wait for macbuilder's result.
# These checks inform the release and never gate it: a check result is reported, never turned into a failure.
#
#   winbuilder [--dry-run] --commit <sha> <tarball> <flavor>...
#     Upload the tarball by anonymous FTP to `<WINBUILDER_URL>/<flavor>/<file name>`, where the flavor is `R-devel`,
#     the only one used, as `devtools:::submit_winbuilder_ftp()` and `upload_ftp()` do for `check_win_devel()`
#     (devtools 2.5.2, R/check-win.R). Win-builder emails the results to the maintainer named in the tarball.
#     Its email names only the package and the version, so the file uploaded is the tarball repacked
#     with the commit's first 40 bits appended to `Version:` in DESCRIPTION and to the file name,
#     as four components of 10 bits each: commit c4a875c47d... turns 1.0.1 into 1.0.1.786.647.369.125.
#     No component reaches 1234 or has a leading zero, so `R CMD check --as-cran` adds no NOTE for the version;
#     the README shows how to turn the four components back into the commit.
#     Any flavor but a single `R-devel` fails before sending. A failed connection is retried twice; a failed upload fails the stage.
#     Writes `results`, `<flavor>=<uploaded|failed|dry-run>`, and `tarball`, the uploaded file's name, to GITHUB_OUTPUT.
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
#   WINBUILDER_MAX_TIME        seconds an upload attempt may take, default 300
#   WINBUILDER_RETRY_SECONDS   the pause before retrying a failed connection, default 10
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

# The commit's first 40 bits as four version components of 10 bits each, 0 to 1023, separated by dots.
commit_components() { # <sha>
  local n=$((16#${1:0:10}))
  printf '%d.%d.%d.%d' $(((n >> 30) & 1023)) $(((n >> 20) & 1023)) $(((n >> 10) & 1023)) $((n & 1023))
}

# Sets upload to the tarball <tarball> repacked as `<package>_<version>.tar.gz` with `Version: <version>` in DESCRIPTION,
# its only change; read_tarball has set pkg and base.
repack() { # <tarball> <version> <stage>
  local tarball=$1 version=$2 stage=$3 dir=$work/repack
  mkdir -p "$dir/src" "$dir/out"
  # `R CMD build` puts everything under `<package>/`; anything else would be lost in the repack.
  if ! tar -tzf "$tarball" >"$work/members" 2>"$work/tar.err" || grep -qv "^$pkg/" "$work/members"; then
    grep -v "^$pkg/" "$work/members" | head -n 20 >>"$work/tar.err" || true
    fail "$stage" "The tarball cannot be repacked" "\`$base\` cannot be listed, or holds files outside \`$pkg/\`." "$work/tar.err" -- \
      "Upload the tarball the check workflow built and kept as an artifact, which the checked-tarball action verifies."
  fi
  if ! tar -xzf "$tarball" -C "$dir/src" 2>"$work/tar.err"; then
    fail "$stage" "The tarball cannot be repacked" "\`$base\` cannot be extracted." "$work/tar.err" -- \
      "Upload the tarball the check workflow built and kept as an artifact, which the checked-tarball action verifies."
  fi
  # Only the first `Version:` line changes, and keeps a carriage return it ends in.
  { awk -v v="$version" '!done && /^Version:/ { print "Version: " v ($0 ~ /\r$/ ? "\r" : ""); done = 1; next } { print }' \
    "$dir/src/$pkg/DESCRIPTION" >"$dir/DESCRIPTION" &&
    touch -r "$dir/src/$pkg/DESCRIPTION" "$dir/DESCRIPTION" &&
    cat "$dir/DESCRIPTION" >"$dir/src/$pkg/DESCRIPTION" &&
    touch -r "$dir/DESCRIPTION" "$dir/src/$pkg/DESCRIPTION"; } 2>"$work/tar.err" ||
    fail "$stage" "The tarball cannot be repacked" "\`$base\`'s DESCRIPTION cannot be rewritten." "$work/tar.err" -- \
      "Compare the tarball's file modes with what \`R CMD build\` writes."
  [ "$(dcf_field Version "$dir/src/$pkg/DESCRIPTION")" = "$version" ] ||
    fail "$stage" "The tarball cannot be repacked" "\`Version:\` in \`$base\`'s DESCRIPTION could not be set to $version." -- \
      "Compare DESCRIPTION with what \`R CMD build\` writes."
  upload=$dir/out/${pkg}_$version.tar.gz
  tar -czf "$upload" -C "$dir/src" "$pkg" 2>"$work/tar.err" ||
    fail "$stage" "The tarball cannot be repacked" "\`${pkg}_$version.tar.gz\` cannot be written." "$work/tar.err" -- \
      "Check the runner's disk space, then dispatch this workflow again."
}

cmd_winbuilder() {
  local dry_run='' commit='' tarball='' flavors=() flavor
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1 ;;
      --commit) [ $# -ge 2 ] || usage; commit=$2; shift ;;
      -*) usage ;;
      *) if [ -z "$tarball" ]; then tarball=$1; else flavors+=("$1"); fi ;;
    esac
    shift
  done
  [ -n "$tarball" ] || usage
  [ ${#flavors[@]} -gt 0 ] ||
    fail "Win-builder" "No win-builder flavor" "No flavor was given." -- \
      "Pass \`R-devel\` in the action's \`flavors\` input."
  { [ ${#flavors[@]} -eq 1 ] && [ "${flavors[0]}" = R-devel ]; } ||
    fail "Win-builder" "No win-builder flavor" "\`${flavors[*]}\` is not \`R-devel\`, the only flavor win-builder checks on here." -- \
      "Pass \`R-devel\` alone, as win-builder's upload directory names it."
  flavor=R-devel
  valid_sha "$commit" ||
    fail "Win-builder" "No commit SHA" "The commit given is no full 40-character commit SHA." -- \
      "Pass the commit the tarball was built from in the action's \`commit\` input."
  local base_url=${WINBUILDER_URL:-ftp://win-builder.r-project.org} upload uploaded checked
  read_tarball "$tarball" "Win-builder"
  checked=$sha
  repack "$tarball" "$version.$(commit_components "$commit")" "Win-builder"
  uploaded=$(basename "$upload")
  sha=$(sha256_of "$upload")
  group "Win-builder: $uploaded"
  val "checked tarball" "$base"
  val "sha256" "$checked"
  val "commit" "$commit"
  val "uploaded as" "$uploaded"
  val "sha256" "$sha"
  val "maintainer" "$maint"
  val "flavor" "$flavor"
  endgroup
  summary "### Win-builder${dry_run:+: dry run}" "" "- Tarball: \`$base\`, sha256 \`$checked\`" \
    "- Uploaded as \`$uploaded\`, sha256 \`$sha\`: the same files, with commit \`${commit:0:10}\` encoded in \`Version:\`"
  output tarball "$uploaded"

  local url=$base_url/$flavor/$uploaded rc
  if [ -n "$dry_run" ]; then
    say "Dry run: would upload $uploaded to $url"
    summary "- $flavor: would upload to $url" \
      "" "Nothing was sent. A real run uploads the file by anonymous FTP; win-builder emails the results to $maint." ""
    output results "$flavor=dry-run"
    notice "Dry run" "Nothing was sent to win-builder. A real run uploads $uploaded for $flavor."
    return 0
  fi
  group "Win-builder: upload to $flavor"
  val "url" "$url"
  # Anonymous FTP upload, as devtools' upload_ftp() does with curl's `upload = TRUE`;
  # at most three attempts of five minutes each, which the workflow's job timeout covers.
  # Only a failed connection (curl's 6 and 7) is retried: after any other error, such as a timeout (28),
  # part of the file may have arrived, and a retry would send it again under the same name.
  local attempt
  for attempt in 1 2 3; do
    rc=0
    curl --silent --show-error --connect-timeout 30 --max-time "${WINBUILDER_MAX_TIME:-300}" \
      --upload-file "$upload" "$url" >"$work/ftp.out" 2>"$work/ftp.err" || rc=$?
    case "$rc" in
      6 | 7) [ "$attempt" -lt 3 ] || break ;;
      *) break ;;
    esac
    say "  attempt $attempt: curl exited with status $rc, no connection: $(head -n 1 "$work/ftp.err"); retrying"
    sleep "${WINBUILDER_RETRY_SECONDS:-10}"
  done
  endgroup
  if [ "$rc" -ne 0 ]; then
    output results "$flavor=failed"
    fail "Win-builder" "The upload to win-builder failed" \
      "curl exited with status $rc uploading \`$uploaded\` to $url: $(head -n 1 "$work/ftp.err")" "$work/ftp.err" -- \
      "Check win-builder's status at https://win-builder.r-project.org/, then dispatch this workflow again." \
      "Win-builder checks inform the release and do not gate it; the CRAN submission does not wait for them."
  fi
  say "Uploaded $uploaded to $url"
  summary "- $flavor: uploaded to $url" "" "Win-builder emails the results to $maint, usually within 30 minutes." ""
  output results "$flavor=uploaded"
  notice "Uploaded to win-builder" "$uploaded for $flavor; the results arrive by email to the maintainer."
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
      "Pass \`r-devel\` or \`r-release\` in the action's \`flavors\` input."
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
# The check log ends in `Status: ...`, `* result classification: ...` and `</pre>`, in that order;
# `</pre>` may end the classification line itself.
page_result() { # <page>
  awk '
    /^Status: / { st = substr($0, 9); seen = 1; cls = ""; next }
    seen && /^\* result classification: / {
      cls = substr($0, 26)
      if (cls ~ /<\/pre>/) { sub(/[ \t]*<\/pre>.*$/, "", cls); print st "\t" cls; exit }
      next
    }
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
