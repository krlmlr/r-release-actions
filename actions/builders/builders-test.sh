#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Check builders.sh offline, against a fake win-builder FTP server and a fake macbuilder on 127.0.0.1:
# nothing reaches either service.
#
#   1. `winbuilder` uploads the tarball's own bytes by anonymous FTP to `<flavor>/<file name>` for each flavor,
#      tries every flavor when one fails, fails loudly after them, and outputs each flavor's result.
#   2. `macbuilder` posts `pkgfile` and `rflavor` with `Accept: application/json`, and outputs the result page's URL;
#      a 502, an answer without a result URL, and a URL on another host fail.
#   3. `macbuilder-poll` waits through 404s and a page without a status, and reports OK, a NOTE and an ERROR;
#      a page that never finishes ends in a timeout; neither an ERROR nor a timeout fails.
#   4. A dry run sends nothing and reports what a real run would send; a misnamed tarball fails before sending.
#
# Usage:
#   actions/builders/builders-test.sh
#
# Environment variables:
#   KEEP - if non-empty, do not delete the scratch directory

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../cran-lib/test-lib.sh
. "$HERE/../cran-lib/test-lib.sh"
FTP_PID='' HTTP_PID=''
# shellcheck disable=SC2016  # evaluated at exit
CLEANUP+=('[ -z "$FTP_PID" ] || kill "$FTP_PID" 2>/dev/null' '[ -z "$HTTP_PID" ] || kill "$HTTP_PID" 2>/dev/null')

# --- the fake win-builder: an anonymous FTP server ------------------------------
#
# Enough of RFC 959 and RFC 2428 for curl's upload: USER, PASS, PWD, CWD, EPSV, PASV, TYPE, STOR, QUIT.
# Its directories are R-devel, R-release and R-oldrelease; the file `ftp-mode` set to `denied` refuses every STOR.
# Every stored file is recorded in `ftp-requests` as `STOR /<dir>/<name> sha256=<digest>`.

cat >"$SCRATCH/ftp.py" <<'EOF'
import hashlib, os, socket, socketserver, sys

scratch = sys.argv[1]
DIRS = {"R-devel", "R-release", "R-oldrelease"}


def record(line):
    with open(os.path.join(scratch, "ftp-requests"), "a") as f:
        f.write(line + "\n")


def mode():
    with open(os.path.join(scratch, "ftp-mode")) as f:
        return f.read().strip()


