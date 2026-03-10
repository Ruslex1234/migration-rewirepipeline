<#
.SYNOPSIS
Rewires a classic Azure DevOps pipeline to point to a GitHub repository.

.DESCRIPTION
Updates ONLY the repository section of a classic (process type 1) pipeline
definition. This avoids the `settingsSourceType=2` issue caused by
`gh ado2gh rewire-pipeline` on classic pipelines.

.PREREQUISITES
- PowerShell 5.1+ or PowerShell 7+
- Azure DevOps PAT with Build (Read & Execute)
- Existing GitHub service connection in Azure DevOps

.USAGE
$env:ADO_PAT = "your-ado-pat"

.\Rewire-ClassicPipeline.ps1 `
  -AdoOrg my-ado-org `
  -AdoProject MyProject `
  -PipelineId 130 `
  -GitHubOrg my-github-org `
  -GitHubRepo my-repo `
  -ServiceConnectionId 8846673b-b6bc-4f7c-aeeb-6d7447b2334d `
  [-DefaultBranch main]
#>

param (
    [Parameter(Mandatory)]
    [string]$AdoOrg,

    [Parameter(Mandatory)]
    [string]$AdoProject,

    [Parameter(Mandatory)]
    [int]$PipelineId,

    [Parameter(Mandatory)]
    [string]$GitHubOrg,

    [Parameter(Mandatory)]
    [string]$GitHubRepo,

    [Parameter(Mandatory)]
    [string]$ServiceConnectionId,

    [string]$DefaultBranch = "main"
)

if (-not $env:ADO_PAT) {
    Write-Error "ADO_PAT environment variable is not set"
    exit 1
}

$baseUrl = "https://dev.azure.com/$AdoOrg/$AdoProject/_apis/build/definitions/$($PipelineId)?api-version=6.0"

$headers = @{
    Authorization = "Basic " + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes(":$($env:ADO_PAT)")
    )
}

Write-Host "Fetching pipeline definition (ID: $PipelineId)..."

try {
    $definition = Invoke-RestMethod -Method GET -Uri $baseUrl -Headers $headers
}
catch {
    Write-Error "Failed to fetch pipeline definition"
    throw
}

if (-not $definition.repository.type) {
    Write-Error "Invalid pipeline definition returned"
    $definition | ConvertTo-Json -Depth 20
    exit 1
}

$currentRepo = $definition.repository.name
$currentType = $definition.repository.type
$processType = $definition.process.type

Write-Host "  Current repository: $currentRepo (type: $currentType)"
Write-Host "  Process type: $processType"

if ($processType -ne 1) {
    Write-Warning "Process type is $processType (not classic)"
    Write-Warning "Consider using 'gh ado2gh rewire-pipeline' for YAML pipelines"
    $confirm = Read-Host "Continue anyway? (y/N)"
    if ($confirm -notin @("y", "Y")) {
        Write-Host "Aborted."
        exit 0
    }
}

Write-Host "Updating repository to: $GitHubOrg/$GitHubRepo (GitHub)..."

$definition.repository = @{
    properties = @{
        apiUrl            = "https://api.github.com/repos/$GitHubOrg/$GitHubRepo"
        branchesUrl       = "https://api.github.com/repos/$GitHubOrg/$GitHubRepo/branches"
        cloneUrl          = "https://github.com/$GitHubOrg/$GitHubRepo.git"
        connectedServiceId = $ServiceConnectionId
        defaultBranch     = $DefaultBranch
        fullName          = "$GitHubOrg/$GitHubRepo"
        manageUrl         = "https://github.com/$GitHubOrg/$GitHubRepo"
        orgName           = $GitHubOrg
        refsUrl           = "https://api.github.com/repos/$GitHubOrg/$GitHubRepo/git/refs"
        safeRepository    = "$GitHubOrg/$GitHubRepo"
        shortName         = $GitHubRepo
        reportBuildStatus = "true"
    }
    id                  = "$GitHubOrg/$GitHubRepo"
    type                = "GitHub"
    name                = "$GitHubOrg/$GitHubRepo"
    url                 = "https://github.com/$GitHubOrg/$GitHubRepo.git"
    defaultBranch       = $DefaultBranch
    clean               = "false"
    checkoutSubmodules  = "false"
}

$jsonBody = $definition | ConvertTo-Json -Depth 20

try {
    $result = Invoke-RestMethod `
        -Method PUT `
        -Uri $baseUrl `
        -Headers $headers `
        -ContentType "application/json" `
        -Body $jsonBody
}
catch {
    Write-Error "Pipeline update failed"
    throw
}

Write-Host ""
Write-Host "Successfully rewired pipeline!"
Write-Host "  Pipeline: $($result.name) (ID: $PipelineId)"
Write-Host "  Revision: $($result.revision)"
Write-Host "  Repository: $($result.repository.name) (type: $($result.repository.type))"
