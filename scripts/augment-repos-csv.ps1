<#
.SYNOPSIS
    Augments repos.csv with three new columns: github_org, github_repo,
    gh_repo_visibility.

.DESCRIPTION
    Reads an existing repos.csv file and appends three columns to every
    data row:
      github_org          - set via -GitHubOrg, or left blank
      github_repo         - column C value with optional prefix/suffix applied
      gh_repo_visibility  - "private" by default; override with -Visibility

    The original file is overwritten with the augmented version.
    If the three columns already exist in the header they are not added
    again, preventing duplicates on repeated runs.

.PARAMETER CsvFile
    Path to repos.csv. Defaults to repos.csv in the same directory as
    this script.

.PARAMETER Visibility
    Value written to gh_repo_visibility for every row.
    Must be one of: private, public, internal (all lowercase).
    Use "off" to leave the field blank.
    Default: private

.PARAMETER GitHubOrg
    Value written to github_org for every row.
    Default: blank (fill in later).

.PARAMETER GitHubRepoPrefix
    Text prepended to the column C value when building github_repo.

.PARAMETER GitHubRepoSuffix
    Text appended to the column C value when building github_repo.

.EXAMPLE
    .\augment-repos-csv.ps1

.EXAMPLE
    .\augment-repos-csv.ps1 -CsvFile C:\migration\repos.csv -Visibility public

.EXAMPLE
    .\augment-repos-csv.ps1 -Visibility off

.EXAMPLE
    .\augment-repos-csv.ps1 -GitHubOrg my-gh-org -GitHubRepoPrefix migrated- -GitHubRepoSuffix -prod
#>

[CmdletBinding()]
param (
    [string]$CsvFile          = "",
    [string]$Visibility       = "private",
    [string]$GitHubOrg        = "",
    [string]$GitHubRepoPrefix = "",
    [string]$GitHubRepoSuffix = ""
)

# ── Resolve default path ───────────────────────────────────────────────────────
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $CsvFile) {
    $CsvFile = Join-Path $ScriptDir "repos.csv"
}

# ── Validate -Visibility ───────────────────────────────────────────────────────
$validValues = @("private", "public", "internal", "off")

if ($Visibility -notin $validValues) {
    # Check if it is a casing issue
    $lower = $Visibility.ToLower()
    if ($lower -in $validValues) {
        Write-Host "ERROR: -Visibility value '$Visibility' must be all lowercase. Did you mean '$lower'?" -ForegroundColor Red
    } else {
        Write-Host "ERROR: -Visibility '$Visibility' is not valid. Allowed values: private, public, internal, off" -ForegroundColor Red
    }
    exit 1
}

# ── Validate input file ────────────────────────────────────────────────────────
if (-not (Test-Path $CsvFile)) {
    Write-Host "ERROR: CSV file not found: $CsvFile" -ForegroundColor Red
    Write-Host "   Place repos.csv in the scripts/ folder or use -CsvFile <path>" -ForegroundColor Yellow
    exit 1
}

$lines = [System.IO.File]::ReadAllLines($CsvFile, [System.Text.Encoding]::UTF8)

if ($lines.Count -le 1) {
    Write-Host "WARNING: No data rows found in: $CsvFile (file is empty or header-only)" -ForegroundColor Yellow
    exit 0
}

$rowCount = $lines.Count - 1
Write-Host "Input      : $CsvFile ($rowCount data row(s))"
Write-Host "github_org : $(if ($GitHubOrg) { $GitHubOrg } else { '(blank -- fill in later)' })"
Write-Host "repo prefix: $(if ($GitHubRepoPrefix) { $GitHubRepoPrefix } else { '(none)' })"
Write-Host "repo suffix: $(if ($GitHubRepoSuffix) { $GitHubRepoSuffix } else { '(none)' })"
Write-Host "visibility : $Visibility"

# ── Parse header ───────────────────────────────────────────────────────────────
$header    = $lines[0] -split ',' | ForEach-Object { $_.Trim().Trim('"') }
$newCols   = @("github_org", "github_repo", "gh_repo_visibility")
$colsToAdd = $newCols | Where-Object { $_ -notin $header }

if ($colsToAdd.Count -eq 0) {
    Write-Host "INFO: All three columns already present -- no changes made." -ForegroundColor Cyan
    exit 0
}

# ── Build augmented CSV ────────────────────────────────────────────────────────
$tmpFile = $CsvFile + ".tmp"

try {
    $output = [System.Collections.Generic.List[string]]::new()

    $newHeaderLine = $lines[0].TrimEnd(',') + ',' + ($colsToAdd -join ',')
    $output.Add($newHeaderLine)

    foreach ($line in $lines[1..($lines.Count - 1)]) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            $output.Add($line)
            continue
        }

        $fields    = $line -split ','
        $colCValue = if ($fields.Count -gt 2) { $fields[2].Trim().Trim('"') } else { "" }
        $repoValue = "$GitHubRepoPrefix$colCValue$GitHubRepoSuffix"
        $visValue  = if ($Visibility -eq "off") { "" } else { $Visibility }

        $extra = foreach ($col in $colsToAdd) {
            switch ($col) {
                "github_org"          { $GitHubOrg  }
                "github_repo"         { $repoValue  }
                "gh_repo_visibility"  { $visValue   }
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
