#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Check that a package's checkout is ready for a CRAN release: enforce what CRAN requires, and report on what it expects.
#
#   hard <package dir> <out dir>
#     Every check runs, and the step fails when any of them fails, each with its own error:
#     - the version has exactly three components;
#     - DESCRIPTION has no `Remotes` field;
#     - no dependency in Depends, Imports or LinkingTo needs a development version, one with four or more components,
#       or names a source as `Remotes` does (`owner/repo`, `github::owner/repo`, `url::...`);
#     - NEWS.md has exactly one section for the version, found by `# <package> <version>` with the date optional,
#       whose heading's date is DESCRIPTION's `Date:`, at most 31 days old and at most a day ahead (UTC);
#     - CRAN's package database sets no `Deadline` for the package, which a package not on CRAN passes.
#     Writes `package`, `version`, `passed` (`true` or `false`) and `report`, a Markdown list, to GITHUB_OUTPUT.
#   report <package dir> <out dir> [<tarball>]
#     Reports, and never fails on a finding: help pages documenting functions without `\value`,
#     a README.md older than README.Rmd in the git history or different from a fresh knit,
#     URLs that urlchecker flags, words that spelling flags, and, with a tarball,
#     `R CMD check --as-cran --no-manual` on it with CRAN's incoming checks.
#     A check that cannot run is reported as such. Writes `report`, Markdown, to GITHUB_OUTPUT.
#
# Usage:
#   release-gate.sh hard <package dir> <out dir>
#   release-gate.sh report <package dir> <out dir> [<tarball>]
#
# Environment:
#   TODAY                the date to compare with, YYYY-MM-DD; default today in UTC (the tests set it)
#   CRAN_DB_URL          CRAN's package database, default https://cran.r-project.org/web/packages/packages.rds;
#                        release-gate-test.sh points it at a local file
#   RSCRIPT, R_CMD       the Rscript and R commands, default `Rscript` and `R`; release-gate-test.sh stubs them
#   GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, GITHUB_ACTIONS
#
# Exit status: 0 when every hard check passes (always, for `report`), 1 on a failed check, 2 on a usage error.

set -euo pipefail

# shellcheck source=../cran-lib/cran-lib.sh
. "$(dirname "$0")/../cran-lib/cran-lib.sh"

