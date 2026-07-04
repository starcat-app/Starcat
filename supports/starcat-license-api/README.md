# starcat-license-api

Starcat Direct 分发授权 API。客户端只调用本服务，本服务再对接 Creem 或后续其他支付/授权 provider。

## Endpoints

- `GET /healthz`
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

## Contract

客户端 activate 时提交 `licenseKey + deviceID + appVersion`。服务端调用 Creem `/licenses/activate`，把 `deviceID` 映射为 Creem 的 `instance_name`，返回标准化 `instanceID`。后续 validate/deactivate 必须提交 `licenseKey + instanceID`。
