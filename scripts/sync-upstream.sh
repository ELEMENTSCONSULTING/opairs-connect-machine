#!/usr/bin/env bash
# Uebernimmt Aenderungen aus benthos-umh (Upstream) in einen neuen Branch.
#
#   ./scripts/sync-upstream.sh            # bis Upstream main
#   ./scripts/sync-upstream.sh <commit>   # bis zu einem bestimmten Commit
#
# Ablauf: Diff zwischen dem in UPSTREAM.md eingetragenen Basis-Commit und dem
# Ziel wird als 3-Wege-Merge angewendet. Ergebnis ist ein Branch
# chore/upstream-sync-<sha>, der per Pull Request geprueft wird.
# Konflikte (z. B. im Dockerfile) muessen von Hand geloest werden.
set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM_URL="https://github.com/united-manufacturing-hub/benthos-umh"
TARGET="${1:-main}"

[ -z "$(git status --porcelain)" ] || { echo "Arbeitsverzeichnis nicht sauber"; exit 1; }

OLD=$(grep -o 'Basis-Commit: `[0-9a-f]\{40\}`' UPSTREAM.md | grep -o '[0-9a-f]\{40\}')
[ -n "$OLD" ] || { echo "Basis-Commit nicht in UPSTREAM.md gefunden"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git clone --quiet "$UPSTREAM_URL" "$tmp/up"
NEW=$(git -C "$tmp/up" rev-parse "$TARGET")

if [ "$OLD" = "$NEW" ]; then
    echo "Bereits aktuell ($OLD)."
    exit 0
fi

# Gleiche Ausschluesse wie beim Basis-Import (siehe UPSTREAM.md).
git -C "$tmp/up" diff --binary "$OLD" "$NEW" -- . \
    ':(exclude).github' ':(exclude)CLAUDE.md' ':(exclude)CODEOWNERS' \
    ':(exclude).coderabbit.yaml' ':(exclude)renovate.json' \
    ':(exclude)CONTRIBUTOR_LICENSE_AGREEMENT_ENTITY.md' \
    ':(exclude)CONTRIBUTOR_LICENSE_AGREEMENT_INDIVIDUAL.md' \
  | sed -E -e 's#^(diff --git a/)README\.md( b/)README\.md$#\1README.upstream.md\2README.upstream.md#' \
           -e 's#^((---|\+\+\+) [ab]/)README\.md$#\1README.upstream.md#' \
  > "$tmp/upstream.patch"

if [ ! -s "$tmp/upstream.patch" ]; then
    echo "Keine relevanten Aenderungen zwischen ${OLD:0:7} und ${NEW:0:7}."
    exit 0
fi

BRANCH="chore/upstream-sync-${NEW:0:7}"
git checkout -b "$BRANCH"

if ! git apply --3way --index "$tmp/upstream.patch"; then
    echo
    echo "Konflikte beim Anwenden. Bitte loesen (git status), dann:"
    echo "  sed -i 's/$OLD/$NEW/' UPSTREAM.md && git add -A && git commit"
    exit 2
fi

sed -i "s/$OLD/$NEW/" UPSTREAM.md
git add UPSTREAM.md
git commit -q -m "Upstream-Sync benthos-umh ${OLD:0:7}..${NEW:0:7}"
echo "Branch $BRANCH erstellt. Jetzt pushen und Pull Request oeffnen:"
echo "  git push -u origin $BRANCH"
