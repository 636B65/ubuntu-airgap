#!/usr/bin/env bash
# Run every lint check that CI runs, the same way (the CI Lint job runs this).
#
#   tests/lint.sh                 run all checks, report every failure
#   ln -s ../../tests/lint.sh .git/hooks/pre-push   run them before each push
#   ZIZMOR_ONLINE=1 tests/lint.sh  also run zizmor's online audits (needs GH_TOKEN)
#
# Tools: shellcheck, python3, node (npx). The Python tools (ruff, codespell,
# zizmor) come from .github/requirements/lint.txt:
#   pip install --require-hashes --no-deps -r .github/requirements/lint.txt
# actionlint runs from its local binary, else from the pinned Docker image.
set -uo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." || exit 1

ci="$(cat .github/workflows/ci.yml)"
pin() { sed -n "s/^  $1: \"\(.*\)\"$/\1/p" <<<"$ci"; }   # pinned versions in ci.yml env
MARKDOWNLINT_VERSION="${MARKDOWNLINT_VERSION:-$(pin MARKDOWNLINT_VERSION)}"
ACTIONLINT_IMAGE="${ACTIONLINT_IMAGE:-$(pin ACTIONLINT_IMAGE)}"

failed=()
check() {  # NAME command...
  local name="$1"; shift
  printf '\033[1;34m### %s\033[0m\n' "$name"
  if "$@"; then return 0; fi
  failed+=("$name")
}
need() {  # NAME TOOL: fail the check (not the script) when TOOL is missing
  command -v "$2" >/dev/null && return 0
  echo "$2 is not installed" >&2; failed+=("$1"); return 1
}

if need ShellCheck shellcheck; then
  check ShellCheck shellcheck -x ubuntu-airgap.sh tests/*.sh .github/*.sh
fi

bash_syntax() {
  local f rc=0
  for f in ubuntu-airgap.sh tests/*.sh .github/*.sh airgap.conf.example; do bash -n "$f" || rc=1; done
  return $rc
}
check "Bash syntax" bash_syntax

ruff_check() {
  tests/extract-helper.sh tests/.airgap_helper_lint.py && ruff check ${CI:+--output-format github} tests/
}
if need Ruff ruff; then check "Ruff (embedded Python helper + tests)" ruff_check; fi
if need Codespell codespell; then check Codespell codespell; fi

actionlint_check() {
  if command -v actionlint >/dev/null; then actionlint
  else docker run --rm -v "$PWD:/repo" -w /repo "$ACTIONLINT_IMAGE" -color
  fi
}
check actionlint actionlint_check

if need "Markdown lint" npx; then
  check "Markdown lint" npx --yes "markdownlint-cli2@${MARKDOWNLINT_VERSION}" "**/*.md"
fi

# CI audits workflows in its own zizmor job (online, with SARIF upload).
# Locally offline by default; ZIZMOR_ONLINE=1 (with GH_TOKEN) adds online audits.
if [[ -z "${CI:-}" ]] && need zizmor zizmor; then
  zizmor_args=(--format plain)
  [[ "${ZIZMOR_ONLINE:-0}" == 1 ]] || zizmor_args+=(--offline)
  check "zizmor (workflow security)" zizmor "${zizmor_args[@]}" .github/workflows/
fi

echo
if [[ ${#failed[@]} -gt 0 ]]; then
  printf '\033[1;31mFAILED:\033[0m %s\n' "${failed[@]}"
  exit 1
fi
printf '\033[1;32mAll lint checks passed.\033[0m\n'
