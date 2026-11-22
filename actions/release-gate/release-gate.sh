#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Check that a package's checkout is ready for a CRAN release: enforce what CRAN requires, and report on what it expects.
#
#   hard <package dir> <out dir>
#     Every check runs, and the step fails when any of them fails, each with its own error:
#     - the version is a release version: three components, or four with the last below 9000;
#     - DESCRIPTION has no `Remotes` field;
#     - CRAN's package database can be read; the next checks use it;
#     - no dependency in Depends, Imports, LinkingTo, Suggests or Enhances names a source as `Remotes` does
#       (`owner/repo`, `github::owner/repo`, `url::...`), or requires a version that CRAN does not have:
#       higher than CRAN's for `>=` and `>`, another for `==`. Base packages pass; recommended ones are on CRAN.
#       A package not on CRAN passes, reported, when Bioconductor's release indexes (BIOC_URL) list it,
#       or when it is in Suggests or Enhances and DESCRIPTION has `Additional_repositories`, as CRAN's policy allows;
#       otherwise it fails. Indexes that cannot be read are reported once, and such a package then fails with that cause;
#     - NEWS.md has exactly one section for the version, found by `# <package> <version>` with the date optional,
#       outside code fences, whose heading's date is DESCRIPTION's `Date:`, at most 31 days old and at most a day ahead (UTC);
#       without one, the error names the headings that mention the version;
#     `Additional_repositories` is reported, not enforced.
#     Writes `package`, `version`, `passed` (`true` or `false`) and `report`, a Markdown list, to GITHUB_OUTPUT.
#   report <package dir> <out dir> [<tarball>]
#     Reports, and never fails on a finding: a setup step that failed (SETUP),
#     a `Deadline` that CRAN's package database (CRAN_DB_URL) sets for the package, naming its date,
#     a checked tarball that could not be taken (TARBALL_OUTCOME), help pages documenting functions without `\value`,
#     a README.md older than README.Rmd in the git history or different from a fresh knit,
#     URLs that urlchecker flags, words that spelling flags, and, with a tarball,
#     `R CMD check --as-cran --no-manual` on it with CRAN's incoming checks.
#     A check that cannot run is reported as such. Writes `report`, Markdown, to GITHUB_OUTPUT.
#     It holds no token: the package's own code runs here.
#   job-url
#     Writes `job-url`, the URL of the job named JOB_NAME among the run's jobs, which a reusable workflow's caller
#     prefixes with its own job's name, to GITHUB_OUTPUT; the run's URL when the job cannot be found or the jobs cannot be read.
#     It runs before the package's code, as the only step that holds the token.
#
# Usage:
#   release-gate.sh hard <package dir> <out dir>
#   release-gate.sh report <package dir> <out dir> [<tarball>]
#   release-gate.sh job-url
#
# Environment:
#   SETUP                `report`: one `<setup step>=<outcome>` per line, as `steps.<id>.outcome` gives it
#   TARBALL_OUTCOME      `report`: the outcome of the step that takes the checked tarball; empty when there was none
#   TARBALL_FAILURE_FILE `report`: the file in which that step wrote its failure's title and message, quoted when it failed
#   JOB_URL              `report`: the job to link, from `job-url`; default the run's URL
#   JOB_NAME             `job-url`: the job's name; GH_TOKEN with `actions: read` reads the run's jobs;
#                        GH, the gh command, default `gh`, which release-gate-test.sh stubs
#   TODAY                the date to compare with, YYYY-MM-DD; default today in UTC (the tests set it)
#   CRAN_DB_URL          CRAN's package database, default https://cran.r-project.org/web/packages/packages.rds;
#                        release-gate-test.sh points it at a local file
#   BIOC_URL             Bioconductor's release, default https://bioconductor.org/packages/release, whose
#                        bioc, data/annotation and data/experiment indexes are read; the tests point it at local files
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
# The dependencies of <tsv> (field, name, operator, version, entry) that CRAN cannot satisfy, as
# `fail` or `note`, field, entry and reason, tab-separated.
# <bioc> holds Bioconductor's packages, one `<name>\t<version>` per line, or is empty when its indexes cannot be read,
# for the reason <bioc cause>; <additional> is `yes` when DESCRIPTION has `Additional_repositories`.
# shellcheck disable=SC2016  # R code
r_deps='
args <- commandArgs(TRUE)
db <- as.data.frame(readRDS(args[[1]]), stringsAsFactors = FALSE)
if (!all(c("Package", "Version") %in% names(db))) stop("the database has no Package or Version column")
deps <- utils::read.delim(args[[2]], header = FALSE, colClasses = "character", quote = "", na.strings = character(),
  col.names = c("field", "name", "op", "ver", "entry"))