class Session(socketserver.StreamRequestHandler):
    def send(self, line):
        self.wfile.write((line + "\r\n").encode())

    def handle(self):
        cwd, data = "/", None
        self.send("220 fake win-builder")
        for raw in self.rfile:
            cmd, _, arg = raw.decode().strip().partition(" ")
            cmd = cmd.upper()
            if cmd == "USER":
                self.send("331 send password")
            elif cmd == "PASS":
                self.send("230 logged in")
            elif cmd == "PWD":
                self.send('257 "%s"' % cwd)
            elif cmd == "CWD":
                d = arg.strip("/")
                if d in DIRS:
                    cwd = "/" + d
                    self.send("250 ok")
                else:
                    self.send("550 no such directory")
            elif cmd in ("EPSV", "PASV"):
                data = socket.socket()
                data.bind(("127.0.0.1", 0))
                data.listen(1)
                port = data.getsockname()[1]
                if cmd == "EPSV":
                    self.send("229 Entering Extended Passive Mode (|||%d|)" % port)
                else:
                    self.send("227 Entering Passive Mode (127,0,0,1,%d,%d)" % (port // 256, port % 256))
            elif cmd == "TYPE":
                self.send("200 type set")
            elif cmd == "STOR":
                if mode() == "denied":
                    self.send("553 permission denied")
                    continue
                self.send("150 ok to send")
                conn, _ = data.accept()
                h = hashlib.sha256()
                while True:
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    h.update(chunk)
                conn.close()
                data.close()
                record("STOR %s/%s sha256=%s" % (cwd, arg, h.hexdigest()))
                self.send("226 transfer complete")
            elif cmd == "QUIT":
                self.send("221 bye")
                return
            else:
                self.send("502 not implemented")


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True


srv = Server(("127.0.0.1", 0), Session)
with open(os.path.join(scratch, "ftp-port.tmp"), "w") as f:
    f.write(str(srv.server_address[1]))
os.rename(os.path.join(scratch, "ftp-port.tmp"), os.path.join(scratch, "ftp-port"))
srv.serve_forever()
EOF

# --- the fake macbuilder ------------------------------------------------------------
#
# POST /macbuilder/v1/submit records its fields and the Accept header, and answers by `mac-mode`:
# `ok` with the JSON `{"url": ".../macbuilder/results/<mac-job>/"}`, `down` with nginx's 502,
# `nourl` with JSON without a URL, `foreign` with a result URL on another host.
# GET /macbuilder/results/<job>/ answers by the job's name, counting the GETs of each:
# `ok` 404 first, then a page without a status, then a finished page with `Status: OK`;
# `note` and `error` a finished page at once; `never` 404 always.
# The finished pages copy the shape of real ones: the check log in a <pre>, ending in `Status:` and the classification.

cat >"$SCRATCH/http.py" <<'EOF'
import collections, email.parser, email.policy, hashlib, http.server, json, os, sys

scratch = sys.argv[1]
gets = collections.Counter()


def read(name):
    with open(os.path.join(scratch, name)) as f:
        return f.read().strip()


def record(line):
    with open(os.path.join(scratch, "http-requests"), "a", encoding="utf-8") as f:
        f.write(line + "\n")


FINISHED = """<!doctype html>
<html lang="en"><head><title>macOS build result for %s</title></head><body>
<h3>macOS builder results</h3>
<div class="tab-pane" id="tab1"><pre>Resetting rust
OUTPUT:
</pre></div>
<div class="tab-pane" id="tab3"><pre>* using log directory '/Volumes/PkgBuild/work/x/fakepkg.Rcheck'
* checking PDF version of manual ... OK
* DONE
Status: %s
* using check arguments '--no-clean-on-error '
* result classification: %s
</pre></div>
</body></html>
"""


class Mac(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body, ctype="text/html"):
        body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        record("GET %s" % self.path)
        job = self.path.rstrip("/").rsplit("/", 1)[-1]
        gets[job] += 1
        n = gets[job]
        if job == "ok" and n == 1 or job == "never":
            return self.reply(404, "<html><body><h1>404 Not Found</h1></body></html>")
        if job == "ok" and n == 2:
            return self.reply(200, "<html><body><h3>macOS builder results</h3><pre>Resetting rust\n</pre></body></html>")
        status = {"ok": ("OK", "OK, errors:no, warnings:no, notes:no"),
                  "note": ("1 NOTE", "NOTE, errors:no, warnings:no, notes:yes"),
                  "error": ("1 ERROR, 1 WARNING", "ERROR, errors:yes, warnings:yes, notes:no")}[job]
        self.reply(200, FINISHED % ((job,) + status))

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
                record("field %s file=%s sha256=%s" % (name, part.get_filename(), hashlib.sha256(data).hexdigest()))
            else:
                record("field %s=%s" % (name, data.decode("utf-8")))
        record("POST %s %s accept=%s" % (self.path, ",".join(names), self.headers.get("Accept")))
        m = read("mac-mode")
        if m == "down":
            return self.reply(502, "<html><body><h1>An error occurred.</h1><p>Sorry, the page you are looking for is currently unavailable.</p></body></html>")
        if m == "nourl":
            return self.reply(200, json.dumps({"error": "no maintainer"}), "application/json")
        host = "elsewhere.example" if m == "foreign" else "127.0.0.1:%d" % self.server.server_port
        url = "http://%s/macbuilder/results/%s/" % (host, read("mac-job"))
        self.reply(200, json.dumps({"url": url}), "application/json")


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Mac)
with open(os.path.join(scratch, "http-port.tmp"), "w") as f:
    f.write(str(srv.server_port))
os.rename(os.path.join(scratch, "http-port.tmp"), os.path.join(scratch, "http-port"))
srv.serve_forever()
EOF

echo ok >"$SCRATCH/ftp-mode"
echo ok >"$SCRATCH/mac-mode"
echo ok >"$SCRATCH/mac-job"
mkdir "$SCRATCH/srv"
(cd "$SCRATCH/srv" && exec python3 -I "$SCRATCH/ftp.py" "$SCRATCH") &
# shellcheck disable=SC2034  # read at exit, through CLEANUP
FTP_PID=$!
(cd "$SCRATCH/srv" && exec python3 -I "$SCRATCH/http.py" "$SCRATCH") &
# shellcheck disable=SC2034  # read at exit, through CLEANUP
HTTP_PID=$!
for _ in $(seq 100); do
  [ -s "$SCRATCH/ftp-port" ] && [ -s "$SCRATCH/http-port" ] && break
  sleep 0.1
done
{ [ -s "$SCRATCH/ftp-port" ] && [ -s "$SCRATCH/http-port" ]; } || {
  echo "the fake servers did not start" >&2
  exit 1
}
FTP=ftp://127.0.0.1:$(cat "$SCRATCH/ftp-port")
MAC=http://127.0.0.1:$(cat "$SCRATCH/http-port")
# The local servers are reached directly, never through a proxy.
export no_proxy=127.0.0.1 NO_PROXY=127.0.0.1
unset ftp_proxy FTP_PROXY all_proxy ALL_PROXY
export WINBUILDER_URL=$FTP MACBUILDER_URL=$MAC/macbuilder/v1/submit MACBUILDER_POLL_SECONDS=0 MACBUILDER_TIMEOUT_SECONDS=30

SUMMARY=$SCRATCH/summary.md
run() {
  local rc=0 out
  : >"$SUMMARY"
  : >"$SCRATCH/output"
  : >"$SCRATCH/ftp-requests"
  : >"$SCRATCH/http-requests"
  out=$(GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY=$SUMMARY GITHUB_OUTPUT=$SCRATCH/output \
    "$HERE/builders.sh" "$@" 2>&1) || rc=$?
  printf '%s\nexit %s\n' "$out" "$rc"
}
field() { sed -n "s/^field $1=//p" "$SCRATCH/http-requests"; }

mkdir -p "$SCRATCH/pkg/fakepkg"
printf 'Package: fakepkg\nVersion: 1.0.1\nMaintainer: Jane Doe <jane@example.org>\n' >"$SCRATCH/pkg/fakepkg/DESCRIPTION"
TARBALL=$SCRATCH/pkg/fakepkg_1.0.1.tar.gz
tar -czf "$TARBALL" -C "$SCRATCH/pkg" fakepkg
SHA=$(sha256sum "$TARBALL" | cut -d' ' -f1)

section "winbuilder uploads by anonymous FTP, as devtools' submit_winbuilder_ftp() does"
out=$(run winbuilder "$TARBALL" R-devel R-release)
has "it succeeds" "$out" "exit 0"
is "one STOR per flavor, into the flavor's directory, of the tarball's bytes" "$(cat "$SCRATCH/ftp-requests")" \
  "STOR /R-devel/fakepkg_1.0.1.tar.gz sha256=$SHA
STOR /R-release/fakepkg_1.0.1.tar.gz sha256=$SHA"
is "the results" "$(cat "$SCRATCH/output")" "results=R-devel=uploaded R-release=uploaded"
has "the summary names the URLs" "$(cat "$SUMMARY")" "- R-devel: uploaded to $FTP/R-devel/fakepkg_1.0.1.tar.gz"
has "and where the results go" "$(cat "$SUMMARY")" "Win-builder emails the results to Jane Doe <jane@example.org>"
has "with a notice" "$out" "::notice title=Uploaded to win-builder::"

section "winbuilder failures"
echo denied >"$SCRATCH/ftp-mode"
out=$(run winbuilder "$TARBALL" R-devel R-release)
has "a refused upload fails" "$out" "exit 1"
has "loudly, naming the URL" "$out" "::error title=The upload to win-builder failed::curl exited with status"
has "for every flavor tried" "$(grep -c 'The upload to win-builder failed' <<<"$out")" 2
is "and outputs the results" "$(cat "$SCRATCH/output")" "results=R-devel=failed R-release=failed"
echo ok >"$SCRATCH/ftp-mode"
out=$(run winbuilder "$TARBALL" R-patched)
has "an unknown flavor fails" "$out" "::error title=No win-builder flavor::"
is "before anything is sent" "$(cat "$SCRATCH/ftp-requests")" ""
out=$(WINBUILDER_URL=ftp://127.0.0.1:1 run winbuilder "$TARBALL" R-devel)
has "an unreachable server fails" "$out" "exit 1"
cp "$TARBALL" "$SCRATCH/pkg/fakepkg.tar.gz"
out=$(run winbuilder "$SCRATCH/pkg/fakepkg.tar.gz" R-devel)
has "a misnamed tarball fails" "$out" "::error title=The tarball is misnamed::"
is "and sends nothing" "$(cat "$SCRATCH/ftp-requests")" ""
printf 'not a tarball' >"$SCRATCH/pkg/fakepkg_9.9.tar.gz"
out=$(run winbuilder "$SCRATCH/pkg/fakepkg_9.9.tar.gz" R-devel)
has "a file that is no tarball fails" "$out" "::error title=The tarball cannot be read::"
cp "$TARBALL" "$SCRATCH/pkg/fakepkg_1.0.2.tar.gz"
out=$(run winbuilder "$SCRATCH/pkg/fakepkg_1.0.2.tar.gz" R-devel)
has "a tarball of another release fails" "$out" "::error title=The tarball is of another release::"

section "winbuilder dry run"
out=$(run winbuilder --dry-run "$TARBALL" R-devel R-release)
has "it succeeds" "$out" "exit 0"
is "and sends nothing" "$(cat "$SCRATCH/ftp-requests")" ""
has "it says what it would upload, and where" "$(cat "$SUMMARY")" "- R-release: would upload to $FTP/R-release/fakepkg_1.0.1.tar.gz"
is "the results say so" "$(cat "$SCRATCH/output")" "results=R-devel=dry-run R-release=dry-run"
has "with a notice" "$out" "::notice title=Dry run::Nothing was sent to win-builder."

section "macbuilder posts as devtools' check_mac() does"
out=$(run macbuilder "$TARBALL" r-devel)
has "it succeeds" "$out" "exit 0"
has "one POST of pkgfile and rflavor, asking for JSON" "$(cat "$SCRATCH/http-requests")" \
  "POST /macbuilder/v1/submit pkgfile,rflavor accept=application/json"
is "pkgfile is the tarball" "$(sed -n 's/^field pkgfile //p' "$SCRATCH/http-requests")" "file=fakepkg_1.0.1.tar.gz sha256=$SHA"
is "rflavor" "$(field rflavor)" "r-devel"
is "it outputs the result page" "$(cat "$SCRATCH/output")" "url=$MAC/macbuilder/results/ok/"

section "macbuilder failures"
echo down >"$SCRATCH/mac-mode"
out=$(run macbuilder "$TARBALL" r-devel)
has "a 502 fails" "$out" "::error title=Macbuilder refused the upload::The submission answered HTTP 502"
has "saying the service is down" "$(cat "$SUMMARY")" "HTTP 502 is what macbuilder answers while its service is down"
echo nourl >"$SCRATCH/mac-mode"
out=$(run macbuilder "$TARBALL" r-devel)
has "an answer without a URL fails" "$out" "::error title=No result URL from macbuilder::"
echo foreign >"$SCRATCH/mac-mode"
out=$(run macbuilder "$TARBALL" r-devel)
has "a result URL on another host fails" "$out" "::error title=No result URL from macbuilder::"
is "and outputs nothing" "$(cat "$SCRATCH/output")" ""
echo ok >"$SCRATCH/mac-mode"
out=$(run macbuilder "$TARBALL" r-oldrel)
has "an unknown flavor fails" "$out" "::error title=No macbuilder flavor::"
is "before anything is sent" "$(cat "$SCRATCH/http-requests")" ""
out=$(MACBUILDER_URL=http://127.0.0.1:1/macbuilder/v1/submit run macbuilder "$TARBALL" r-devel)
has "an unreachable service fails" "$out" "::error title=Macbuilder could not be reached::"

section "macbuilder dry run"
out=$(run macbuilder --dry-run "$TARBALL" r-release)
has "it succeeds" "$out" "exit 0"
is "and sends nothing" "$(cat "$SCRATCH/http-requests")" ""
has "it reports the fields" "$(cat "$SUMMARY")" "- \`pkgfile\`: \`fakepkg_1.0.1.tar.gz\`
- \`rflavor\`: \`r-release\`"
has "with a notice" "$out" "::notice title=Dry run::Nothing was sent to macbuilder."

section "macbuilder-poll"
out=$(run macbuilder-poll "$MAC/macbuilder/results/ok/")
has "it waits through a 404" "$out" "poll 1: no result page yet (HTTP 404)"
has "and a page without a status" "$out" "poll 2: the page has no check status yet"
has "and succeeds on the finished page" "$out" "exit 0"
is "with its outcome and status" "$(cat "$SCRATCH/output")" "outcome=ok
status=OK"
has "the log shows the classification" "$out" "OK, errors:no, warnings:no, notes:no"
has "with a notice" "$out" "::notice title=Macbuilder status OK::"
is "after three GETs" "$(grep -c '^GET' "$SCRATCH/http-requests")" 3
out=$(run macbuilder-poll "$MAC/macbuilder/results/note/")
is "a NOTE" "$(cat "$SCRATCH/output")" "outcome=note
status=1 NOTE"
has "warns" "$out" "::warning title=Macbuilder status 1 NOTE::"
out=$(run macbuilder-poll "$MAC/macbuilder/results/error/")
has "an ERROR does not fail" "$out" "exit 0"
is "its outcome is the worst" "$(cat "$SCRATCH/output")" "outcome=error
status=1 ERROR, 1 WARNING"
has "and warns" "$out" "::warning title=Macbuilder status 1 ERROR%2C 1 WARNING::"
out=$(MACBUILDER_POLL_SECONDS=1 MACBUILDER_TIMEOUT_SECONDS=2 run macbuilder-poll "$MAC/macbuilder/results/never/")
has "a page that never finishes times out without failing" "$out" "exit 0"
is "as a timeout" "$(cat "$SCRATCH/output")" "outcome=timeout
status="
has "with a warning" "$out" "::warning title=Macbuilder result pending::No check result at $MAC/macbuilder/results/never/"
out=$(run macbuilder-poll "$MAC/elsewhere/")
has "a URL that is no result page is a usage error" "$out" "exit 2"

done_testing
