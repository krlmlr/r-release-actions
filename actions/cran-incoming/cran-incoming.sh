#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Refuse while CRAN's incoming queue still holds a submission of the package, which CRAN's policy forbids.
#
# Reads the directory listings under CRAN's incoming folder, two levels deep
# (the queue's folders, and the folders inside them such as `special/<check>`),
# and looks for a file named `<package>_*.tar.gz`.
# `archive/`, which holds rejected submissions, is not part of the queue and is skipped.
# A listing that cannot be read fails the run, because the queue's state is then unknown.
# Whether an upload whose confirmation link was never followed shows in the queue is not known.
#
# Usage:
#   cran-incoming.sh <package>
#
# Environment:
#   CRAN_INCOMING_URL    default https://cran.r-project.org/incoming/; cran-incoming-test.sh points it at a local server
#   DRY_RUN              `true` turns a queued submission into a warning
#   GITHUB_STEP_SUMMARY, GITHUB_ACTIONS
#
# Exit status: 0 when the queue holds no submission of the package, 1 otherwise, 2 on a usage error.

set -euo pipefail

# shellcheck source=../cran-lib/cran-lib.sh
. "$(dirname "$0")/../cran-lib/cran-lib.sh"

{ [ $# -eq 1 ] && valid_package "$1"; } || {
  sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}
pkg=$1
base=${CRAN_INCOMING_URL:-https://cran.r-project.org/incoming/}
base=${base%/}/
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The relative links of a listing: subfolders end in `/`; sort links, parents and absolute links are dropped.
links() { # <html file>
  grep -o 'href="[^"]*"' "$1" | sed 's/^href="//; s/"$//' | grep -v -e '^[/?#]' -e '^\.\.' -e '://' || true
}
listing() { # <url> <file>
  curl --silent --show-error --fail --location --connect-timeout 30 --max-time 120 --output "$2" "$1" 2>"$work/err" ||
    fail "Incoming" "CRAN's incoming queue cannot be read" "Reading $1 failed: $(head -n 1 "$work/err")" "$work/err" -- \
      "Check CRAN's status, then dispatch the submission again; nothing was drafted or uploaded."
}

summary "## CRAN's incoming queue" ""
group "Incoming: $base"
val "package" "$pkg"
listing "$base" "$work/top.html"
found=()
scan() { # <url> <depth>
  local url=$1 depth=$2 file l
  file=$work/$(printf '%s' "$url" | md5sum | cut -c1-12).html
  listing "$url" "$file"
  while IFS= read -r l; do
    case "$l" in
      archive/) ;;
      */) [ "$depth" -ge 2 ] || scan "$url$l" $((depth + 1)) ;;
      "${pkg}"_*.tar.gz) found+=("${url#"$base"}$l") ;;
    esac
  done < <(links "$file")
}
scan "$base" 0
n=0
while IFS= read -r l; do
  case "$l" in */) [ "$l" = archive/ ] || n=$((n + 1)) ;; esac
done < <(links "$work/top.html")
val "folders" "$n"
endgroup

if [ ${#found[@]} -gt 0 ]; then
  printf '%s\n' "${found[@]}" >"$work/found"
  if [ "${DRY_RUN:-false}" = true ]; then
    warn "In CRAN's incoming queue" "CRAN's incoming queue holds $(paste -s -d ' ' "$work/found"); a real run refuses to submit."
    summary "- **Queued:** \`$(paste -s -d ' ' "$work/found")\`; a real run refuses to submit while it is there." ""
    exit 0
  fi
  fail "Incoming" "$pkg is in CRAN's incoming queue" \
    "CRAN's incoming queue holds $(paste -s -d ' ' "$work/found"), and CRAN's policy forbids a submission while an earlier one is pending. Nothing was drafted or uploaded." \
    "$work/found" -- \
    "Wait until CRAN has decided on the earlier submission, then dispatch the submission again." \
    "If CRAN waits for an answer from the maintainer, the folder \`waiting/\` says so; reply to CRAN's email first."
fi
summary "- No submission of $pkg in $n folders of $base (\`archive/\` skipped)." ""
notice "CRAN's incoming queue" "No submission of $pkg is queued."
