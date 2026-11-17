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
[[ -d "$tmp/dm/pocket/dists" && ! -e "$tmp/dm/pocket/pool/old_1.0_amd64.deb" ]] \
  && ok "empty pocket re-mirrored fresh" || bad "empty pocket re-mirrored fresh" "$(find "$tmp/dm/pocket")"
expect "empty pocket, no .debs: first try"     0 ""                           -- dm_run "$tmp/dm/pocket" '^$'
mkdir -p "$tmp/dm/full"
expect "no filter: empty result stays fatal"   nonzero "unexpected retry"     -- dm_run "$tmp/dm/full" ''

# The airgap.conf.example must be valid bash
expect "example config parses"  0 ""                        -- bash -n "$root/airgap.conf.example"

echo "----"; echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
