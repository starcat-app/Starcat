# Starcat Backend

这是 Starcat 应用的后端服务，主要提供 AI 分享页面的生成和托管功能。

## 功能特性

- **分享链接生成**：接收来自客户端的 Repo 数据和 AI 摘要，生成唯一的分享链接 (`POST /api/share`)。
- **分享页面渲染**：通过短链接访问时，使用 Go 原生 `html/template` 结合 Tailwind CSS 渲染响应式的精美分享页面 (`GET /s/{id}`)。
- **数据持久化**：使用基于内存的并发安全 Map，并自动将数据落盘到本地的 `data.json` 文件中，实现轻量级存储。

## 快速开始

### 环境要求

- Go 1.23+

### 运行服务

进入 `backend` 目录并启动服务：

```bash
cd backend
go run main.go
```

默认情况下，服务会在 `8080` 端口启动，并在控制台输出日志。

### 环境变量配置

你可以通过配置环境变量来覆盖默认行为：

- `PORT`: 服务监听的本地端口，默认为 `8080`。
- `BASE_URL`: 分享链接的基础域名，默认为 `https://starcat.app`。可以在本地测试时配置为 `http://localhost:8080`。

例如：
```bash
PORT=3000 BASE_URL=http://localhost:3000 go run main.go
```

## API 接口文档

### 1. 创建分享链接

**请求端点**: `POST /api/share`

**请求格式**: `application/json`

**请求体示例**:

```json
{
  "repo": {
    "fullName": "owner/repo",
    "description": "项目描述...",
    "language": "Swift",
    "starsCount": 12345,
    "forksCount": 1234,
    "topics": ["swift", "macos", "ios"],
    "homepage": "https://example.com",
    "url": "https://github.com/owner/repo"
  },
  "aiSummary": {
    "oneLiner": "AI 生成的一句话总结",
    "summary": "这是由 AI 对该开源项目进行的详细分析和总结...",
    "platforms": ["macOS", "iOS"],
    "suitableFor": ["适合需要快速开发 UI 的开发者", "适合学习 Swift 现代特性的团队"],
    "strengths": ["架构清晰，代码可读性高", "活跃的开源社区支持"],
    "risks": ["目前处于早期版本，API 可能发生变动"],
    "suggestedTags": [
      {"name": "SwiftUI", "confidence": 0.95},
    ]
  }
}
```

**响应格式**: `application/json`

**响应体示例**:

```json
{
  "shareUrl": "https://starcat.app/s/aBcD1234",
  "expiresAt": "2026-07-04T00:00:00Z"
}
```

*注：默认每个分享链接的有效期为自生成起 1 个月。*

### 2. 访问分享视图

**请求端点**: `GET /s/{id}`

**响应**: 返回渲染后的 HTML 页面。如果给定的 `id` 不存在或已过期，则返回 HTTP 404 (Not Found)。
