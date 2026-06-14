$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$serverRoot = Join-Path $root "pay233-server"
$tmp = Join-Path $serverRoot ".tmp"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$bin = Join-Path $tmp "pay233-server.exe"
Push-Location $serverRoot
try { go build -o $bin ./cmd/pay233-server }
finally { Pop-Location }

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$listener.Stop()

$logDir = Join-Path $tmp "logs-health"
$dataDir = Join-Path $tmp "data-health"
$config = Join-Path $tmp "config.health-e2e.json"
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $logDir, $dataDir
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
  "monitor": {"channel_health_interval_seconds": 60, "channel_health_timeout_seconds": 5},
  "channels": [
    {"name":"mock-ok","provider":"mock","enabled":true},
    {"name":"mock-down","provider":"mock","enabled":true,"options":{"health_status":"down"}}
  ]
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

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    Invoke-RestMethod -Uri "$baseUrl/admin/login" -Method POST -Body '{"username":"root","password":"root"}' -ContentType "application/json" -WebSession $session | Out-Null
    $result = Invoke-RestMethod -Uri "$baseUrl/admin/api/channels/health-check" -Method POST -Body '{}' -ContentType "application/json" -WebSession $session
    $down = $result.channels | Where-Object { $_.name -eq "mock-down" } | Select-Object -First 1
    if (-not $down -or $down.health -ne "down") {
        throw "expected mock-down to be down"
    }

    $audit = Invoke-RestMethod -Uri "$baseUrl/admin/api/audit?limit=50" -WebSession $session
    $hit = $audit.entries | Where-Object { $_.action -eq "channel_health_status" -and $_.target -eq "mock-down" } | Select-Object -First 1
    if (-not $hit) {
        throw "expected channel health audit entry"
    }

    Write-Host "pay233 health e2e passed"
}
finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
}
