#!/usr/bin/env bash
# CI-Hilfe: fuehrt einen Befehl aus, schreibt die Ausgabe in ein Log und gibt
# bei Fehler die letzten Zeilen zusaetzlich als GitHub-Annotation aus (damit
# sie auch ohne Zugriff auf die Job-Logs sichtbar sind).
#
#   scripts/ci-run.sh "<Titel>" <befehl> [args...]
set -uo pipefail
title="$1"; shift
log="$(mktemp)"
"$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
if [ "$rc" -ne 0 ]; then
    msg=$(tail -n 40 "$log" | sed -e 's/%/%25/g' -e 's/\r/%0D/g' | awk 'BEGIN{ORS="%0A"} {print}')
    echo "::error title=${title}::${msg}"
fi
rm -f "$log"
exit "$rc"
