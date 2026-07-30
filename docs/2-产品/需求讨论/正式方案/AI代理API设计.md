# AI 代理 API 设计

> 本文档定义 AI 代理服务的 API 接口规范。
>
> **设计思路**：简洁、安全、可扩展。防盗用是首要考虑。

---

## 一、设计思路

### 1.1 核心原则

1. **防盗用**
   - API Key 验证
   - 请求签名（HMAC）
   - 请求频率限制
   - 配额控制

2. **简洁至上**
   - RESTful 风格
   - 最少化端点
   - JSON 格式

3. **可扩展**
   - Provider 抽象
   - 模型可配置
   - 预留缓存接口

### 1.2 架构概览

```
┌─────────────────────────────────────────────────────────────┐
│                    Starcat App                              │
│                    (AI Proxy Client)                        │
└─────────────────────────┬───────────────────────────────────┘
                          │ HTTPS + HMAC Signature
                          ▼
┌─────────────────────────────────────────────────────────────┐
│                    AI Proxy Server                          │
│                    (你的云服务器)                            │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │
│  │   Gemini    │  │  OpenAI    │  │  DeepSeek   │       │
│  │  Provider  │  │  Provider  │  │  Provider   │       │
│  └─────────────┘  └─────────────┘  └─────────────┘       │
│                          │                                  │
│                          ▼                                  │
│                    ┌─────────────┐                         │
│                    │    Redis    │                         │
│                    │   (Cache)   │                         │
│                    └─────────────┘                         │
└─────────────────────────────────────────────────────────────┘
```

---

## 二、API 端点

### 2.1 端点列表

| 方法 | 路径 | 描述 |
|------|------|------|
| `POST` | `/api/v1/summarize` | 生成仓库摘要 |
| `POST` | `/api/v1/tags` | 推荐标签 |
| `POST` | `/api/v1/embed` | 生成 Embedding |
| `POST` | `/api/v1/search` | 语义搜索 |
| `GET` | `/api/v1/quota` | 查询配额 |
| `GET` | `/api/v1/health` | 健康检查 |

### 2.2 通用请求头

```
Authorization: Bearer <api_key>
X-Signature: <hmac_sha256_signature>
X-Timestamp: <unix_timestamp>
X-Nonce: <unique_nonce>
Content-Type: application/json
```

### 2.3 签名算法

```python
# HMAC 签名生成
import hmac
import hashlib
import time
import secrets

def sign_request(api_key, api_secret, method, path, body):
    timestamp = str(int(time.time()))
    nonce = secrets.token_hex(8)
    message = f"{method}:{path}:{timestamp}:{nonce}:{body}"
    signature = hmac.new(
        api_secret.encode(),
        message.encode(),
        hashlib.sha256
    ).hexdigest()
    return timestamp, nonce, signature
```

---

## 三、API 详情

### 3.1 生成摘要

**POST** `/api/v1/summarize`

```json
// Request
{
    "repo": {
        "owner": "apple",
        "name": "swift",
        "description": "The Swift Programming Language",
        "language": "C++",
        "stars": 62000,
        "topics": ["swift", "language", "ios"]
    },
    "readme": "## Swift\n\nSwift is a general-purpose programming language...",
    "options": {
        "language": "zh",  // "zh" or "en"
        "model": "gemini-2.5-flash"  // optional
    }
}

// Response (200 OK)
{
    "success": true,
    "data": {
        "one_liner": "现代编程语言",
        "summary": "Swift 是 Apple 推出的现代编程语言...",
        "tags": ["programming-language", "ios", "apple"],
        "platforms": ["macOS", "iOS", "Linux"],
        "category": "language",
        "pros": ["内存安全", "现代化语法", "Apple 生态"],
        "cons": ["生态相对封闭"],
        "min_example": "let greeting = \"Hello, Swift!\""
    },
    "cached": false,
    "quota_used": 1
}

// Response (429 Too Many Requests)
{
    "success": false,
    "error": {
        "code": "QUOTA_EXCEEDED",
        "message": "Monthly quota exceeded",
        "quota_remaining": 0,
        "reset_at": "2026-06-01T00:00:00Z"
    }
}
```

### 3.2 推荐标签

**POST** `/api/v1/tags`

```json
// Request
{
    "repo": {
        "name": "swift",
        "description": "...",
        "language": "C++",
        "topics": ["swift", "ios"]
    },
    "readme": "...",
    "existing_tags": ["编程语言", "开发工具"],  // 用户现有标签
    "options": {
        "count": 5,
        "model": "gemini-2.5-flash"
    }
}

// Response
{
    "success": true,
    "data": {
        "recommendations": [
            {"tag": "Swift", "confidence": 0.95, "reason": "官方主题匹配"},
            {"tag": "编程语言", "confidence": 0.88, "similar_to": "开发工具"},
            {"tag": "Apple生态", "confidence": 0.82, "reason": "Apple 官方项目"}
        ],
        "merged_suggestions": [
            {"original": "LLM", "similar": ["大模型", "语言模型"], "action": "merge"}
        ]
    },
    "quota_used": 1
}
```

