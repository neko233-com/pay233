$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$serverRoot = Join-Path $root "pay233-server"
$tmp = Join-Path $serverRoot ".tmp"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

function New-Pay233Signature {
    param([string]$Secret, [string]$Timestamp, [string]$Body)
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($Secret))
    $bytes = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Timestamp.$Body"))
    return -join ($bytes | ForEach-Object { $_.ToString("x2") })
}

function Invoke-SignedJson {
    param([string]$BaseUrl, [string]$Path, [object]$Body)
    $json = $Body | ConvertTo-Json -Depth 8 -Compress
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $headers = @{
        "X-Pay233-Timestamp" = $timestamp
        "X-Pay233-Signature" = New-Pay233Signature -Secret "dev-secret" -Timestamp $timestamp -Body $json
    }
    return Invoke-RestMethod -Uri "$BaseUrl$Path" -Method POST -Body $json -ContentType "application/json" -Headers $headers
}

$bin = Join-Path $tmp "pay233-server.exe"
Push-Location $serverRoot
try { go build -o $bin ./cmd/pay233-server }
finally { Pop-Location }

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$listener.Stop()

$logDir = Join-Path $tmp "logs-env-channel"
$dataDir = Join-Path $tmp "data-env-channel"
$config = Join-Path $tmp "config.env-channel-e2e.json"
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $logDir, $dataDir
@"
{
  "http": {"addr": "127.0.0.1:$port"},
  "api": {"signing_secret": "dev-secret", "signature_max_skew_seconds": 300},
  "admin": {"username":"root","password":"root","session_secret":"dev-admin-secret"},
  "logging": {"dir": "$($logDir.Replace('\','\\'))", "retention_days": 31},
  "storage": {
    "payments_path": "$((Join-Path $dataDir "payments.jsonl").Replace('\','\\'))",
    "admin_users_path": "$((Join-Path $dataDir "admin-users.json").Replace('\','\\'))",
    "audit_path": "$((Join-Path $dataDir "audit.jsonl").Replace('\','\\'))",
    "audit_retention_days": 31
  },
  "monitor": {"channel_health_interval_seconds": 60, "channel_health_timeout_seconds": 5},
  "channels": [{
    "name": "mock",
    "provider": "mock",
    "enabled": true,
    "options": {"pay_url_base": "https://default.pay233.local/mock/pay"},
    "environments": {
      "test": {
        "credentials": {"merchant_id": "mock-test-merchant", "api_key": "test-key"},
        "options": {"pay_url_base": "https://test.pay233.local/mock/pay", "health_status": "ok"}
      },
      "release": {
        "credentials": {"merchant_id": "mock-release-merchant", "api_key": "release-key"},
        "options": {"pay_url_base": "https://release.pay233.local/mock/pay", "health_status": "degraded"}
      }
    }
  }]
}
"@ | Set-Content -Path $config -Encoding UTF8

$proc = Start-Process -FilePath $bin -ArgumentList "-config", $config -WorkingDirectory $serverRoot -PassThru -WindowStyle Hidden
try {
    $baseUrl = "http://127.0.0.1:$port"
    $ready = $false
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $health = Invoke-RestMethod -Uri "$baseUrl/healthz" -TimeoutSec 1
            if ($health.status -eq "ok") { $ready = $true; break }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    if (-not $ready) { throw "server did not become ready" }

    $expected = @{
        test = "https://test.pay233.local/mock/pay/"
        release = "https://release.pay233.local/mock/pay/"
    }
    foreach ($envType in @("test", "release")) {
        $payment = Invoke-SignedJson -BaseUrl $baseUrl -Path "/v1/payments" -Body @{
            envType = $envType
            merchant_id = "env-channel-e2e"
            out_trade_no = "same-order"
            channel = "mock"
            amount = @{ currency = "CNY"; amount = 100 }
            subject = "env channel e2e $envType"
        }
        if ($payment.env_type -ne $envType) {
            throw "expected payment env $envType, got $($payment.env_type)"
        }
        if ($payment.pay_url -notlike "$($expected[$envType])*") {
            throw "expected $envType pay_url to start with $($expected[$envType]), got $($payment.pay_url)"
        }
    }

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    Invoke-RestMethod -Uri "$baseUrl/admin/login" -Method POST -Body '{"username":"root","password":"root"}' -ContentType "application/json" -WebSession $session | Out-Null
    $result = Invoke-RestMethod -Uri "$baseUrl/admin/api/channels/health-check" -Method POST -Body '{}' -ContentType "application/json" -WebSession $session

    $testHealth = $result.channels | Where-Object { $_.name -eq "mock" -and $_.env_type -eq "test" } | Select-Object -First 1
    $releaseHealth = $result.channels | Where-Object { $_.name -eq "mock" -and $_.env_type -eq "release" } | Select-Object -First 1
    if (-not $testHealth -or $testHealth.health -ne "ok") {
        throw "expected mock/test health ok"
    }
    if (-not $releaseHealth -or $releaseHealth.health -ne "degraded") {
        throw "expected mock/release health degraded"
    }

    Write-Host "pay233 env-channel e2e passed"
}
finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
}
