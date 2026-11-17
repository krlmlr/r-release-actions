#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Check release-gate.sh offline, against package checkouts written here, a CRAN package database written here,
# and stubs of urlchecker, spelling, the README's knit and `R CMD check`: nothing reaches CRAN.
#
#   1. `hard` passes a release that meets every requirement, and reports each check.
#   2. `hard` fails, each with its own error, on a development version, `Remotes`, a dependency on a source outside CRAN
#      or on a version CRAN does not have (four components CRAN has pass; base packages pass; Bioconductor's packages,
#      read from local indexes, and Additional_repositories are reported, and unreadable indexes too),
#      a missing, doubled, undated, mismatched, stale or future NEWS.md section,
#      naming near-miss headings and ignoring code fences, a deadline in CRAN's package database,
#      and a database that cannot be read; one failure does not hide another.
#   3. `report` never fails, and reports a failed setup step, a checked tarball that could not be taken,
#      help pages without `\value`, a stale or differently knitted README, URLs, spelling, and the problems of
#      `R CMD check`, run with CRAN's incoming checks on the tarball; a check that cannot run is reported as not run,
#      and a long report is cut to fit an environment variable; it reads nothing from GitHub.
#   4. `job-url` finds the job among the run's jobs, and falls back to the run with a notice.
#
# Usage:
#   actions/release-gate/release-gate-test.sh

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../cran-lib/test-lib.sh
. "$HERE/../cran-lib/test-lib.sh"

export TODAY=2026-11-15
SUMMARY=$SCRATCH/summary.md
PKG=$SCRATCH/pkg
STUB=$SCRATCH/stub
mkdir -p "$STUB" "$SCRATCH/bin"

# CRAN's package database: fakepkg without a deadline, and the packages the fixtures depend on, one of them with a deadline.
DB=$SCRATCH/packages.rds
db() { # <fakepkg's deadline, or empty, or `absent`>
  Rscript --vanilla -e '
    a <- commandArgs(TRUE)
    db <- data.frame(
      Package = c("other", "cli", "rlang", "Matrix", "RcppArmadillo", "cpp11", "BH", "testthat"),
      Version = c("1.0.0", "3.6.5", "1.1.6", "1.7-4", "15.0.2-2", "0.5.2", "1.87.0-1", "3.3.0"),
      Deadline = c("2026-12-01", rep(NA, 7))
    )
    if (a[[2]] != "absent") db <- rbind(db, data.frame(Package = "fakepkg", Version = "1.0.0",
      Deadline = if (nzchar(a[[2]])) a[[2]] else NA))
    saveRDS(as.matrix(db), a[[1]])
  ' "$DB" "${1:-}"
}
db ""
export CRAN_DB_URL=file://$DB

# Bioconductor's release indexes: software, annotation and experiment data, one package each.
BIOC=$SCRATCH/bioc
for r in bioc:limma data/annotation:org.Hs.eg.db data/experiment:airway; do
  mkdir -p "$BIOC/${r%%:*}/src/contrib"
  printf 'Package: %s\nVersion: 1.0.0\n\nPackage: BiocOther\nVersion: 2.0.0\n' "${r#*:}" >"$BIOC/${r%%:*}/src/contrib/PACKAGES"
done
export BIOC_URL=file://$BIOC

# Rscript answers urlchecker, spelling and the README's knit from $STUB, and runs anything else, the database read included.
REAL_RSCRIPT=$(command -v Rscript)
cat >"$SCRATCH/bin/Rscript" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *urlchecker::url_check*) cat "$STUB/urls.out"; exit "\$(cat "$STUB/urls.rc")" ;;
  *spelling::spell_check_package*) cat "$STUB/spelling.out"; exit "\$(cat "$STUB/spelling.rc")" ;;
  *rmarkdown::render*)
    echo "knit in \$PWD" >>"$STUB/knit.log"
    cp "$STUB/README.knit" README.md
    exit "\$(cat "$STUB/knit.rc")" ;;
  *) exec "$REAL_RSCRIPT" "\$@" ;;
esac
EOF
# R CMD check writes $STUB/00check.log as the check's log, and records the environment it ran in.
cat >"$SCRATCH/bin/R" <<EOF
#!/usr/bin/env bash
echo "R \$*" >"$STUB/R.args"
env | grep '^_R_CHECK_CRAN_INCOMING' | sort >"$STUB/R.env" || :
name=\$(basename "\${!#}")
mkdir -p "\${name%%_*}.Rcheck"
cp "$STUB/00check.log" "\${name%%_*}.Rcheck/00check.log"
exit "\$(cat "$STUB/check.rc")"
EOF
chmod +x "$SCRATCH/bin/Rscript" "$SCRATCH/bin/R"
export RSCRIPT=$SCRATCH/bin/Rscript R_CMD=$SCRATCH/bin/R