bioc <- if (!nzchar(args[[3]])) NULL else if (file.size(args[[3]]) == 0) data.frame(Package = character(), Version = character()) else
  utils::read.delim(args[[3]], header = FALSE, colClasses = "character", quote = "", na.strings = character(),
    col.names = c("Package", "Version"))
bioc_cause <- args[[4]]
additional <- args[[5]] == "yes"
base <- c("R", "base", "compiler", "datasets", "graphics", "grDevices", "grid", "methods", "parallel", "splines",
  "stats", "stats4", "tcltk", "tools", "utils")
say <- function(kind, d, why) cat(kind, "\t", d$field, "\t", d$entry, "\t", why, "\n", sep = "")
for (i in seq_len(nrow(deps))) {
  d <- deps[i, ]
  if (d$name %in% base) next
  cran <- db$Version[db$Package == d$name]
  repo <- "CRAN"
  if (length(cran) == 0 && !is.null(bioc) && d$name %in% bioc$Package) {
    cran <- bioc$Version[bioc$Package == d$name]
    repo <- "Bioconductor"
    say("note", d, "not on CRAN, on Bioconductor")
  }
  if (length(cran) == 0) {
    if (additional && d$field %in% c("Suggests", "Enhances"))
      say("note", d, "not on CRAN or Bioconductor, to come from `Additional_repositories`")
    else if (is.null(bioc)) say("fail", d, paste0("not on CRAN, and Bioconductor cannot be checked: ", bioc_cause))
    else say("fail", d, "not on CRAN or Bioconductor")
    next
  }
  if (!d$op %in% c(">=", ">", "==")) next
  need <- tryCatch(package_version(d$ver), error = function(e) NULL)
  if (is.null(need)) { say("fail", d, "no valid version"); next }
  have <- tryCatch(package_version(cran[[1]]), error = function(e) NULL)
  if (is.null(have)) { say("fail", d, paste0(repo, " gives no valid version: ", cran[[1]])); next }
  if ((d$op == ">=" && need > have) || (d$op == ">" && need >= have) || (d$op == "==" && need != have))
    say("fail", d, paste0(repo, " has ", cran[[1]]))
}
'

# A multi-line output of at most <bytes> bytes, between a delimiter that the value cannot contain.
# The report reaches the comment through an environment variable, which holds at most 128 KiB,
# so a longer one is cut at a line, closing a fence or collapsed block left open, and saying so.
output_file() { # <name> <file> <bytes>
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  local delim
  delim="EOF_$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
  {
    echo "$1<<$delim"
    if [ "$(wc -c <"$2")" -le "$3" ]; then
      cat "$2"
    else
      head -c "$3" "$2" | sed '$d' | awk '
        { print }
        /^````/ { fence = !fence }
        /^<details>/ { open++ }
        /^<\/details>/ { open-- }
        END {
          if (fence) print "````"
          print ""
          print "[Cut to fit: the run'"'"'s summary page has the rest.]"
          for (; open > 0; open--) { print ""; print "</details>" }
        }'
    fi
    echo "$delim"
  } >>"$GITHUB_OUTPUT"
}

# At most <n> lines of a file, each cut at 300 characters, then a line saying how many were left out.
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

