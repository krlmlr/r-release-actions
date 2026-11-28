#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Check builders.sh offline, against a fake win-builder FTP server and a fake macbuilder on 127.0.0.1:
# nothing reaches either service.
#
#   1. `winbuilder` uploads the tarball by anonymous FTP to `<flavor>/<file name>`, repacked with the commit's first six bytes
#      appended to its version as six decimal components of one byte each, and otherwise unchanged;
#      for each flavor, tries every flavor when one fails, fails loudly after them, and outputs the uploaded file's name
#      and each flavor's result; an unknown flavor, and a missing or short commit, fail before sending.
#   2. `macbuilder` posts `pkgfile` and `rflavor` with `Accept: application/json`, and outputs the result page's URL;
#      a 502 or another refusal, an answer without a result URL or that is no JSON,
#      and a URL on another host, with another scheme or with user info fail.
#   3. `macbuilder-poll` waits through 404s, other HTTP errors, curl's failures and a page without a finished check log,
#      including one whose log holds a stray `Status:` line, and reports OK, a NOTE, an ERROR and an unknown status;
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
# Its directories are R-devel, R-release and R-oldrelease; the file `ftp-mode` set to `denied` refuses every STOR,
# set to `denied-devel` refuses a STOR into R-devel only,
# and set to `stall` answers a STOR only after five seconds.
# Every STOR is recorded in `ftp-requests` as `STOR-begin /<dir>/<name>`,
# and every stored file as `STOR /<dir>/<name> sha256=<digest>`, its bytes kept as `stored/<dir>/<name>`.

cat >"$SCRATCH/ftp.py" <<'EOF'
import hashlib, os, socket, socketserver, sys, time

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
                record("STOR-begin %s/%s" % (cwd, arg))
                if mode() == "denied" or mode() == "denied-devel" and cwd == "/R-devel":
                    self.send("553 permission denied")
                    continue
                if mode() == "stall":
                    time.sleep(5)
                self.send("150 ok to send")
                conn, _ = data.accept()
                h = hashlib.sha256()
                os.makedirs(os.path.join(scratch, "stored", cwd.strip("/")), exist_ok=True)
                with open(os.path.join(scratch, "stored", cwd.strip("/"), os.path.basename(arg)), "wb") as out:
                    while True:
                        chunk = conn.recv(65536)
                        if not chunk:
                            break
                        h.update(chunk)
                        out.write(chunk)
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
# `nourl` with JSON without a URL, `foreign` with a result URL on another host,
# `e403` with a 403, `html` with a 200 HTML page, `scheme` with an https result URL, `userinfo` with user info in its host.
# GET /macbuilder/results/<job>/ answers by the job's name, counting the GETs of each:
# `ok` 404 first, then a page without a status, then a finished page with `Status: OK`;
# `note` and `error` a finished page at once; `never` 404 always; `e500` 500 always;
# `stray` first a running page whose build log holds a `Status:` line, then a finished page with that line too;
# `crlf` a finished page with CRLF line ends; `inline` a finished page with `</pre>` on the classification line; `odd` a finished page whose status is no status of R CMD check.
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
        if job == "e500":
            return self.reply(500, "<html><body><h1>500</h1></body></html>")
        if job == "ok" and n == 2:
            return self.reply(200, "<html><body><h3>macOS builder results</h3><pre>Resetting rust\n</pre></body></html>")
        if job == "stray":
            stray = "<pre>Resetting rust\n  Status: indented\nStatus: 1 ERROR\n* checking tests ...\n"
            if n == 1:
                return self.reply(200, "<html><body>%s</pre><pre>* checking examples ...\nStatus: 2 NOTEs\n" % stray)
            return self.reply(200, (FINISHED % ("stray", "OK", "OK, errors:no")).replace("<pre>Resetting rust\n", stray, 1))
        if job == "inline":
            return self.reply(200, (FINISHED % ("inline", "1 NOTE", "NOTE, notes:yes")).replace("notes:yes\n</pre>", "notes:yes</pre>"))
        if job == "crlf":
            return self.reply(200, (FINISHED % ("crlf", "OK", "OK, errors:no")).replace("\n", "\r\n"))
        if job == "odd":
            return self.reply(200, FINISHED % ("odd", "done `rm` \x07" + "x" * 300, "?"))
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
        if m == "e403":
            return self.reply(403, "<html><body><h1>403 Forbidden</h1></body></html>")
        if m == "html":
            return self.reply(200, "<html><body><p>Thank you for your submission.</p></body></html>")
        host = "elsewhere.example" if m == "foreign" else "127.0.0.1:%d" % self.server.server_port
        if m == "userinfo":
            host = "user@" + host
        scheme = "https" if m == "scheme" else "http"
        url = "%s://%s/macbuilder/results/%s/" % (scheme, host, read("mac-job"))
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
export WINBUILDER_RETRY_SECONDS=0 WINBUILDER_URL=$FTP MACBUILDER_URL=$MAC/macbuilder/v1/submit MACBUILDER_POLL_SECONDS=0 MACBUILDER_TIMEOUT_SECONDS=30

