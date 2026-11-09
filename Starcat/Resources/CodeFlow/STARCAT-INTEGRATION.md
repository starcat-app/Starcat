# CodeFlow vendored integration

- Upstream: https://github.com/braedonsaunders/codeflow
- Commit: `51ab9708841e14258bebfb5fb326e8b37782d193`
- Imported: 2026-06-13
- Upstream license statement: README says `MIT License`; the imported commit does not contain a `LICENSE` file.

Starcat changes are intentionally narrow:

1. Add the `__STARCAT_CODEFLOW_ZIP_PAYLOAD_TOKEN__` placeholder.
2. On page load, decode the injected GitHub ZIP into a browser `File` object.
3. Reuse upstream `readZipArchive` so JSZip extraction, analysis, and visualization remain upstream-compatible.
4. Pin the previously floating `3d-force-graph` CDN reference to `1.80.2/dist/3d-force-graph.min.js` (dependency audit, 2026-11-09).

Do not replace the vendored HTML without reapplying and verifying these four changes.
