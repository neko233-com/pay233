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
docker compose up --build
```

After the server is running locally:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/smoke.ps1
```

GitHub Actions runs `go vet`, race-enabled tests, and coverage output for both child modules. Local race tests require CGO and a C compiler.

The server listens on port `5500` by default.

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
