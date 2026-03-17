# Rewire Classic Azure DevOps Pipeline

Scripts that rewire a **classic** Azure DevOps pipeline to point to a GitHub repository. They update only the repository section of the pipeline definition, avoiding the `settingsSourceType=2` issue caused by `gh ado2gh rewire-pipeline` on classic pipelines.

Two modes are available:

| Mode | Use when |
|---|---|
| **Single pipeline** (root scripts) | Rewiring one pipeline at a time |
| **Batch / CSV mode** (`batch/` folder) | Rewiring many pipelines at scale from a CSV file |

### Single-pipeline scripts

| Script | Platform |
|---|---|
| `rewire-classicpipeline.ps1` | Windows / macOS / Linux (PowerShell) |
| `rewire-classicpipeline.sh` | Linux / macOS (Bash) |

### Batch scripts

| Script | Platform |
|---|---|
| `batch/rewire-classicpipeline-batch.ps1` | Windows / macOS / Linux (PowerShell) |
| `batch/rewire-classicpipeline-batch.sh` | Linux / macOS (Bash) |

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
- **No `GH_PAT` required.** Classic pipeline rewiring calls only Azure DevOps REST APIs. GitHub authentication is handled by the service connection already configured in Azure DevOps — no GitHub PAT is needed.

---

## Batch / CSV Mode

Use the scripts in the `batch/` folder to rewire many classic pipelines at once from a CSV file. This is the recommended approach for large migrations and integrates with the `repos_with_status.csv` artifact produced by the migration pipeline.

### CSV file: `classic_pipeline.csv`

Place this file in the `batch/` folder (or pass its path with `--csv` / `-CsvFile`).

The column layout mirrors the `pipelines.csv` format generated by `gh ado2gh generate-script --generate-archive-data` (ado2gh inventory), with two additional optional columns.

| Column | Required | Description |
|---|---|---|
| `org` | Yes | Azure DevOps organization name |
| `teamproject` | Yes | Azure DevOps project name |
| `repo` | Yes | Azure DevOps repository name — cross-referenced with `repos_with_status.csv` |
| `pipeline` | Yes | Pipeline name (exact match). Used for name-to-ID lookup when `pipeline_id` is empty |
| `pipeline_id` | No | Numeric pipeline ID. When provided, skips the name lookup (faster and unambiguous) |
| `url` | No | Pipeline URL — informational only, populated automatically by `ado2gh generate-script` |
| `serviceConnection` | Yes | GUID of the GitHub service connection in Azure DevOps |
| `github_org` | Yes | Target GitHub organization |
| `github_repo` | Yes | Target GitHub repository name |
| `default_branch` | No | Default branch to set (defaults to `main`) |

> **Tip:** Start from the `pipelines.csv` generated by `ado2gh generate-script --generate-archive-data`. It already contains `org`, `teamproject`, `repo`, `pipeline`, and `url`. Add the `serviceConnection`, `github_org`, `github_repo`, and optionally `pipeline_id` / `default_branch` columns.

**Example `classic_pipeline.csv`:**

```csv
org,teamproject,repo,pipeline,pipeline_id,url,serviceConnection,github_org,github_repo,default_branch
myorg,Platform,api-service,api-service-build,,https://dev.azure.com/myorg/Platform/_build?definitionId=101,3dfa8dac-601c-4b68-a4eb-29737c5ebf04,mycompany-gh,api-service,main
myorg,Platform,web-frontend,,202,https://dev.azure.com/myorg/Platform/_build?definitionId=202,3dfa8dac-601c-4b68-a4eb-29737c5ebf04,mycompany-gh,web-frontend,main
myorg,Platform,data-pipeline,nightly-etl,,https://dev.azure.com/myorg/Platform/_build?definitionId=303,3dfa8dac-601c-4b68-a4eb-29737c5ebf04,mycompany-gh,data-pipeline,develop
```

> Row 1 uses **pipeline name** (`api-service-build`) — the script looks up the ID automatically.
> Row 2 uses **pipeline ID** (`202`) directly — name lookup is skipped.

---

### Using the batch scripts

#### Linux / macOS — Bash

```bash
chmod +x batch/rewire-classicpipeline-batch.sh
export ADO_PAT="your-ado-pat"

# Default: reads batch/classic_pipeline.csv
./batch/rewire-classicpipeline-batch.sh

# Custom CSV path
./batch/rewire-classicpipeline-batch.sh --csv /path/to/classic_pipeline.csv

# With migration status filter (only rewire successfully migrated repos)
./batch/rewire-classicpipeline-batch.sh --repos-status /path/to/repos_with_status.csv
```

#### Windows / macOS / Linux — PowerShell

```powershell
$env:ADO_PAT = "your-ado-pat"

# Default: reads batch/classic_pipeline.csv
.\batch\rewire-classicpipeline-batch.ps1

# Custom CSV path
.\batch\rewire-classicpipeline-batch.ps1 -CsvFile C:\migration\classic_pipeline.csv

# With migration status filter
.\batch\rewire-classicpipeline-batch.ps1 `
    -CsvFile         C:\migration\classic_pipeline.csv `
    -ReposStatusFile C:\migration\repos_with_status.csv
```

#### Batch script flags / parameters

| Bash flag | PowerShell parameter | Required | Description |
|---|---|---|---|
| `--csv` | `-CsvFile` | No | Path to `classic_pipeline.csv`. Defaults to `batch/classic_pipeline.csv` |
| `--repos-status` | `-ReposStatusFile` | No | Path to `repos_with_status.csv` to filter by successful migrations |

---

### Integration with the migration pipeline (repos_with_status.csv)

When running as part of the full ADO → GitHub migration pipeline, place `repos_with_status.csv` (published by Stage 3) alongside the batch scripts or pass its path explicitly. The batch scripts will then:

- **Process** only pipelines whose `repo` column appears in `repos_with_status.csv` with status `Success`
- **Skip** pipelines for repos that failed migration, logging each skip with a reason
- Exit with `SucceededWithIssues` (ADO pipeline-compatible) when any rows are skipped or failed, so downstream stages continue

If `repos_with_status.csv` is **not present**, all rows in `classic_pipeline.csv` are processed regardless of migration status.

---

### What the batch scripts do for each row

1. Check whether the repo migrated successfully (if `repos_with_status.csv` is available)
2. Resolve the pipeline name to a numeric ID (skipped when `pipeline_id` is provided)
3. Fetch the full pipeline definition from Azure DevOps
4. Validate it is a classic pipeline (process type `1`) — YAML pipelines are skipped with a warning
5. Patch the repository section to point to the GitHub repository and service connection
6. PUT the updated definition back to Azure DevOps
7. Record the result (success / skipped / failed) and write a timestamped log file
