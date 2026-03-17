<#
.SYNOPSIS
    Batch-rewires classic Azure DevOps pipelines to GitHub using classic_pipeline.csv.

.DESCRIPTION
    Reads pipeline rows from classic_pipeline.csv and rewires each classic
    (process type 1) pipeline to its corresponding GitHub repository via the
    Azure DevOps REST API.

    If repos_with_status.csv is present (Stage 3 output from the migration
    pipeline), only pipelines whose ADO repo migrated successfully are
    processed; all others are skipped with a warning.

.PREREQUISITES
    - PowerShell 5.1+ or PowerShell 7+
    - ADO_PAT environment variable (Build: Read & Execute)

.PARAMETER CsvFile
    Path to classic_pipeline.csv. Defaults to classic_pipeline.csv in the
    same directory as this script.

.PARAMETER ReposStatusFile
    Path to repos_with_status.csv from Stage 3 of the migration pipeline.
    When supplied (or auto-detected), only pipelines whose ADO repo migrated
    successfully are processed.

.EXAMPLE
    $env:ADO_PAT = "your-ado-pat"
    .\rewire-classicpipeline-batch.ps1

.EXAMPLE
    $env:ADO_PAT = "your-ado-pat"
    .\rewire-classicpipeline-batch.ps1 -CsvFile C:\migration\classic_pipeline.csv

.EXAMPLE
    $env:ADO_PAT = "your-ado-pat"
    .\rewire-classicpipeline-batch.ps1 `
        -CsvFile            C:\migration\classic_pipeline.csv `
        -ReposStatusFile    C:\migration\repos_with_status.csv

.CSV FORMAT (classic_pipeline.csv)
    Required columns : org, teamproject, repo, pipeline, serviceConnection,
                       github_org, github_repo
    Optional columns : pipeline_id   (numeric ID; takes precedence over pipeline name)
                       default_branch (defaults to "main")
                       url            (informational only, from ado2gh inventory)
#>

[CmdletBinding()]
param (
    [string]$CsvFile        = "",
    [string]$ReposStatusFile = ""
)

# ── Resolve default CSV path ──────────────────────────────────────────────────
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $CsvFile) {
    $CsvFile = Join-Path $ScriptDir "classic_pipeline.csv"
}

# ── Placeholder values that should be rejected ───────────────────────────────
$PlaceholderValues = @(
    "your-service-connection-id", "placeholder", "TODO", "TBD", "xxx",
    "00000000-0000-0000-0000-000000000000"
)

# ── Counters / result lists ───────────────────────────────────────────────────
$SuccessCount  = 0
$FailureCount  = 0
$SkippedCount  = 0
$Results       = [System.Collections.Generic.List[string]]::new()
$FailedDetails = [System.Collections.Generic.List[string]]::new()
$SkippedDetails= [System.Collections.Generic.List[string]]::new()
$MigratedRepos = @{}
$FilterByStatus= $false

# ── Helper: load repos_with_status.csv ───────────────────────────────────────
function Load-MigratedRepos {
    param([string]$StatusFile)
    $script:FilterByStatus = $true
    Write-Host "Loading successfully migrated repositories from: $StatusFile" -ForegroundColor Yellow

    Import-Csv $StatusFile | ForEach-Object {
        $repo   = $_.repo.Trim()
        $status = $_.status.Trim()
        if ($status -eq "Success") { $script:MigratedRepos[$repo] = $true }
    }

    Write-Host "✅ Loaded $($script:MigratedRepos.Count) successfully migrated repositories" -ForegroundColor Green

    if ($script:MigratedRepos.Count -eq 0) {
        Write-Host "⚠️  No successful migrations found — all pipelines will be skipped" -ForegroundColor Yellow
    }
}

