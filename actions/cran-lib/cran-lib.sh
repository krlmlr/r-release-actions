#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Adapted from duckdb/duckdb-r's scripts/cran-lib.sh at ca768a9 (MIT).
# Shared helpers for the scripts of the release actions: the log, the annotations, the step summary.
#
# Sourced, not run. The log folds each stage into a group and annotates outcomes
# when GITHUB_ACTIONS is true, and prints plain lines otherwise.
# The report goes to GITHUB_STEP_SUMMARY when that is set, and nowhere otherwise;
# the advice on a failure goes to stderr either way.
# A commit is linked when GITHUB_REPOSITORY is set, with GITHUB_SERVER_URL defaulting to github.com.

process_url=https://github.com/krlmlr/r-release-actions#readme

# --- output ---------------------------------------------------------------

in_actions() { [ "${GITHUB_ACTIONS:-}" = true ]; }

# Workflow command values escape %, CR and LF; properties also escape : and ,.
esc_data() {
  local s=${1//%/%25}
  s=${s//$'\r'/%0D}
  printf '%s' "${s//$'\n'/%0A}"
}
esc_prop() {
  local s
  s=$(esc_data "$1")
  s=${s//:/%3A}
  printf '%s' "${s//,/%2C}"
}

open_group=
group() {
  endgroup
  if in_actions; then echo "::group::$(esc_data "$1")"; else printf '\n== %s\n' "$1"; fi
  open_group=1
}
endgroup() {
  [ -n "$open_group" ] || return 0
  open_group=
  if in_actions; then echo "::endgroup::"; fi
}

say() { printf '%s\n' "$@"; }
# A value the stage uses, printed as `name: value`.
val() { printf '  %-20s %s\n' "$1:" "$2"; }

notice() { # <title> <message>
  if in_actions; then
    echo "::notice title=$(esc_prop "$1")::$(esc_data "$2")"
  else
    printf 'NOTICE: %s: %s\n' "$1" "$2"
  fi
}
warn() { # <title> <message>
  if in_actions; then
    echo "::warning title=$(esc_prop "$1")::$(esc_data "$2")"
  else
    printf 'WARNING: %s: %s\n' "$1" "$2" >&2
  fi
}

summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"
}

# Report a failed stage: close the group, annotate, write the report, advise.
#   failure <stage> <title> <message> [<excerpt file>] -- <how-to-resolve bullet>...
failure() {
  local stage=$1 title=$2 message=$3 excerpt=
  shift 3
  if [ "${1:-}" != -- ]; then
    excerpt=$1
    shift
  fi
  shift
  endgroup
  if in_actions; then
    echo "::error title=$(esc_prop "$title")::$(esc_data "$message")"
  else
    printf 'ERROR: %s: %s\n' "$title" "$message" >&2
  fi
  {
    echo
    echo "How to resolve:"
    printf '  - %s\n' "$@"
    echo "  (the release process: $process_url)"
  } >&2
  summary "" "### $stage: failed" "" "**$title.** $message" ""
  if [ -n "$excerpt" ] && [ -s "$excerpt" ]; then
    summary "<details><summary>Details</summary>" "" '```text' "$(cat "$excerpt")" '```' "" "</details>" ""
  fi
  summary "#### How to resolve" ""
  local b
  for b in "$@"; do summary "- $b"; done
  summary "- The release process: $process_url" ""
}

# Report a failed stage as failure() does, and exit 1.
fail() {
  failure "$@"
  exit 1
}

# A commit as Markdown: linked in CI, where GITHUB_REPOSITORY names the repository.
commit_link() { # <sha>
  if [ -n "${GITHUB_REPOSITORY:-}" ]; then
    printf '%s' "[\`${1:0:10}\`](${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/commit/$1)"
  else
    printf '%s' "\`${1:0:10}\`"
  fi
}

# Write `name=value` lines to GITHUB_OUTPUT when it is set; values must be single lines.
output() { # <name> <value> [<name> <value>]...
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  while [ $# -ge 2 ]; do
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
    shift 2
  done
}

# One field of a DCF file, continuation lines folded into one.
dcf_field() { # <field> <file>
  awk -v f="$1" '
    found && /^[ \t]/ { sub(/^[ \t]+/, " "); v = v $0; next }
    found { exit }
    index($0, f ":") == 1 { found = 1; v = substr($0, length(f) + 2); sub(/^[ \t]+/, "", v) }
    END { if (found) print v }' "$2"
}

sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# A package name and a release version as CRAN accepts them, checked before either reaches a URL, a jq program or a marker.
valid_package() { [[ $1 =~ ^[A-Za-z][A-Za-z0-9.]*[A-Za-z0-9]$ ]]; }
valid_version() { [[ $1 =~ ^[0-9]+[.-][0-9]+([.-][0-9]+)*$ ]]; }
valid_sha() { [[ $1 =~ ^[0-9a-f]{40}$ ]]; }
