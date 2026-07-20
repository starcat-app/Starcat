#!/usr/bin/env python3
"""同步 supports 各独立项目 README 中的 Starcat 推广区块。

这个脚本只维护 marker 包住的推广区块，避免每个支持项目手写一份
Starcat 介绍后逐渐漂移。运行后会：
  - 在目标 README 的一级标题后插入或替换 `starcat-promo` 区块。
  - 为缺少中文说明的项目补充 `README-ZH.md`。
  - 清理 `homebrew-starcat` 旧的本地图片头图与重复 Starcat 介绍。

常用命令：

    supports/scripts/sync-starcat-readme-promo.py

公开图片统一引用 `starcat-pro`，不要复制到各仓库：
  - https://raw.githubusercontent.com/starcat-app/starcat-pro/main/banner.webp
  - https://raw.githubusercontent.com/starcat-app/starcat-pro/main/main.webp
"""

from __future__ import annotations

import re
import shutil
from dataclasses import dataclass
from pathlib import Path


START = "<!-- starcat-promo:start -->"
END = "<!-- starcat-promo:end -->"
BANNER = "https://raw.githubusercontent.com/starcat-app/starcat-pro/main/banner.webp"
MAIN = "https://raw.githubusercontent.com/starcat-app/starcat-pro/main/main.webp"


@dataclass(frozen=True)
class Project:
    path: Path
    title: str
    kind: str
    zh_title: str
    zh_summary: str
    en_summary: str


ROOT = Path(__file__).resolve().parents[2]


PROJECTS = [
    Project(
        Path("supports/homebrew-starcat"),
        "Homebrew Starcat",
        "homebrew",
        "Homebrew Starcat",
        "这是 Starcat 的官方 Homebrew tap，也是推荐安装与更新入口。",
        "Official Homebrew tap for installing and updating Starcat.",
    ),
    Project(
        Path("supports/extensions/starcat-chrome-plugin"),
        "Starcat Chrome Plugin",
        "browser",
        "Starcat Chrome 插件",
        "这是 Starcat 的 Chrome/Chromium companion extension，把 Starcat 的仓库上下文带到 GitHub 页面。",
        "Chrome/Chromium companion extension that brings Starcat context to GitHub pages.",
    ),
    Project(
        Path("supports/extensions/starcat-safari-plugin"),
        "Starcat Safari Plugin",
        "browser",
        "Starcat Safari 插件",
        "这是 Starcat 的 Safari WebExtension companion package，把 Starcat 的仓库上下文带到 GitHub 页面。",
        "Safari WebExtension companion package that brings Starcat context to GitHub pages.",
    ),
    Project(
        Path("supports/starcat-discovery-api"),
        "Starcat Discovery API",
        "api",
        "Starcat Discovery API",
        "这是 Starcat 探索、热门、新发布仓库 feed 的可自部署支撑服务。",
        "Self-hostable support API for Starcat discovery, hot repositories and new-release feeds.",
    ),
    Project(
        Path("supports/starcat-license-api"),
        "starcat-license-api",
        "api",
        "starcat-license-api",
        "这是 Starcat Direct 分发授权链路的可自部署支撑服务。",
        "Self-hostable support API for Starcat Direct licensing flows.",
    ),
    Project(
        Path("supports/starcat-recommend-api"),
        "starcat-recommend-api",
        "api",
        "starcat-recommend-api",
        "这是 Starcat 相似仓库推荐的可自部署支撑服务。",
        "Self-hostable support API for Starcat similar-repository recommendations.",
    ),
    Project(
        Path("supports/starcat-sharing-api"),
        "Starcat Sharing API",
        "api",
        "Starcat Sharing API",
        "这是 Starcat 分享页面生成与托管的可自部署支撑服务。",
        "Self-hostable support API for Starcat share page generation and hosting.",
    ),
    Project(
        Path("supports/starcat-trending-api"),
        "Starcat Trending API",
        "api",
        "Starcat Trending API",
        "这是 Starcat GitHub Trending 数据的可自部署支撑服务。",
        "Self-hostable support API for Starcat GitHub Trending data.",
    ),
    Project(
        Path("supports/starcat-weekly-api"),
        "starcat-weekly-api",
        "api",
        "starcat-weekly-api",
        "这是 Starcat 周刊项目源与发现流水线的可自部署支撑服务。",
        "Self-hostable support API for Starcat weekly project feeds and discovery pipeline.",
    ),
    Project(
        Path("supports/starcat-wiki-api"),
        "Starcat Wiki API",
        "api",
        "Starcat Wiki API",
        "这是 Starcat 外部文档站索引探测的可自部署支撑服务。",
        "Self-hostable support API for Starcat external documentation index checks.",
    ),
    Project(
        Path("supports/starcat-localization"),
        "Starcat Localization",
        "localization",
        "Starcat 本地化",
        "这是 Starcat 的公开本地化协作仓库，帮助更多用户用母语使用 Starcat。",
        "Public localization collaboration repository for Starcat.",
    ),
]


