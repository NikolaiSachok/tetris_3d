#!/bin/zsh
# Bumps the semantic version in VERSION: patch (bug fix), minor (feature) or major (breaking change).
# Usage: scripts/bump_version.sh patch|minor|major
set -euo pipefail

root="${0:A:h:h}"
file="$root/VERSION"
parts=("${(@s:.:)$(tr -d '[:space:]' < "$file")}")
[[ ${#parts} -eq 3 ]] || { echo "VERSION must be MAJOR.MINOR.PATCH" >&2; exit 1; }
major=${parts[1]} minor=${parts[2]} patch=${parts[3]}

case "${1:-}" in
    patch) patch=$((patch + 1)) ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    major) major=$((major + 1)); minor=0; patch=0 ;;
    *) echo "Usage: $0 patch|minor|major" >&2; exit 1 ;;
esac

echo "$major.$minor.$patch" > "$file"
echo "$major.$minor.$patch"
