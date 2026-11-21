#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Check cran-lib.sh offline: the escaping of workflow commands, the failure report, the outputs, and the validators.
#
# Usage:
#   actions/cran-lib/cran-lib-test.sh

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.sh
. "$HERE/test-lib.sh"
# shellcheck source=cran-lib.sh
. "$HERE/cran-lib.sh"

section "workflow commands escape their values"
is "data escapes %, CR and LF" "$(esc_data $'50% a\r\nb')" "50%25 a%0D%0Ab"
is "properties also escape : and ," "$(esc_prop 'a: b, c')" "a%3A b%2C c"
is "outside Actions, a notice is a plain line" "$(GITHUB_ACTIONS='' notice T m)" "NOTICE: T: m"
is "inside, a workflow command" "$(GITHUB_ACTIONS=true notice 'T: x' 'm%')" "::notice title=T%3A x::m%25"

section "a failure annotates, reports and advises"
export GITHUB_STEP_SUMMARY=$SCRATCH/summary.md
printf 'line one\n' >"$SCRATCH/excerpt"
out=$( (GITHUB_ACTIONS=true fail "Stage" "Title" "Message" "$SCRATCH/excerpt" -- "First." "Second.") 2>&1) && rc=0 || rc=$?
is "it exits 1" "$rc" 1
has "with an error annotation" "$out" "::error title=Title::Message"
has "and the advice on stderr" "$out" "  - First."
s=$(cat "$GITHUB_STEP_SUMMARY")
has "the summary names the stage" "$s" "### Stage: failed"
has "with the excerpt" "$s" "line one"
has "and the advice" "$s" "- Second."
has "and the process" "$s" "- The release process: https://github.com/krlmlr/r-release-actions#readme"
(FAILURE_FILE=$SCRATCH/failure fail "Stage" "Title" $'Two\nlines' -- "Advice.") >/dev/null 2>&1 || :
is "with FAILURE_FILE, the title and message go there as one line" "$(cat "$SCRATCH/failure")" "Title: Two lines"
unset GITHUB_STEP_SUMMARY

section "outputs and fields"
export GITHUB_OUTPUT=$SCRATCH/output
output a 1 b "two words"
is "outputs are name=value lines" "$(cat "$GITHUB_OUTPUT")" "a=1
b=two words"
unset GITHUB_OUTPUT
printf 'Package: p\nDescription: one\n    two\nVersion: 1.0\n' >"$SCRATCH/DESCRIPTION"
is "a field with a continuation line is folded" "$(dcf_field Description "$SCRATCH/DESCRIPTION")" "one two"
printf 'Package: p \r\nMaintainer: Jane Doe\r\n    <jane@example.org>\t\r\nDate: 2026-11-15\r\n' >"$SCRATCH/DESCRIPTION.crlf"
is "trailing whitespace and CR are dropped" "$(dcf_field Package "$SCRATCH/DESCRIPTION.crlf")" "p"
is "also on a continuation line" "$(dcf_field Maintainer "$SCRATCH/DESCRIPTION.crlf")" "Jane Doe <jane@example.org>"
is "and on the last field" "$(dcf_field Date "$SCRATCH/DESCRIPTION.crlf")" "2026-11-15"
is "a missing field is empty" "$(dcf_field Date "$SCRATCH/DESCRIPTION")" ""

section "validators"
succeeds "RSQLite is a package name" valid_package RSQLite
succeeds "data.table is one" valid_package data.table
fails "a quote is not" valid_package 'x"; rm'
succeeds "1.2.3 is a version" valid_version 1.2.3
fails "a quote is not" valid_version '1.2.3"'
succeeds "a full SHA is one" valid_sha 0123456789abcdef0123456789abcdef01234567
fails "a short one is not" valid_sha 0123456789

section "counting lines"
is "no input is zero lines, not a failure" "$(count_lines '')" 0
is "a last line without a newline counts" "$(count_lines $'a\nb')" 2
is "with one, too" "$(count_lines $'a\nb\n')" 2
is "blank lines do not count" "$(count_lines $'a\n\n  \nb')" 2

done_testing
