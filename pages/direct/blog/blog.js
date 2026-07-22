/**
 * Starcat Blog helpers.
 *
 * Why a thin wrapper: pages stay static HTML; authors only drop Markdown under
 * posts/ and register the slug in posts/index.json. marked.js turns MD → HTML
 * in the browser so we do not need a build step for every draft.
 *
 * Constraints:
 * - CSP on starcat.ink only allows same-origin scripts → marked is vendored.
 * - connect-src is 'self' → fetch posts/*.md from this origin only.
 * - Slug must match /^[a-z0-9]+(?:-[a-z0-9]+)*$/ to avoid path traversal.
 */
(function (global) {
    'use strict';

    var SLUG_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

    /**
     * Split optional YAML-ish frontmatter from the Markdown body.
     * Only simple `key: value` lines are supported (no nested YAML).
     */
    function parseFrontmatter(raw) {
        var text = String(raw || '').replace(/^\uFEFF/, '');
        if (!text.startsWith('---\n') && !text.startsWith('---\r\n')) {
            return { meta: {}, body: text };
        }
        var end = text.indexOf('\n---', 3);
        if (end === -1) {
            return { meta: {}, body: text };
        }
        var fmBlock = text.slice(4, end);
        var body = text.slice(end + 4).replace(/^\r?\n/, '');
        var meta = {};
        fmBlock.split(/\r?\n/).forEach(function (line) {
            var m = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
            if (!m) return;
            var key = m[1].trim();
            var value = m[2].trim();
            if ((value.startsWith('"') && value.endsWith('"')) ||
                (value.startsWith("'") && value.endsWith("'"))) {
                value = value.slice(1, -1);
            }
            meta[key] = value;
        });
        return { meta: meta, body: body };
    }

    function isValidSlug(slug) {
        return typeof slug === 'string' && SLUG_RE.test(slug);
    }

    function getSlugFromQuery() {
        try {
            var params = new URLSearchParams(window.location.search);
            return params.get('slug') || '';
        } catch (e) {
            return '';
        }
    }

    /** Format ISO date (YYYY-MM-DD) for display, e.g. July 22, 2026. */
    function formatDate(iso) {
        if (!iso) return '';
        var parts = String(iso).split('-');
        if (parts.length !== 3) return iso;
        var months = [
            'January', 'February', 'March', 'April', 'May', 'June',
            'July', 'August', 'September', 'October', 'November', 'December'
        ];
        var month = months[Number(parts[1]) - 1];
        var day = Number(parts[2]);
        if (!month || !day) return iso;
        return month + ' ' + day + ', ' + parts[0];
    }

    /** Rough reading-time estimate (~220 wpm). */
    function estimateMinutes(markdownBody) {
        var words = String(markdownBody || '').trim().split(/\s+/).filter(Boolean).length;
        return Math.max(1, Math.round(words / 220));
    }

    function escapeHtml(str) {
        return String(str)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }

    function loadIndex() {
        return fetch('posts/index.json', { cache: 'no-cache' })
            .then(function (res) {
                if (!res.ok) throw new Error('Failed to load posts/index.json (' + res.status + ')');
                return res.json();
            })
            .then(function (data) {
                var posts = Array.isArray(data) ? data : (data.posts || []);
                return posts.slice().sort(function (a, b) {
                    return String(b.date || '').localeCompare(String(a.date || ''));
                });
            });
    }

    function loadPost(slug) {
        if (!isValidSlug(slug)) {
            return Promise.reject(new Error('Invalid post slug.'));
        }
        return fetch('posts/' + slug + '.md', { cache: 'no-cache' })
            .then(function (res) {
                if (!res.ok) throw new Error('Post not found (' + slug + ').');
                return res.text();
            })
            .then(function (raw) {
                var parsed = parseFrontmatter(raw);
                return {
                    slug: slug,
                    meta: parsed.meta,
                    body: parsed.body,
                    minutes: estimateMinutes(parsed.body)
                };
            });
    }

    function renderMarkdown(markdown) {
        if (!global.marked || typeof global.marked.parse !== 'function') {
            throw new Error('marked.js is not loaded.');
        }
        // GFM keeps tables / strikethrough usable for future posts.
        if (typeof global.marked.setOptions === 'function') {
            global.marked.setOptions({ gfm: true, breaks: false });
        }
        return global.marked.parse(markdown);
    }

    global.StarcatBlog = {
        parseFrontmatter: parseFrontmatter,
        isValidSlug: isValidSlug,
        getSlugFromQuery: getSlugFromQuery,
        formatDate: formatDate,
        estimateMinutes: estimateMinutes,
        escapeHtml: escapeHtml,
        loadIndex: loadIndex,
        loadPost: loadPost,
        renderMarkdown: renderMarkdown
    };
})(window);
