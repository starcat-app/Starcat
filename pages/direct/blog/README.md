# Starcat Blog — authoring guide

Static blog for [starcat.ink](https://starcat.ink). Posts are Markdown; the browser renders them with [marked](https://github.com/markedjs/marked) (MIT, vendored under `vendor/marked.min.js`).

## Add a post

1. Create `posts/your-slug.md` (slug: lowercase letters, numbers, hyphens only).
2. Optional frontmatter at the top:

```markdown
---
title: Your Title
date: 2026-07-22
summary: One-line description for SEO / previews.
author: Starcat
---

Markdown body starts here.
```

3. Register the post in `posts/index.json` (list page + metadata). Newest posts should have the latest `date` — the list sorts by `date` descending.

```json
{
  "slug": "your-slug",
  "title": "Your Title",
  "summary": "One-line description for SEO / previews.",
  "date": "2026-07-22",
  "author": "Starcat",
  "minutes": 4
}
```

4. Deploy the `pages/` site as usual. No Markdown build step required.

## URLs

| Page | Path |
|------|------|
| List | `/blog/` or `/blog/index.html` |
| Post | `/blog/post.html?slug=your-slug` |

## Local preview

Serve the `pages/direct` directory over HTTP (file:// will block `fetch` of `.md` in most browsers):

```bash
cd pages/direct && python3 -m http.server 8765
```

Then open `http://127.0.0.1:8765/blog/`.
