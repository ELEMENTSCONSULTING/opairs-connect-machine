# Upstream

Dieses Repository basiert auf **benthos-umh** der UMH Systems GmbH
(https://github.com/united-manufacturing-hub/benthos-umh), lizenziert unter
der Apache License 2.0 (siehe `LICENSE` und `NOTICE`).

- Basis-Commit: `fdd6fb9d99c551058fb3e92747a2770a3b7f5baf`
  (Merge pull request #474, Stand 2026-10-30)
- Der Basis-Commit auf `main` enthaelt den Upstream-Code unveraendert, mit
  folgenden bewusst weggelassenen Projektdateien (UMH-interne Prozesse):
  `.github/` (CI/Release von UMH), `CLAUDE.md`, `CODEOWNERS`,
  `.coderabbit.yaml`, `renovate.json`, `CONTRIBUTOR_LICENSE_AGREEMENT_*`.
- Aenderungen von ELEMENTS Consulting erfolgen ausschliesslich in
  nachfolgenden Commits und Pull Requests.
- Das upstream `README.md` liegt hier als `README.upstream.md`.

## Upstream-Aenderungen uebernehmen

```bash
./scripts/sync-upstream.sh            # bis Upstream main
./scripts/sync-upstream.sh <commit>   # bis zu einem bestimmten Commit
```

Das Skript bildet den Diff zwischen dem oben eingetragenen Basis-Commit und dem
Ziel (mit denselben Ausschluessen wie beim Import), wendet ihn als
3-Wege-Merge auf einem neuen Branch `chore/upstream-sync-<sha>` an und
aktualisiert den Basis-Commit in dieser Datei. Konflikte (am ehesten im
`Dockerfile`, das hier angepasst ist) werden von Hand geloest. Danach Branch
pushen und per Pull Request pruefen; die CI baut und testet den Stack.
