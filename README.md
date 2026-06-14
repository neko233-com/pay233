# pay233

`pay233` is the umbrella repository for the company payment center.

It manages two development repositories:

- `pay233-server`: unified payment access service
- `pay233-lib-go`: Go client SDK for business services

## Clone

```bash
git clone --recurse-submodules https://github.com/neko233-com/pay233.git
```

Because both child repositories started empty, create and push their first commits before recording submodule SHAs in this umbrella repository.

## Automation

```bash
make test
make test-race
make vet
make env-e2e
make health-e2e
make admin-e2e
make verify
docker compose up --build
```

After the server is running locally:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/smoke.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/env-e2e.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/health-e2e.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/admin-e2e.ps1
```

`env-e2e.ps1` starts a temporary server and proves that the same `out_trade_no` can exist once in `test` and once in `release`, while admin dashboard filters remain isolated. `health-e2e.ps1` verifies channel health checks and audit records. `admin-e2e.ps1` verifies login-first access and captures desktop/mobile screenshots.

GitHub Actions runs `go vet`, race-enabled tests, and coverage output for both child modules. Local race tests require CGO and a C compiler.

The server listens on port `5500` by default.

## Environment Isolation

Every create-payment HTTP request can carry `envType`:

```json
{
  "envType": "test",
  "merchant_id": "merchant_1",
  "out_trade_no": "order_10001",
  "channel": "mock",
  "amount": { "currency": "CNY", "amount": 100 },
  "subject": "Test order"
}
```

Supported values are `test` and `release`. Empty values default to `test`, and the server also accepts `env_type` for snake-case clients. Webhook callbacks can carry the same field so test callbacks cannot update release payments. The admin dashboard defaults to the test view and can switch between test, release, and all environments without deploying another server.

## Install Server

Linux/macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/neko233-com/pay233/main/scripts/install-server.sh | sh
```

Windows PowerShell:

```powershell
iwr -useb https://raw.githubusercontent.com/neko233-com/pay233/main/scripts/install-server.ps1 | iex
```

Install a specific version:

```bash
curl -fsSL https://raw.githubusercontent.com/neko233-com/pay233/main/scripts/install-server.sh | sh -s -- v0.1.0
```

The installer downloads `pay233-server` from `neko233-com/pay233-server` releases, creates a default config, and installs startup integration where available.

Default installed channels include `mock`, `wechat`, `alipay`, `stripe`, `paypal`, `google-pay`, `apple-iap`, and `unionpay`. The admin console is available at `/admin` with default credentials `root` / `root`; change them before production use.

Logs are daily rotated and retained for 31 days by default:

- app logs: `logs/app-YYYY-MM-DD.log`
- payment audit logs: `logs/payments/payment-YYYY-MM-DD.log`

Payments are persisted by default:

- payment store: `data/payments.jsonl`
- admin users: `data/admin-users.json`
- operation audit log: `data/audit.jsonl`, retained for 31 days

Admin roles are `root`, `admin`, and `employee`. `root` can create admin/employee accounts and prune expired audit logs; `employee` is read-only.

Downstream payment channel health is checked automatically every 60 seconds by default. The admin dashboard shows health, latency, last check time, and recent errors; `root` and `admin` can trigger immediate checks.

For installer-based deployments, override paths and secrets with environment variables such as `PAY233_SERVER_DATA_DIR`, `PAY233_SERVER_LOG_DIR`, `PAY233_SIGNING_SECRET`, `PAY233_ADMIN_USERNAME`, `PAY233_ADMIN_PASSWORD`, and `PAY233_ADMIN_SESSION_SECRET`.
