#!/usr/bin/env bash
# Fast CLI tests (no network, no docker containers are started).
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$root/ubuntu-airgap.sh"
pass=0 fail=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '     %s\n' "$2"; }

# expect NAME EXIT_CODE GREP_PATTERN -- command...
expect() {
  local name="$1" want="$2" pat="$3"; shift 4
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [[ "$want" == nonzero && $rc -eq 0 ]] || [[ "$want" != nonzero && $rc -ne $want ]]; then
    bad "$name" "exit $rc (wanted $want): $(head -3 <<<"$out")"; return
  fi
  if [[ -n "$pat" ]] && ! grep -q -E -- "$pat" <<<"$out"; then
    bad "$name" "output does not match /$pat/: $(head -3 <<<"$out")"; return
  fi
  ok "$name"
}

ver="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$S")"
expect "syntax"                 0 ""                        -- bash -n "$S"
expect "version is semver"      0 '^[0-9]+\.[0-9]+\.[0-9]+$' -- echo "$ver"
expect "version command"        0 "ubuntu-airgap.sh $ver"   -- "$S" version
expect "--version"              0 "$ver"                    -- "$S" --version
expect "help"                   0 "COMMANDS"                -- "$S" help
expect "no args shows help"     0 "DOWNLOAD OPTIONS"        -- "$S"
expect "unknown command"        nonzero "unknown command"   -- "$S" frobnicate
expect "unknown option"         nonzero "unknown option"    -- "$S" download --nope
expect "download needs dest"    nonzero "--dest DIR is required" -- "$S" download
expect "repo needs name"        nonzero "needs name="       -- "$S" download -d "$tmp/m" --repo "url=https://e.com;suites=a;components=b;key=k"
expect "repo name reserved"     nonzero "reserved"          -- "$S" download -d "$tmp/m" --repo "name=ubuntu;url=https://e.com;suites=a;components=b;key=k"
expect "repo needs components"  nonzero "flat repositories" -- "$S" download -d "$tmp/m" --repo "name=x;url=https://e.com;suites=a;key=k"
expect "repo bad key"           nonzero "unknown key"       -- "$S" download -d "$tmp/m" --repo "name=x;url=https://e.com;suites=a;components=b;key=k;foo=1"
expect "repo key file missing"  nonzero "not readable"      -- "$S" download -d "$tmp/m" --repo "name=x;url=https://e.com;suites=a;components=b;key=$tmp/missing.gpg"
expect "ppa format"             nonzero "OWNER/NAME"        -- "$S" download -d "$tmp/m" --ppa "not a ppa"
expect "snap name format"       nonzero "NAME or NAME=CHANNEL" -- "$S" download -d "$tmp/m" --snap "Fire Fox"
expect "snap channel format"    nonzero "NAME or NAME=CHANNEL" -- "$S" download -d "$tmp/m" --snap "firefox=bad channel"
expect "snaps needs root"       nonzero "run as root|not a mirror" -- "$S" snaps -m "$tmp"
expect "help mentions --snap"   0 "--snap NAME"             -- "$S" help
expect "repo-deb must exist"    nonzero "not a readable"    -- "$S" download -d "$tmp/m" --repo-deb "$tmp/missing.deb"
expect "--opt=value form"       nonzero "--dest DIR is required" -- "$S" download --components=main
if [[ $EUID -ne 0 ]]; then
  expect "install needs root"   nonzero "run as root"       -- "$S" install -m "$tmp"
fi
expect "serve needs a mirror"   nonzero "not a mirror|no airgap-mirror.conf" -- "$S" serve -m "$tmp"

cat >"$tmp/cfg" <<'EOF'
DEST=/nonexistent/should/be/overridden
PPAS=("bad ppa from config")
EOF
expect "config file is read"    nonzero "OWNER/NAME"        -- "$S" download -c "$tmp/cfg"
expect "missing config file"    nonzero "cannot read config" -- "$S" download -c "$tmp/nope"

# Upgrade-plan classification (i386 removal guard, amd64v3 switch, downgrades)
sim='Inst libc6 [2.43-2ubuntu2] (2.43-2ubuntu2.7 Ubuntu:26.04/resolute-updates [amd64])
Inst bash [5.3-2ubuntu1] (5.3-2ubuntu1 Ubuntu:26.04/resolute [amd64])
Inst foo [2.0] (1.0 Ubuntu:26.04/resolute [amd64])
Remv libc6:i386 [2.43-2ubuntu2]
Remv wine32:i386 [10.0-1]
Remv oldpkg [1.0]
Conf libc6 (2.43-2ubuntu2.7 Ubuntu:26.04/resolute-updates [amd64])'
want='switch|bash
down|foo 2.0 -> 1.0
fremove|libc6:i386
fremove|wine32:i386'
if ! command -v dpkg >/dev/null; then          # downgrade check needs dpkg (always on Ubuntu)
  want="$(grep -v '^down|' <<<"$want")"
fi
got="$("$S" _classify-sim <<<"$sim" 2>/dev/null)"
if [[ "$got" == "$want" ]]; then ok "classify apt simulation"; else bad "classify apt simulation" "got: $(tr '\n' ';' <<<"$got")"; fi