SUMMARY=$SCRATCH/summary.md
run() {
  local rc=0 out
  : >"$SUMMARY"
  : >"$SCRATCH/output"
  : >"$SCRATCH/ftp-requests"
  : >"$SCRATCH/http-requests"
  rm -rf "$SCRATCH/stored"
  out=$(GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY=$SUMMARY GITHUB_OUTPUT=$SCRATCH/output \
    "$HERE/builders.sh" "$@" 2>&1) || rc=$?
  printf '%s\nexit %s\n' "$out" "$rc"
}
field() { sed -n "s/^field $1=//p" "$SCRATCH/http-requests"; }

mkdir -p "$SCRATCH/pkg/fakepkg/R"
printf 'Package: fakepkg\nVersion: 1.0.1\nMaintainer: Jane Doe <jane@example.org>\nVersioned: Version: 1.0.1\n' \
  >"$SCRATCH/pkg/fakepkg/DESCRIPTION"
echo 'f <- function() 1' >"$SCRATCH/pkg/fakepkg/R/f.R"
chmod 644 "$SCRATCH/pkg/fakepkg/DESCRIPTION"
# A mode the usual umask would change, so that the repack must keep it.
chmod 664 "$SCRATCH/pkg/fakepkg/R/f.R"
printf '#!/bin/sh\n' >"$SCRATCH/pkg/fakepkg/configure"
chmod 755 "$SCRATCH/pkg/fakepkg/configure"
touch -d '2026-01-02 03:04:05' "$SCRATCH/pkg/fakepkg" "$SCRATCH/pkg/fakepkg"/* "$SCRATCH/pkg/fakepkg/R"/*
TARBALL=$SCRATCH/pkg/fakepkg_1.0.1.tar.gz
tar -czf "$TARBALL" -C "$SCRATCH/pkg" fakepkg
SHA=$(sha256sum "$TARBALL" | cut -d' ' -f1)
# The commit the tarball was built from, and its first six bytes, c4 a8 75 c4 7d 9c, as six decimal components.
COMMIT=c4a875c47d9c90ab66f647daaba6543598c1234e
UPLOADED=fakepkg_1.0.1.196.168.117.196.125.156.tar.gz
# The README's decoding, from the version in win-builder's email back to the commit's first twelve hex digits.
decode() { local c; IFS=. read -r -a c <<<"$1"; printf '%02x' "${c[@]: -6}"; }
# A version that R CMD check's incoming checks accept: no component of 1234 or more, none with a leading zero.
incoming_ok() {
  local c x
  IFS=. read -r -a c <<<"$1"
  for x in "${c[@]}"; do [[ $x =~ ^(0|[1-9][0-9]*)$ ]] && [ "$x" -lt 1234 ] || return 1; done
}

section "winbuilder uploads by anonymous FTP, as devtools' submit_winbuilder_ftp() does"
out=$(run winbuilder --commit "$COMMIT" "$TARBALL" R-devel R-release)
has "it succeeds" "$out" "exit 0"
STORED=$(sha256sum "$SCRATCH/stored/R-devel/$UPLOADED" | cut -d' ' -f1)
is "one STOR per flavor, into the flavor's directory, of the same tarball with the commit in its version" \
  "$(grep -v '^STOR-begin' "$SCRATCH/ftp-requests")" "STOR /R-devel/$UPLOADED sha256=$STORED
STOR /R-release/$UPLOADED sha256=$STORED"
is "the uploaded file's name, and the results written after each flavor" "$(cat "$SCRATCH/output")" "tarball=$UPLOADED
results=R-devel=uploaded
results=R-devel=uploaded R-release=uploaded"
has "the summary names the URLs" "$(cat "$SUMMARY")" "- R-devel: uploaded to $FTP/R-devel/$UPLOADED
- R-release: uploaded to $FTP/R-release/$UPLOADED"
has "and both files" "$(cat "$SUMMARY")" "- Tarball: \`fakepkg_1.0.1.tar.gz\`, sha256 \`$SHA\`
- Uploaded as \`$UPLOADED\`, sha256 \`$(sha256sum "$SCRATCH/stored/R-devel/$UPLOADED" | cut -d' ' -f1)\`: the same files, with commit \`c4a875c47d9c\` encoded in \`Version:\`"
has "and where the results go" "$(cat "$SUMMARY")" "Win-builder emails the results for R-devel, R-release to Jane Doe <jane@example.org>"
has "with a notice" "$out" "::notice title=Uploaded to win-builder::"

section "winbuilder repacks the tarball with the commit in its version"
mkdir -p "$SCRATCH/x/checked" "$SCRATCH/x/uploaded"
tar -xzf "$TARBALL" -C "$SCRATCH/x/checked"
tar -xzf "$SCRATCH/stored/R-devel/$UPLOADED" -C "$SCRATCH/x/uploaded"
# Mode, size, date, time to the second and name of each member.
listing() { tar --full-time -tvzf "$1" | awk '{ print $1, $3, $4, $5, $6 }' | sort; }
is "the same files, modes, sizes and times but DESCRIPTION's size" \
  "$(listing "$SCRATCH/stored/R-devel/$UPLOADED" | grep -v DESCRIPTION)" "$(listing "$TARBALL" | grep -v DESCRIPTION)"
is "which are there, the package's directory with its time" "$(listing "$TARBALL" | grep -c ' 2026-01-02 03:04:05 ')" 5
is "and DESCRIPTION keeps its mode and time" "$(listing "$SCRATCH/stored/R-devel/$UPLOADED" | grep DESCRIPTION | cut -d' ' -f1,3,4)" \
  "-rw-r--r-- 2026-01-02 03:04:05"
is "as a file the usual umask would change does" "$(listing "$SCRATCH/stored/R-devel/$UPLOADED" | awk '/f.R$/ { print $1 }')" "-rw-rw-r--"
is "an executable stays executable" "$(tar -tvzf "$SCRATCH/stored/R-devel/$UPLOADED" | awk '/configure$/ { print $1 }')" "-rwxr-xr-x"
is "the same contents but DESCRIPTION" "$(diff -r -x DESCRIPTION "$SCRATCH/x/checked" "$SCRATCH/x/uploaded" && echo same)" same
is "DESCRIPTION differs in the Version field only" \
  "$(diff "$SCRATCH/x/checked/fakepkg/DESCRIPTION" "$SCRATCH/x/uploaded/fakepkg/DESCRIPTION")" "2c2
< Version: 1.0.1
---
> Version: 1.0.1.196.168.117.196.125.156"
is "the README's decoding gives back the commit's first twelve hex digits" "$(decode 1.0.1.196.168.117.196.125.156)" "${COMMIT:0:12}"
for c in 000000000000 ffffffffffff 00a01b2c3d4e 0123456789ab 090a0f10ff00; do
  sha=${c}$(printf '0%.0s' $(seq 28))
  out=$(run winbuilder --dry-run --commit "$sha" "$TARBALL" R-devel)
  v=$(sed -n 's/^tarball=fakepkg_\(.*\)\.tar\.gz$/\1/p' "$SCRATCH/output")
  is "commit $c: six components, each below 1234 without a leading zero, decoded back" \
    "$(incoming_ok "$v" && [[ $v =~ ^1\.0\.1(\.[0-9]+){6}$ ]] && decode "$v")" "$c"
done
is "zero bits are zero components" "$(run winbuilder --dry-run --commit "$(printf '0%.0s' $(seq 40))" "$TARBALL" R-devel >/dev/null; head -n 1 "$SCRATCH/output")" \
  "tarball=fakepkg_1.0.1.0.0.0.0.0.0.tar.gz"
is "all one bits are 255" "$(run winbuilder --dry-run --commit "$(printf 'f%.0s' $(seq 40))" "$TARBALL" R-devel >/dev/null; head -n 1 "$SCRATCH/output")" \
  "tarball=fakepkg_1.0.1.255.255.255.255.255.255.tar.gz"
mkdir -p "$SCRATCH/pkg4/fakepkg"
printf 'Package: fakepkg\nVersion: 1.4.2.1\nMaintainer: Jane Doe <jane@example.org>\n' >"$SCRATCH/pkg4/fakepkg/DESCRIPTION"
tar -czf "$SCRATCH/pkg4/fakepkg_1.4.2.1.tar.gz" -C "$SCRATCH/pkg4" fakepkg
out=$(run winbuilder --commit "$COMMIT" "$SCRATCH/pkg4/fakepkg_1.4.2.1.tar.gz" R-devel)
is "a four-component release keeps its four" "$(grep -v '^STOR-begin' "$SCRATCH/ftp-requests" | sed 's/ sha256=.*//')" \
  "STOR /R-devel/fakepkg_1.4.2.1.196.168.117.196.125.156.tar.gz"
