#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Adapted from duckdb/duckdb-r's scripts/cran-submit-test.sh at ca768a9 (MIT).
# Check cran-submit.sh offline, against a fake CRAN submission form on 127.0.0.1: nothing reaches CRAN.
#
#   1. `upload` sends the two POSTs of `devtools:::upload_cran()`, field for field and in order,
#      with the tarball's own bytes, the maintainer from DESCRIPTION and the comment `Commit: <sha>`
#      (`<package> <version>` without SUBMIT_SHA),
#      and reports the next step: the confirmation email.
#   2. A 404 reads CRAN's maintenance message from the index page and fails with it.
#   3. An upload without `pkg_id`, a confirmation without `submit=1`, a 500 and an unreachable form
#      each fail before the next POST, with a "How to resolve" section in the step summary.
#   4. A misnamed tarball, and a file that is no tarball, fail before anything is sent.
#   5. `upload --dry-run` sends nothing, and prints and reports every field a real run would post.
#
# The fake form answers as CRAN's does: the upload redirects to `index2.php?pkg_id=...`,
# the confirmation to `index2.php?submit=1`, and the server records every field it receives.
#
# Usage:
#   actions/cran-submit/cran-submit-test.sh
#
# Environment variables:
#   KEEP - if non-empty, do not delete the scratch directory

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../cran-lib/test-lib.sh
. "$HERE/../cran-lib/test-lib.sh"
SERVER_PID=
# shellcheck disable=SC2016  # evaluated at exit
CLEANUP+=('[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null')

# --- the fake submission form ------------------------------------------------
#
# `mode` says how the form answers: ok, maintenance, nopkgid, nosubmit, error500.
# Every request appends to `requests`: one line per field, then one per request.

cat >"$SCRATCH/server.py" <<'EOF'
import email.parser, email.policy, hashlib, http.server, os, sys

scratch = sys.argv[1]


def mode():
    with open(os.path.join(scratch, "mode")) as f:
        return f.read().strip()


def record(line):
    with open(os.path.join(scratch, "requests"), "a", encoding="utf-8") as f:
        f.write(line + "\n")


class Form(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def page(self, code, text):
        body = (
            "<html><head><title>CRAN package Submission</title></head>\n"
            "<body><h1>Submit package to CRAN</h1>\n<p>%s</p>\n</body></html>\n" % text
        ).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, query):
        self.send_response(302)
        self.send_header("Location", "/cransubmit/index2.php?" + query)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        record("GET %s" % self.path)
        if self.path == "/cransubmit/index.php":
            self.page(200, "The submission form is closed for maintenance until 2 November.")
        else:
            self.page(200, "Page %s" % self.path)

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        head = b"Content-Type: " + self.headers["Content-Type"].encode() + b"\r\n\r\n"
        msg = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(head + body)
        names = []
        for part in msg.iter_parts():
            name = part.get_param("name", header="content-disposition")
            names.append(name)
            data = part.get_payload(decode=True)
            if part.get_filename() is not None:
                record("field %s file=%s type=%s sha256=%s" % (
                    name, part.get_filename(), part.get_content_type(), hashlib.sha256(data).hexdigest()))
            else:
                record("field %s=%s" % (name, data.decode("utf-8")))
        record("POST %s %s" % (self.path, ",".join(names)))
        m = mode()
        if m == "maintenance":
            return self.page(404, "Not Found")
        if m == "error500":
            return self.page(500, "Internal Server Error")
        if "upload" in names:
            if m == "nopkgid":
                return self.page(200, "The maintainer&#39;s email address could not be verified.")
            return self.redirect("pkg_id=XYZ123")
        if m == "nosubmit":
            return self.page(200, "Please confirm that you have read the policy.")
        return self.redirect("submit=1")


srv = http.server.HTTPServer(("127.0.0.1", 0), Form)
with open(os.path.join(scratch, "port.tmp"), "w") as f:
    f.write(str(srv.server_port))
os.rename(os.path.join(scratch, "port.tmp"), os.path.join(scratch, "port"))
srv.serve_forever()
EOF

echo ok >"$SCRATCH/mode"
mkdir "$SCRATCH/srv"
(cd "$SCRATCH/srv" && exec python3 -I "$SCRATCH/server.py" "$SCRATCH") &
# shellcheck disable=SC2034  # read at exit, through CLEANUP
SERVER_PID=$!
for _ in $(seq 100); do
  [ -s "$SCRATCH/port" ] && break
  sleep 0.1
done
[ -s "$SCRATCH/port" ] || {
  echo "the fake form did not start" >&2
  exit 1
}
FORM=http://127.0.0.1:$(cat "$SCRATCH/port")/cransubmit/index2.php
# The local form is reached directly, never through a proxy.
export no_proxy=127.0.0.1 NO_PROXY=127.0.0.1

# What a run on GitHub sets, and the commit the workflow passes.
export GITHUB_SERVER_URL=https://github.example GITHUB_REPOSITORY=owner/fakepkg GITHUB_REF_NAME=release-x
export SUBMIT_SHA=0123456789abcdef0123456789abcdef01234567
LINK="Commit [\`0123456789\`](https://github.example/owner/fakepkg/commit/$SUBMIT_SHA)."