# A checkout: <version> <Date or empty> <NEWS.md heading line>... ; EXTRA holds more DESCRIPTION lines.
checkout() {
  local version=$1 date=$2
  shift 2
  rm -rf "$PKG"
  mkdir -p "$PKG"
  {
    echo "Package: fakepkg"
    echo "Version: $version"
    echo "Title: A Package That Is Never Released"
    [ -z "$date" ] || echo "Date: $date"
    echo "Depends: R (>= 4.1.0)"
    echo "Imports: cli (>= 3.6.0),"
    echo "    rlang"
    [ -z "${EXTRA:-}" ] || printf '%s\n' "$EXTRA"
  } >"$PKG/DESCRIPTION"
  {
    local h
    # shellcheck disable=SC2016  # the backticks are Markdown
    for h in "$@"; do printf '%s\n\n- New `foo()`.\n\n' "$h"; done
    printf '# fakepkg 0.9.0 (2026-01-02)\n\n- Old news.\n'
  } >"$PKG/NEWS.md"
}

run() {
  local rc=0 out
  : >"$SUMMARY"
  : >"$SCRATCH/output"
  rm -rf "$SCRATCH/out"
  out=$(GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY=$SUMMARY GITHUB_OUTPUT=$SCRATCH/output \
    "$HERE/release-gate.sh" "$@" 2>&1) || rc=$?
  printf '%s\nexit %s\n' "$out" "$rc"
}
hard() { run hard "$PKG" "$SCRATCH/out"; }

section "hard: a release that meets every requirement"
checkout 1.0.1 2026-11-10 "# fakepkg 1.0.1 (2026-11-10)"
out=$(hard)
has "it succeeds" "$out" "exit 0"
o=$(cat "$SCRATCH/output")
has "with the package" "$o" "package=fakepkg"
has "and the version" "$o" "version=1.0.1"
has "and the verdict" "$o" "passed=true"
has "the report says the version passed" "$o" "- ✅ **Version:** \`1.0.1\` has three components."
has "and Remotes" "$o" "- ✅ **Remotes:**"
has "and the dependencies" "$o" "- ✅ **Dependencies:**"
has "and NEWS.md, found with its date" "$o" \
  "- ✅ **NEWS.md:** one section \`# fakepkg 1.0.1 (2026-11-10)\`, dated as \`DESCRIPTION\`, 5 days ago."
has "and the deadline" "$o" "- ✅ **CRAN deadline:** CRAN set no deadline for fakepkg."
has "the report is a multi-line output" "$o" "report<<EOF_"
has "a notice says so" "$out" "::notice title=Release gate::fakepkg 1.0.1 passes every hard check."
checkout 1.0-1 2026-10-15 "# fakepkg 1.0-1 (2026-10-15)"
out=$(hard)
has "a dash separates components too, and 31 days pass" "$out" "exit 0"
checkout 1.0.1 2026-11-16 "# fakepkg 1.0.1 (2026-11-16)"
has "a day ahead passes, for the maintainer's time zone" "$(hard)" "exit 0"
db absent
checkout 1.0.1 2026-11-15 "# fakepkg 1.0.1 (2026-11-15)"
out=$(hard)
has "a package not on CRAN has no deadline" "$out" "exit 0"
has "and says so" "$(cat "$SCRATCH/output")" "fakepkg is not on CRAN, so CRAN set no deadline."
db ""

section "hard: the version"
checkout 1.0.1.9000 2026-11-15 "# fakepkg 1.0.1.9000 (2026-11-15)"
out=$(hard)
has "a development version fails" "$out" "::error title=No release version::\`DESCRIPTION\` carries \`1.0.1.9000\`"
has "with exit status 1" "$out" "exit 1"
has "and the verdict" "$(cat "$SCRATCH/output")" "passed=false"
has "the other checks still run" "$(cat "$SCRATCH/output")" "- ✅ **CRAN deadline:**"
checkout 1.0 2026-11-15 "# fakepkg 1.0 (2026-11-15)"
has "two components fail" "$(hard)" "::error title=No release version::"