# `yes` when a DCF file has the field, `no` otherwise.
has_field() { # <field> <file>
  if grep -q "^$1:" "$2"; then echo yes; else echo no; fi
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
  note() { # <check> <text>
    printf -- '- ⚠️ **%s:** %s\n' "$1" "$2" >>"$report"
    warn "$1" "$2"
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
  if release_version "$version"; then
    pass "Version" "\`$version\` is a release version."
  else
    flunk "Version" "No release version" \
      "\`DESCRIPTION\` carries \`$version\`, and a release version has three components, such as \`1.2.3\`, or four with the last below 9000, such as \`1.2.3.1\`." -- \
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

  group "CRAN's package database"
  local db_url=${CRAN_DB_URL:-https://cran.r-project.org/web/packages/packages.rds} db=$out/packages.rds
  val "database" "$db_url"
  if ! curl --silent --show-error --fail --location --connect-timeout 30 --max-time 300 \
    --output "$db" "$db_url" 2>"$out/curl.err"; then
    db=''
    flunk "CRAN database" "CRAN's package database cannot be read" \
      "Reading $db_url failed: $(head -n 1 "$out/curl.err"), so the dependencies cannot be checked." \
      "$out/curl.err" -- \
      "Run the gate again; if CRAN is down, wait until it is back."
  fi
  endgroup

  group "Bioconductor's package indexes"
  local bioc_url=${BIOC_URL:-https://bioconductor.org/packages/release} bioc=$out/bioc.names bioc_cause='' repo
  val "indexes" "$bioc_url"
  : >"$bioc"
  for repo in bioc data/annotation data/experiment; do
    if ! curl --silent --show-error --fail --location --connect-timeout 30 --max-time 120 \
      --output "$out/PACKAGES" "$bioc_url/$repo/src/contrib/PACKAGES" 2>"$out/curl.err"; then
      bioc_cause="reading $bioc_url/$repo/src/contrib/PACKAGES failed: $(head -n 1 "$out/curl.err")"
      break
    fi
    # One `<name>\t<version>` line per package.
    awk '
      /^Package:/ { name = $2 }
      /^Version:/ { version = $2 }
      /^[ \t\r]*$/ { if (name != "") print name "\t" version; name = ""; version = "" }
      END { if (name != "") print name "\t" version }
    ' "$out/PACKAGES" >>"$bioc"
  done
  if [ -n "$bioc_cause" ]; then
    bioc=''
    note "Bioconductor" "Bioconductor's package indexes cannot be read, so a dependency that is not on CRAN fails: $bioc_cause."
  else
    val "packages" "$(wc -l <"$bioc" | tr -d ' ')"
  fi
  endgroup

  group "Dependencies"
  local field
  : >"$out/deps.remote"
  for field in Depends Imports LinkingTo Suggests Enhances; do
    dcf_field "$field" "$desc" | tr ',' '\n' | awk -v field="$field" -v remote="$out/deps.remote" '
      { gsub(/^[ \t]+|[ \t]+$/, "") }
      NF == 0 { next }
      {
        name = $0
        sub(/[ \t]*\(.*$/, "", name)
        op = ""
        ver = ""
        if (match($0, /\([^)]*\)/)) {
          ver = substr($0, RSTART + 1, RLENGTH - 2)
          gsub(/^[ \t]+|[ \t]+$/, "", ver)
          if (match(ver, /^[<>=!]+/)) { op = substr(ver, 1, RLENGTH); ver = substr(ver, RLENGTH + 1) }
          sub(/^[ \t]+/, "", ver)
        }
        if (name ~ /[\/:@]/) print field "\t`" $0 "`\ta source outside CRAN" >>remote
        else print field "\t" name "\t" op "\t" ver "\t" $0
      }'
  done >"$out/deps.tsv"
  local checked="against CRAN's package database and Bioconductor's indexes" r_failed=''
  : >"$out/deps.cran"
  if [ -z "$db" ]; then
    checked="for sources outside CRAN only, as CRAN's package database cannot be read"
  elif [ -s "$out/deps.tsv" ] && ! "$rscript" --vanilla -e "$r_deps" "$db" "$out/deps.tsv" "$bioc" "$bioc_cause" \
    "$(has_field Additional_repositories "$desc")" >"$out/deps.cran" 2>"$out/r.err"; then
    : >"$out/deps.cran"
    r_failed="Reading CRAN's package database with R failed: $(tail -n 1 "$out/r.err")."
  fi
  # The failures: sources outside CRAN, and versions CRAN does not have.
  {
    awk -F '\t' '{ print $1 ": " $2 ", " $3 }' "$out/deps.remote"
    awk -F '\t' '$1 == "fail" { print $2 ": `" $3 "`, " $4 }' "$out/deps.cran"
  } >"$out/deps"
  awk -F '\t' '$1 == "note" { print $2 ": `" $3 "`, " $4 }' "$out/deps.cran" >"$out/deps.notes"
  cat "$out/deps" "$out/deps.notes"
  local listed=''
  [ ! -s "$out/deps" ] || listed="$(paste -s -d ';' "$out/deps" | sed 's/;/; /g'). "
  if [ -n "$r_failed" ]; then
    # One failure, which names both causes.
    cat "$out/r.err" >>"$out/deps"
    flunk "Dependencies" "The dependencies cannot be checked against CRAN" \
      "$listed$r_failed" "$out/deps" -- \
      "Run the gate again; if it fails again, the database's format has changed, and this check needs to follow."
  elif [ -n "$listed" ]; then
    flunk "Dependencies" "A dependency is not on CRAN" \
      "${listed}CRAN installs dependencies only from CRAN and Bioconductor, in their current versions." \
      "$out/deps" -- \
      "Require versions of the dependencies that CRAN has, and wait for any that is not on CRAN yet."
  else
    pass "Dependencies" "Depends, Imports, LinkingTo, Suggests and Enhances need nothing outside CRAN, checked $checked."
  fi
  if [ -s "$out/deps.notes" ]; then
    note "Dependencies" "$(paste -s -d ';' "$out/deps.notes" | sed 's/;/; /g')."
  fi
  if grep -q '^Additional_repositories:' "$desc"; then
    local repos
    repos=$(dcf_field Additional_repositories "$desc" | sed 's/^ *//')
    note "Additional repositories" "\`Additional_repositories: $repos\`: CRAN accepts it for packages in Suggests or Enhances; \
check that each repository is reachable and needed."
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
    # The headings of the version's sections, with or without a date, and, in <out>/near, the other headings
    # that mention the version; neither inside code fences.
    awk -v h="# $pkg $version" -v v="$version" -v near="$out/near" '
      { sub(/[ \t\r]+$/, "") }
      /^(```|~~~)/ { fence = !fence; next }
      fence { next }
      $0 == h { print NR ": " $0; next }
      index($0, h " (") == 1 && substr($0, length(h) + 1) ~ /^ \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/ { print NR ": " $0; next }
      /^#/ && (i = index($0, v)) > 0 {
        before = substr($0, i - 1, 1)
        after = substr($0, i + length(v), 1)
        if (before !~ /[0-9.-]/ && after !~ /[0-9.-]/) print NR ": " $0 >near
      }
    ' "$pkgdir/NEWS.md" >"$out/headings"
    touch "$out/near"
    n=$(wc -l <"$out/headings" | tr -d ' ')
    heading=$(cut -d' ' -f2- "$out/headings" | head -n 1)
    news_date=$(printf '%s\n' "$heading" | sed -n 's/^.* (\([0-9-]*\))$/\1/p')
    if [ "$n" -eq 0 ] && [ -s "$out/near" ]; then
      flunk "NEWS.md" "No NEWS.md section for $pkg $version" \
        "\`NEWS.md\` has no section headed \`# $pkg $version\`, only headings that mention the version: \
$(awk -v q=$'\x60' '{ sub(/^[0-9]+: /, ""); printf "%s%s%s%s", (NR > 1 ? "; " : ""), q, $0, q }' "$out/near")." "$out/near" -- \
        "Head the version's section \`# $pkg $version ($today)\`: one \`#\`, the package's name, the version without \`v\`, \
and the date in parentheses, each after one space."
    elif [ "$n" -ne 1 ]; then
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

  output_file report "$report" 30000
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

# The run's URL.
run_url() { printf '%s' "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-0}"; }

# --- job-url --------------------------------------------------------------

# A failed lookup falls back to the run's URL, with a notice: the link is a convenience, not a check.
cmd_job_url() {
  [ $# -eq 0 ] || usage
  local url='' errf
  errf=$(mktemp)
  if [ -n "${JOB_NAME:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    if ! url=$("${GH:-gh}" api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/${GITHUB_RUN_ATTEMPT:-1}/jobs?per_page=100" \
      --jq "[.jobs[] | select(.name == \"$JOB_NAME\" or (.name | endswith(\" / $JOB_NAME\")))][0].html_url // \"\"" 2>"$errf"); then
      notice "Job URL" "The run's jobs cannot be read ($(head -n 1 "$errf")); the report links the run."
      url=''
    elif [ -z "$url" ]; then
      notice "Job URL" "No job of the run is named '$JOB_NAME'; the report links the run."
    fi
  fi
  rm -f "$errf"
  output job-url "${url:-$(run_url)}"
  say "${url:-$(run_url)}"
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
  local job_url=${JOB_URL:-$(run_url)} deps_failed=false

  # A setup step that failed: the checks that need what it installs report themselves as not run.
  local step outcome
  while IFS='=' read -r step outcome; do
    [ -n "$step" ] || continue
    [ "$outcome" != success ] || continue
    [ "$step" != dependencies ] || deps_failed=true
    unrun "Setup: $step" "the job's step that sets up \`$step\` ended with \`$outcome\`; its error in $job_url names the cause, \
and the checks below that need it cannot run."
  done <<<"${SETUP:-}"

  # A deadline asks for a fix in a release, so it never blocks one; it is reported with its date.
  group "CRAN deadline"
  local db_url=${CRAN_DB_URL:-https://cran.r-project.org/web/packages/packages.rds} pkg deadline
  pkg=$(dcf_field Package "$pkgdir/DESCRIPTION" 2>/dev/null) || pkg=''
  val "database" "$db_url"
  if ! valid_package "$pkg"; then
    unrun "CRAN deadline" "\`DESCRIPTION\` names no valid package."
  elif ! curl --silent --show-error --fail --location --connect-timeout 30 --max-time 300 \
    --output "$out/packages.rds" "$db_url" 2>"$out/curl.err"; then
    unrun "CRAN deadline" "reading $db_url failed: $(head -n 1 "$out/curl.err")."
  elif ! deadline=$("$rscript" --vanilla -e "$r_deadline" "$out/packages.rds" "$pkg" 2>"$out/r.err"); then
    unrun "CRAN deadline" "reading CRAN's package database with R failed: $(tail -n 1 "$out/r.err")." "$out/r.err"
  else
    val "deadline" "$deadline"
    case "$deadline" in
      absent) clean "CRAN deadline" "$pkg is not on CRAN, so CRAN set no deadline." ;;
      none) clean "CRAN deadline" "CRAN set no deadline for $pkg." ;;
      *)
        finding "CRAN deadline" "CRAN set the deadline \`$deadline\` for $pkg, and archives it unless the problems CRAN found \
are fixed by then: see https://cran.r-project.org/web/checks/check_results_$pkg.html and CRAN's email to the maintainer, \
and fix them in this release. The deadline stays until CRAN accepts a fixed version."
        ;;
    esac
  fi
  endgroup

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
  local cause=''
  if [ -n "${TARBALL_FAILURE_FILE:-}" ] && [ -s "$TARBALL_FAILURE_FILE" ]; then
    cause=$(head -n 1 "$TARBALL_FAILURE_FILE")
  fi
  if [ "${TARBALL_OUTCOME:-success}" = failure ] && [ -n "$cause" ]; then
    unrun "R CMD check" "taking the checked tarball failed: $cause (see $job_url)."
  elif [ "${TARBALL_OUTCOME:-success}" = failure ]; then
    unrun "R CMD check" "taking the checked tarball failed, and its step wrote no cause; its error in $job_url names it."
  elif [ "${TARBALL_OUTCOME:-success}" != success ]; then
    unrun "R CMD check" "the step that takes the checked tarball ended with \`$TARBALL_OUTCOME\`."
  elif [ "$deps_failed" = true ]; then
    unrun "R CMD check" "the package's dependencies could not be installed, so its check would fail on them."
  elif [ -z "$tarball" ]; then
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
  output_file report "$out/report.md" 60000
}

case "${1:-}" in
  hard) shift; cmd_hard "$@" ;;
  report) shift; cmd_report "$@" ;;
  job-url) shift; cmd_job_url "$@" ;;
  *) usage ;;
esac
