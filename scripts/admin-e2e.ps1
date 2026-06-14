$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$serverRoot = Join-Path $root "pay233-server"
$tmp = Join-Path $serverRoot ".tmp"
$out = if ($env:PAY233_E2E_OUTPUT) { $env:PAY233_E2E_OUTPUT } else { Join-Path $env:TEMP "pay233-admin-qa" }

New-Item -ItemType Directory -Force -Path $tmp, $out | Out-Null

$bin = Join-Path $tmp "pay233-server.exe"
Push-Location $serverRoot
try {
    go build -o $bin ./cmd/pay233-server

    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()

    $logDir = Join-Path $tmp "logs"
    $dataDir = Join-Path $tmp "data-admin"
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $logDir, $dataDir
    $config = Join-Path $tmp "config.admin-e2e.json"
    @"
{
  "http": {"addr": "127.0.0.1:$port"},
  "api": {"signing_secret": "dev-secret"},
  "admin": {"username":"root","password":"root","session_secret":"dev-admin-secret"},
  "logging": {"dir": "$($logDir.Replace('\','\\'))", "retention_days": 31},
  "storage": {
    "payments_path": "$((Join-Path $dataDir "payments.jsonl").Replace('\','\\'))",
    "admin_users_path": "$((Join-Path $dataDir "admin-users.json").Replace('\','\\'))",
    "audit_path": "$((Join-Path $dataDir "audit.jsonl").Replace('\','\\'))",
    "audit_retention_days": 31
  },
  "channels": [
    {"name":"mock","provider":"mock","enabled":true},
    {"name":"wechat","provider":"wechat_pay","enabled":true},
    {"name":"alipay","provider":"alipay","enabled":true},
    {"name":"stripe","provider":"stripe","enabled":true},
    {"name":"paypal","provider":"paypal","enabled":true},
    {"name":"google-pay","provider":"google_pay","enabled":true},
    {"name":"apple-iap","provider":"apple_iap","enabled":true},
    {"name":"unionpay","provider":"unionpay","enabled":true}
  ]
}
"@ | Set-Content -Path $config -Encoding UTF8

    $proc = Start-Process -FilePath $bin -ArgumentList "-config", $config -WorkingDirectory $serverRoot -PassThru -WindowStyle Hidden
    try {
        $ready = $false
        for ($i = 0; $i -lt 30; $i++) {
            try {
                $health = Invoke-RestMethod -Uri "http://127.0.0.1:$port/healthz" -TimeoutSec 1
                if ($health.status -eq "ok") { $ready = $true; break }
            } catch {}
            Start-Sleep -Milliseconds 500
        }
        if (-not $ready) { throw "server did not become ready" }

        $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$port/admin/dashboard.html")
        $req.AllowAutoRedirect = $false
        try { $resp = $req.GetResponse() } catch { $resp = $_.Exception.Response }
        if ([int]$resp.StatusCode -ne 302 -or $resp.Headers["Location"] -ne "/admin/login.html") {
            throw "unexpected dashboard redirect: $([int]$resp.StatusCode) $($resp.Headers["Location"])"
        }
        $resp.Close()

        function Clean-PlaywrightValue($value) {
            return ($value | Out-String).Trim().Trim('"')
        }

        npx --yes @playwright/cli open "http://127.0.0.1:$port/admin/dashboard.html" | Out-Host
        Start-Sleep -Seconds 1
        $path = Clean-PlaywrightValue (npx --yes @playwright/cli eval "() => location.pathname" --raw)
        if ($path -ne "/admin/login.html") { throw "expected /admin/login.html, got $path" }

        npx --yes @playwright/cli screenshot --filename "$out\login-desktop.png" --full-page | Out-Host
        npx --yes @playwright/cli fill "input[name=username]" root | Out-Host
        npx --yes @playwright/cli fill "input[name=password]" root | Out-Host
        npx --yes @playwright/cli click "button[type=submit]" | Out-Host
        Start-Sleep -Seconds 2

        $path = Clean-PlaywrightValue (npx --yes @playwright/cli eval "() => location.pathname" --raw)
        if ($path -ne "/admin/dashboard.html") { throw "expected /admin/dashboard.html, got $path" }
        $title = Clean-PlaywrightValue (npx --yes @playwright/cli eval "() => document.querySelector('h1')?.textContent" --raw)
        if ($title -ne "支付运营大盘") { throw "dashboard title mismatch: $title" }

        npx --yes @playwright/cli screenshot --filename "$out\dashboard-desktop.png" --full-page | Out-Host
        npx --yes @playwright/cli resize 390 900 | Out-Host
        Start-Sleep -Seconds 1
        npx --yes @playwright/cli screenshot --filename "$out\dashboard-mobile.png" --full-page | Out-Host
        npx --yes @playwright/cli click "#logoutBtn" | Out-Host
        Start-Sleep -Seconds 1

        $path = Clean-PlaywrightValue (npx --yes @playwright/cli eval "() => location.pathname" --raw)
        if ($path -ne "/admin/login.html") { throw "expected /admin/login.html after logout, got $path" }
        $console = npx --yes @playwright/cli console
        if (($console | Out-String) -notlike "*Total messages: 0*") {
            throw "console had messages: $console"
        }

        $date = (Get-Date).ToString("yyyy-MM-dd")
        $appLog = Join-Path $logDir "app-$date.log"
        if (!(Test-Path $appLog)) { throw "missing app log $appLog" }

        Write-Host "pay233 admin e2e passed"
        Write-Host "Screenshots: $out"
    }
    finally {
        npx --yes @playwright/cli close 2>$null | Out-Null
        if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
    }
}
finally {
    Pop-Location
}
