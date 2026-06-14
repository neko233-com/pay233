$ErrorActionPreference = "Stop"

$baseUrl = if ($env:PAY233_BASE_URL) { $env:PAY233_BASE_URL } else { "http://127.0.0.1:8080" }
$secret = if ($env:PAY233_SIGNING_SECRET) { $env:PAY233_SIGNING_SECRET } else { "dev-secret" }

function New-Pay233Signature {
    param(
        [string] $Secret,
        [string] $Timestamp,
        [string] $Body
    )

    $hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($Secret))
    $bytes = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes("$Timestamp.$Body"))
    return -join ($bytes | ForEach-Object { $_.ToString("x2") })
}

$health = Invoke-RestMethod -Uri "$baseUrl/healthz" -Method GET
if ($health.status -ne "ok") {
    throw "health check failed"
}

$body = @{
    merchant_id = "smoke-merchant"
    out_trade_no = "smoke-$(Get-Date -Format yyyyMMddHHmmss)"
    channel = "mock"
    amount = @{
        currency = "CNY"
        amount = 100
    }
    subject = "pay233 smoke test"
} | ConvertTo-Json -Depth 5 -Compress

$timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$signature = New-Pay233Signature -Secret $secret -Timestamp $timestamp -Body $body
$headers = @{
    "X-Pay233-Timestamp" = $timestamp
    "X-Pay233-Signature" = $signature
}

$payment = Invoke-RestMethod -Uri "$baseUrl/v1/payments" -Method POST -Body $body -ContentType "application/json" -Headers $headers
if (-not $payment.id -or $payment.status -ne "pending") {
    throw "create payment failed"
}

$loaded = Invoke-RestMethod -Uri "$baseUrl/v1/payments/$($payment.id)" -Method GET
if ($loaded.id -ne $payment.id) {
    throw "get payment failed"
}

Write-Host "pay233 smoke test passed: $($payment.id)"
