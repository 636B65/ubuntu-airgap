#!/usr/bin/env bash
# Publish the GitHub release for tag $1 (vX.Y.Z) on commit $GITHUB_SHA.
# Used by release.yml (tag pushed by a person) and by CI (green push to main
# whose VERSION has no tag yet; gh creates the tag on $GITHUB_SHA).
# Needs GH_TOKEN with contents: write.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tag_name="${1:?usage: release.sh vX.Y.Z}"
tag="${tag_name#v}"

script_version="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' ubuntu-airgap.sh)"
echo "script: $script_version  tag: $tag"
[[ "$script_version" == "$tag" ]] || { echo "::error::VERSION ($script_version) != tag ($tag)"; exit 1; }
[[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "::error::tag is not semver"; exit 1; }
grep -q "^## \[$tag\]" CHANGELOG.md || { echo "::error::CHANGELOG.md has no section for $tag"; exit 1; }

tests/test_cli.sh
python3 -m unittest discover -s tests

work="$(mktemp -d)"
awk -v t="$tag" '
  $0 ~ "^## \\[" t "\\]" {on=1; next}
  on && /^## \[/ {exit}
  on {print}
' CHANGELOG.md > "$work/notes.md"
cat "$work/notes.md"

mkdir "$work/dist"
cp ubuntu-airgap.sh airgap.conf.example "$work/dist/"
(cd "$work/dist" && sha256sum ./* > SHA256SUMS)
prerelease=()
[[ "$tag" == *-* ]] && prerelease=(--prerelease)
# --target only matters when the tag does not exist yet (the CI path)
gh release create "$tag_name" "$work/dist"/* --target "${GITHUB_SHA:?}" \
  --title "ubuntu-airgap $tag_name" --notes-file "$work/notes.md" "${prerelease[@]}"