# ── Core rewiring function ────────────────────────────────────────────────────
# Returns: "success" | "skipped-yaml" | throws on error
function Invoke-RewireClassicPipeline {
    param (
        [string]$AdoOrg,
        [string]$AdoProject,
        [int]   $PipelineId,
        [string]$GitHubOrg,
        [string]$GitHubRepo,
        [string]$ServiceConnectionId,
        [string]$DefaultBranch
    )

    $headers = @{
        Authorization = "Basic " + [Convert]::ToBase64String(
            [Text.Encoding]::ASCII.GetBytes(":$($env:ADO_PAT)")
        )
    }

    $defUrl = "https://dev.azure.com/$AdoOrg/$AdoProject/_apis/build/definitions/$($PipelineId)?api-version=6.0"
    $definition = Invoke-RestMethod -Method GET -Uri $defUrl -Headers $headers

    $processType = $definition.process.type
    if ($processType -ne 1) {
        return "skipped-yaml"
    }

    $definition.repository = [PSCustomObject]@{
        properties = [PSCustomObject]@{
            apiUrl             = "https://api.github.com/repos/$GitHubOrg/$GitHubRepo"
            branchesUrl        = "https://api.github.com/repos/$GitHubOrg/$GitHubRepo/branches"
            cloneUrl           = "https://github.com/$GitHubOrg/$GitHubRepo.git"
            connectedServiceId = $ServiceConnectionId
            defaultBranch      = $DefaultBranch
            fullName           = "$GitHubOrg/$GitHubRepo"
            manageUrl          = "https://github.com/$GitHubOrg/$GitHubRepo"
            orgName            = $GitHubOrg
            refsUrl            = "https://api.github.com/repos/$GitHubOrg/$GitHubRepo/git/refs"
            safeRepository     = "$GitHubOrg/$GitHubRepo"
            shortName          = $GitHubRepo
            reportBuildStatus  = "true"
        }
        id                   = "$GitHubOrg/$GitHubRepo"
        type                 = "GitHub"
        name                 = "$GitHubOrg/$GitHubRepo"
        url                  = "https://github.com/$GitHubOrg/$GitHubRepo.git"
        defaultBranch        = $DefaultBranch
        clean                = "false"
        checkoutSubmodules   = "false"
    }

    $jsonBody = $definition | ConvertTo-Json -Depth 20
    Invoke-RestMethod -Method PUT -Uri $defUrl -Headers $headers `
        -ContentType "application/json" -Body $jsonBody | Out-Null

    return "success"
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  ADO2GH: Batch Rewire Classic Pipelines" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Auto-detect repos_with_status.csv
if (-not $ReposStatusFile) {
    foreach ($candidate in @(
        (Join-Path $ScriptDir "repos_with_status.csv"),
        (Join-Path $ScriptDir ".." "repos_with_status.csv")
    )) {
        if (Test-Path $candidate) { $ReposStatusFile = $candidate; break }
    }
}

if ($ReposStatusFile) {
    if (Test-Path $ReposStatusFile) {
        Load-MigratedRepos -StatusFile $ReposStatusFile
    } else {
        Write-Host "⚠️  repos_with_status.csv not found at: $ReposStatusFile — processing all rows" -ForegroundColor Yellow
    }
} else {
    Write-Host "ℹ️  No repos_with_status.csv detected — processing all rows in CSV" -ForegroundColor Gray
}

# ── Step 1: Validate ADO_PAT ──────────────────────────────────────────────────
Write-Host "[Step 1/4] Validating ADO_PAT..." -ForegroundColor Yellow
if (-not $env:ADO_PAT) {
    Write-Host "❌ ERROR: ADO_PAT environment variable is not set" -ForegroundColor Red
    exit 1
}
Write-Host "✅ ADO_PAT validated" -ForegroundColor Green

# ── Step 2: Validate CSV file ─────────────────────────────────────────────────
Write-Host "`n[Step 2/4] Validating classic_pipeline.csv..." -ForegroundColor Yellow
if (-not (Test-Path $CsvFile)) {
    Write-Host "❌ ERROR: CSV file not found: $CsvFile" -ForegroundColor Red
    Write-Host "   Use -CsvFile <path> or place classic_pipeline.csv in the batch/ folder" -ForegroundColor Yellow
    exit 1
}

$rows = Import-Csv $CsvFile
$PipelineCount = $rows.Count
if ($PipelineCount -eq 0) {
    Write-Host "⚠️  No pipelines found in CSV (only header or empty file)" -ForegroundColor Yellow
    exit 0
}
Write-Host "✅ File loaded: $PipelineCount pipeline(s) found" -ForegroundColor Green

# ── Step 3: Validate columns and service connection IDs ───────────────────────
Write-Host "`n[Step 3/4] Validating CSV columns and data..." -ForegroundColor Yellow

$RequiredCols = @("org","teamproject","repo","pipeline","serviceConnection","github_org","github_repo")
$CsvHeaders   = ($rows[0].PSObject.Properties.Name)
$MissingCols  = $RequiredCols | Where-Object { $_ -notin $CsvHeaders }

if ($MissingCols.Count -gt 0) {
    Write-Host "❌ ERROR: CSV missing required columns: $($MissingCols -join ', ')" -ForegroundColor Red
    Write-Host "   Required : $($RequiredCols -join ', ')" -ForegroundColor Yellow
    Write-Host "   Found    : $($CsvHeaders -join ', ')" -ForegroundColor Gray
    exit 1
}
Write-Host "✅ All required columns present" -ForegroundColor Green

Write-Host "   Validating service connection IDs..." -ForegroundColor Gray
$InvalidRows = [System.Collections.Generic.List[string]]::new()
$rowNum = 1
foreach ($row in $rows) {
    $rowNum++
    $svc = $row.serviceConnection.Trim()
    $pl  = $row.pipeline.Trim()
    if (-not $svc) {
        $InvalidRows.Add("Row ${rowNum}: '${pl}' — empty serviceConnection")
    } elseif ($svc -in $PlaceholderValues) {
        $InvalidRows.Add("Row ${rowNum}: '${pl}' — placeholder value: '$svc'")
    }
}

if ($InvalidRows.Count -gt 0) {
    Write-Host "`n❌ ERROR: Invalid service connection IDs found:" -ForegroundColor Red
    $InvalidRows | ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow }
    Write-Host "`n   💡 Fix: Azure DevOps → Project Settings → Service Connections → copy the GUID" -ForegroundColor Cyan
    exit 1
}
Write-Host "✅ All service connection IDs validated" -ForegroundColor Green