def promo(project: Project, lang: str) -> str:
    is_zh = lang == "zh"
    summary = project.zh_summary if is_zh else project.en_summary
    app_desc = (
        "Starcat 是一款原生 macOS 应用，可以把 GitHub Stars 变成可搜索、可整理、可用 AI 理解的知识库。"
        "它支持 README 渲染、标签与私有笔记、Release 追踪、仓库健康度、AI 摘要、语义搜索、浏览器插件工作流，并提供多个可自部署 API。"
        if is_zh
        else
        "Starcat is a native macOS app that turns GitHub Stars into a searchable, organized and AI-assisted knowledge base. "
        "It supports README rendering, tags, private notes, release tracking, repository health signals, AI summaries, semantic search, browser plugin workflows and self-hostable support APIs."
    )
    install = (
        "首选 Homebrew 安装"
        if is_zh
        else "Preferred install method"
    )
    colon = "：" if is_zh else ":"
    links_title = "相关链接" if is_zh else "Useful links"
    ecosystem_title = "Starcat 生态项目" if is_zh else "Starcat ecosystem"
    link_rows = (
        """- 官网: https://starcat.ink
- 下载: https://starcat.ink/downloads/Starcat-1.1.0-arm64.dmg
- 公开支持与发布说明: https://github.com/starcat-app/starcat-pro
- Homebrew tap: https://github.com/dong4j/homebrew-starcat
- 浏览器插件: [Chrome](https://github.com/dong4j/starcat-chrome-plugin) / [Safari](https://github.com/starcat-app/starcat-safari-plugin)
- 本地化: https://github.com/starcat-app/starcat-localization"""
        if is_zh
        else """- Home: https://starcat.ink
- Download: https://starcat.ink/downloads/Starcat-1.1.0-arm64.dmg
- Public support and release notes: https://github.com/starcat-app/starcat-pro
- Homebrew tap: https://github.com/dong4j/homebrew-starcat
- Browser plugins: [Chrome](https://github.com/dong4j/starcat-chrome-plugin) / [Safari](https://github.com/starcat-app/starcat-safari-plugin)
- Localization: https://github.com/starcat-app/starcat-localization"""
    )
    language_link = (
        '<sub><a href="./README.md">English</a></sub>'
        if is_zh
        else '<sub><a href="./README-ZH.md">中文说明</a></sub>'
    )
    api_note = (
        "\n\n> Starcat 为普通用户提供默认托管服务。这个 API 开源出来，是为了让进阶用户可以审查实现、本地运行，或部署自己的实例。"
        if project.kind == "api" and is_zh
        else "\n\n> Starcat provides hosted defaults for normal users. This API is open source so advanced users can inspect it, run it locally, or deploy their own instance."
        if project.kind == "api"
        else ""
    )
    return f"""{START}
<div align="center">
<a href="https://starcat.ink"><img src="{BANNER}" width="100%" alt="Starcat" /></a>

<p><strong>{summary}</strong></p>
<p>{app_desc}</p>

<a href="https://github.com/dong4j/homebrew-starcat"><img src="https://img.shields.io/badge/Install%20with-Homebrew-FBBF24?style=for-the-badge&logo=homebrew&logoColor=white" width="220" alt="Install with Homebrew"/></a>
<br/>
{language_link}
</div>

<div align="center">
<a href="https://starcat.ink"><img src="https://img.shields.io/badge/website-starcat.ink-38BDF8?style=flat&color=blue" alt="website"/></a>
<a href="https://github.com/starcat-app/starcat-pro"><img src="https://img.shields.io/badge/support-starcat--pro-lightgrey.svg?style=flat&color=blue" alt="support"/></a>
<a href="https://github.com/dong4j/homebrew-starcat"><img src="https://img.shields.io/badge/install-homebrew-lightgrey.svg?style=flat&color=blue" alt="homebrew"/></a>
<a href="https://github.com/starcat-app/starcat-localization"><img src="https://img.shields.io/badge/localization-open-lightgrey.svg?style=flat&color=blue" alt="localization"/></a>
</div>

<div align="center">
<img width="900" src="{MAIN}" alt="Starcat main window"/>
</div>

**{install}{colon}**

```bash
brew tap dong4j/starcat
brew trust dong4j/starcat
brew install --cask starcat
```

**{links_title}{colon}**

{link_rows}

**{ecosystem_title}{colon}**

- [starcat-sharing-api](https://github.com/dong4j/starcat-sharing-api)
- [starcat-trending-api](https://github.com/dong4j/starcat-trending-api)
- [starcat-weekly-api](https://github.com/dong4j/starcat-weekly-api)
- [starcat-wiki-api](https://github.com/dong4j/starcat-wiki-api)
- [starcat-recommend-api](https://github.com/dong4j/starcat-recommend-api)
- [starcat-discovery-api](https://github.com/dong4j/starcat-discovery-api)
- [starcat-license-api](https://github.com/dong4j/starcat-license-api){api_note}
{END}"""