is "in DESCRIPTION too" "$(tar -xzOf "$SCRATCH/stored/R-devel/fakepkg_1.4.2.1.196.168.117.196.125.156.tar.gz" fakepkg/DESCRIPTION | sed -n 2p)" \
  "Version: 1.4.2.1.196.168.117.196.125.156"
out=$(run winbuilder "$TARBALL" R-devel)
has "no commit fails, saying so" "$out" "::error title=No commit SHA::The commit given is no full 40-character commit SHA."
is "before anything is sent" "$(cat "$SCRATCH/ftp-requests")" ""
out=$(run winbuilder --commit "${COMMIT:0:12}" "$TARBALL" R-devel)
has "a short commit fails" "$out" "::error title=No commit SHA::"
out=$(run winbuilder "$TARBALL" R-devel --commit)
has "a --commit without its value is a usage error" "$out" "exit 2"
mkdir -p "$SCRATCH/pkgcr/fakepkg"
printf 'Package: fakepkg\r\nVersion: 1.0.1\r\nMaintainer: Jane Doe <jane@example.org>\r\n' >"$SCRATCH/pkgcr/fakepkg/DESCRIPTION"
tar -czf "$SCRATCH/pkgcr/fakepkg_1.0.1.tar.gz" -C "$SCRATCH/pkgcr" fakepkg
out=$(run winbuilder --commit "$COMMIT" "$SCRATCH/pkgcr/fakepkg_1.0.1.tar.gz" R-devel)
is "a DESCRIPTION with CRLF line ends keeps them" "$(tar -xzOf "$SCRATCH/stored/R-devel/$UPLOADED" fakepkg/DESCRIPTION | od -c)" \
  "$(printf 'Package: fakepkg\r\nVersion: 1.0.1.196.168.117.196.125.156\r\nMaintainer: Jane Doe <jane@example.org>\r\n' | od -c)"
