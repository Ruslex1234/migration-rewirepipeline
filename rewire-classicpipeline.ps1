<#
.SYNOPSIS
Rewires a classic Azure DevOps pipeline to point to a GitHub repository.
Mirrors gh ado2gh rewire-pipeline behavior for classic (process type 1) pipelines.

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

# By pipeline name (like ado2gh):
.\Rewire-ClassicPipeline.ps1 `
  -AdoOrg my-ado-org `
  -AdoProject MyProject `
  -AdoPipelineName "my-classic-pipeline" `
  -GitHubOrg my-github-org `
  -GitHubRepo my-repo `
  -ServiceConnectionId 8846673b-b6bc-4f7c-aeeb-6d7447b2334d

# By pipeline ID (direct, same as ado2gh --ado-pipeline-id):
.\Rewire-ClassicPipeline.ps1 `
  -AdoOrg my-ado-org `
  -AdoProject MyProject `
  -AdoPipelineId 42 `
  -GitHubOrg my-github-org `
  -GitHubRepo my-repo `
  -ServiceConnectionId 8846673b-b6bc-4f7c-aeeb-6d7447b2334d
#>

param (
    [Parameter(Mandatory)]
    [string]$AdoOrg,

    [Parameter(Mandatory)]
    [string]$AdoProject,

    # Accept name OR id, just like ado2gh
    [Parameter(Mandatory, ParameterSetName = "ByName")]
    [string]$AdoPipelineName,

    [Parameter(Mandatory, ParameterSetName = "ById")]
    [int]$AdoPipelineId,

    [Parameter(Mandatory)]
    [string]$GitHubOrg,

    [Parameter(Mandatory)]
    [string]$GitHubRepo,

    [Parameter(Mandatory)]
    [string]$ServiceConnectionId,

    [string]$DefaultBranch = "main"
)

# ── Auth ────────────────────────────────────────────────────────────────────
if (-not $env:ADO_PAT) {
    Write-Error "ADO_PAT environment variable is not set"
    exit 1
}

$headers = @{
    Authorization = "Basic " + [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes(":$($env:ADO_PAT)")
    )
}

$apiBase = "https://dev.azure.com/$AdoOrg/$AdoProject/_apis"

# ── Resolve pipeline name to ID (mirrors ado2gh get-pipeline-id) ────────────
if ($PSCmdlet.ParameterSetName -eq "ByName") {
    Write-Host "Resolving pipeline name '$AdoPipelineName' to ID..."
    $listUrl = "$apiBase/build/definitions?api-version=7.1&name=$([Uri]::EscapeDataString($AdoPipelineName))"
    try {
        $list = Invoke-RestMethod -Method GET -Uri $listUrl -Headers $headers
    }
    catch {
        Write-Error "Failed to query pipeline list"
        throw
    }

    if ($list.count -eq 0) {
        Write-Error "No pipeline found with name: '$AdoPipelineName'"
        exit 1
    }
    if ($list.count -gt 1) {
        Write-Warning "Multiple pipelines matched '$AdoPipelineName':"
        $list.value | ForEach-Object { Write-Warning "  ID: $($_.id)  Name: $($_.name)" }
        Write-Error "Provide a more specific name or use -AdoPipelineId instead"
        exit 1
    }

    $AdoPipelineId = $list.value[0].id
    Write-Host "  Resolved '$AdoPipelineName' to pipeline ID: $AdoPipelineId"
}

# ── Fetch full pipeline definition ──────────────────────────────────────────
$defUrl = "$apiBase/build/definitions/$($AdoPipelineId)?api-version=6.0"

Write-Host "Fetching pipeline definition (ID: $AdoPipelineId)..."

try {
    $definition = Invoke-RestMethod -Method GET -Uri $defUrl -Headers $headers
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

# ── Validate it's a classic pipeline ────────────────────────────────────────
$currentRepo  = $definition.repository.name
$currentType  = $definition.repository.type
$processType  = $definition.process.type
$pipelineName = $definition.name

Write-Host ""
Write-Host "Pipeline:     $pipelineName (ID: $AdoPipelineId)"
Write-Host "Current repo: $currentRepo (type: $currentType)"
Write-Host "Process type: $processType $(if ($processType -eq 1) { '(classic)' } else { '(YAML - consider gh ado2gh rewire-pipeline instead)' })"

if ($processType -ne 1) {
    Write-Warning "This is a YAML pipeline. Use 'gh ado2gh rewire-pipeline' for YAML."
    $confirm = Read-Host "Continue anyway? (y/N)"
    if ($confirm -notin @("y", "Y")) {
        Write-Host "Aborted."
        exit 0
    }
}

# ── Rewire repository ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Rewiring to: $GitHubOrg/$GitHubRepo (GitHub)..."

$definition.repository = @{
    properties = @{
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

try {
    $result = Invoke-RestMethod `
        -Method PUT `
        -Uri $defUrl `
        -Headers $headers `
        -ContentType "application/json" `
        -Body $jsonBody
}
catch {
    Write-Error "Pipeline update failed"
    throw
}

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Successfully rewired pipeline!"
Write-Host "  Pipeline:   $($result.name) (ID: $AdoPipelineId)"
Write-Host "  Revision:   $($result.revision)"
Write-Host "  Repository: $($result.repository.name) (type: $($result.repository.type))"
Write-Host "  Branch:     $($result.repository.defaultBranch)"
