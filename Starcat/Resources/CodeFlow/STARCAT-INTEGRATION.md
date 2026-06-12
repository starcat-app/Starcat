# CodeFlow vendored integration

- Upstream: https://github.com/braedonsaunders/codeflow
- Commit: `51ab9708841e14258bebfb5fb326e8b37782d193`
- Imported: 2026-06-13
- Upstream license statement: README says `MIT License`; the imported commit does not contain a `LICENSE` file.

Starcat changes are intentionally narrow:

1. Add the `__STARCAT_CODEFLOW_PAYLOAD_TOKEN__` payload placeholder.
2. On page load, decode the injected project payload into browser `File[]` objects.
3. Reuse upstream `readLocalFolderFromFiles` so analysis and visualization behavior remain upstream-compatible.

Do not replace the vendored HTML without reapplying and verifying these three changes.