# ── Step 4: Rewire pipelines ──────────────────────────────────────────────────
Write-Host "`n[Step 4/4] Rewiring classic pipelines to GitHub..." -ForegroundColor Yellow

foreach ($row in $rows) {
    $AdoOrg        = $row.org.Trim()
    $AdoProject    = $row.teamproject.Trim()
    $AdoRepo       = $row.repo.Trim()
    $PipelineName  = $row.pipeline.Trim()
    $GitHubOrg     = $row.github_org.Trim()
    $GitHubRepo    = $row.github_repo.Trim()
    $SvcConnId     = $row.serviceConnection.Trim()
    $PipelineIdCsv = if ($CsvHeaders -contains "pipeline_id") { $row.pipeline_id.Trim() } else { "" }
    $DefaultBranch = if ($CsvHeaders -contains "default_branch" -and $row.default_branch.Trim()) {
                         $row.default_branch.Trim() } else { "main" }

    $PipelineLabel = if ($PipelineIdCsv) { "'$PipelineName' (ID: $PipelineIdCsv)" } else { "'$PipelineName'" }

    Write-Host "`n   🔍 Checking: $PipelineLabel — repo: '$AdoRepo'" -ForegroundColor Gray

    # Optional status filter
    if ($FilterByStatus -and -not $MigratedRepos.ContainsKey($AdoRepo)) {
        $SkippedCount++
        Write-Host "   ⏭️  Skipped: $PipelineLabel" -ForegroundColor Yellow
        Write-Host "      Reason: '$AdoRepo' not found in repos_with_status.csv as Success" -ForegroundColor Gray
        $SkippedDetails.Add("$AdoProject/$PipelineLabel : repo '$AdoRepo' not successfully migrated")
        continue
    }

    Write-Host "   🔄 Processing: $PipelineLabel" -ForegroundColor Cyan
    Write-Host "      ADO    : $AdoOrg/$AdoProject" -ForegroundColor Gray
    Write-Host "      GitHub : $GitHubOrg/$GitHubRepo (branch: $DefaultBranch)" -ForegroundColor Gray
    Write-Host "      Svc    : $SvcConnId" -ForegroundColor Gray

    # Resolve pipeline name → ID if needed
    $ResolvedId = 0
    if ($PipelineIdCsv) {
        $ResolvedId = [int]$PipelineIdCsv
    } else {
        Write-Host "      Resolving pipeline name to ID..." -ForegroundColor Gray
        $headers = @{
            Authorization = "Basic " + [Convert]::ToBase64String(
                [Text.Encoding]::ASCII.GetBytes(":$($env:ADO_PAT)")
            )
        }
        $encodedName = [Uri]::EscapeDataString($PipelineName)
        $listUrl = "https://dev.azure.com/$AdoOrg/$AdoProject/_apis/build/definitions?api-version=7.1&name=$encodedName"

        try {
            $list = Invoke-RestMethod -Method GET -Uri $listUrl -Headers $headers
        } catch {
            $FailureCount++
            $err = "Failed to query pipeline list for '$PipelineName': $_"
            Write-Host "      ❌ FAILED: $err" -ForegroundColor Red
            $Results.Add("❌ FAILED | $AdoProject/$PipelineLabel")
            $FailedDetails.Add("$AdoProject/$PipelineLabel : $err")
            continue
        }

        if ($list.count -eq 0) {
            $FailureCount++
            $err = "No pipeline found with name '$PipelineName'"
            Write-Host "      ❌ FAILED: $err" -ForegroundColor Red
            $Results.Add("❌ FAILED | $AdoProject/$PipelineLabel")
            $FailedDetails.Add("$AdoProject/$PipelineLabel : $err")
            continue
        }
        if ($list.count -gt 1) {
            $FailureCount++
            $err = "Multiple pipelines matched '$PipelineName' — add pipeline_id column to disambiguate"
            Write-Host "      ❌ FAILED: $err" -ForegroundColor Red
            $Results.Add("❌ FAILED | $AdoProject/$PipelineLabel")
            $FailedDetails.Add("$AdoProject/$PipelineLabel : $err")
            continue
        }

        $ResolvedId = $list.value[0].id
        Write-Host "      Resolved to pipeline ID: $ResolvedId" -ForegroundColor Gray
    }

    # Rewire
    try {
        $outcome = Invoke-RewireClassicPipeline `
            -AdoOrg            $AdoOrg `
            -AdoProject        $AdoProject `
            -PipelineId        $ResolvedId `
            -GitHubOrg         $GitHubOrg `
            -GitHubRepo        $GitHubRepo `
            -ServiceConnectionId $SvcConnId `
            -DefaultBranch     $DefaultBranch

        if ($outcome -eq "skipped-yaml") {
            $SkippedCount++
            Write-Host "      ⏭️  SKIPPED (YAML pipeline — use gh ado2gh rewire-pipeline instead)" -ForegroundColor Yellow
            $SkippedDetails.Add("$AdoProject/$PipelineLabel : YAML pipeline")
            $Results.Add("⏭️  SKIPPED (YAML) | $AdoProject/$PipelineLabel")
        } else {
            $SuccessCount++
            Write-Host "      ✅ SUCCESS" -ForegroundColor Green
            $Results.Add("✅ SUCCESS | $AdoProject/$PipelineLabel → $GitHubOrg/$GitHubRepo")
        }
    } catch {
        $FailureCount++
        $err = $_.Exception.Message
        Write-Host "      ❌ FAILED: $err" -ForegroundColor Red
        $Results.Add("❌ FAILED | $AdoProject/$PipelineLabel → $GitHubOrg/$GitHubRepo")
        $FailedDetails.Add("$AdoProject/$PipelineLabel : $err")
    }

    Start-Sleep -Seconds 1
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Batch Rewiring Summary"                -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total Pipelines : $PipelineCount"
Write-Host "Successful      : $SuccessCount"  -ForegroundColor Green
Write-Host "Skipped         : $SkippedCount"  -ForegroundColor Yellow
Write-Host "Failed          : $FailureCount"  -ForegroundColor Red

Write-Host "`n📋 Detailed Results:" -ForegroundColor Cyan
$Results | ForEach-Object { Write-Host "   $_" -ForegroundColor Gray }

if ($SkippedDetails.Count -gt 0) {
    Write-Host "`n⏭️  Skipped:" -ForegroundColor Yellow
    $SkippedDetails | ForEach-Object { Write-Host "   • $_" -ForegroundColor Gray }
}

if ($FailedDetails.Count -gt 0) {
    Write-Host "`n❌ Failed:" -ForegroundColor Red
    $FailedDetails | ForEach-Object { Write-Host "   • $_" -ForegroundColor Gray }
}

# ── Write log file ────────────────────────────────────────────────────────────
$Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$LogFile   = Join-Path $ScriptDir ("classic-rewiring-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".txt")

$logContent = @"
Classic Pipeline Batch Rewiring Log - $Timestamp
========================================
Total Pipelines : $PipelineCount
Successful      : $SuccessCount
Skipped         : $SkippedCount
Failed          : $FailureCount

Results:
$($Results -join "`n")

Skipped Details:
$($SkippedDetails -join "`n")

Failed Details:
$($FailedDetails -join "`n")
"@

$logContent | Out-File -FilePath $LogFile -Encoding utf8
Write-Host "`n📄 Log saved: $LogFile" -ForegroundColor Gray

# ── Exit ──────────────────────────────────────────────────────────────────────
if ($FailureCount -eq 0 -and $SkippedCount -eq 0) {
    Write-Host "`n✅ All classic pipelines rewired successfully" -ForegroundColor Green
    exit 0
} elseif ($FailureCount -eq 0) {
    Write-Host "`n✅ Rewiring completed ($SkippedCount skipped)" -ForegroundColor Green
    Write-Host "##vso[task.complete result=SucceededWithIssues]Rewiring completed with $SkippedCount skipped"
    exit 0
} else {
    Write-Host "`n⚠️  Rewiring completed with issues: $SuccessCount succeeded, $SkippedCount skipped, $FailureCount failed" -ForegroundColor Yellow
    Write-Host "##[warning]$FailureCount pipeline(s) failed rewiring"
    Write-Host "##vso[task.complete result=SucceededWithIssues]$SuccessCount succeeded, $SkippedCount skipped, $FailureCount failed"
    exit 0
}
