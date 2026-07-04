# starcat-license-api

Starcat Direct 分发授权 API。客户端只调用本服务，本服务再对接 Creem 或后续其他支付/授权 provider。

首期实现包含两个 provider 边界：

- `PaymentProvider`：返回 checkout / customer portal URL；当前实现是 `StaticPaymentProvider`，由环境变量配置 Creem hosted URL。
- `LicenseProvider`：处理 license activate / validate / deactivate；当前实现是 `CreemProvider`。

## Endpoints

- `GET /healthz`
- `POST /v1/direct/checkout`
- `POST /v1/direct/customer-portal`
- `POST /v1/direct/licenses/activate`
- `POST /v1/direct/licenses/validate`
- `POST /v1/direct/licenses/deactivate`
- `POST /v1/webhooks/direct/creem`

业务接口需要：

```http
Authorization: Bearer <API_KEYS 中的任一 key>
Content-Type: application/json
```

Creem webhook 走 `creem-signature` HMAC-SHA256 校验，secret 来自 `CREEM_WEBHOOK_SECRET`。

## Local

```bash
cp .env.example .env
go test ./...
go run ./cmd/server
```

关键环境变量：

```text
API_KEYS=dev-api-key
CREEM_API_KEY=creem-test-key
CREEM_API_BASE_URL=https://test-api.creem.io/v1
CREEM_CHECKOUT_URL=https://...
CREEM_CUSTOMER_PORTAL_URL=https://...
CREEM_WEBHOOK_SECRET=...
```

## Contract

客户端 activate 时提交 `licenseKey + deviceID + appVersion`。服务端调用 Creem `/licenses/activate`，把 `deviceID` 映射为 Creem 的 `instance_name`，返回标准化 `instanceID`。后续 validate/deactivate 必须提交 `licenseKey + instanceID`。
