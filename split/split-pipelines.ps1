<#
.SYNOPSIS
    Splits an ado2gh pipelines.csv into YAML and Classic pipeline files.

.DESCRIPTION
    Reads each row from pipelines.csv, queries the Azure DevOps
    build/definitions API to check process.type, then routes rows to:
      - pipelines.csv        (YAML pipelines,    process.type = 2)
      - classic_pipeline.csv (Classic pipelines, process.type = 1)

    Both output files are written to the same directory as the input file.
    The definition ID is extracted from the 'url' column when available
    (skips an extra name-lookup API call). Falls back to a name lookup
    when no URL or definitionId is present.

.PREREQUISITES
    - PowerShell 5.1+ or PowerShell 7+
    - ADO_PAT environment variable (Build: Read scope)

.PARAMETER CsvFile
    Path to the input pipelines.csv.
    Defaults to pipelines.csv in the same directory as this script.

.EXAMPLE
    $env:ADO_PAT = "your-ado-pat"
    .\split-pipelines.ps1

.EXAMPLE
    $env:ADO_PAT = "your-ado-pat"
    .\split-pipelines.ps1 -CsvFile C:\migration\my-pipelines.csv

.OUTPUTS
    pipelines.csv        — YAML pipelines only        (same dir as input)
    classic_pipeline.csv — Classic pipelines only     (same dir as input)

.NOTES
    After splitting, add the serviceConnection, github_org, github_repo, and
    (optionally) default_branch columns to classic_pipeline.csv before using
    it with batch\rewire-classicpipeline-batch.ps1.
#>

[CmdletBinding()]
param (
    [string]$CsvFile = ""
)

# ── Resolve default path ───────────────────────────────────────────────────────
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $CsvFile) {
    $CsvFile = Join-Path $ScriptDir "pipelines.csv"
}

# ── Validate inputs ────────────────────────────────────────────────────────────
if (-not $env:ADO_PAT) {
    Write-Host "ERROR: ADO_PAT environment variable is not set" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $CsvFile)) {
    Write-Host "ERROR: Input file not found: $CsvFile" -ForegroundColor Red
    Write-Host "  Use -CsvFile <path> or place pipelines.csv in the split/ folder" -ForegroundColor Yellow
    exit 1
}

$OutputDir   = Split-Path -Parent (Resolve-Path $CsvFile)
$YamlOut     = Join-Path $OutputDir "pipelines.csv"
$ClassicOut  = Join-Path $OutputDir "classic_pipeline.csv"

$headers = @{
    Authorization = "Basic " + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes(":$($env:ADO_PAT)")
    )
}

# ── Load CSV ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Split pipelines.csv by process type"   -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan
Write-Host "Input : $CsvFile"     -ForegroundColor Gray
Write-Host "Output: $OutputDir`n" -ForegroundColor Gray

$rows = Import-Csv $CsvFile
if ($rows.Count -eq 0) {
    Write-Host "No rows found in input file." -ForegroundColor Yellow
    exit 0
}

$csvHeaders = $rows[0].PSObject.Properties.Name

foreach ($col in @("org", "teamproject", "pipeline")) {
    if ($col -notin $csvHeaders) {
        Write-Host "ERROR: Required column '$col' not found in CSV header" -ForegroundColor Red
        Write-Host "  Found columns: $($csvHeaders -join ', ')" -ForegroundColor Gray
        exit 1
    }
}

$hasUrlCol = "url" -in $csvHeaders

# ── Process rows ───────────────────────────────────────────────────────────────
$YamlRows    = [System.Collections.Generic.List[PSObject]]::new()
$ClassicRows = [System.Collections.Generic.List[PSObject]]::new()
$UnknownRows = [System.Collections.Generic.List[PSObject]]::new()
$FailedRows  = [System.Collections.Generic.List[PSObject]]::new()
$Total       = 0