chmod 444 "$SCRATCH/pkgcr/fakepkg/DESCRIPTION"
tar -czf "$SCRATCH/pkgcr/fakepkg_1.0.1.tar.gz" -C "$SCRATCH/pkgcr" fakepkg
out=$(run winbuilder --commit "$COMMIT" "$SCRATCH/pkgcr/fakepkg_1.0.1.tar.gz" R-devel)
is "a read-only DESCRIPTION is repacked, and stays read-only" "$(tar -tvzf "$SCRATCH/stored/R-devel/$UPLOADED" | awk '/DESCRIPTION$/ { print $1 }')" \
  "-r--r--r--"
mkdir -p "$SCRATCH/pkgx/fakepkg"
cp "$SCRATCH/pkg/fakepkg/DESCRIPTION" "$SCRATCH/pkgx/fakepkg/"
touch "$SCRATCH/pkgx/extra"
tar -czf "$SCRATCH/pkgx/fakepkg_1.0.1.tar.gz" -C "$SCRATCH/pkgx" fakepkg extra
out=$(run winbuilder --commit "$COMMIT" "$SCRATCH/pkgx/fakepkg_1.0.1.tar.gz" R-devel)
has "a tarball with files outside the package's directory fails" "$out" \
  "::error title=The tarball cannot be repacked::\`fakepkg_1.0.1.tar.gz\` holds files outside \`fakepkg/\`"
has "naming them in the summary" "$(cat "$SUMMARY")" "extra"
is "and sends nothing" "$(cat "$SCRATCH/ftp-requests")" ""

