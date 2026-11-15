#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Adapted from duckdb/duckdb-r's scripts/cran-submit-test.sh at ca768a9 (MIT).
# Shared helpers for the offline tests beside the actions: assertions, a scratch directory, and the tally.
#
# Sourced, not run. Sets SCRATCH, removed on exit unless KEEP is non-empty,
# and counts the assertions; `done_testing` prints the tally and fails when any assertion failed.

SCRATCH=$(mktemp -d)
CLEANUP=()
cleanup() {
  local c
  for c in "${CLEANUP[@]}"; do eval "$c" || true; done
  [ -n "${KEEP:-}" ] || rm -rf "$SCRATCH"
}
trap cleanup EXIT
[ -z "${KEEP:-}" ] || echo "scratch: $SCRATCH"

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
no() { fail=$((fail + 1)); echo "  FAIL $1"; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1"; echo "         actual: $2"; echo "       expected: $3"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1"; echo "       missing: $3"; echo "        in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) no "$1"; echo "       present: $3" ;; *) ok "$1" ;; esac; }
succeeds() { local name=$1; shift; if "$@"; then ok "$name"; else no "$name"; fi; }
fails() { local name=$1; shift; if "$@"; then no "$name"; else ok "$name"; fi; }
section() { printf '\n== %s\n' "$1"; }

# A `gh` stub on the PATH that answers `gh api` offline: nothing reaches GitHub.
# A GET of <path> answers from $API/<path>.json, a write from $API/<METHOD> <path>.json or `{}`,
# with `/?=&:,` in the path replaced by `_`, and applies `--jq` to the answer; a missing file is a 404.
# Every call goes to $SCRATCH/gh.log, every write to $SCRATCH/writes as `<METHOD> <path>`,
# with each `-f`/`-F` field after it, `body=@<file>` as the file's contents.
gh_stub() {
  API=$SCRATCH/api
  mkdir -p "$API" "$SCRATCH/bin"
  : >"$SCRATCH/writes"
  cat >"$SCRATCH/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "gh $*" >>"$SCRATCH/gh.log"
[ "${1:-}" = api ] || { echo "gh stub: only api" >&2; exit 2; }
shift
path='' jq='.' method='' fields=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jq=$2; shift 2 ;;
    -X | --method) method=$2; shift 2 ;;
    -f | -F | --raw-field | --field)
      f=$2
      if [[ $f == *=@* ]]; then f="${f%%=@*}=$(cat "${f#*=@}")"; fi
      fields+=("$f"); shift 2 ;;
    --input) fields+=("input=sha256:$(sha256sum "$2" | cut -d' ' -f1)"); shift 2 ;;
    -H | --header) shift 2 ;;
    --paginate | --silent) shift ;;
    *) path=$1; shift ;;
  esac
done
[ -n "$method" ] || if [ ${#fields[@]} -gt 0 ]; then method=POST; else method=GET; fi
key=$(printf '%s' "$path" | tr '/?=&:,' '______')
if [ "$method" = GET ]; then
  file=$API/$key.json
  [ -f "$file" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
else
  { echo "$method $path"; for f in "${fields[@]+"${fields[@]}"}"; do printf '  %s\n' "$f"; done; } >>"$SCRATCH/writes"
  [ -z "${GH_STUB_FAIL_WRITES:-}" ] || { echo "gh: Forbidden (HTTP 403)" >&2; exit 1; }
  file=$API/$method\ $key.json
  [ -f "$file" ] || file=/dev/null
fi
if [ "$file" = /dev/null ]; then echo '{}' | jq -r "$jq"; else jq -r "$jq" "$file"; fi
STUB
  chmod +x "$SCRATCH/bin/gh"
  export SCRATCH API PATH="$SCRATCH/bin:$PATH"
}
# Writes the answer for a GET (or `<METHOD> <path>`) of a path.
answer() { # <path> <json>
  local key
  key=$(printf '%s' "$1" | tr '/?=&:,' '______')
  printf '%s\n' "$2" >"$API/$key.json"
}

done_testing() {
  echo
  echo "$pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}
