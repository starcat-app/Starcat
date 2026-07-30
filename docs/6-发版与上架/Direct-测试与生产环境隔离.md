# Direct 测试与生产环境隔离

> 目标：Direct 落地页、License API、Creem、App 构建长期保持测试 / 生产两套环境。`supports/starcat-site/direct` 永远是正式生产站，`supports/starcat-site/direct-test` 永远是测试站，避免测试购买链路污染 `starcat.ink`。

## 环境矩阵

| 层级 | 测试环境 | 生产环境 |
|------|----------|----------|
| 源码目录 | `supports/starcat-site/direct-test` | `supports/starcat-site/direct` |
| 落地页域名 | `https://test.starcat.ink` | `https://starcat.ink` / `https://www.starcat.ink` |
| 静态目录 | `/var/www/starcat-test` | `/var/www/starcat` |
| nginx 配置 | `supports/starcat-site/direct-test/starcat-test.ink.conf` | `supports/starcat-site/direct/starcat.ink.conf` |
| License API | `https://starcat-license-api-staging.fly.dev` | `https://starcat-license-api.fly.dev` |
| Checkout endpoint | `https://starcat-license-api-staging.fly.dev/v1/direct/checkout` | `https://starcat-license-api.fly.dev/v1/direct/checkout` |
| Creem | Test Mode | Live Mode |
| Direct App 构建 | `StarcatDirect Debug` / `make run-direct` | `StarcatDirect Release` / `make package-direct` |
| App 内环境值 | `STARCAT_LICENSE_API_ENVIRONMENT = test` | `STARCAT_LICENSE_API_ENVIRONMENT = live` |

## 设计约束

- `starcat.ink` 永远代表生产购买链路，不临时切到 Creem Test Mode。
- `test.starcat.ink` 专用于测试购买、支付回跳、license 激活和 staging webhook 验证。
- `supports/starcat-site/direct` 不允许出现 `starcat-license-api-staging.fly.dev`、`test.starcat.ink` 或 `runtime-config.js`。
- `supports/starcat-site/direct-test` 不允许出现生产 checkout endpoint `https://starcat-license-api.fly.dev/v1/direct/checkout`。
- `supports/starcat-site/direct-test` 只保留测试购买必需文件；隐私政策、用户协议、更新记录、下载链接和 appcast 复用生产站 `https://starcat.ink`。
- 测试站使用 `noindex, nofollow` 和 `robots.txt Disallow: /`，避免被搜索引擎收录。
- Direct 正式发布脚本只使用 `supports/starcat-site/direct`；`supports/starcat-site/direct-test` 只用于人工测试部署。

## 首次准备

1. DNS 增加 `test.starcat.ink` 解析到当前落地页服务器。
2. 确认证书 `/etc/nginx/encrypt/starcat/fullchain.pem` 覆盖 `test.starcat.ink`。
3. 确认远程目录存在：

```bash
ssh aliyun2 'mkdir -p /var/www/starcat /var/www/starcat-test'
```

4. 确认 staging 后端使用 Creem Test Mode：
   - `CREEM_API_BASE_URL=https://test-api.creem.io/v1`
   - `STARCAT_SUCCESS_URL=https://starcat-license-api-staging.fly.dev/payment/success`
5. 确认 production 后端使用 Creem Live Mode：
   - `CREEM_API_BASE_URL=https://api.creem.io/v1`
   - `STARCAT_SUCCESS_URL=https://starcat-license-api.fly.dev/payment/success`

## 部署测试落地页

测试站点只用于测试购买，不承载正式用户购买入口。

```bash
cd /Users/dong4j/Developer/1.AI/ai-incubator/Starcat

make deploy-pages-test
```

等价底层命令：

```bash
cd supports/starcat-site/direct-test
./deploy.sh
```

部署后检查：

```bash
curl -fsS https://starcat-license-api-staging.fly.dev/healthz
curl -fsS https://test.starcat.ink/ | rg 'starcat-license-api-staging'
```

在浏览器打开 `https://test.starcat.ink`，点击购买按钮后应跳转到：

```text
https://creem.io/test/checkout/...
```

## 部署生产落地页

生产站点只使用 Creem Live Mode。上线前必须确认测试站已完成完整购买、回跳和激活验证。

```bash
cd /Users/dong4j/Developer/1.AI/ai-incubator/Starcat

make deploy-pages
```

等价底层命令：

```bash
cd supports/starcat-site/direct
./deploy.sh
```

部署后检查：

```bash
curl -fsS https://starcat-license-api.fly.dev/healthz
curl -fsS https://starcat.ink/ | rg 'starcat-license-api.fly.dev'
```

生产 smoke test 只验证 checkout URL 是否能创建，不要随意完成真实付款：

```bash
curl -sS -X POST 'https://starcat-license-api.fly.dev/v1/direct/checkout' \
  -H 'Content-Type: application/json' \
  -d '{"plan":"monthly","requestID":"smoke-monthly"}'
```

预期返回 `https://creem.io/checkout/...`，不能是 `https://creem.io/test/checkout/...`。

## Direct App 构建规则

`StarcatDirect` target 在 `project.yml` 中按 configuration 固定选择环境：

- `Debug`：`STARCAT_LICENSE_API_ENVIRONMENT = test`
- `Release`：`STARCAT_LICENSE_API_ENVIRONMENT = live`

本地测试：

```bash
make run-direct
```

`scripts/run-debug-direct.sh` 会在启动前检查 `Info.plist`，如果 `STARCAT_LICENSE_API_ENVIRONMENT` 不是 `test` 会直接失败。

正式打包：

```bash
make package-direct VERSION=1.0.0
```

`scripts/package-direct.sh` 会在打包时检查 `Info.plist`，如果 `STARCAT_LICENSE_API_ENVIRONMENT` 不是 `live` 会直接失败。

## 常见问题

### 点击购买显示 `Failed to fetch`

优先检查浏览器 Console 是否有 `Content Security Policy` 报错。

- `test.starcat.ink` 的 CSP 必须允许 `https://starcat-license-api-staging.fly.dev`。
- `starcat.ink` 的 CSP 必须允许 `https://starcat-license-api.fly.dev`。
- 修改 nginx 配置后直接执行 `make deploy-pages` 或 `make deploy-pages-test`；部署脚本会先同步 nginx 并 reload，再同步静态资源。

### 支付成功页显示签名失败

测试环境必须确保 checkout 来自 staging API，支付回跳也回到 staging success URL：

```text
https://starcat-license-api-staging.fly.dev/payment/success
```

生产环境对应：

```text
https://starcat-license-api.fly.dev/payment/success
```

如果 checkout 用 staging 创建，但回跳到 production，或反过来，Creem API key / product id / signature 都会错位。
