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

# The airgap.conf.example must be valid bash
expect "example config parses"  0 ""                        -- bash -n "$root/airgap.conf.example"

echo "----"; echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]