# run_debmirror: an empty --package-filter result must not be fatal, even when
# the pocket directory still holds .debs that no longer match. The stub
# debmirror refuses an empty result unless the directory is new, like the real one.
mkdir -p "$tmp/dm/bin" "$tmp/dm/pocket/pool"; touch "$tmp/dm/pocket/pool/old_1.0_amd64.deb"
cat >"$tmp/dm/bin/debmirror" <<'STUB'
#!/usr/bin/env bash
t="${!#}"; [[ -d "$t" ]] && { echo "No packages after parsing Packages and Sources files!"; exit 2; }
mkdir -p "$t/dists"; echo "All done."
STUB
chmod +x "$tmp/dm/bin/debmirror"
dm_fn="$(sed -n '/^run_debmirror() {/,/^}/p' "$S")"
dm_run() {  # TARGET: run run_debmirror with the stub; sleep must never be reached
  PATH="$tmp/dm/bin:$PATH" bash -c 'set -Eeuo pipefail
    log() { :; }; warn() { echo "WARNING: $*" >&2; }; die() { echo "ERROR: $*" >&2; exit 1; }
    sleep() { echo "unexpected retry" >&2; exit 3; }
    CONTENTS=0 DRY_RUN=0 PACKAGE_FILTER="$2" DEBMIRROR_EXTRA=()
    eval "$1"; run_debmirror "$3" http archive.ubuntu.com ubuntu resolute-security main /k amd64' _ "$dm_fn" "$2" "$1"
}
expect "empty pocket, stale .debs: non-fatal"  0 "mirroring index files only" -- dm_run "$tmp/dm/pocket" '^$'
if [[ -d "$tmp/dm/pocket/dists" && ! -e "$tmp/dm/pocket/pool/old_1.0_amd64.deb" ]]; then
  ok "empty pocket re-mirrored fresh"
else
  bad "empty pocket re-mirrored fresh" "$(find "$tmp/dm/pocket")"
fi
expect "empty pocket, no .debs: first try"     0 ""                           -- dm_run "$tmp/dm/pocket" '^$'
mkdir -p "$tmp/dm/full"
expect "no filter: empty result stays fatal"   nonzero "unexpected retry"     -- dm_run "$tmp/dm/full" ''

# run_debmirror retries server outages: 5 attempts, 1/2/4/8 min apart
cat >"$tmp/dm/bin/debmirror-flaky" <<'STUB'
#!/usr/bin/env bash
n="$(cat "$DM_COUNT" 2>/dev/null || echo 0)"; echo $((n + 1)) >"$DM_COUNT"
[[ $n -ge $DM_FAILS ]] || { echo "Download of dists/resolute/Release failed: 503 Service Unavailable"; exit 1; }
mkdir -p "${!#}/dists"; echo "All done."
STUB
chmod +x "$tmp/dm/bin/debmirror-flaky"
dm_flaky() {  # FAILS: prints the sleeps and whether it gave up, one line
  rm -rf "$tmp/dm/count" "$tmp/dm/flaky" "$tmp/dm/events"
  mkdir -p "$tmp/dm/fbin"; ln -sf "$tmp/dm/bin/debmirror-flaky" "$tmp/dm/fbin/debmirror"
  PATH="$tmp/dm/fbin:$PATH" DM_COUNT="$tmp/dm/count" DM_FAILS="$1" EV="$tmp/dm/events" bash -c 'set -Eeuo pipefail
    log() { :; }; warn() { :; }; die() { echo "gave-up" >>"$EV"; exit 1; }; sleep() { echo "$1" >>"$EV"; }
    CONTENTS=0 DRY_RUN=0 PACKAGE_FILTER="" DEBMIRROR_EXTRA=()
    eval "$1"; run_debmirror "$2" http h r d s /k amd64' _ "$dm_fn" "$tmp/dm/flaky" >/dev/null 2>&1
  tr '\n' ' ' <"$tmp/dm/events" 2>/dev/null
}
expect "debmirror: outage retried with backoff" 0 "^60 120 240 \$"   -- dm_flaky 3
expect "debmirror: gives up after 5 attempts"  0 "^60 120 240 480 gave-up \$" -- dm_flaky 9