SUMMARY=$SCRATCH/summary.md
# Runs the script as a workflow step would, against the fake form;
# prints its output and its exit status.
run() {
  local rc=0 out
  : >"$SUMMARY"
  : >"$SCRATCH/requests"
  out=$(GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY=$SUMMARY GITHUB_OUTPUT=$SCRATCH/output \
    CRAN_SUBMISSION_URL=${URL:-$FORM} "$HERE/cran-submit.sh" "$@" 2>&1) || rc=$?
  printf '%s\nexit %s\n' "$out" "$rc"
}
requests() { cat "$SCRATCH/requests"; }
field() { sed -n "s/^field $1=//p" "$SCRATCH/requests"; }

# --- the fixture -------------------------------------------------------------
#
# A package tarball as R CMD build writes it, by hand: a DESCRIPTION with a
# `Maintainer:` field, a non-ASCII name, and a continuation line.

mkdir -p "$SCRATCH/pkg/fakepkg"
cat >"$SCRATCH/pkg/fakepkg/DESCRIPTION" <<'EOF'
Package: fakepkg
Version: 1.0.1
Title: A Package That Is Never Submitted
Description: Stands in for the package in cran-submit-test.sh,
    against a fake submission form.
License: MIT + file LICENSE
Encoding: UTF-8
Maintainer: Jane Müller <jane@example.org>
EOF
TARBALL=$SCRATCH/pkg/fakepkg_1.0.1.tar.gz
tar -czf "$TARBALL" -C "$SCRATCH/pkg" fakepkg
SHA=$(sha256sum "$TARBALL" | cut -d' ' -f1)

# --- 1: a submission -----------------------------------------------------------

echo
echo "== upload and confirm, as devtools:::upload_cran() does"
echo ok >"$SCRATCH/mode"
out=$(run upload "$TARBALL")
has "it succeeds" "$out" "exit 0"
is "two POSTs, upload fields first, in devtools' order" "$(grep '^POST' "$SCRATCH/requests")" \
  "POST /cransubmit/index2.php pkg_id,name,email,uploaded_file,comment,upload
POST /cransubmit/index2.php pkg_id,name,email,policy_check,submit"
is "pkg_id is empty, then the one from the redirect" "$(field pkg_id)" "
XYZ123"
is "name, twice, from Maintainer:" "$(field name)" "Jane Müller
Jane Müller"
is "email, twice, from Maintainer:" "$(field email)" "jane@example.org
jane@example.org"
is "uploaded_file is the tarball, as application/x-gzip" "$(sed -n 's/^field uploaded_file //p' "$SCRATCH/requests")" \
  "file=fakepkg_1.0.1.tar.gz type=application/x-gzip sha256=$SHA"
is "comment is the single line Commit: <sha>" "$(field comment)" "Commit: $SUBMIT_SHA"
is "upload" "$(field upload)" "Upload package"
is "policy_check" "$(field policy_check)" "1/"
is "submit" "$(field submit)" "Submit package"
has "the log prints the pkg_id" "$out" "XYZ123"
has "and the sha256" "$out" "$SHA"
has "and groups the stages" "$out" "::group::Confirm: POST the submission"
has "it ends with a notice" "$out" "::notice title=Submitted to CRAN::fakepkg 1.0.1"
summary=$(cat "$SUMMARY")
has "the summary names the tarball" "$summary" "fakepkg_1.0.1.tar.gz"
has "and links the commit" "$summary" "### Upload to CRAN

- $LINK"
has "the log names the commit" "$out" "$(printf '  %-20s %s' commit: "$SUBMIT_SHA (release-x)")"
has "and the next step" "$summary" "**Next step:** CRAN emailed jane@example.org; click the confirmation link in that email to finish the submission."
hasnt "and no failure" "$summary" "How to resolve"

echo
echo "== without SUBMIT_SHA, the comment is <package> <version>"
out=$(SUBMIT_SHA='' run upload "$TARBALL")
has "it succeeds" "$out" "exit 0"
is "comment is the single line <package> <version>" "$(field comment)" "fakepkg 1.0.1"
hasnt "and the summary links no commit" "$(cat "$SUMMARY")" "$LINK"

# --- 2: maintenance ------------------------------------------------------------

echo
echo "== a 404 reads CRAN's message from the index page"
echo maintenance >"$SCRATCH/mode"
out=$(run upload "$TARBALL")
has "it fails" "$out" "exit 1"
has "with an error annotation" "$out" "::error title=CRAN submissions are closed::"
has "showing CRAN's message" "$out" "closed for maintenance until 2 November"
is "after one POST and a GET of index.php" "$(grep -v '^field' "$SCRATCH/requests")" \
  "POST /cransubmit/index2.php pkg_id,name,email,uploaded_file,comment,upload
