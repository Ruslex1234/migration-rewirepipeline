# Rewire Classic Azure DevOps Pipeline

A PowerShell script that rewires a **classic** Azure DevOps pipeline to point to a GitHub repository. It updates only the repository section of the pipeline definition, avoiding the `settingsSourceType=2` issue caused by `gh ado2gh rewire-pipeline` on classic pipelines.

## Prerequisites

- PowerShell 5.1+ or PowerShell 7+
- An Azure DevOps Personal Access Token (PAT) with **Build (Read & Execute)** permissions
- An existing GitHub service connection configured in your Azure DevOps project

## Setup

Set your Azure DevOps PAT as an environment variable before running the script.

**PowerShell (Windows / Linux / macOS):**
```powershell
$env:ADO_PAT = "your-ado-pat"
```

**Bash / Zsh (Linux / macOS):**
```bash
export ADO_PAT="your-ado-pat"
```

## Usage

You can identify the pipeline by **name** or by **ID** — use whichever is more convenient.

### By pipeline name

```powershell
.\rewire-classicpipeline.ps1 `
  -AdoOrg              <ado-org-name> `
  -AdoProject          <ado-project-name> `
  -AdoPipelineName     "<pipeline-name>" `
  -GitHubOrg           <github-org-name> `
  -GitHubRepo          <github-repo-name> `
  -ServiceConnectionId <service-connection-guid> `
  [-DefaultBranch      <branch-name>]
```

### By pipeline ID

```powershell
.\rewire-classicpipeline.ps1 `
  -AdoOrg              <ado-org-name> `
  -AdoProject          <ado-project-name> `
  -AdoPipelineId       <pipeline-id> `
  -GitHubOrg           <github-org-name> `
  -GitHubRepo          <github-repo-name> `
  -ServiceConnectionId <service-connection-guid> `
  [-DefaultBranch      <branch-name>]
```

### Parameters

| Parameter | Required | Description |
|---|---|---|
| `-AdoOrg` | Yes | Your Azure DevOps organization name (e.g. `my-ado-org`) |
| `-AdoProject` | Yes | Your Azure DevOps project name (e.g. `MyProject`) |
| `-AdoPipelineName` | Yes* | Name of the pipeline to rewire. Mutually exclusive with `-AdoPipelineId` |
| `-AdoPipelineId` | Yes* | Numeric ID of the pipeline to rewire. Mutually exclusive with `-AdoPipelineName` |
| `-GitHubOrg` | Yes | The GitHub organization or user that owns the target repo |
| `-GitHubRepo` | Yes | The name of the GitHub repository to point the pipeline at |
| `-ServiceConnectionId` | Yes | The GUID of the GitHub service connection in Azure DevOps |
| `-DefaultBranch` | No | Default branch for the pipeline (default: `main`) |

\* Provide either `-AdoPipelineName` **or** `-AdoPipelineId`, not both.

## Examples

```powershell
$env:ADO_PAT = "your-ado-pat"

# Using pipeline name
.\rewire-classicpipeline.ps1 `
  -AdoOrg              my-ado-org `
  -AdoProject          MyProject `
  -AdoPipelineName     "my-classic-pipeline" `
  -GitHubOrg           my-github-org `
  -GitHubRepo          my-repo `
  -ServiceConnectionId 8846673b-b6bc-4f7c-aeeb-6d7447b2334d

# Using pipeline ID
.\rewire-classicpipeline.ps1 `
  -AdoOrg              my-ado-org `
  -AdoProject          MyProject `
  -AdoPipelineId       42 `
  -GitHubOrg           my-github-org `
  -GitHubRepo          my-repo `
  -ServiceConnectionId 8846673b-b6bc-4f7c-aeeb-6d7447b2334d `
  -DefaultBranch       main
```

## Notes

- This script targets **classic pipelines** (process type `1`). If a YAML pipeline is detected (process type `2`), you will be prompted to confirm before continuing. For YAML pipelines, consider using `gh ado2gh rewire-pipeline` instead.
- When using `-AdoPipelineName`, the name must match exactly one pipeline. If multiple pipelines match, the script will list them and ask you to use `-AdoPipelineId` instead.
- The script uses the Azure DevOps REST API (`api-version=6.0` for definitions, `api-version=7.1` for name lookup) and authenticates with Basic auth via your PAT.
