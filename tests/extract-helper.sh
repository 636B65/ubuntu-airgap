#!/usr/bin/env bash
# Extract the embedded Python helper (PY_HELPER) from ubuntu-airgap.sh so that
# it can be linted and unit tested.  Usage: tests/extract-helper.sh OUTFILE
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:?usage: $0 OUTFILE}"
sed -n "/^PY_HELPER=\$(cat <<'PY'\$/,/^PY\$/p" "$root/ubuntu-airgap.sh" | sed '1d;$d' >"$out"
[[ -s "$out" ]] || { echo "could not extract PY_HELPER" >&2; exit 1; }
