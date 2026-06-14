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

$logDir = Join-Path $tmp "logs-env"
$config = Join-Path $tmp "config.env-e2e.json"
@"
{
  "http": {"addr": "127.0.0.1:$port"},
  "api": {"signing_secret": "dev-secret"},
  "admin": {"username":"root","password":"root","session_secret":"dev-admin-secret"},
  "logging": {"dir": "$($logDir.Replace('\','\\'))", "retention_days": 31},
  "channels": [{"name":"mock","provider":"mock","enabled":true}]
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

    foreach ($envType in @("test", "release")) {
        $payment = Invoke-SignedJson -BaseUrl $baseUrl -Path "/v1/payments" -Body @{
            envType = $envType
            merchant_id = "env-e2e"
            out_trade_no = "same-order"
            channel = "mock"
            amount = @{ currency = "CNY"; amount = 100 }
            subject = "env e2e $envType"
        }
        if ($payment.env_type -ne $envType) {
            throw "expected payment env $envType, got $($payment.env_type)"
        }
    }

    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    Invoke-RestMethod -Uri "$baseUrl/admin/login" -Method POST -Body '{"username":"root","password":"root"}' -ContentType "application/json" -WebSession $session | Out-Null
    $testDash = Invoke-RestMethod -Uri "$baseUrl/admin/api/dashboard?envType=test" -WebSession $session
    $releaseDash = Invoke-RestMethod -Uri "$baseUrl/admin/api/dashboard?envType=release" -WebSession $session
    $allDash = Invoke-RestMethod -Uri "$baseUrl/admin/api/dashboard?envType=all" -WebSession $session

    if ($testDash.kpis.total_payments -ne 1) { throw "test dashboard expected 1, got $($testDash.kpis.total_payments)" }
    if ($releaseDash.kpis.total_payments -ne 1) { throw "release dashboard expected 1, got $($releaseDash.kpis.total_payments)" }
    if ($allDash.kpis.total_payments -ne 2) { throw "all dashboard expected 2, got $($allDash.kpis.total_payments)" }

    Write-Host "pay233 env e2e passed"
}
finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
}
