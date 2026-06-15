param(
    [string]$Branch = "main",
    [switch]$NoRun,
    [switch]$Open
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "missing required command: $Name"
    }
}

function Invoke-GhJson {
    param([string[]]$Arguments)
    $raw = & gh @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "gh $($Arguments -join ' ') failed"
    }
    if (-not $raw) {
        return $null
    }
    return ($raw | ConvertFrom-Json)
}

function Test-PagesEnabled {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & gh api repos/:owner/:repo/pages 2>&1 | Out-Null
        return $LASTEXITCODE -eq 0
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Enable-PagesWorkflow {
    if (Test-PagesEnabled) {
        Write-Host "GitHub Pages already exists; switching build type to workflow."
        & gh api -X PUT repos/:owner/:repo/pages -f build_type=workflow | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "failed to update GitHub Pages build type"
        }
        return
    }

    Write-Host "Creating GitHub Pages site with GitHub Actions workflow source."
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & gh api -X POST repos/:owner/:repo/pages -f build_type=workflow 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($exitCode -ne 0) {
        if (($output | Out-String) -match "already|exists|409|422") {
            & gh api -X PUT repos/:owner/:repo/pages -f build_type=workflow | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "failed to update existing GitHub Pages site"
            }
            return
        }
        throw "failed to create GitHub Pages site: $output"
    }
}

Require-Command gh

if (-not (Test-Path ".github/workflows/pages.yml")) {
    throw "missing .github/workflows/pages.yml"
}
if (-not (Test-Path "docs/index.html")) {
    throw "missing docs/index.html"
}

$repo = Invoke-GhJson @("repo", "view", "--json", "nameWithOwner,url,defaultBranchRef")
$defaultBranch = $repo.defaultBranchRef.name
if ([string]::IsNullOrWhiteSpace($Branch)) {
    $Branch = $defaultBranch
}

Write-Host "Repository: $($repo.nameWithOwner)"
Write-Host "Docs source: docs/"
Write-Host "Publish branch: $Branch"

Enable-PagesWorkflow

$previous = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    & gh workflow enable pages.yml 2>&1 | Out-Null
} finally {
    $ErrorActionPreference = $previous
}

if (-not $NoRun) {
    Write-Host "Triggering Pages workflow..."
    & gh workflow run pages.yml --ref $Branch
    if ($LASTEXITCODE -ne 0) {
        throw "failed to trigger pages.yml workflow; make sure it has been pushed to $Branch"
    }

    Start-Sleep -Seconds 4
    $run = Invoke-GhJson @("run", "list", "--workflow", "pages.yml", "--branch", $Branch, "--limit", "1", "--json", "databaseId,status,conclusion,url")
    if (-not $run -or $run.Count -eq 0) {
        throw "could not find Pages workflow run"
    }
    $runId = $run[0].databaseId
    Write-Host "Watching workflow run: $runId"
    & gh run watch $runId --exit-status
    if ($LASTEXITCODE -ne 0) {
        throw "Pages workflow failed"
    }
}

$pages = Invoke-GhJson @("api", "repos/:owner/:repo/pages")
Write-Host "GitHub Pages URL: $($pages.html_url)"

if ($Open) {
    gh browse $pages.html_url
}