GET /cransubmit/index.php"
summary=$(cat "$SUMMARY")
has "the summary says the upload failed" "$summary" "### Upload: failed"
has "with CRAN's message" "$summary" "closed for maintenance until 2 November"
has "and how to resolve it" "$summary" "#### How to resolve"
has "which is to wait" "$summary" "Wait until CRAN reopens"

# --- 3: the other failures -----------------------------------------------------

echo
echo "== an upload without pkg_id stops before the confirmation"
echo nopkgid >"$SCRATCH/mode"
out=$(run upload "$TARBALL")
has "it fails" "$out" "exit 1"
has "naming the missing pkg_id" "$out" "::error title=No pkg_id from CRAN::"
has "and showing CRAN's page, entities decoded" "$out" "The maintainer's email address could not be verified."
is "after one POST" "$(grep -c '^POST' "$SCRATCH/requests")" 1
summary=$(cat "$SUMMARY")
has "the summary resolves it" "$summary" "#### How to resolve"
has "against devtools" "$summary" "devtools:::upload_cran()"
has "and CRAN's form" "$summary" "https://cran.r-project.org/submit.html"

echo
echo "== a confirmation without submit=1 fails"
echo nosubmit >"$SCRATCH/mode"
out=$(run upload "$TARBALL")
has "it fails" "$out" "exit 1"
has "naming the step" "$out" "::error title=CRAN did not confirm the submission::"
is "after both POSTs" "$(grep -c '^POST' "$SCRATCH/requests")" 2
has "the summary says the confirmation failed" "$(cat "$SUMMARY")" "### Confirm: failed"

echo
echo "== a 500 fails with the status"
echo error500 >"$SCRATCH/mode"
out=$(run upload "$TARBALL")
has "it fails" "$out" "exit 1"
has "with the status" "$out" "answered HTTP 500"
is "after one POST" "$(grep -c '^POST' "$SCRATCH/requests")" 1
has "the summary resolves it" "$(cat "$SUMMARY")" "Check the maintainer fields"

echo
echo "== an unreachable form fails"
out=$(URL=http://127.0.0.1:1/cransubmit/index2.php run upload "$TARBALL")
has "it fails" "$out" "exit 1"
has "saying so" "$out" "::error title=CRAN could not be reached::"

# --- 4: a misnamed tarball -----------------------------------------------------

echo
echo "== a misnamed tarball is not sent"
echo ok >"$SCRATCH/mode"
cp "$TARBALL" "$SCRATCH/pkg/fakepkg.tar.gz"
out=$(run upload "$SCRATCH/pkg/fakepkg.tar.gz")
has "it fails" "$out" "exit 1"
has "naming the expected name" "$out" "fakepkg_1.0.1.tar.gz"
is "and sends nothing" "$(requests)" ""

echo
echo "== a tarball that is not one is not sent"
printf 'not a tarball' >"$SCRATCH/pkg/fakepkg_9.9.tar.gz"
out=$(run upload "$SCRATCH/pkg/fakepkg_9.9.tar.gz")
has "it fails" "$out" "exit 1"
has "saying so" "$out" "::error title=The tarball cannot be read::"
is "and sends nothing" "$(requests)" ""

# --- 5: a dry run --------------------------------------------------------------

echo
echo "== a dry run sends nothing and shows what it would"
echo ok >"$SCRATCH/mode"
out=$(run upload --dry-run "$TARBALL")
has "it succeeds" "$out" "exit 0"
is "the form receives no request" "$(requests)" ""
has "the log lists the uploaded file" "$out" \
  "$(printf '  %-20s %s' uploaded_file: "fakepkg_1.0.1.tar.gz (application/x-gzip, $(wc -c <"$TARBALL" | tr -d ' ') bytes, sha256 $SHA)")"
has "and the confirmation's fields" "$out" "$(printf '  %-20s %s' policy_check: 1/)"
has "with a notice" "$out" "::notice title=Dry run::Nothing was sent to CRAN."
summary=$(cat "$SUMMARY")
has "the summary says it is a dry run" "$summary" "### Upload to CRAN: dry run"
has "and nothing was sent" "$summary" "Nothing was sent to CRAN. A real run posts this to $FORM:"
has "with every upload field" "$summary" "   - \`pkg_id\`: empty
   - \`name\`: \`Jane Müller\`
   - \`email\`: \`jane@example.org\`
   - \`uploaded_file\`: \`fakepkg_1.0.1.tar.gz\`, \`application/x-gzip\`"
has "the comment" "$summary" "   - \`comment\`: \`Commit: $SUBMIT_SHA\`"
has "and every confirmation field" "$summary" "   - \`policy_check\`: \`1/\`
   - \`submit\`: \`Submit package\`"
has "and how to dispatch the real run" "$summary" "dispatch the submission again on the same commit with \`dry-run\` off"
hasnt "and no next step of a real submission" "$summary" "click the confirmation link"
out=$(run upload --dry-run "$SCRATCH/pkg/fakepkg.tar.gz")
has "a misnamed tarball still fails" "$out" "::error title=The tarball is misnamed::"
is "and sends nothing" "$(requests)" ""

done_testing
