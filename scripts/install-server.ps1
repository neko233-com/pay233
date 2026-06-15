# pay233-server installer (Windows PowerShell)
# iwr -useb https://raw.githubusercontent.com/neko233-com/pay233/main/scripts/install-server.ps1 | iex
# iwr -useb https://raw.githubusercontent.com/neko233-com/pay233/main/scripts/install-server.ps1 | iex; Install-Pay233Server -Version v0.1.0

param(
    [string]$Version = "latest"
)

$ErrorActionPreference = "Stop"
$BinaryName = "pay233-server"
$Repo = if ($env:PAY233_SERVER_REPO) { $env:PAY233_SERVER_REPO } else { "neko233-com/pay233-server" }
$InstallDir = if ($env:PAY233_SERVER_INSTALL) { $env:PAY233_SERVER_INSTALL } else { Join-Path $env:LOCALAPPDATA "pay233" }
$ConfigDir = if ($env:PAY233_SERVER_CONFIG_DIR) { $env:PAY233_SERVER_CONFIG_DIR } else { Join-Path $env:ProgramData "pay233" }
$ConfigFile = if ($env:PAY233_SERVER_CONFIG) { $env:PAY233_SERVER_CONFIG } else { Join-Path $ConfigDir "config.json" }
$ListenAddr = if ($env:PAY233_SERVER_ADDR) { $env:PAY233_SERVER_ADDR } else { ":5500" }
$TaskName = if ($env:PAY233_SERVER_TASK) { $env:PAY233_SERVER_TASK } else { "pay233-server" }
$LogDir = if ($env:PAY233_SERVER_LOG_DIR) { $env:PAY233_SERVER_LOG_DIR } else { Join-Path $ConfigDir "logs" }
$DataDir = if ($env:PAY233_SERVER_DATA_DIR) { $env:PAY233_SERVER_DATA_DIR } else { Join-Path $ConfigDir "data" }
$AdminUsername = if ($env:PAY233_ADMIN_USERNAME) { $env:PAY233_ADMIN_USERNAME } else { "root" }
$AdminPassword = if ($env:PAY233_ADMIN_PASSWORD) { $env:PAY233_ADMIN_PASSWORD } else { "root" }

function Get-Pay233LatestVersion {
    $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest"
    return ($r.tag_name -replace '^[vV]', '')
}

function New-Pay233Secret {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    return -join ($bytes | ForEach-Object { $_.ToString("x2") })
}

function Write-Pay233Config {
    if (Test-Path $ConfigFile) {
        Write-Host "Config exists: $ConfigFile"
        return
    }

    $secret = if ($env:PAY233_SIGNING_SECRET) { $env:PAY233_SIGNING_SECRET } else { New-Pay233Secret }
    $adminSecret = if ($env:PAY233_ADMIN_SESSION_SECRET) { $env:PAY233_ADMIN_SESSION_SECRET } else { New-Pay233Secret }
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    $config = [ordered]@{
        http = [ordered]@{ addr = $ListenAddr }
        api = [ordered]@{
            signing_secret = $secret
            signature_max_skew_seconds = 300
        }
        admin = [ordered]@{
            username = $AdminUsername
            password = $AdminPassword
            session_secret = $adminSecret
        }
        logging = [ordered]@{
            dir = $LogDir
            retention_days = 31
        }
        storage = [ordered]@{
            payments_path = (Join-Path $DataDir "payments.jsonl")
            admin_users_path = (Join-Path $DataDir "admin-users.json")
            audit_path = (Join-Path $DataDir "audit.jsonl")
            audit_retention_days = 31
        }
        monitor = [ordered]@{
            channel_health_interval_seconds = 60
            channel_health_timeout_seconds = 5
        }
        channels = @(
            [ordered]@{
                name = "mock"
                provider = "mock"
                enabled = $true
                options = [ordered]@{
                    pay_url_base = "https://pay233.local/mock/pay"
                }
                environments = [ordered]@{
                    test = [ordered]@{
                        credentials = [ordered]@{ merchant_id = "mock-test-merchant" }
                        options = [ordered]@{
                            pay_url_base = "https://pay233.local/mock/test/pay"
                            health_status = "ok"
                        }
                    }
                    release = [ordered]@{
                        credentials = [ordered]@{ merchant_id = "mock-release-merchant" }
                        options = [ordered]@{
                            pay_url_base = "https://pay233.local/mock/release/pay"
                            health_status = "ok"
                        }
                    }
                }
            },
            [ordered]@{
                name = "wechat"
                provider = "wechat_pay"
                enabled = $true
            },
            [ordered]@{
                name = "alipay"
                provider = "alipay"
                enabled = $true
            },
            [ordered]@{
                name = "stripe"
                provider = "stripe"
                enabled = $true
            },
            [ordered]@{
                name = "paypal"
                provider = "paypal"
                enabled = $true
            },
            [ordered]@{
                name = "google-pay"
                provider = "google_pay"
                enabled = $true
            },
            [ordered]@{
                name = "apple-iap"
                provider = "apple_iap"
                enabled = $true
            },
            [ordered]@{
                name = "unionpay"
                provider = "unionpay"
                enabled = $true
            }
        )
    }
    $config | ConvertTo-Json -Depth 8 | Set-Content -Path $ConfigFile -Encoding UTF8
    Write-Host "Created config: $ConfigFile"
}

function Install-Pay233ScheduledTask {
    param([string]$ExePath)

    $args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"& '$ExePath' -config '$ConfigFile'`""
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $args
    try {
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        Write-Host "Installed startup task: $TaskName"
    } catch {
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        Write-Host "Installed logon task: $TaskName"
    }
}

function Get-Pay233HealthUrl {
    if ($ListenAddr.StartsWith(":")) {
        return "http://127.0.0.1$ListenAddr/healthz"
    }
    return "http://$ListenAddr/healthz"
}

function Install-Pay233Server {
    param([string]$Version = "latest")

    if ($Version -eq "latest") {
        $Version = Get-Pay233LatestVersion
    }
    $Version = $Version -replace '^[vV]', ''

    $arch = "amd64"
    if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { $arch = "arm64" }
    $asset = "$BinaryName-windows-$arch.exe"
    $url = "https://github.com/$Repo/releases/download/v$Version/$asset"

    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $dest = Join-Path $InstallDir "$BinaryName.exe"

    Write-Host "Downloading $url ..."
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    Write-Pay233Config
    Install-Pay233ScheduledTask -ExePath $dest

    Write-Host "Installed $BinaryName v$Version -> $dest"
    Write-Host "Config: $ConfigFile"
    Write-Host "Start now: & `"$dest`" -config `"$ConfigFile`""
    Write-Host "Health: $(Get-Pay233HealthUrl)"
}

Install-Pay233Server -Version $Version
