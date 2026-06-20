#!/usr/bin/env python3
"""
将项目根目录的 CHANGELOG.md 转换为 pages/changelog.html。
暗色主题，与落地页风格一致。
用法: python3 generate-changelog.py
"""

import re
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
MD_PATH = PROJECT_ROOT / "CHANGELOG.md"
HTML_PATH = SCRIPT_DIR / "changelog.html"

HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="zh-Hans">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="description" content="Starcat Changelog — 版本更新记录">
    <meta name="robots" content="index, follow">
    <title>更新记录 · Starcat</title>
    <link rel="icon" type="image/png" href="starcat-logo.png">

    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;500;600;700&display=swap" rel="stylesheet">

    <style>
        :root {{
            --color-bg:         #0F172A;
            --color-bg-soft:    #1E293B;
            --color-card:       rgba(30, 41, 59, 0.6);
            --color-border:     rgba(148, 163, 184, 0.12);
            --color-border-hover: rgba(148, 163, 184, 0.25);
            --color-text:       #F8FAFC;
            --color-text-secondary: #94A3B8;
            --color-text-tertiary:  #64748B;
            --color-primary:    #38BDF8;
            --color-primary-hover: #7DD3FC;
            --color-cta:        #22C55E;
            --color-success:    #4ADE80;
            --color-accent:     #FBBF24;
            --color-pro:        #A78BFA;
            --fs-hero: clamp(28px, 4vw, 40px);
            --fs-h2: clamp(22px, 3vw, 28px);
            --fs-h3: 20px;
            --fs-body: 16px;
            --fs-small: 14px;
            --radius: 14px; --radius-sm: 8px;
            --font-sans: 'IBM Plex Sans', -apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif;
            --font-mono: 'JetBrains Mono', 'SF Mono', Menlo, Consolas, monospace;
        }}

        * {{ box-sizing: border-box; }}
        html {{ scroll-behavior: smooth; -webkit-text-size-adjust: 100%; }}
        body {{
            margin: 0; background: var(--color-bg); color: var(--color-text);
            font-family: var(--font-sans); font-size: var(--fs-body); line-height: 1.7;
            -webkit-font-smoothing: antialiased; -moz-osx-font-smoothing: grayscale;
        }}
        ::selection {{ background: rgba(34, 197, 94, 0.3); color: var(--color-text); }}
        a {{ color: var(--color-primary); text-decoration: none; transition: color .15s ease; }}
        a:hover {{ color: var(--color-primary-hover); }}
        code {{
            background: rgba(148, 163, 184, 0.12); border-radius: 4px;
            padding: 2px 6px; font-family: var(--font-mono); font-size: 0.9em; color: var(--color-text);
        }}

        .topbar {{ position: sticky; top: 0; z-index: 50; background: rgba(15, 23, 42, 0.75); backdrop-filter: blur(24px); -webkit-backdrop-filter: blur(24px); border-bottom: 1px solid var(--color-border); }}
        .topbar-inner {{ max-width: 900px; margin: 0 auto; padding: 14px 24px; display: flex; align-items: center; justify-content: space-between; }}
        .brand {{ display: flex; align-items: center; gap: 10px; font-family: 'JetBrains Mono', monospace; font-weight: 700; font-size: 17px; color: var(--color-text); }}
        .brand-logo {{ width: 28px; height: 28px; border-radius: 7px; }}
        .topbar-nav {{ display: flex; gap: 28px; font-size: 14px; }}
        .topbar-nav a {{ color: var(--color-text-secondary); font-weight: 400; transition: color .15s ease; }}
        .topbar-nav a:hover {{ color: var(--color-text); text-decoration: none; }}

        .hero {{ background: linear-gradient(180deg, var(--color-bg) 0%, var(--color-bg-soft) 100%); padding: 72px 24px 56px; border-bottom: 1px solid var(--color-border); }}
        .hero-inner {{ max-width: 900px; margin: 0 auto; }}
        .hero-eyebrow {{ font-family: 'JetBrains Mono', monospace; font-size: 13px; text-transform: uppercase; letter-spacing: 0.15em; color: var(--color-cta); font-weight: 600; margin: 0 0 12px; }}
        .hero h1 {{ font-family: 'JetBrains Mono', monospace; font-size: var(--fs-hero); font-weight: 700; margin: 0 0 16px; letter-spacing: -0.02em; }}

        main {{ max-width: 900px; margin: 0 auto; padding: 48px 24px 96px; }}
        .changelog-content {{ background: var(--color-card); border: 1px solid var(--color-border); border-radius: var(--radius); padding: 48px 56px; backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); }}

        .changelog-content h1 {{ font-family: 'JetBrains Mono', monospace; font-size: var(--fs-hero); font-weight: 700; margin: 0 0 8px; color: var(--color-text); }}
        .changelog-content h2 {{ font-family: 'JetBrains Mono', monospace; font-size: var(--fs-h2); font-weight: 700; margin: 48px 0 16px; padding-bottom: 12px; border-bottom: 1px solid var(--color-border); color: var(--color-text); }}
        .changelog-content h2:first-of-type {{ margin-top: 0; }}
        .changelog-content h3 {{ font-family: 'JetBrains Mono', monospace; font-size: var(--fs-h3); font-weight: 600; margin: 32px 0 12px; color: var(--color-cta); }}
        .changelog-content p {{ margin: 12px 0; color: var(--color-text-secondary); line-height: 1.7; }}
        .changelog-content ul {{ padding-left: 20px; margin: 12px 0; list-style: none; }}
        .changelog-content ul li {{ margin: 10px 0; color: var(--color-text-secondary); line-height: 1.6; position: relative; padding-left: 16px; }}
        .changelog-content ul li::before {{ content: "·"; position: absolute; left: 0; color: var(--color-text-tertiary); font-weight: 700; }}
        .changelog-content strong {{ color: var(--color-text); font-weight: 600; }}
        .changelog-content a {{ color: var(--color-primary); }}
        .changelog-content a:hover {{ color: var(--color-primary-hover); }}
        .changelog-content hr {{ border: none; border-top: 1px solid var(--color-border); margin: 40px 0; }}
        .changelog-content blockquote {{ border-left: 3px solid var(--color-border); padding: 8px 16px; margin: 16px 0; color: var(--color-text-tertiary); font-style: italic; background: rgba(148,163,184,0.05); border-radius: 0 var(--radius-sm) var(--radius-sm) 0; }}
        .changelog-content blockquote p {{ color: var(--color-text-tertiary); }}

        footer.site-footer {{ background: var(--color-bg); border-top: 1px solid var(--color-border); padding: 40px 24px; color: var(--color-text-tertiary); font-size: 13px; text-align: center; }}
        footer.site-footer .links {{ display: flex; justify-content: center; gap: 28px; margin-bottom: 16px; flex-wrap: wrap; }}
        footer.site-footer .links a {{ color: var(--color-text-tertiary); transition: color .15s ease; }}
        footer.site-footer .links a:hover {{ color: var(--color-text-secondary); text-decoration: none; }}
        footer.site-footer .copyright {{ color: var(--color-text-tertiary); font-size: 12px; margin: 0; }}

        @media (max-width: 767px) {{
            .changelog-content {{ padding: 28px 22px; }}
            .topbar-nav {{ display: none; }}
            .hero {{ padding: 48px 16px 36px; }}
            .hero h1 {{ font-size: 28px; }}
        }}
    </style>