### 3.3 生成 Embedding

**POST** `/api/v1/embed`

```json
// Request
{
    "texts": [
        "Swift is a programming language",
        "Python is great for data science"
    ],
    "model": "text-embedding-3-small"  // optional
}

// Response
{
    "success": true,
    "data": [
        {"embedding": [0.123, -0.456, ...], "dimension": 1536},
        {"embedding": [0.789, -0.012, ...], "dimension": 1536}
    ],
    "cached": false,
    "quota_used": 2
}
```

### 3.4 语义搜索

**POST** `/api/v1/search`

```json
// Request
{
    "query": "找适合做 API 的 Python 框架",
    "repo_ids": ["repo1", "repo2", "repo3", ...],
    "embeddings": [
        {"repo_id": "repo1", "embedding": [...]},
        ...
    ],
    "top_k": 5,
    "options": {
        "rerank": true
    }
}

// Response
{
    "success": true,
    "data": {
        "results": [
            {
                "repo_id": "repo2",
                "score": 0.95,
                "reason": "描述中提到 'FastAPI 是一个现代 Python Web 框架'"
            }
        ],
        "query_embedding_used": true,
        "bm25_results": 3,
        "vector_results": 2
    },
    "quota_used": 1
}
```

### 3.5 查询配额

**GET** `/api/v1/quota`

```json
// Response
{
    "success": true,
    "data": {
        "plan": "pro",
        "quota_total": 500,
        "quota_used": 127,
        "quota_remaining": 373,
        "reset_at": "2026-06-01T00:00:00Z",
        "features": ["summarize", "tags", "embed", "search"]
    }
}
```

### 3.6 健康检查

**GET** `/api/v1/health`

```json
// Response
{
    "status": "ok",
    "version": "1.0.0",
    "providers": {
        "gemini": "available",
        "openai": "available",
        "deepseek": "available"
    }
}
```

---

## 四、防盗用机制

### 4.1 身份验证

```
┌─────────────────────────────────────────────────────────────┐
│                    请求验证流程                               │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. 检查 Authorization header                                  │
│  2. 验证 API Key 是否有效                                     │
│  3. 验证 HMAC 签名                                          │
│  4. 检查 Timestamp (5 分钟内有效)                            │
│  5. 检查 Nonce (防止重放攻击)                                │
│  6. 检查请求频率                                             │
│  7. 检查配额                                                │
│                                                              │
│  全部通过 ──▶ 处理请求                                       │
│  任一失败 ──▶ 返回 401/403/429                              │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 频率限制

| 级别 | 限制 | 说明 |
|------|------|------|
| IP 级别 | 100 req/min | 同一 IP |
| API Key 级别 | 60 req/min | 同一用户 |
| 端点级别 | 10 req/min | 特定端点 |

### 4.3 配额控制

```python
# 配额示例
QUOTA_PLANS = {
    "free": {"monthly": 50, "daily": 10},
    "pro": {"monthly": 500, "daily": 100},
    "unlimited": {"monthly": -1, "daily": -1}  # 无限制
}
```

---

## 五、错误码

| 错误码 | HTTP 状态 | 说明 |
|--------|-----------|------|
| `INVALID_API_KEY` | 401 | API Key 无效 |
| `INVALID_SIGNATURE` | 401 | 签名验证失败 |
| `EXPIRED_TIMESTAMP` | 401 | 请求过期 |
| `RATE_LIMITED` | 429 | 请求过于频繁 |
| `QUOTA_EXCEEDED` | 429 | 配额用尽 |
| `INVALID_REQUEST` | 400 | 请求格式错误 |
| `MODEL_UNAVAILABLE` | 503 | 模型不可用 |
| `INTERNAL_ERROR` | 500 | 服务器内部错误 |

---

## 六、部署建议

### 6.1 基础设施

```
- 服务器：你的云服务器（建议 2核4G 起）
- 操作系统：Ubuntu 22.04 LTS
- Docker：用于容器化部署
- Nginx：反向代理 + SSL
- Redis：缓存层
- PostgreSQL：配额记录存储
```

### 6.2 Docker 部署

```dockerfile
FROM python:3.11-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY ./app ./app
EXPOSE 8080

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
```

### 6.3 Nginx 配置

```nginx
server {
    listen 443 ssl;
    server_name ai.starcat.ink;   # 规划域名；部署前必须先配置 DNS 与证书

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location /api/ {
        limit_req zone=api burst=10 nodelay;
        proxy_pass http://localhost:8080/api/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

---

## 七、后续完善点

- [ ] 实现完整的 Redis 缓存逻辑
- [ ] 实现请求去重（Nonce 存储）
- [ ] 实现更精细的配额控制
- [ ] 实现请求日志和监控
- [ ] 实现 Provider 的 Failover 机制
- [ ] 编写完整的测试用例

---

*最后更新：2026-05-29*
