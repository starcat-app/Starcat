# Contributing

Thanks for improving Starcat Chrome Plugin.

## Scope

This extension is intentionally small. It should only enhance GitHub repository pages with context provided by the local Starcat app.

Do not add:

- Direct GitHub API calls.
- Direct Starcat backend calls.
- Direct OpenSSF or AI provider calls.
- Background polling, badge logic, right-click menus, or capture workflows unless the product scope changes first.

## Local Development

Load the extension manually:

1. Open `chrome://extensions/`.
2. Enable Developer mode.
3. Click Load unpacked.
4. Select `supports/extensions/starcat-chrome-plugin`.

## Structure

```text
supports/extensions/starcat-chrome-plugin/
  manifest.json
  src/
    content/
    options/
    shared/
```

## Checks

Run these before submitting changes:

```bash
python3 -m json.tool supports/extensions/starcat-chrome-plugin/manifest.json >/dev/null
node --check supports/extensions/starcat-chrome-plugin/src/shared/shared.js
node --check supports/extensions/starcat-chrome-plugin/src/options/options.js
node --check supports/extensions/starcat-chrome-plugin/src/content/content-script.js
```

If Starcat app API paths or DTOs change, also run the Companion app-side checks documented in the main Starcat repository.

## Pull Request Expectations

- Keep changes scoped.
- Update `README.md` when setup or behavior changes.
- Update `PRIVACY.md` when data handling changes.
- Update `SECURITY.md` when token handling, permissions, or local API behavior changes.
- Update `CHANGELOG.md` for user-visible changes.