</head>
<body>

<header class="topbar" role="banner">
    <div class="topbar-inner">
        <a class="brand" href="./index.html">
            <img src="starcat-logo.png" alt="Starcat" class="brand-logo" width="28" height="28">
            <span>Starcat</span>
        </a>
        <nav class="topbar-nav" aria-label="导航">
            <a href="./index.html">Home</a>
            <a href="./privacy.html">Privacy</a>
            <a href="./changelog.html" style="color:var(--color-text);font-weight:500;">Changelog</a>
        </nav>
    </div>
</header>

<section class="hero">
    <div class="hero-inner">
        <p class="hero-eyebrow">Release Notes</p>
        <h1>Changelog</h1>
    </div>
</section>

<main>
    <div class="changelog-content">
{content}
    </div>
</main>

<footer class="site-footer" role="contentinfo">
    <div class="links">
        <a href="./index.html">Home</a>
        <a href="./privacy.html">Privacy Policy</a>
        <a href="./changelog.html">Changelog</a>
        <a href="mailto:dong4j@gmail.com">Contact</a>
    </div>
    <p class="copyright">Copyright &copy; 2026 Starcat. All rights reserved.</p>
</footer>

</body>
</html>
"""


def md_to_html(text: str) -> str:
    """Simple Markdown to HTML converter. Handles the subset used in CHANGELOG.md."""
    lines = text.split("\n")
    out = []
    i = 0
    in_code_block = False
    in_list = False
    in_blockquote = False

    while i < len(lines):
        line = lines[i]

        # Code blocks
        if line.startswith("```"):
            if in_code_block:
                out.append("</code></pre>")
                in_code_block = False
            else:
                out.append("<pre><code>")
                in_code_block = True
            i += 1
            continue

        if in_code_block:
            out.append(_escape(line))
            i += 1
            continue

        # Empty line
        if not line.strip():
            if in_list:
                out.append("</ul>")
                in_list = False
            if in_blockquote:
                out.append("</blockquote>")
                in_blockquote = False
            i += 1
            continue

        # Blockquote
        if line.startswith("> "):
            if not in_blockquote:
                out.append("<blockquote>")
                in_blockquote = True
            content = _inline(line[2:])
            out.append(f"<p>{content}</p>")
            i += 1
            continue
        elif line.startswith(">") and in_blockquote:
            content = _inline(line[1:].lstrip())
            out.append(f"<p>{content}</p>")
            i += 1
            continue
        elif in_blockquote and not line.startswith(">"):
            out.append("</blockquote>")
            in_blockquote = False

        # Horizontal rule
        if line.strip() == "---":
            if in_list:
                out.append("</ul>")
                in_list = False
            out.append("<hr>")
            i += 1
            continue

        # Headings
        if line.startswith("# "):
            if in_list:
                out.append("</ul>")
                in_list = False
            out.append(f"<h1>{_inline(line[2:])}</h1>")
            i += 1
            continue
        if line.startswith("## "):
            if in_list:
                out.append("</ul>")
                in_list = False
            # Parse version heading like "## [1.0.0] — 2026-06-19"
            out.append(f"<h2>{_inline(line[3:])}</h2>")
            i += 1
            continue
        if line.startswith("### "):
            if in_list:
                out.append("</ul>")
                in_list = False
            out.append(f"<h3>{_inline(line[4:])}</h3>")
            i += 1
            continue

        # Unordered list
        if re.match(r"^- ", line):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{_inline(line[2:])}</li>")
            i += 1
            continue

        # Paragraph
        if in_list:
            out.append("</ul>")
            in_list = False
        out.append(f"<p>{_inline(line)}</p>")
        i += 1

    if in_list:
        out.append("</ul>")
    if in_blockquote:
        out.append("</blockquote>")
    if in_code_block:
        out.append("</code></pre>")

    return "\n".join(out)


def _inline(text: str) -> str:
    """Handle inline markdown: bold, italic, code, links."""
    # Links [text](url)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2" target="_blank" rel="noopener">\1</a>', text)
    # Bold **text**
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    # Inline code `text`
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    # Italic *text* (but not **)
    text = re.sub(r"(?<!\*)\*([^*\n]+)\*(?!\*)", r"<em>\1</em>", text)
    return text


def _escape(text: str) -> str:
    """Escape HTML entities."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def main():
    if not MD_PATH.exists():
        print(f"Error: {MD_PATH} not found", file=sys.stderr)
        sys.exit(1)

    md_text = MD_PATH.read_text(encoding="utf-8")
    html_body = md_to_html(md_text)
    full_html = HTML_TEMPLATE.format(content=html_body)

    HTML_PATH.write_text(full_html, encoding="utf-8")
    print(f"✓ Generated {HTML_PATH} ({len(full_html)} bytes)")


if __name__ == "__main__":
    main()