section "hard: Remotes and dependencies"
EXTRA=$'Remotes:\n    r-lib/rlang' checkout 1.0.1 2026-11-15 "# fakepkg 1.0.1 (2026-11-15)"
out=$(hard)
has "a Remotes field fails" "$out" "::error title=DESCRIPTION has a Remotes field::\`Remotes: r-lib/rlang\`"
EXTRA='Remotes:' checkout 1.0.1 2026-11-15 "# fakepkg 1.0.1 (2026-11-15)"
has "an empty one too" "$(hard)" "::error title=DESCRIPTION has a Remotes field::"
deps() { # <Imports line>, then more DESCRIPTION lines
  local imports=$1
  shift
  EXTRA=$(printf '%s\n' "$@") checkout 1.0.1 2026-11-15 "# fakepkg 1.0.1 (2026-11-15)"
  sed -i "s|^    rlang\$|    rlang, $imports|" "$PKG/DESCRIPTION"
}
deps 'Matrix (>= 1.6-1.1), RcppArmadillo (>= 0.12.6.6.0), cli (== 3.6.5), stats, tools (>= 99.0.0)'
out=$(hard)
has "four components that CRAN has pass, as do an exact version and base packages" "$out" "exit 0"
has "and the report says what they are checked against" "$(cat "$SCRATCH/output")" \
  "- ✅ **Dependencies:** Depends, Imports, LinkingTo, Suggests and Enhances need nothing outside CRAN, \
checked against CRAN's package database and Bioconductor's indexes."
deps 'BH' 'LinkingTo: cpp11 (>= 0.5.2.9000), BH (>= 1.87.0-1)'
out=$(hard)
has "a version CRAN does not have yet fails" "$out" \
  "::error title=A dependency is not on CRAN::LinkingTo: \`cpp11 (>= 0.5.2.9000)\`, CRAN has 0.5.2."
hasnt "and names only that one" "$out" "BH (>="
deps 'cli (> 3.6.5), rlang (== 1.1.5), Matrix (< 99.0)'
out=$(hard)
has "> needs a higher version than CRAN's" "$out" "Imports: \`cli (> 3.6.5)\`, CRAN has 3.6.5"
has "== needs CRAN's" "$out" "Imports: \`rlang (== 1.1.5)\`, CRAN has 1.1.6"
hasnt "< is not checked" "$out" "Matrix"
deps 'cli (>= x.y)'
has "a version that is no version fails" "$(hard)" "Imports: \`cli (>= x.y)\`, no valid version"
deps 'notapkg'
has "a package in neither CRAN nor Bioconductor fails" "$(hard)" \
  "::error title=A dependency is not on CRAN::Imports: \`notapkg\`, not on CRAN or Bioconductor."
deps 'notapkg' 'biocViews:'
has "whatever biocViews says" "$(hard)" "Imports: \`notapkg\`, not on CRAN or Bioconductor."
deps 'limma' 'Suggests: org.Hs.eg.db, airway'
out=$(hard)
has "a Bioconductor package passes, without biocViews" "$out" "exit 0"
has "from each of Bioconductor's indexes, and is reported" "$(cat "$SCRATCH/output")" \
  "- ⚠️ **Dependencies:** Imports: \`limma\`, not on CRAN, on Bioconductor; Suggests: \`org.Hs.eg.db\`, not on CRAN, on Bioconductor; \
Suggests: \`airway\`, not on CRAN, on Bioconductor."
deps 'limma (>= 1.0.0)' 'Suggests: airway (>= 99.0)'
out=$(hard)
has "a Bioconductor package's constraint is checked against Bioconductor's version" "$out" \
  "::error title=A dependency is not on CRAN::Suggests: \`airway (>= 99.0)\`, Bioconductor has 1.0.0."
