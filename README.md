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

```powershell
.\rewire-classicpipeline.ps1 `
  -AdoOrg      <ado-org-name> `
  -AdoProject  <ado-project-name> `
  -PipelineId  <pipeline-id> `
  -GitHubOrg   <github-org-name> `
  -GitHubRepo  <github-repo-name> `
  -ServiceConnectionId <service-connection-guid> `
  [-DefaultBranch <branch-name>]
```

### Parameters

| Parameter | Required | Description |
|---|---|---|
| `-AdoOrg` | Yes | Your Azure DevOps organization name (e.g. `my-ado-org`) |
| `-AdoProject` | Yes | Your Azure DevOps project name (e.g. `MyProject`) |
| `-PipelineId` | Yes | The numeric ID of the pipeline to rewire (e.g. `130`) |
| `-GitHubOrg` | Yes | The GitHub organization or user that owns the target repo |
| `-GitHubRepo` | Yes | The name of the GitHub repository to point the pipeline at |
| `-ServiceConnectionId` | Yes | The GUID of the GitHub service connection in Azure DevOps |
| `-DefaultBranch` | No | Default branch for the pipeline (default: `main`) |

## Example

```powershell
$env:ADO_PAT = "your-ado-pat"

.\rewire-classicpipeline.ps1 `
  -AdoOrg              my-ado-org `
  -AdoProject          MyProject `
  -PipelineId          130 `
  -GitHubOrg           my-github-org `
  -GitHubRepo          my-repo `
  -ServiceConnectionId 8846673b-b6bc-4f7c-aeeb-6d7447b2334d `
  -DefaultBranch       main
```

## Notes

- This script targets **classic pipelines** (process type `1`). If a YAML pipeline is detected (process type `2`), you will be prompted to confirm before continuing. For YAML pipelines, consider using `gh ado2gh rewire-pipeline` instead.
- The script uses the Azure DevOps REST API (`api-version=6.0`) and authenticates with Basic auth via your PAT.