# check_repo_suite: a 503 outage is retried, only a 404 means "not found"
cat >"$tmp/srv.py" <<'PY'
import http.server, sys
hits = {}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        hits[self.path] = hits.get(self.path, 0) + 1
        if self.path.startswith("/flaky/") and hits[self.path] <= 2: code = 503
        elif self.path.startswith("/down/"): code = 503
        elif self.path.startswith("/flaky/dists/s/InRelease"): code = 200
        else: code = 404
        self.send_response(code); self.end_headers()
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_port))
srv.serve_forever()
PY
python3 -I "$tmp/srv.py" "$tmp/srv.port" & srv_pid=$!
for _ in $(seq 50); do [[ -s "$tmp/srv.port" ]] && break; python3 -c 'import time; time.sleep(0.1)'; done
srv="http://127.0.0.1:$(cat "$tmp/srv.port")"
crs_fn="$(sed -n '/^check_repo_suite() {/,/^}/p' "$S")"
crs_run() {  # URL [curl retry args]
  NO_PROXY='*' no_proxy='*' bash -c 'set -Eeuo pipefail
    die() { echo "ERROR: $*"; exit 1; }
    CURL_RETRY=('"${2:---retry 10 --retry-max-time 900}"')
    eval "$1"; check_repo_suite r "$2" s && echo found' _ "$crs_fn" "$1"
}
expect "repo check: 503 outage retried, then found" 0 "^found$"            -- crs_run "$srv/flaky"
expect "repo check: 404 means not found"           1 "not found \(flat"    -- crs_run "$srv/missing"
expect "repo check: outage is not 'not found'"     1 "cannot reach .*HTTP 503" -- crs_run "$srv/down" "--retry 1 --retry-delay 0"
kill "$srv_pid" 2>/dev/null

# snap_download retries a failing "snap download" (Snap Store rate limits)
mkdir -p "$tmp/sd/bin" "$tmp/sd/out"
cat >"$tmp/sd/bin/snap" <<'STUB'
#!/usr/bin/env bash
n="$(cat "$SD_COUNT" 2>/dev/null || echo 0)"; echo $((n + 1)) >"$SD_COUNT"
[[ $n -ge $SD_FAILS ]] || { touch partial.tmp; echo "error: too many requests" >&2; exit 1; }
touch "${2}_42.snap" "${2}_42.assert"
STUB
chmod +x "$tmp/sd/bin/snap"
sd_fn="$(sed -n '/^snap_download() {/,/^}/p' "$S")"
sd_run() {  # FAILS: run snap_download; prints sleeps, then the files left behind
  rm -f "$tmp/sd/count" "$tmp/sd/out"/*
  PATH="$tmp/sd/bin:$PATH" SD_COUNT="$tmp/sd/count" SD_FAILS="$1" bash -c 'set -Eeuo pipefail
    warn() { :; }; sleep() { echo "sleep $1"; }
    eval "$1"; snap_download hello latest/stable "$2"; ls "$2"' _ "$sd_fn" "$tmp/sd/out"
}
expect "snap download: retried until it works" 0 "^sleep 20$"            -- sd_run 2
if [[ "$(sd_run 2 2>/dev/null | tr '\n' ' ')" == "sleep 10 sleep 20 hello_42.assert hello_42.snap " ]]; then
  ok "snap download: partial files cleaned between attempts"
else
  bad "snap download: partial files cleaned between attempts" "$(sd_run 2 | tr '\n' ' ')"
fi
expect "snap download: gives up after 5 tries" 1 "sleep 80"               -- sd_run 9

# _missing: 404s on the mirror, minus InRelease when Release.gpg exists
mkdir -p "$tmp/mm/repos/ppa/dists/resolute" "$tmp/mm/repos/x/dists/resolute"
touch "$tmp/mm/repos/ppa/dists/resolute/Release" "$tmp/mm/repos/x/dists/resolute/Release"
echo sig >"$tmp/mm/repos/ppa/dists/resolute/Release.gpg"
cat >"$tmp/mm.log" <<'LOG'
127.0.0.1 - - [17/Nov/2026 17:47:56] "GET /repos/ppa/dists/resolute/InRelease HTTP/1.1" 404 -
127.0.0.1 - - [17/Nov/2026 17:47:56] "GET /repos/ppa/dists/resolute/Release HTTP/1.1" 200 -
127.0.0.1 - - [17/Nov/2026 17:47:56] "GET /repos/x/dists/resolute/InRelease HTTP/1.1" 404 -
127.0.0.1 - - [17/Nov/2026 17:47:57] "GET /ubuntu/pool/main/h/hello/hello_1_amd64.deb HTTP/1.1" 404 -
127.0.0.1 - - [17/Nov/2026 17:47:57] "GET /ubuntu/pool/main/h/hello/hello_1_amd64.deb HTTP/1.1" 404 -
LOG
got="$("$S" _missing -m "$tmp/mm" <"$tmp/mm.log" 2>&1 | tr '\n' ' ')"
if [[ "$got" == "/repos/x/dists/resolute/InRelease /ubuntu/pool/main/h/hello/hello_1_amd64.deb " ]]; then
  ok "404 report skips InRelease when Release.gpg exists"
else
  bad "404 report skips InRelease when Release.gpg exists" "got: $got"
fi
# A clean log (no 404s at all, the normal case) must not be an error
grep -v '" 404 ' "$tmp/mm.log" >"$tmp/mm-clean.log"
expect "404 report: clean log is not an error" 0 "^$" -- "$S" _missing -m "$tmp/mm" <"$tmp/mm-clean.log"
expect "404 report: empty log is not an error" 0 "^$" -- "$S" _missing -m "$tmp/mm" </dev/null

# The airgap.conf.example must be valid bash
expect "example config parses"  0 ""                        -- bash -n "$root/airgap.conf.example"

echo "----"; echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
