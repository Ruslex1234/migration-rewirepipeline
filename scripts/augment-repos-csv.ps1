<#
.SYNOPSIS
    Augments repos.csv with three new columns: github_org, github_repo,
    gh_repo_visibility.

.DESCRIPTION
    Reads an existing repos.csv file and appends three columns to every
    data row:
      github_org          - left blank for the user to fill in
      github_repo         - copied from column C (the third column)
      gh_repo_visibility  - set to "private" for all rows

    The original file is overwritten with the augmented version.
    If the three columns already exist in the header they are not added
    again, preventing duplicates on repeated runs.

.PARAMETER CsvFile
    Path to repos.csv. Defaults to repos.csv in the same directory as
    this script.

.EXAMPLE
    # Default: reads/writes repos.csv in the same directory as this script
    .\augment-repos-csv.ps1

.EXAMPLE
    # Custom file path
    .\augment-repos-csv.ps1 -CsvFile C:\migration\repos.csv
#>

[CmdletBinding()]
param (
    [string]$CsvFile = ""
)

# ── Resolve default path ───────────────────────────────────────────────────────
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $CsvFile) {
    $CsvFile = Join-Path $ScriptDir "repos.csv"
}

# ── Validate input file ────────────────────────────────────────────────────────
if (-not (Test-Path $CsvFile)) {
    Write-Host "ERROR: CSV file not found: $CsvFile" -ForegroundColor Red
    Write-Host "   Place repos.csv in the scripts/ folder or use -CsvFile <path>" -ForegroundColor Yellow
    exit 1
}

# Read raw lines to preserve column C by position (not by name)
$lines = [System.IO.File]::ReadAllLines($CsvFile, [System.Text.Encoding]::UTF8)

if ($lines.Count -le 1) {
    Write-Host "WARNING: No data rows found in: $CsvFile (file is empty or header-only)" -ForegroundColor Yellow
    exit 0
}

$rowCount = $lines.Count - 1
Write-Host "Input : $CsvFile ($rowCount data row(s))"

# ── Parse header ───────────────────────────────────────────────────────────────
# Simple CSV header split (headers are not expected to contain commas)
$header = $lines[0] -split ',' | ForEach-Object { $_.Trim().Trim('"') }

$newCols   = @("github_org", "github_repo", "gh_repo_visibility")
$colsToAdd = $newCols | Where-Object { $_ -notin $header }

if ($colsToAdd.Count -eq 0) {
    Write-Host "INFO: All three columns already present -- no changes made." -ForegroundColor Cyan
    exit 0
}

# ── Build augmented CSV ────────────────────────────────────────────────────────
# Use a temp file so the original is never left in a partial state
$tmpFile = $CsvFile + ".tmp"

try {
    $output = [System.Collections.Generic.List[string]]::new()

    # New header line
    $newHeaderLine = $lines[0].TrimEnd(',') + ',' + ($colsToAdd -join ',')
    $output.Add($newHeaderLine)

    # Data rows
    foreach ($line in $lines[1..($lines.Count - 1)]) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            $output.Add($line)
            continue
        }

        # Split on commas -- simple split (values are not expected to contain commas)
        $fields = $line -split ','

        # Column C = index 2
        $colCValue = if ($fields.Count -gt 2) { $fields[2].Trim().Trim('"') } else { "" }

        $extra = foreach ($col in $colsToAdd) {
            switch ($col) {
                "github_org"           { "" }           # blank -- user fills in later
                "github_repo"          { $colCValue }   # copy from column C
                "gh_repo_visibility"   { "private" }
            }
        }

        $newLine = $line.TrimEnd(',') + ',' + ($extra -join ',')
        $output.Add($newLine)
    }

    [System.IO.File]::WriteAllLines($tmpFile, $output, [System.Text.Encoding]::UTF8)
    Move-Item -Path $tmpFile -Destination $CsvFile -Force

    Write-Host "Done -- columns added: $($colsToAdd -join ', ')" -ForegroundColor Green

} catch {
    if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force }
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