hasnt "one that Bioconductor meets passes" "$out" "limma (>= 1.0.0)\`, Bioconductor has"
deps 'limma'
out=$(BIOC_URL=file://$SCRATCH/nobioc hard)
has "indexes that cannot be read are reported once" "$out" \
  "::warning title=Bioconductor::Bioconductor's package indexes cannot be read, so a dependency that is not on CRAN fails: \
reading file://$SCRATCH/nobioc/bioc/src/contrib/PACKAGES failed"
is "once" "$(grep -c '^::warning title=Bioconductor::' <<<"$out")" 1
has "and a Bioconductor package then fails with that cause" "$out" \
  "Imports: \`limma\`, not on CRAN, and Bioconductor cannot be checked: reading file://$SCRATCH/nobioc/bioc/src/contrib/PACKAGES failed"
deps 'cli' 'Suggests: testthat (>= 3.3.0.9000), elsewhere'
out=$(hard)
has "Suggests is checked as well" "$out" \
  "Suggests: \`testthat (>= 3.3.0.9000)\`, CRAN has 3.3.0; Suggests: \`elsewhere\`, not on CRAN or Bioconductor."
deps 'cli' 'Enhances: elsewhere'
has "and Enhances" "$(hard)" "Enhances: \`elsewhere\`, not on CRAN or Bioconductor."
deps 'cli' 'Suggests: elsewhere' 'Enhances: another' 'Additional_repositories: https://example.org/repo'
out=$(hard)
has "a suggested or enhanced package from Additional_repositories passes" "$out" "exit 0"
o=$(cat "$SCRATCH/output")
has "and is reported" "$o" "Suggests: \`elsewhere\`, not on CRAN or Bioconductor, to come from \`Additional_repositories\`"
has "both" "$o" "Enhances: \`another\`, not on CRAN or Bioconductor, to come from \`Additional_repositories\`"
has "as is the field itself" "$o" \
  "- ⚠️ **Additional repositories:** \`Additional_repositories: https://example.org/repo\`: CRAN accepts it"
has "with a warning in the run" "$out" "::warning title=Additional repositories::"
deps 'elsewhere' 'Additional_repositories: https://example.org/repo'
has "an import from Additional_repositories still fails" "$(hard)" "Imports: \`elsewhere\`, not on CRAN or Bioconductor."
deps 'github::r-lib/rlang, owner/pkg@v1'
out=$(hard)
has "a source outside CRAN fails" "$out" \
  "Imports: \`github::r-lib/rlang\`, a source outside CRAN; Imports: \`owner/pkg@v1\`, a source outside CRAN"
EXTRA='Suggests: r-lib/testthat' checkout 1.0.1 2026-11-15 "# fakepkg 1.0.1 (2026-11-15)"
has "in Suggests too" "$(hard)" "Suggests: \`r-lib/testthat\`, a source outside CRAN"

section "hard: NEWS.md"
checkout 1.0.1 2026-11-15 "## fakepkg 1.0.1 (2026-11-15)" "# fakepkg v1.0.1" "# fakepkg  1.0.1" \
  "# fakepkg 1.0.1 (2026-11-15) beta" "# fakepkg 1.0.10"
out=$(hard)
has "without a section, the headings that mention the version are named" "$out" \
  "::error title=No NEWS.md section for fakepkg 1.0.1::\`NEWS.md\` has no section headed \`# fakepkg 1.0.1\`, \
only headings that mention the version: \
\`## fakepkg 1.0.1 (2026-11-15)\`; \`# fakepkg v1.0.1\`; \`# fakepkg  1.0.1\`; \`# fakepkg 1.0.1 (2026-11-15) beta\`."
hasnt "but not another version" "$out" "1.0.10\`"
checkout 1.0.1 2026-11-15 "# fakepkg 1.0.1 (2026-11-15)"
# shellcheck disable=SC2016  # a Markdown code fence
printf '```\n# fakepkg 1.0.1 (2026-11-15)\n```\n' >>"$PKG/NEWS.md"
has "a heading inside a code fence is not one" "$(hard)" "exit 0"
checkout 1.0.1 2026-11-15 "# fakepkg 1.0.1"
has "a heading without a date fails" "$(hard)" "::error title=The NEWS.md heading has no date::"
checkout 1.0.1 2026-11-14 "# fakepkg 1.0.1 (2026-11-15)"
has "dates that differ fail" "$(hard)" "::error title=The dates differ::"
checkout 1.0.1 "" "# fakepkg 1.0.1 (2026-11-15)"
has "a missing Date fails as differing" "$(hard)" "::error title=The dates differ::"
checkout 1.0.1 2026-11-15 "# fakepkg 1.0.2 (2026-11-15)"
has "a missing section fails" "$(hard)" "::error title=No single NEWS.md section for fakepkg 1.0.1::"
checkout 1.0.1 2026-11-15 "# fakepkg 1.0.1 (2026-11-15)" "# fakepkg 1.0.1"
has "a doubled section fails, with a date or without" "$(hard)" "has 2 sections headed"
checkout 1.0.1 2026-11-15 "# fakepkg 1.0.10 (2026-11-15)" "# fakepkg 1.0.1 (2026-11-15)"
has "a version that only starts the same is another" "$(hard)" "exit 0"
checkout 1.0.1 2026-10-14 "# fakepkg 1.0.1 (2026-10-14)"
out=$(hard)
has "32 days are stale" "$out" "::error title=The date is stale::The release is dated \`2026-10-14\`, 32 days before today"
checkout 1.0.1 2026-11-17 "# fakepkg 1.0.1 (2026-11-17)"
has "two days ahead are in the future" "$(hard)" "::error title=The date is in the future::"
checkout 1.0.1 2026-02-30 "# fakepkg 1.0.1 (2026-02-30)"
has "a date that is no date fails" "$(hard)" "::error title=The date is no date::"
rm "$PKG/NEWS.md"
has "no NEWS.md fails" "$(hard)" "::error title=No NEWS.md::"

section "hard: CRAN's deadline"
db 2026-12-01
checkout 1.0.1 2026-11-15 "# fakepkg 1.0.1 (2026-11-15)"
out=$(hard)
has "a deadline fails" "$out" "::error title=CRAN set a deadline::CRAN's package database gives fakepkg the deadline \`2026-12-01\`"
has "pointing at the check results" "$out" "check_results_fakepkg.html"
db ""
out=$(CRAN_DB_URL=file://$SCRATCH/missing.rds hard)
has "a database that cannot be downloaded fails" "$out" "::error title=CRAN's package database cannot be read::Reading file://"
is "once, and nothing else fails" "$(grep -c '^::error' <<<"$out")" 1
has "the dependencies are checked for sources outside CRAN only" "$(cat "$SCRATCH/output")" \
  "checked for sources outside CRAN only, as CRAN's package database cannot be read."
echo "not an rds" >"$SCRATCH/bad.rds"
out=$(CRAN_DB_URL=file://$SCRATCH/bad.rds hard)
has "and one that R cannot read" "$out" \
  "::error title=CRAN's package database cannot be read::Reading the downloaded database with R failed"
has "which the dependencies report too" "$out" \
  "::error title=The dependencies cannot be checked against CRAN::Reading CRAN's package database with R failed"
deps 'owner/pkg'
out=$(CRAN_DB_URL=file://$SCRATCH/bad.rds hard)
is "with a source outside CRAN as well, the dependencies fail once" \
  "$(grep -c '^::error title=.*dependencies\|^::error title=A dependency' <<<"$out")" 1
has "naming both causes" "$out" \
  "::error title=The dependencies cannot be checked against CRAN::Imports: \`owner/pkg\`, a source outside CRAN. \
Reading CRAN's package database"

section "hard: one failure does not hide another"
db 2026-12-01
EXTRA='Remotes: r-lib/rlang' checkout 1.0.1.9000 2026-10-01 "# fakepkg 1.0.1.9000 (2026-10-01)"
out=$(hard)
is "four checks fail, each with its own error" "$(grep -c '^::error' <<<"$out")" 4
has "and the log names them" "$out" "4 hard checks failed: Version Remotes NEWS.md CRAN deadline."
has "the summary too" "$(cat "$SUMMARY")" "**Not ready:** Version, Remotes, NEWS.md, CRAN deadline failed."
db ""

section "hard: usage"
mkdir -p "$SCRATCH/empty"
has "a checkout without DESCRIPTION fails" "$(run hard "$SCRATCH/empty" "$SCRATCH/out")" "::error title=No DESCRIPTION::"
has "a missing argument is a usage error" "$(run hard "$PKG")" "exit 2"

section "report: everything clean"
# A clean stub state: no finding anywhere.
clean_stubs() {
  : >"$STUB/urls.out"
  echo 0 >"$STUB/urls.rc"
  : >"$STUB/spelling.out"
  echo 0 >"$STUB/spelling.rc"
  echo 0 >"$STUB/knit.rc"
  echo 0 >"$STUB/check.rc"
  : >"$STUB/knit.log"
  printf '* using log directory\n* checking CRAN incoming feasibility ... [3s/9s] OK\n* DONE\nStatus: OK\n' >"$STUB/00check.log"
}
clean_stubs
checkout 1.0.1 2026-11-15 "# fakepkg 1.0.1 (2026-11-15)"
mkdir -p "$PKG/man"
printf '\\name{foo}\n\\usage{foo()}\n\\value{A number.}\n' >"$PKG/man/foo.Rd"
printf '\\name{data1}\n\\docType{data}\n\\usage{data1}\n' >"$PKG/man/data1.Rd"
printf '\\name{fakepkg}\n\\docType{package}\n' >"$PKG/man/fakepkg-package.Rd"
printf 'The README.\n' >"$PKG/README.md"
cp "$PKG/README.md" "$STUB/README.knit"
printf -- '---\noutput: github_document\n---\n\nThe README.\n' >"$PKG/README.Rmd"
git -C "$PKG" init -q
git -C "$PKG" add README.md README.Rmd
GIT_COMMITTER_DATE=2026-11-01T00:00:00Z git -C "$PKG" -c user.name=t -c user.email=t@example.org commit -q -m readme
touch "$SCRATCH/fakepkg_1.0.1.tar.gz"
out=$(run report "$PKG" "$SCRATCH/out" "$SCRATCH/fakepkg_1.0.1.tar.gz")
has "it succeeds" "$out" "exit 0"
o=$(cat "$SCRATCH/output")
has "help pages, without data and the package's page" "$o" \
  "- ✅ **Help pages:** every page with a \`\\usage\` section has a \`\\value\` section."
has "the README" "$o" "- ✅ **README:** \`README.md\` is what \`README.Rmd\` knits to."
has "knitted in a copy" "$(cat "$STUB/knit.log")" "knit in $SCRATCH/out/knit"
has "URLs" "$o" "- ✅ **URLs:** urlchecker flags none."
has "spelling" "$o" "- ✅ **Spelling:** spelling flags no word."
has "R CMD check" "$o" "- ✅ **R CMD check:** \`fakepkg_1.0.1.tar.gz\`: OK with CRAN's incoming checks."
is "on the tarball, as CRAN does" "$(cat "$STUB/R.args")" "R CMD check --as-cran --no-manual $SCRATCH/fakepkg_1.0.1.tar.gz"
is "with the incoming checks, remote ones included, and the dates not skipped" "$(cat "$STUB/R.env")" \
  "_R_CHECK_CRAN_INCOMING_=true
_R_CHECK_CRAN_INCOMING_REMOTE_=true"
out=$(_R_CHECK_CRAN_INCOMING_SKIP_DATES_=true run report "$PKG" "$SCRATCH/out" "$SCRATCH/fakepkg_1.0.1.tar.gz")
hasnt "a caller's setting does not skip the dates" "$(cat "$STUB/R.env")" "SKIP_DATES"

section "report: findings, which never fail"
printf '\\name{bar}\n\\usage{bar()}\n' >"$PKG/man/bar.Rd"
printf '  URL  Status Message\n1 https://example.org/gone 404 Not Found\n' >"$STUB/urls.out"
echo 3 >"$STUB/urls.rc"
printf '  WORD  FOUND IN\nteh   foo.Rd:3\n' >"$STUB/spelling.out"
echo 3 >"$STUB/spelling.rc"
printf 'Another README.\n' >"$STUB/README.knit"
cat >"$STUB/00check.log" <<'LOG'
* using log directory
* checking CRAN incoming feasibility ... [3s/9s] NOTE
Maintainer: 'A <a@example.org>'
New submission
* checking for code/documentation mismatches ... OK
* checking examples ... WARNING
Found the following significant warnings:
  warning in foo()
* DONE
Status: 1 WARNING, 1 NOTE
LOG
echo 1 >"$STUB/check.rc"
out=$(run report "$PKG" "$SCRATCH/out" "$SCRATCH/fakepkg_1.0.1.tar.gz")
has "it succeeds" "$out" "exit 0"
o=$(cat "$SCRATCH/output")
has "a page without \\value is reported" "$o" "- ⚠️ **Help pages:** 1 pages with a \`\\usage\` section lack a \`\\value\` section"
has "and named" "$o" "bar.Rd"
has "with a warning in the run" "$out" "::warning title=Help pages::"
has "a different knit is reported" "$o" "- ⚠️ **README:** knitting \`README.Rmd\` gives another \`README.md\`"
has "with the difference" "$o" "+Another README."
is "the checkout's README.md is left alone" "$(cat "$PKG/README.md")" "The README."
has "URLs are reported" "$o" "- ⚠️ **URLs:** urlchecker flags URLs"
has "with urlchecker's answer" "$o" "https://example.org/gone 404 Not Found"
has "spelling is reported" "$o" "- ⚠️ **Spelling:** spelling flags words"
has "with the words" "$o" "teh   foo.Rd:3"
has "R CMD check's status is reported" "$o" "- ⚠️ **R CMD check:** \`fakepkg_1.0.1.tar.gz\`: 1 WARNING, 1 NOTE."
has "with the checks that did not pass" "$o" "* checking CRAN incoming feasibility ... [3s/9s] NOTE
Maintainer: 'A <a@example.org>'
New submission
* checking examples ... WARNING"
hasnt "and not those that did" "$o" "code/documentation mismatches"
has "details are in a block three backticks cannot close" "$o" '````text'
{ printf 'https://example.org/%0400d\n' 0; seq 70; } >"$STUB/urls.out"
out=$(run report "$PKG" "$SCRATCH/out" "$SCRATCH/fakepkg_1.0.1.tar.gz")
o=$(cat "$SCRATCH/output")
has "a long line is cut" "$o" "$(printf 'https://example.org/%0280d [...]' 0)"
has "and a long text after 60 lines" "$o" "[11 more lines]"
hasnt "the rest is gone" "$o" $'\n60\n'
# Four long reports of 60 lines of 300 characters each are more than the 60000 bytes the report may take.
long() { for i in $(seq 70); do printf "%s %0300d\n" "$1" "$i"; done; }
long url >"$STUB/urls.out"
long word >"$STUB/spelling.out"
{ long knit; } >"$STUB/README.knit"
{ echo "* checking examples ... ERROR"; long check; echo "Status: 1 ERROR"; } >"$STUB/00check.log"
for f in urls spelling; do echo 3 >"$STUB/$f.rc"; done
out=$(run report "$PKG" "$SCRATCH/out" "$SCRATCH/fakepkg_1.0.1.tar.gz")
o=$(cat "$SCRATCH/output")
has "a long report is cut" "$o" "[Cut to fit: the run's summary page has the rest.]"
has "closing its blocks" "$o" "$(printf '[Cut to fit: the run'"'"'s summary page has the rest.]\n\n</details>')"
is "and stays far below the 128 KiB of an environment variable" "$(($(wc -c <"$SCRATCH/output") < 61000))" 1

section "report: a README.Rmd committed after README.md"
printf -- '---\noutput: github_document\n---\n\nThe new README.\n' >"$PKG/README.Rmd"
git -C "$PKG" add README.Rmd
GIT_COMMITTER_DATE=2026-11-02T00:00:00Z git -C "$PKG" -c user.name=t -c user.email=t@example.org commit -q -m rmd
: >"$STUB/knit.log"
out=$(run report "$PKG" "$SCRATCH/out")
has "is reported" "$(cat "$SCRATCH/output")" "- ⚠️ **README:** \`README.Rmd\` was committed after \`README.md\`: knit it again."
is "without a knit" "$(cat "$STUB/knit.log")" ""
rm -rf "$PKG/.git"

section "report: checks that cannot run"
echo 1 >"$STUB/urls.rc"
echo "Error in loadNamespace(x) : there is no package called 'urlchecker'" >"$STUB/urls.out"
echo 1 >"$STUB/spelling.rc"
echo 1 >"$STUB/knit.rc"
out=$(run report "$PKG" "$SCRATCH/out")
has "it still succeeds" "$out" "exit 0"
o=$(cat "$SCRATCH/output")
has "a failed knit is not run" "$o" "- ⏭️ **README:** not run: knitting \`README.Rmd\` failed with status 1."
has "urlchecker's failure" "$o" "- ⏭️ **URLs:** not run: urlchecker failed with status 1."
has "with its error" "$o" "there is no package called 'urlchecker'"
has "spelling's" "$o" "- ⏭️ **Spelling:** not run: spelling failed with status 1."
has "no tarball skips R CMD check" "$o" "- ⏭️ **R CMD check:** not run: no checked tarball of this commit"
has "with a warning in the run" "$out" "::warning title=R CMD check not run::"
out=$(run report "$PKG" "$SCRATCH/out" "$SCRATCH/none_1.0.1.tar.gz")
has "a missing tarball is not run" "$(cat "$SCRATCH/output")" "not run: the tarball"
RUN_ENV=(GITHUB_SERVER_URL=https://github.example GITHUB_REPOSITORY=owner/fakepkg GITHUB_RUN_ID=99 GITHUB_RUN_ATTEMPT=2)
out=$(export "${RUN_ENV[@]}"; SETUP=$'pandoc=success\ndependencies=failure' TARBALL_OUTCOME=failure \
  run report "$PKG" "$SCRATCH/out")
o=$(cat "$SCRATCH/output")
has "naming the step and pointing at its error" "$o" \
  "- ⏭️ **Setup: dependencies:** not run: the job's step that sets up \`dependencies\` ended with \`failure\`; \
its error in https://github.example/owner/fakepkg/actions/runs/99 names the cause"
hasnt "a successful one is not" "$o" "Setup: pandoc"
has "a failed tarball step without a cause is not reported as a missing tarball" "$o" \
  "- ⏭️ **R CMD check:** not run: taking the checked tarball failed, and its step wrote no cause; \
its error in https://github.example/owner/fakepkg/actions/runs/99 names it."
hasnt "which it is not" "$o" "no checked tarball of this commit"
# The step's failure, written by cran-lib's `fail` with FAILURE_FILE, and this job among the run's jobs.
FAILURE_FILE=$SCRATCH/tarball-failure bash -c '. "$1/../cran-lib/cran-lib.sh"; fail "Tarball" "The check run is not green" \
  "Run 7 of R-CMD-check.yaml concluded failure." -- "Fix it."' _ "$HERE" >/dev/null 2>&1 || :
gh_stub
answer "repos/owner/fakepkg/actions/runs/99/attempts/2/jobs?per_page=100" '{"jobs": [
  {"name": "gate / Enforce what CRAN requires", "html_url": "https://github.example/owner/fakepkg/actions/runs/99/job/1"},
  {"name": "gate / Report on what CRAN expects", "html_url": "https://github.example/owner/fakepkg/actions/runs/99/job/2"}]}'
out=$(export "${RUN_ENV[@]}"; JOB_NAME='Report on what CRAN expects' run job-url)
has "job-url finds the job under the caller's prefix" "$out" "exit 0"
is "and writes its URL" "$(cat "$SCRATCH/output")" "job-url=https://github.example/owner/fakepkg/actions/runs/99/job/2"
out=$(export "${RUN_ENV[@]}"; JOB_NAME='Another job' run job-url)
is "a name that matches no job links the run" "$(cat "$SCRATCH/output")" "job-url=https://github.example/owner/fakepkg/actions/runs/99"
has "with a notice" "$out" "::notice title=Job URL::No job of the run is named 'Another job'; the report links the run."
out=$(export "${RUN_ENV[@]}" GITHUB_RUN_ATTEMPT=3; JOB_NAME='Report on what CRAN expects' run job-url)
is "jobs that cannot be read link the run" "$(cat "$SCRATCH/output")" "job-url=https://github.example/owner/fakepkg/actions/runs/99"
has "with GitHub's error in a notice" "$out" "::notice title=Job URL::The run's jobs cannot be read (gh: Not Found (HTTP 404))"
: >"$SCRATCH/gh.log"
out=$(export "${RUN_ENV[@]}"; SETUP='dependencies=success' TARBALL_OUTCOME=failure TARBALL_FAILURE_FILE=$SCRATCH/tarball-failure \
  JOB_URL=https://github.example/owner/fakepkg/actions/runs/99/job/2 GH_TOKEN=secret \
  run report "$PKG" "$SCRATCH/out" "$SCRATCH/fakepkg_1.0.1.tar.gz")
has "the step's failure is quoted, linking the job given" "$(cat "$SCRATCH/output")" \
  "- ⏭️ **R CMD check:** not run: taking the checked tarball failed: The check run is not green: \
Run 7 of R-CMD-check.yaml concluded failure. (see https://github.example/owner/fakepkg/actions/runs/99/job/2)."
is "report reads nothing from GitHub" "$(cat "$SCRATCH/gh.log")" ""
out=$(export "${RUN_ENV[@]}"; SETUP='dependencies=failure' TARBALL_OUTCOME=success \
  run report "$PKG" "$SCRATCH/out" "$SCRATCH/fakepkg_1.0.1.tar.gz")
has "without the dependencies, R CMD check is not run" "$(cat "$SCRATCH/output")" \
  "- ⏭️ **R CMD check:** not run: the package's dependencies could not be installed, so its check would fail on them."
out=$(export "${RUN_ENV[@]}"; SETUP='pandoc=failure' run report "$PKG" "$SCRATCH/out")
has "without a job's URL, report links the run" "$(cat "$SCRATCH/output")" \
  "its error in https://github.example/owner/fakepkg/actions/runs/99 names the cause"
out=$(TARBALL_OUTCOME=skipped run report "$PKG" "$SCRATCH/out")
has "nor a skipped one" "$(cat "$SCRATCH/output")" "the step that takes the checked tarball ended with \`skipped\`."
rm "$STUB/00check.log"
out=$(run report "$PKG" "$SCRATCH/out" "$SCRATCH/fakepkg_1.0.1.tar.gz")
has "a check that writes no log is not run" "$(cat "$SCRATCH/output")" \
  "- ⏭️ **R CMD check:** not run: \`R CMD check\` wrote no log, and exited with status 1."
rm -rf "$PKG/man" "$PKG/README.Rmd"
clean_stubs
out=$(run report "$PKG" "$SCRATCH/out")
o=$(cat "$SCRATCH/output")
has "a package without help pages has nothing to report" "$o" "- ✅ **Help pages:** there is no \`man/*.Rd\`."
has "nor one without README.Rmd" "$o" "- ✅ **README:** there is no \`README.Rmd\`."

done_testing