def strip_existing_promo(text: str) -> str:
    pattern = re.compile(rf"\n?{re.escape(START)}.*?{re.escape(END)}\n?", re.DOTALL)
    return pattern.sub("\n\n", text).strip() + "\n"


def normalize_homebrew_readme(text: str, project: Project, lang: str) -> str:
    text = strip_existing_promo(text)
    text = re.sub(r"^<div align=\"center\">.*?</div>\s*<br />\s*", "", text, count=1, flags=re.DOTALL)
    text = re.sub(
        r"\n<div align=\"center\">\n<a href=\"https://starcat\.ink\"><img src=\"https://img\.shields\.io/badge/website-starcat\.ink.*?</div>\s*<br />\s*",
        "\n",
        text,
        count=1,
        flags=re.DOTALL,
    )
    text = re.sub(
        r"\n## About Starcat\n\n.*?<div align=\"center\">\n<img width=\"900\" src=\"\./assets/main\.webp\".*?</div>\n",
        "\n",
        text,
        count=1,
        flags=re.DOTALL,
    )
    if not text.startswith("# "):
        text = f"# {project.title}\n\n{text.lstrip()}"
    return text


def ensure_h1(text: str, title: str) -> str:
    if text.startswith("# "):
        return text
    return f"# {title}\n\n{text.lstrip()}"


def insert_promo(text: str, project: Project, lang: str) -> str:
    text = strip_existing_promo(text)
    if project.kind == "homebrew":
        text = normalize_homebrew_readme(text, project, lang)
    text = ensure_h1(text, project.title if lang == "en" else project.zh_title)
    lines = text.splitlines()
    if not lines or not lines[0].startswith("# "):
        raise ValueError(f"README 缺少一级标题: {project.path}")
    body = "\n".join(lines[1:]).lstrip()
    return "\n".join([lines[0], "", promo(project, lang), "", body]).rstrip() + "\n"


def zh_readme_source(project: Project) -> str:
    zh = ROOT / project.path / "README-ZH.md"
    if zh.exists():
        return zh.read_text(encoding="utf-8")
    return (ROOT / project.path / "README.md").read_text(encoding="utf-8")


def main() -> int:
    for project in PROJECTS:
        repo = ROOT / project.path
        readme = repo / "README.md"
        if not readme.exists():
            raise FileNotFoundError(readme)
        readme.write_text(insert_promo(readme.read_text(encoding="utf-8"), project, "en"), encoding="utf-8")

        zh_readme = repo / "README-ZH.md"
        zh_text = zh_readme_source(project)
        zh_readme.write_text(insert_promo(zh_text, project, "zh"), encoding="utf-8")

        if project.kind == "homebrew":
            assets = repo / "assets"
            if assets.exists():
                shutil.rmtree(assets)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