usage() {
  sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
rscript=${RSCRIPT:-Rscript}
r_cmd=${R_CMD:-R}
today=${TODAY:-$(date -u +%Y-%m-%d)}
max_lines=60
# The deadline CRAN's package database sets for a package: `absent` when it is not on CRAN, `none` when there is none.
# shellcheck disable=SC2016  # R code
r_deadline='
args <- commandArgs(TRUE)
db <- as.data.frame(readRDS(args[[1]]), stringsAsFactors = FALSE)
if (!"Package" %in% names(db)) stop("the database has no Package column")
row <- db[db$Package == args[[2]], , drop = FALSE]
d <- if ("Deadline" %in% names(row)) row$Deadline[1] else NA
cat(if (nrow(row) == 0) "absent" else if (is.na(d) || !nzchar(d)) "none" else d, "\n", sep = "")
'

# A multi-line output, between a delimiter that the value cannot contain.
output_file() { # <name> <file>
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  local delim
  delim="EOF_$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  { echo "$1<<$delim"; cat "$2"; echo "$delim"; } >>"$GITHUB_OUTPUT"
}

# At most <n> lines of a file, each cut at 300 characters, then a line saying how many were left out:
# the report reaches the comment through an environment variable, which holds at most 128 KiB.
excerpt() { # <file> <n>
  awk -v n="$2" '
    NR <= n { print (length($0) > 300 ? substr($0, 1, 300) " [...]" : $0) }
    END { if (NR > n) print "[" NR - n " more lines]" }' "$1"
}

# A collapsed block of text for the report; four backticks, so that three in the text cannot close it.
details() { # <summary> <file>
  # shellcheck disable=SC2016  # Markdown backticks
  printf '\n<details><summary>%s</summary>\n\n````text\n%s\n````\n\n</details>\n' "$1" "$(excerpt "$2" "$max_lines")"
}

# --- hard -----------------------------------------------------------------

cmd_hard() {
  [ $# -eq 2 ] || usage
  local pkgdir=$1 out=$2
  mkdir -p "$out"
  local report=$out/hard.md failed=()
  : >"$report"
  pass() { # <check> <text>
    printf -- '- ✅ **%s:** %s\n' "$1" "$2" >>"$report"
  }
  # A failed check: annotated and reported as `failure` does, then the run goes on to the next check.
  flunk() { # <check> <title> <message> [<excerpt>] -- <advice>...
    printf -- '- ❌ **%s:** %s. %s\n' "$1" "$2" "$3" >>"$report"
    failed+=("$1")
    failure "Release gate: $1" "${@:2}"
  }

  summary "## Release gate" ""
  [ -f "$pkgdir/DESCRIPTION" ] ||
    fail "Release gate" "No DESCRIPTION" "The checkout has no \`DESCRIPTION\` at its root." -- \
      "Call the release gate from the package's own repository."
  local desc=$pkgdir/DESCRIPTION pkg version desc_date
  pkg=$(dcf_field Package "$desc")
  version=$(dcf_field Version "$desc")
  desc_date=$(dcf_field Date "$desc")
  valid_package "$pkg" ||
    fail "Release gate" "No valid package name" "\`DESCRIPTION\` gives the package name \`$pkg\`." -- \
      "Fix \`Package:\` in \`DESCRIPTION\`."
  output package "$pkg" version "$version"

  group "Version"
  val "package" "$pkg"
  val "version" "$version"
  local components
  components=$(printf '%s\n' "$version" | awk -F '[.-]' '{ print NF }')
  if valid_version "$version" && [ "$components" -eq 3 ]; then
    pass "Version" "\`$version\` has three components."
  else
    flunk "Version" "No release version" \
      "\`DESCRIPTION\` carries \`$version\`, and a release version has exactly three components, such as \`1.2.3\`." -- \
      "Set \`Version:\` in \`DESCRIPTION\` to the release version: on the release branch, or on the fast path in \`main\`."
  fi
  endgroup

  group "Remotes"
  if grep -q '^Remotes:' "$desc"; then
    flunk "Remotes" "DESCRIPTION has a Remotes field" \
      "\`Remotes: $(dcf_field Remotes "$desc" | sed "s/^ *//")\` installs dependencies from outside CRAN, which CRAN cannot." -- \
      "Remove \`Remotes\` from \`DESCRIPTION\`, after the dependencies it names are on CRAN in the versions the package needs."
  else
    pass "Remotes" "\`DESCRIPTION\` has no \`Remotes\` field."
  fi
  endgroup

  group "Dependencies"
  local field
  for field in Depends Imports LinkingTo; do
    dcf_field "$field" "$desc" | tr ',' '\n' | awk -v field="$field" '
      { gsub(/^[ \t]+|[ \t]+$/, "") }
      NF == 0 { next }
      {
        name = $0
        sub(/[ \t]*\(.*$/, "", name)
        ver = ""
        if (match($0, /\([^)]*\)/)) {
          ver = substr($0, RSTART + 1, RLENGTH - 2)
          sub(/^[ \t]*[<>=!]+[ \t]*/, "", ver)
          sub(/[ \t]+$/, "", ver)
        }
        if (name ~ /[\/:@]/) print field ": `" $0 "`, a source outside CRAN"
        else if (ver != "" && split(ver, parts, /[.-]/) > 3) print field ": `" $0 "`, a development version"
      }'
  done >"$out/deps"
  cat "$out/deps"
  if [ -s "$out/deps" ]; then
    flunk "Dependencies" "A dependency is not on CRAN" \
      "$(paste -s -d ';' "$out/deps" | sed 's/;/; /g'). CRAN installs only released versions from CRAN." "$out/deps" -- \
      "Require released versions of the dependencies, at most three components each, and wait for any that is not on CRAN yet."
  else
    pass "Dependencies" "Depends, Imports and LinkingTo need no development version and no source outside CRAN."
  fi
  endgroup

  group "NEWS.md"
  val "Date" "${desc_date:-(none)}"
  val "today (UTC)" "$today"
  local n heading news_date news_s days
  if [ ! -f "$pkgdir/NEWS.md" ]; then
    flunk "NEWS.md" "No NEWS.md" "The checkout has no \`NEWS.md\`, so the release has no notes." -- \
      "Write the version's section in \`NEWS.md\`, headed \`# $pkg $version ($today)\`."
  else
    # The headings of the version's sections, with or without a date.
    awk -v h="# $pkg $version" '
      { sub(/[ \t\r]+$/, "") }
      $0 == h { print NR ": " $0; next }
      index($0, h " (") == 1 && substr($0, length(h) + 1) ~ /^ \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/ { print NR ": " $0 }
    ' "$pkgdir/NEWS.md" >"$out/headings"
    n=$(wc -l <"$out/headings" | tr -d ' ')
    heading=$(cut -d' ' -f2- "$out/headings" | head -n 1)
    news_date=$(printf '%s\n' "$heading" | sed -n 's/^.* (\([0-9-]*\))$/\1/p')
    if [ "$n" -ne 1 ]; then
      flunk "NEWS.md" "No single NEWS.md section for $pkg $version" \
        "\`NEWS.md\` has $n sections headed \`# $pkg $version\`, and the release needs exactly one." "$out/headings" -- \
        "Head the version's section \`# $pkg $version ($today)\`, once."
    elif [ -z "$news_date" ]; then
      flunk "NEWS.md" "The NEWS.md heading has no date" "The section is headed \`$heading\`, without the release date." -- \
        "Make the date commit: head the section \`# $pkg $version ($today)\` and set \`Date: $today\` in \`DESCRIPTION\`."
    elif [ "$news_date" != "$desc_date" ]; then
      flunk "NEWS.md" "The dates differ" \
        "\`NEWS.md\` dates the release \`$news_date\`, and \`DESCRIPTION\`'s \`Date:\` is \`${desc_date:-(none)}\`." -- \
        "Make the date commit: set both to \`$today\`."
    elif ! news_s=$(date -u -d "$news_date" +%s 2>/dev/null); then
      flunk "NEWS.md" "The date is no date" "The release is dated \`$news_date\`, which is not a calendar date." -- \
        "Make the date commit: set both dates to \`$today\`."
    elif days=$((($(date -u -d "$today" +%s) - news_s) / 86400)) && [ "$days" -gt 31 ]; then
      flunk "NEWS.md" "The date is stale" \
        "The release is dated \`$news_date\`, $days days before today (\`$today\`), and the gate takes at most 31." -- \
        "Make the date commit: set both dates to \`$today\`, then run the checks and the gate on that commit."
    elif [ "$days" -lt -1 ]; then
      flunk "NEWS.md" "The date is in the future" \
        "The release is dated \`$news_date\`, $((-days)) days after today (\`$today\`)." -- \
        "Make the date commit: set both dates to \`$today\`."
    else
      pass "NEWS.md" "one section \`$heading\`, dated as \`DESCRIPTION\`, $days days ago."
    fi
  fi
  endgroup

  group "CRAN deadline"
  local db_url=${CRAN_DB_URL:-https://cran.r-project.org/web/packages/packages.rds} deadline
  val "database" "$db_url"
  if ! curl --silent --show-error --fail --location --connect-timeout 30 --max-time 300 \
    --output "$out/packages.rds" "$db_url" 2>"$out/curl.err"; then
    flunk "CRAN deadline" "CRAN's package database cannot be read" \
      "Reading $db_url failed: $(head -n 1 "$out/curl.err"), so whether CRAN set a deadline is unknown." "$out/curl.err" -- \
      "Run the gate again; if CRAN is down, wait until it is back."
  elif ! deadline=$("$rscript" --vanilla -e "$r_deadline" "$out/packages.rds" "$pkg" 2>"$out/r.err"); then
    flunk "CRAN deadline" "CRAN's package database cannot be read" \
      "Reading the downloaded database with R failed: $(tail -n 1 "$out/r.err")." "$out/r.err" -- \
      "Run the gate again; if it fails again, the database's format has changed, and this check needs to follow."
  else
    val "deadline" "$deadline"
    case "$deadline" in
      absent) pass "CRAN deadline" "$pkg is not on CRAN, so CRAN set no deadline." ;;
      none) pass "CRAN deadline" "CRAN set no deadline for $pkg." ;;
      *)
        flunk "CRAN deadline" "CRAN set a deadline" \
          "CRAN's package database gives $pkg the deadline \`$deadline\`: CRAN asked for a fix of problems it found, and archives the package unless they are fixed by then." -- \
          "Read the problems on https://cran.r-project.org/web/checks/check_results_$pkg.html and in CRAN's email to the maintainer, and fix them in this release." \
          "The deadline stays in the database until CRAN accepts a fixed version."
        ;;
    esac
  fi
  endgroup

  output_file report "$report"
  if [ ${#failed[@]} -gt 0 ]; then
    output passed false
    summary "**Not ready:** $(printf '%s, ' "${failed[@]}" | sed 's/, $//') failed." ""
    echo "Release gate: ${#failed[@]} hard checks failed: ${failed[*]}." >&2
    exit 1
  fi
  output passed true
  summary "$(cat "$report")" ""
  notice "Release gate" "$pkg $version passes every hard check."
}

# --- report ---------------------------------------------------------------

cmd_report() {
  [ $# -eq 2 ] || [ $# -eq 3 ] || usage
  local pkgdir=$1 out=$2 tarball=${3:-}
  mkdir -p "$out"
  pkgdir=$(cd "$pkgdir" && pwd)
  local items=$out/items.md more=$out/details.md
  : >"$items"
  : >"$more"
  clean() { printf -- '- ✅ **%s:** %s\n' "$1" "$2" >>"$items"; }
  finding() { # <check> <text> [<details file>]
    printf -- '- ⚠️ **%s:** %s\n' "$1" "$2" >>"$items"
    warn "$1" "$2"
    [ -z "${3:-}" ] || details "$1" "$3" >>"$more"
  }
  unrun() { # <check> <text> [<details file>]
    printf -- '- ⏭️ **%s:** not run: %s\n' "$1" "$2" >>"$items"
    warn "$1 not run" "$2"
    [ -z "${3:-}" ] || details "$1" "$3" >>"$more"
  }
  # Runs an R expression in the package directory: 0 is clean, 3 a finding, anything else a failure to run.
  r_check() { # <log> <expression>
    local rc=0
    (cd "$pkgdir" && "$rscript" --vanilla -e "$2") >"$1" 2>&1 || rc=$?
    return "$rc"
  }

  summary "## Release gate: reported, not enforced" ""

  group "Help pages: \\value"
  local rd missing=()
  if compgen -G "$pkgdir/man/*.Rd" >/dev/null; then
    for rd in "$pkgdir"/man/*.Rd; do
      ! grep -Eq '\\docType\{(data|package)\}' "$rd" || continue
      grep -q '\\usage{' "$rd" || continue
      grep -q '\\value{' "$rd" || missing+=("$(basename "$rd")")
    done
    if [ ${#missing[@]} -eq 0 ]; then
      clean "Help pages" "every page with a \`\\usage\` section has a \`\\value\` section."
    else
      printf '%s\n' "${missing[@]}" >"$out/value"
      finding "Help pages" "${#missing[@]} pages with a \`\\usage\` section lack a \`\\value\` section, which CRAN's reviewers ask for." \
        "$out/value"
    fi
  else
    clean "Help pages" "there is no \`man/*.Rd\`."
  fi
  endgroup

  group "README"
  local rmd_time md_time rc
  if [ ! -f "$pkgdir/README.Rmd" ]; then
    clean "README" "there is no \`README.Rmd\`."
  elif [ ! -f "$pkgdir/README.md" ]; then
    finding "README" "\`README.Rmd\` has no \`README.md\` knitted from it."
  else
    rmd_time=$(git -C "$pkgdir" log -1 --format=%ct -- README.Rmd 2>/dev/null) || rmd_time=''
    md_time=$(git -C "$pkgdir" log -1 --format=%ct -- README.md 2>/dev/null) || md_time=''
    val "README.Rmd commit" "${rmd_time:-(unknown)}"
    val "README.md commit" "${md_time:-(unknown)}"
    if [ -n "$rmd_time" ] && [ -n "$md_time" ] && [ "$rmd_time" -gt "$md_time" ]; then
      finding "README" "\`README.Rmd\` was committed after \`README.md\`: knit it again."
    else
      # The knit runs in a copy, so that the checkout stays as it was.
      rm -rf "$out/knit"
      cp -a "$pkgdir" "$out/knit"
      rc=0
      (cd "$out/knit" && "$rscript" --vanilla -e 'rmarkdown::render("README.Rmd", quiet = TRUE)') >"$out/knit.log" 2>&1 || rc=$?
      if [ "$rc" -ne 0 ]; then
        unrun "README" "knitting \`README.Rmd\` failed with status $rc." "$out/knit.log"
      elif diff -u "$pkgdir/README.md" "$out/knit/README.md" >"$out/readme.diff"; then
        clean "README" "\`README.md\` is what \`README.Rmd\` knits to."
      else
        finding "README" "knitting \`README.Rmd\` gives another \`README.md\`: knit it again, and commit the result." \
          "$out/readme.diff"
      fi
    fi
  fi
  endgroup

  group "URLs"
  rc=0
  r_check "$out/urls.log" 'res <- urlchecker::url_check("."); if (nrow(res) > 0) { print(res); quit(status = 3) }' || rc=$?
  case "$rc" in
    0) clean "URLs" "urlchecker flags none." ;;
    3) finding "URLs" "urlchecker flags URLs, which CRAN's incoming checks flag too." "$out/urls.log" ;;
    *) unrun "URLs" "urlchecker failed with status $rc." "$out/urls.log" ;;
  esac
  endgroup

  group "Spelling"
  rc=0
  r_check "$out/spelling.log" 'res <- spelling::spell_check_package("."); if (nrow(res) > 0) { print(res); quit(status = 3) }' || rc=$?
  case "$rc" in
    0) clean "Spelling" "spelling flags no word." ;;
    3) finding "Spelling" "spelling flags words; add the right ones to \`inst/WORDLIST\`." "$out/spelling.log" ;;
    *) unrun "Spelling" "spelling failed with status $rc." "$out/spelling.log" ;;
  esac
  endgroup

  group "R CMD check --as-cran"
  local name status
  if [ -z "$tarball" ]; then
    unrun "R CMD check" "no checked tarball of this commit, from a green run of the check workflow."
  elif [ ! -f "$tarball" ]; then
    unrun "R CMD check" "the tarball \`$tarball\` does not exist."
  else
    name=$(basename "$tarball")
    val "tarball" "$name"
    rm -rf "$out/check"
    mkdir -p "$out/check"
    # CRAN's incoming checks, the remote ones included; nothing skips the check of the dates.
    rc=0
    (cd "$out/check" && unset _R_CHECK_CRAN_INCOMING_SKIP_DATES_ &&
      _R_CHECK_CRAN_INCOMING_=true _R_CHECK_CRAN_INCOMING_REMOTE_=true \
        "$r_cmd" CMD check --as-cran --no-manual "$tarball") >"$out/check.out" 2>&1 || rc=$?
    local log=$out/check/${name%%_*}.Rcheck/00check.log
    if [ ! -f "$log" ]; then
      unrun "R CMD check" "\`R CMD check\` wrote no log, and exited with status $rc." "$out/check.out"
    else
      status=$(sed -n 's/^Status: //p' "$log" | tail -n 1)
      # The checks that did not pass, each with the lines that explain it.
      awk '/^\* / { keep = ($0 ~ / (NOTE|WARNING|ERROR)$/) } keep' "$log" >"$out/check.problems"
      if [ "$status" = OK ]; then
        clean "R CMD check" "\`$name\`: OK with CRAN's incoming checks."
      else
        finding "R CMD check" "\`$name\`: ${status:-no status, exit status $rc}." "$out/check.problems"
      fi
    fi
  fi
  endgroup

  cat "$items" "$more" >"$out/report.md"
  summary "$(cat "$out/report.md")" ""
  output_file report "$out/report.md"
}

case "${1:-}" in
  hard) shift; cmd_hard "$@" ;;
  report) shift; cmd_report "$@" ;;
  *) usage ;;
esac
