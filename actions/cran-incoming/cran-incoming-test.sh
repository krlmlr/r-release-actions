#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Check cran-incoming.sh offline, against a fake incoming folder served on 127.0.0.1: nothing reaches CRAN.
#
#   1. An empty queue, or one holding only other packages, passes.
#   2. A submission in a queue folder, or in a folder inside one, fails a real run and warns on a dry run.
#   3. `archive/`, which holds rejected submissions, is skipped.
#   4. A package whose name only starts the same is another package.
#   5. A queue that cannot be read fails.
#
# Usage:
#   actions/cran-incoming/cran-incoming-test.sh

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../cran-lib/test-lib.sh
. "$HERE/../cran-lib/test-lib.sh"

SRV=$SCRATCH/srv
mkdir -p "$SRV/incoming"/{pretest,waiting,archive,special/check1,inspect}
touch "$SRV/incoming/pretest/otherpkg_1.0.tar.gz" "$SRV/incoming/archive/fakepkg_1.0.0.tar.gz"
python3 -I -u -m http.server --bind 127.0.0.1 --directory "$SRV" 0 >"$SCRATCH/server.log" 2>&1 &
# shellcheck disable=SC2034  # read at exit, through CLEANUP
SERVER_PID=$!
# shellcheck disable=SC2016  # evaluated at exit
CLEANUP+=('kill "$SERVER_PID" 2>/dev/null')
PORT=
for _ in $(seq 100); do
  PORT=$(sed -n 's/.*port \([0-9]*\).*/\1/p' "$SCRATCH/server.log" | head -n 1)
  [ -z "$PORT" ] || break
  sleep 0.1
done
[ -n "$PORT" ] || {
  echo "the fake incoming folder did not start" >&2
  exit 1
}
export no_proxy=127.0.0.1 NO_PROXY=127.0.0.1
export CRAN_INCOMING_URL=http://127.0.0.1:$PORT/incoming/
SUMMARY=$SCRATCH/summary.md

run() {
  local rc=0 out
  : >"$SUMMARY"
  out=$(GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY=$SUMMARY "$HERE/cran-incoming.sh" "$@" 2>&1) || rc=$?
  printf '%s\nexit %s\n' "$out" "$rc"
}

section "a queue without the package"
out=$(run fakepkg)
has "passes" "$out" "exit 0"
has "after reading every folder but archive" "$(cat "$SUMMARY")" "No submission of fakepkg in 4 folders"

section "a queued submission"
touch "$SRV/incoming/waiting/fakepkg_1.0.1.tar.gz"
out=$(run fakepkg)
has "fails a real run" "$out" "::error title=fakepkg is in CRAN's incoming queue::"
has "naming the folder" "$out" "waiting/fakepkg_1.0.1.tar.gz"
out=$(DRY_RUN=true run fakepkg)
has "warns on a dry run" "$out" "::warning title=In CRAN's incoming queue::"
has "which passes" "$out" "exit 0"
rm "$SRV/incoming/waiting/fakepkg_1.0.1.tar.gz"
touch "$SRV/incoming/special/check1/fakepkg_1.0.1.tar.gz"
out=$(run fakepkg)
has "a folder inside a queue folder counts" "$out" "special/check1/fakepkg_1.0.1.tar.gz"
rm "$SRV/incoming/special/check1/fakepkg_1.0.1.tar.gz"

section "names"
touch "$SRV/incoming/inspect/fakepkg2_1.0.tar.gz"
out=$(run fakepkg)
has "a package whose name only starts the same is another" "$out" "exit 0"
out=$(run 'fake;pkg')
has "a name that is none is a usage error" "$out" "exit 2"

section "an unreadable queue"
out=$(CRAN_INCOMING_URL=http://127.0.0.1:1/incoming/ run fakepkg)
has "fails" "$out" "::error title=CRAN's incoming queue cannot be read::"

done_testing
