# Starcat AI Discovery（Show HN）最终方案

## 目标
在 Starcat 的 Activity 模块中新增 AI Discovery 频道，通过 Hacker News Show HN 持续发现高质量 AI 开源项目。

数据来源：
- GitHub Trending（已集成）
- Hacker News Show HN（新增）

定位：
- GitHub Trending = 已验证热门项目
- Show HN = 刚开始获得开发者社区关注的新项目

## 导航结构

Activity
├── GitHub Trending
└── AI Discovery

## 数据源

唯一新增数据源：
https://news.ycombinator.com/show

仅使用 Show HN，不接入 shownew。

## 抓取流程

1. 抓取 Show HN
2. 过滤 github.com 项目
3. 标准化 owner/repo
4. 获取 GitHub Metadata
5. 获取 README
6. LLM 分类

## AI 分类体系

### AI Agent
- CrewAI
- AutoGen
- LangGraph
- Mastra

### AI Coding
- OpenHands
- Aider
- Continue
- OpenCode
- Roo Code

### AI MCP
- MCP Server
- MCP Registry
- MCP Gateway

### AI RAG
- RAGFlow
- GraphRAG
- Dify RAG

### AI Infra
- vLLM
- LiteLLM
- Ollama
- Ray

### AI Model
- Qwen
- DeepSeek
- Llama
- Gemma
- GLM

### AI Skill
定义：可供 AI Agent、AI Assistant、MCP Agent 直接加载和复用的能力包。

示例：
- SkillsJars
- Agent Skills
- Prompt Packs
- AI Workflow Templates
- AI Capability Libraries

## 数据表

CREATE TABLE ai_discovery (
    id TEXT PRIMARY KEY,
    hn_id TEXT,
    title TEXT,
    url TEXT,
    github_owner TEXT,
    github_repo TEXT,
    stars INTEGER,
    forks INTEGER,
    category TEXT,
    score INTEGER,
    comments INTEGER,
    published_at DATETIME,
    analyzed_at DATETIME,
    created_at DATETIME
);

## UI

分类：
All / Agent / Coding / MCP / RAG / Infra / Model / Skill

## 定时任务

每小时执行：

Show HN
→ Github Filter
→ Repo Metadata
→ README
→ AI Classification
→ 入库

## 去重

唯一键：owner/repo

## 未来扩展

AI Discovery
├── Show HN
├── Product Hunt AI
├── Reddit LocalLLaMA
├── HuggingFace Trending
└── Awesome AI Lists

第一阶段：GitHub Trending + Show HN