foreach ($row in $rows) {
    $Total++
    $org          = $row.org.Trim()
    $project      = $row.teamproject.Trim()
    $pipelineName = $row.pipeline.Trim()
    $urlVal       = if ($hasUrlCol) { $row.url.Trim() } else { "" }

    # Extract definitionId from URL if present
    $defId = $null
    if ($urlVal -match 'definitionId=(\d+)') {
        $defId = $Matches[1]
    }

    # Fall back to name lookup
    if (-not $defId) {
        $encodedName = [Uri]::EscapeDataString($pipelineName)
        $listUrl = "https://dev.azure.com/$org/$project/_apis/build/definitions?api-version=7.1&name=$encodedName"
        try {
            $list = Invoke-RestMethod -Method GET -Uri $listUrl -Headers $headers
        } catch {
            Write-Host "  ❌ FAILED (API error)    : $pipelineName" -ForegroundColor Red
            $FailedRows.Add($row)
            continue
        }
        if ($list.count -eq 0) {
            Write-Host "  ⚠️  NOT FOUND            : $pipelineName" -ForegroundColor Yellow
            $UnknownRows.Add($row)
            continue
        }
        if ($list.count -gt 1) {
            Write-Host "  ⚠️  AMBIGUOUS ($($list.count) matches): $pipelineName" -ForegroundColor Yellow
            $UnknownRows.Add($row)
            continue
        }
        $defId = $list.value[0].id
    }

    # Fetch full definition
    $defUrl = "https://dev.azure.com/$org/$project/_apis/build/definitions/$($defId)?api-version=6.0"
    try {
        $definition = Invoke-RestMethod -Method GET -Uri $defUrl -Headers $headers
    } catch {
        Write-Host "  ❌ FAILED (definition fetch): $pipelineName" -ForegroundColor Red
        $FailedRows.Add($row)
        continue
    }

    $processType = $definition.process.type

    switch ($processType) {
        2 {
            Write-Host "  ✅ YAML              : $pipelineName" -ForegroundColor Green
            $YamlRows.Add($row)
        }
        1 {
            Write-Host "  🔧 CLASSIC           : $pipelineName" -ForegroundColor Cyan
            $ClassicRows.Add($row)
        }
        default {
            Write-Host "  ❓ UNKNOWN (type=$processType): $pipelineName" -ForegroundColor Yellow
            $UnknownRows.Add($row)
        }
    }

    Start-Sleep -Milliseconds 300
}

# ── Write output files ─────────────────────────────────────────────────────────
Write-Host "`nWriting output files..." -ForegroundColor Yellow

$YamlRows    | Export-Csv -Path $YamlOut    -NoTypeInformation -Encoding UTF8
$ClassicRows | Export-Csv -Path $ClassicOut -NoTypeInformation -Encoding UTF8

# Handle empty result sets — Export-Csv on an empty list writes no file;
# ensure header-only files are created so downstream scripts don't error.
if ($YamlRows.Count -eq 0) {
    ($csvHeaders -join ",") | Out-File -FilePath $YamlOut    -Encoding utf8
}
if ($ClassicRows.Count -eq 0) {
    ($csvHeaders -join ",") | Out-File -FilePath $ClassicOut -Encoding utf8
}

# ── Summary ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Summary"                               -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Total processed  : $Total"
Write-Host "YAML             : $($YamlRows.Count)"    -ForegroundColor Green
Write-Host "Classic          : $($ClassicRows.Count)" -ForegroundColor Cyan
if ($UnknownRows.Count -gt 0) { Write-Host "Unknown / skipped: $($UnknownRows.Count)" -ForegroundColor Yellow }
if ($FailedRows.Count  -gt 0) { Write-Host "Failed           : $($FailedRows.Count)"  -ForegroundColor Red }

Write-Host "`nOutput files:" -ForegroundColor Gray
Write-Host "  YAML    → $YamlOut    ($($YamlRows.Count) pipeline(s))"    -ForegroundColor Gray
Write-Host "  Classic → $ClassicOut ($($ClassicRows.Count) pipeline(s))" -ForegroundColor Gray

if ($ClassicRows.Count -gt 0) {
    Write-Host "`nNext step for classic_pipeline.csv:" -ForegroundColor Yellow
    Write-Host "  Add columns : serviceConnection, github_org, github_repo" -ForegroundColor Gray
    Write-Host "  Optional    : default_branch (defaults to 'main' if omitted)" -ForegroundColor Gray
    Write-Host "  Then run    : batch\rewire-classicpipeline-batch.ps1"   -ForegroundColor Gray
}

if ($FailedRows.Count -gt 0) {
    Write-Host "`nThe following pipelines could not be classified:" -ForegroundColor Red
    $FailedRows | ForEach-Object { Write-Host "  • $($_.pipeline)" -ForegroundColor Gray }
}
