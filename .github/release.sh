#!/usr/bin/env bash
# Build and publish the GitHub release for tag vX.Y.Z on commit $GITHUB_SHA.
# Used by release.yml (tag pushed by a person) and by CI (green push to main
# whose VERSION has no tag yet; gh creates the tag on $GITHUB_SHA).
#
#   .github/release.sh build   vX.Y.Z   checks + tests, release/assets/* and release/notes.md
#   (the workflow attests release/assets/* here: build provenance, Sigstore-signed)
#   .github/release.sh publish vX.Y.Z   gh release create (needs GH_TOKEN, contents: write)
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

cmd="${1:-}" tag_name="${2:-}"
[[ "$cmd" =~ ^(build|publish)$ && -n "$tag_name" ]] || { echo "usage: $0 build|publish vX.Y.Z" >&2; exit 2; }
tag="${tag_name#v}"
out=release

if [[ "$cmd" == build ]]; then
  script_version="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' ubuntu-airgap.sh)"
  echo "script: $script_version  tag: $tag"
  [[ "$script_version" == "$tag" ]] || { echo "::error::VERSION ($script_version) != tag ($tag)"; exit 1; }
  [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "::error::tag is not semver"; exit 1; }
  grep -q "^## \[$tag\]" CHANGELOG.md || { echo "::error::CHANGELOG.md has no section for $tag"; exit 1; }

  tests/test_cli.sh
  python3 -m unittest discover -s tests

  rm -rf "$out"; mkdir -p "$out/assets"
  awk -v t="$tag" '
    $0 ~ "^## \\[" t "\\]" {on=1; next}
    on && /^## \[/ {exit}
    on {print}
  ' CHANGELOG.md > "$out/notes.md"
  cat >> "$out/notes.md" <<EOF

### Verify

The files are signed with [build provenance](https://docs.github.com/actions/security-for-github-actions/using-artifact-attestations)
from this repository's release workflow:

\`\`\`bash
sha256sum -c SHA256SUMS
gh attestation verify ubuntu-airgap.sh --repo ${GITHUB_REPOSITORY:-636B65/ubuntu-airgap}
\`\`\`
EOF
  cat "$out/notes.md"
  cp ubuntu-airgap.sh airgap.conf.example "$out/assets/"
  (cd "$out/assets" && sha256sum ./* > SHA256SUMS)
  exit 0
fi

prerelease=()
[[ "$tag" == *-* ]] && prerelease=(--prerelease)
# --target only matters when the tag does not exist yet (the CI path)
gh release create "$tag_name" "$out/assets"/* --target "${GITHUB_SHA:?}" \
  --title "ubuntu-airgap $tag_name" --notes-file "$out/notes.md" "${prerelease[@]}"