section "winbuilder failures"
echo denied >"$SCRATCH/ftp-mode"
out=$(run winbuilder --commit "$COMMIT" "$TARBALL" R-devel R-release)
has "a refused upload fails" "$out" "exit 1"
has "loudly, naming the URL" "$out" "::error title=The upload to win-builder failed::curl exited with status"
is "for every flavor tried" "$(grep -c 'The upload to win-builder failed' <<<"$out")" 2
is "and outputs the results" "$(tail -n 1 "$SCRATCH/output")" "results=R-devel=failed R-release=failed"
hasnt "without promising an email" "$(cat "$SUMMARY")" "Win-builder emails the results"
echo denied-devel >"$SCRATCH/ftp-mode"
out=$(run winbuilder --commit "$COMMIT" "$TARBALL" R-devel R-release)
is "a failed queue does not stop the next" "$(tail -n 1 "$SCRATCH/output")" "results=R-devel=failed R-release=uploaded"
is "which got the file" "$(grep '^STOR ' "$SCRATCH/ftp-requests" | sed 's/ sha256=.*//')" "STOR /R-release/$UPLOADED"
is "and still fails the stage" "$(tail -n 1 <<<"$out")" "exit 1"
has "promising the email of that queue only" "$(cat "$SUMMARY")" "Win-builder emails the results for R-release to Jane Doe"
echo ok >"$SCRATCH/ftp-mode"
out=$(run winbuilder --commit "$COMMIT" "$TARBALL" R-devel R-patched)
has "an unknown flavor fails" "$out" "::error title=No win-builder flavor::\`R-patched\` is none of"
is "before anything is sent" "$(cat "$SCRATCH/ftp-requests")" ""
out=$(run winbuilder --commit "$COMMIT" "$TARBALL" "R-devel ")
has "a flavor with a space is none" "$out" "::error title=No win-builder flavor::"
is "and sends nothing" "$(cat "$SCRATCH/ftp-requests")" ""
out=$(run winbuilder --commit "$COMMIT" "$TARBALL" "")
has "an empty one is no flavor" "$out" "::error title=No win-builder flavor::No flavor was given"
out=$(run winbuilder --commit "$COMMIT" "$TARBALL" R-devel R-oldrelease R-devel)
is "a flavor given twice is uploaded once" "$(grep -c '^STOR ' "$SCRATCH/ftp-requests")" 2
is "and reported once" "$(tail -n 1 "$SCRATCH/output")" "results=R-devel=uploaded R-oldrelease=uploaded"
out=$(WINBUILDER_URL=ftp://127.0.0.1:1 run winbuilder --commit "$COMMIT" "$TARBALL" R-devel)
has "an unreachable server fails" "$out" "exit 1"
has "after two retries of the connection" "$out" "  attempt 2: curl exited with status 7, no connection"
hasnt "and no third" "$out" "  attempt 3:"
has "naming curl's status" "$out" "::error title=The upload to win-builder failed::curl exited with status 7"
echo stall >"$SCRATCH/ftp-mode"
out=$(WINBUILDER_MAX_TIME=2 run winbuilder --commit "$COMMIT" "$TARBALL" R-devel)
has "a timed-out upload fails" "$out" "curl exited with status 28"
is "without a retry, which could send part of the file again" "$(grep -c '^STOR-begin' "$SCRATCH/ftp-requests")" 1
echo ok >"$SCRATCH/ftp-mode"
out=$(run winbuilder --commit "$COMMIT" "$TARBALL")
has "no flavor fails, saying so" "$out" "::error title=No win-builder flavor::No flavor was given"
cp "$TARBALL" "$SCRATCH/pkg/fakepkg.tar.gz"
out=$(run winbuilder --commit "$COMMIT" "$SCRATCH/pkg/fakepkg.tar.gz" R-devel)
has "a misnamed tarball fails" "$out" "::error title=The tarball is misnamed::"
is "and sends nothing" "$(cat "$SCRATCH/ftp-requests")" ""
printf 'not a tarball' >"$SCRATCH/pkg/fakepkg_9.9.tar.gz"
out=$(run winbuilder --commit "$COMMIT" "$SCRATCH/pkg/fakepkg_9.9.tar.gz" R-devel)
has "a file that is no tarball fails" "$out" "::error title=The tarball cannot be read::"
cp "$TARBALL" "$SCRATCH/pkg/fakepkg_1.0.2.tar.gz"
out=$(run winbuilder --commit "$COMMIT" "$SCRATCH/pkg/fakepkg_1.0.2.tar.gz" R-devel)
has "a tarball of another release fails" "$out" "::error title=The tarball is of another release::"

section "winbuilder dry run"
out=$(run winbuilder --dry-run --commit "$COMMIT" "$TARBALL" R-devel R-release)
has "it succeeds" "$out" "exit 0"
is "and sends nothing" "$(cat "$SCRATCH/ftp-requests")" ""
has "it says what it would upload, and where" "$(cat "$SUMMARY")" "- R-release: would upload to $FTP/R-release/$UPLOADED"
is "the results say so, with the file's name" "$(tail -n 1 "$SCRATCH/output")" "results=R-devel=dry-run R-release=dry-run"
is "which comes first" "$(head -n 1 "$SCRATCH/output")" "tarball=$UPLOADED"
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
echo e403 >"$SCRATCH/mac-mode"
out=$(run macbuilder "$TARBALL" r-devel)
has "another refusal fails with its status" "$out" "::error title=Macbuilder refused the upload::The submission answered HTTP 403"
echo html >"$SCRATCH/mac-mode"
out=$(run macbuilder "$TARBALL" r-devel)
has "a 2xx answer that is no JSON fails" "$out" "::error title=No result URL from macbuilder::The submission answered HTTP 200"
echo scheme >"$SCRATCH/mac-mode"
out=$(run macbuilder "$TARBALL" r-devel)
has "a result URL with another scheme fails" "$out" "::error title=No result URL from macbuilder::"
echo userinfo >"$SCRATCH/mac-mode"
out=$(run macbuilder "$TARBALL" r-devel)
has "a result URL with user info fails" "$out" "::error title=No result URL from macbuilder::"
is "and outputs nothing" "$(cat "$SCRATCH/output")" ""
echo ok >"$SCRATCH/mac-mode"
out=$(run macbuilder "$TARBALL" '')
has "no flavor fails, saying so" "$out" "::error title=No macbuilder flavor::No flavor was given."
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
has "and a page without a status" "$out" "poll 2: the page shows no finished check yet"
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
out=$(run macbuilder-poll "$MAC/macbuilder/results/stray/")
has "a Status: line in a running page's log does not end the wait" "$out" "poll 1: the page shows no finished check yet"
is "the status is the one before the classification" "$(cat "$SCRATCH/output")" "outcome=ok
status=OK"
out=$(run macbuilder-poll "$MAC/macbuilder/results/crlf/")
is "CRLF line ends are dropped" "$(cat "$SCRATCH/output")" "outcome=ok
status=OK"
out=$(run macbuilder-poll "$MAC/macbuilder/results/inline/")
is "a page whose classification line ends the log is finished" "$(cat "$SCRATCH/output")" "outcome=note
status=1 NOTE"
has "with the classification without the tag" "$out" "$(printf '  %-20s %s' classification: 'NOTE, notes:yes')"
out=$(run macbuilder-poll "$MAC/macbuilder/results/odd/")
has "a status that is none of R CMD check's is unknown" "$(head -n 1 "$SCRATCH/output")" "outcome=unknown"
is "without backticks or control characters, at most 200 characters" "$(sed -n 's/^status=//p' "$SCRATCH/output")" \
  "done rm $(printf 'x%.0s' $(seq 192))"
has "and warns" "$out" "::warning title=Macbuilder result not understood::"
out=$(MACBUILDER_POLL_SECONDS=1 MACBUILDER_TIMEOUT_SECONDS=2 run macbuilder-poll "$MAC/macbuilder/results/e500/")
has "another HTTP status keeps waiting" "$out" "poll 1: HTTP 500"
has "until the timeout" "$(cat "$SCRATCH/output")" "outcome=timeout"
out=$(MACBUILDER_POLL_SECONDS=1 MACBUILDER_TIMEOUT_SECONDS=2 run macbuilder-poll "http://127.0.0.1:1/macbuilder/results/x/")
has "a failing curl keeps waiting" "$out" "poll 1: curl exited with status 7"
has "until the timeout, without failing" "$out" "exit 0"
out=$(run macbuilder-poll "http://user@127.0.0.1:1/macbuilder/results/x/")
has "a URL with user info is a usage error" "$out" "exit 2"
out=$(run macbuilder-poll "$MAC/elsewhere/")
has "a URL that is no result page is a usage error" "$out" "exit 2"

done_testing
