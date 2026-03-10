# Rewire Classic Azure DevOps Pipeline

Scripts that rewire a **classic** Azure DevOps pipeline to point to a GitHub repository. They update only the repository section of the pipeline definition, avoiding the `settingsSourceType=2` issue caused by `gh ado2gh rewire-pipeline` on classic pipelines.

| Script | Platform |
|---|---|
| `rewire-classicpipeline.ps1` | Windows / macOS / Linux (PowerShell) |
| `rewire-classicpipeline.sh` | Linux / macOS (Bash) |

---

## Prerequisites

### PowerShell script
- PowerShell 5.1+ or PowerShell 7+
- An Azure DevOps Personal Access Token (PAT) with **Build (Read & Execute)** permissions
- An existing GitHub service connection configured in your Azure DevOps project

### Shell script
- bash 4+
- `curl`
- `jq`
- `python3` (used for URL encoding the pipeline name)
- An Azure DevOps Personal Access Token (PAT) with **Build (Read & Execute)** permissions
- An existing GitHub service connection configured in your Azure DevOps project

---

## Setup

Set your Azure DevOps PAT as an environment variable before running the script.

**Linux / macOS (Bash):**
```bash
export ADO_PAT="your-ado-pat"
```

**PowerShell (Windows / macOS / Linux):**
```powershell
$env:ADO_PAT = "your-ado-pat"
```

---

## Usage

You can identify the pipeline by **name** or by **ID** — use whichever is more convenient.

### Linux / macOS — Shell script

Make the script executable (first time only):
```bash
chmod +x rewire-classicpipeline.sh
```

**By pipeline name:**
```bash
export ADO_PAT="your-ado-pat"

./rewire-classicpipeline.sh \
  --ado-org               my-ado-org \
  --ado-project           MyProject \
  --pipeline-name         "my-classic-pipeline" \
  --github-org            my-github-org \
  --github-repo           my-repo \
  --service-connection-id 8846673b-b6bc-4f7c-aeeb-6d7447b2334d
```

**By pipeline ID:**
```bash
export ADO_PAT="your-ado-pat"

./rewire-classicpipeline.sh \
  --ado-org               my-ado-org \
  --ado-project           MyProject \
  --pipeline-id           42 \
  --github-org            my-github-org \
  --github-repo           my-repo \
  --service-connection-id 8846673b-b6bc-4f7c-aeeb-6d7447b2334d \
  --default-branch        main
```

#### Shell script flags

| Flag | Required | Description |
|---|---|---|
| `--ado-org` | Yes | Azure DevOps organization name |
| `--ado-project` | Yes | Azure DevOps project name |
| `--pipeline-name` | Yes* | Name of the pipeline to rewire |
| `--pipeline-id` | Yes* | Numeric ID of the pipeline to rewire |
| `--github-org` | Yes | GitHub organization or user that owns the target repo |
| `--github-repo` | Yes | Name of the GitHub repository |
| `--service-connection-id` | Yes | GUID of the GitHub service connection in Azure DevOps |
| `--default-branch` | No | Default branch (default: `main`) |

\* Provide either `--pipeline-name` **or** `--pipeline-id`, not both.

---

### Windows / macOS / Linux — PowerShell script

**By pipeline name:**
```powershell
$env:ADO_PAT = "your-ado-pat"

.\rewire-classicpipeline.ps1 `
  -AdoOrg              my-ado-org `
  -AdoProject          MyProject `
  -AdoPipelineName     "my-classic-pipeline" `
  -GitHubOrg           my-github-org `
  -GitHubRepo          my-repo `
  -ServiceConnectionId 8846673b-b6bc-4f7c-aeeb-6d7447b2334d
```

**By pipeline ID:**
```powershell
$env:ADO_PAT = "your-ado-pat"

.\rewire-classicpipeline.ps1 `
  -AdoOrg              my-ado-org `
  -AdoProject          MyProject `
  -AdoPipelineId       42 `
  -GitHubOrg           my-github-org `
  -GitHubRepo          my-repo `
  -ServiceConnectionId 8846673b-b6bc-4f7c-aeeb-6d7447b2334d `
  -DefaultBranch       main
```

#### PowerShell parameters

| Parameter | Required | Description |
|---|---|---|
| `-AdoOrg` | Yes | Azure DevOps organization name |
| `-AdoProject` | Yes | Azure DevOps project name |
| `-AdoPipelineName` | Yes* | Name of the pipeline to rewire |
| `-AdoPipelineId` | Yes* | Numeric ID of the pipeline to rewire |
| `-GitHubOrg` | Yes | GitHub organization or user that owns the target repo |
| `-GitHubRepo` | Yes | Name of the GitHub repository |
| `-ServiceConnectionId` | Yes | GUID of the GitHub service connection in Azure DevOps |
| `-DefaultBranch` | No | Default branch (default: `main`) |

\* Provide either `-AdoPipelineName` **or** `-AdoPipelineId`, not both.

---

## Notes

- Both scripts target **classic pipelines** (process type `1`). If a YAML pipeline is detected (process type `2`), you will be prompted to confirm before continuing. For YAML pipelines, consider using `gh ado2gh rewire-pipeline` instead.
- When resolving by name, the name must match exactly one pipeline. If multiple pipelines match, both scripts will list them and ask you to use the ID flag instead.
- The scripts use the Azure DevOps REST API (`api-version=6.0` for definitions, `api-version=7.1` for name lookup) and authenticate with Basic auth via your PAT.
