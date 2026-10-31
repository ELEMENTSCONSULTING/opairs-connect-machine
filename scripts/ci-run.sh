#!/usr/bin/env bash
# CI-Hilfe: fuehrt einen Befehl aus, schreibt die Ausgabe in ein Log und gibt
# bei Fehler die letzten Zeilen zusaetzlich als GitHub-Annotation aus (damit
# sie auch ohne Zugriff auf die Job-Logs sichtbar sind).
#
#   scripts/ci-run.sh "<Titel>" <befehl> [args...]
#
# Mit CI_NOTICE=1 werden die letzten Zeilen auch bei Erfolg als Hinweis
# ausgegeben (Nachweis, dass Tests wirklich gelaufen sind).
set -uo pipefail
title="$1"; shift
log="$(mktemp)"
"$@" 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
annot() { tail -n "$2" "$log" | sed -e 's/%/%25/g' -e 's/\r/%0D/g' | awk 'BEGIN{ORS="%0A"} {print}'; }
if [ "$rc" -ne 0 ]; then
    echo "::error title=${title}::$(annot x 40)"
elif [ "${CI_NOTICE:-0}" = "1" ]; then
    echo "::notice title=${title}::$(annot x 25)"
fi
rm -f "$log"
exit "$rc"
