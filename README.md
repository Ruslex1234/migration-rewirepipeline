# Rewire Classic Azure DevOps Pipeline

Scripts that rewire a **classic** Azure DevOps pipeline to point to a GitHub repository. They update only the repository section of the pipeline definition, avoiding the `settingsSourceType=2` issue caused by `gh ado2gh rewire-pipeline` on classic pipelines.

---

## Table of Contents

- [Overview](#rewire-classic-azure-devops-pipeline)
- [Prerequisites](#prerequisites)
- [Setup](#setup)
- [Usage — Single Pipeline](#usage)
  - [Shell script flags](#shell-script-flags)
  - [PowerShell parameters](#powershell-parameters)
- [Notes](#notes)
- [Manually Creating CSV Files](#manually-creating-csv-files)
  - [Manually creating pipelines.csv](#manually-creating-pipelinescsv-split-utility-input)
  - [Manually creating classic\_pipeline.csv](#manually-creating-classic_pipelinecsv-batch-rewire-input)
    - [How to find the pipeline name and ID](#how-to-find-the-pipeline-name-and-id)
    - [How to find the service connection GUID](#how-to-find-the-service-connection-guid)
- [Batch / CSV Mode](#batch--csv-mode)
  - [CSV file: classic\_pipeline.csv](#csv-file-classic_pipelinecsv)
  - [Using the batch scripts](#using-the-batch-scripts)
  - [Integration with repos\_with\_status.csv](#integration-with-the-migration-pipeline-repos_with_statuscsv)
  - [What the batch scripts do for each row](#what-the-batch-scripts-do-for-each-row)
- [Split Utility: Classify pipelines.csv by Type](#split-utility-classify-pipelinescsv-by-type)
  - [How it works](#how-it-works)
  - [Usage](#usage-1)
  - [Output files](#output-files)
  - [Recommended workflow](#recommended-workflow)
  - [After splitting: augment classic\_pipeline.csv](#after-splitting-augment-classic_pipelinecsv)
- [Utility Scripts](#utility-scripts)
  - [Augment repos.csv](#augment-reposacsv)

---

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

### Utility scripts

| Script | Platform | Purpose |
|---|---|---|
| `scripts/augment-repos-csv.ps1` | Windows / macOS / Linux (PowerShell) | Add `github_org`, `github_repo`, `gh_repo_visibility` columns to `repos.csv` |
| `scripts/augment-repos-csv.sh` | Linux / macOS (Bash) | Add `github_org`, `github_repo`, `gh_repo_visibility` columns to `repos.csv` |

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

### Linux / macOS — Shell script

Make the script executable (first time only):
```bash
chmod +x rewire-classicpipeline.sh
```

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

#### Shell script flags

| Flag | Required | Description |
|---|---|---|
| `--ado-org` | Yes | Azure DevOps organization name |
| `--ado-project` | Yes | Azure DevOps project name |
| `--pipeline-name` | Yes | Name of the pipeline to rewire |
| `--github-org` | Yes | GitHub organization or user that owns the target repo |
| `--github-repo` | Yes | Name of the GitHub repository |
| `--service-connection-id` | Yes | GUID of the GitHub service connection in Azure DevOps |
| `--default-branch` | No | Default branch (default: `main`) |

---

### Windows / macOS / Linux — PowerShell script

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

#### PowerShell parameters

| Parameter | Required | Description |
|---|---|---|
| `-AdoOrg` | Yes | Azure DevOps organization name |
| `-AdoProject` | Yes | Azure DevOps project name |
| `-AdoPipelineName` | Yes | Name of the pipeline to rewire |
| `-GitHubOrg` | Yes | GitHub organization or user that owns the target repo |
| `-GitHubRepo` | Yes | Name of the GitHub repository |
| `-ServiceConnectionId` | Yes | GUID of the GitHub service connection in Azure DevOps |
| `-DefaultBranch` | No | Default branch (default: `main`) |

---

## Notes

- Both scripts target **classic pipelines** (process type `1`). If a YAML pipeline is detected (process type `2`), you will be prompted to confirm before continuing. For YAML pipelines, consider using `gh ado2gh rewire-pipeline` instead.
- When resolving by name, the name must match exactly one pipeline. If multiple pipelines match, both scripts will list them and ask you to use a more specific pipeline name.
- The scripts use the Azure DevOps REST API (`api-version=6.0` for definitions, `api-version=7.1` for name lookup) and authenticate with Basic auth via your PAT.
- **No `GH_PAT` required.** Classic pipeline rewiring calls only Azure DevOps REST APIs. GitHub authentication is handled by the service connection already configured in Azure DevOps — no GitHub PAT is needed.

---

## Manually Creating CSV Files

If `ado2gh generate-script --generate-archive-data` is unavailable or did not complete successfully, you can create the required CSV files by hand. This section covers how to fill in both files and how to locate each value in Azure DevOps.

---

### Manually creating `pipelines.csv` (split utility input)

The split utility (`split/split-pipelines.sh` or `split/split-pipelines.ps1`) reads `pipelines.csv` and routes each row to either `classic_pipelines.csv` (Classic) or a new `pipelines.csv` (YAML) based on the pipeline type detected via the API.

**Column layout:**

| Column | Required | How to find it |
|---|---|---|
| `org` | Yes | Your Azure DevOps organization name — the part after `dev.azure.com/` in any ADO URL |
| `teamproject` | Yes | The ADO project name — visible in the URL and the ADO project selector |
| `repo` | Yes | The ADO Git repository name the pipeline is currently attached to |
| `pipeline` | Yes* | The pipeline name as shown in ADO Pipelines. Required unless `url` contains a `definitionId` |
| `url` | Recommended | Pipeline URL from ADO. Must contain `?definitionId=NNN` — the split script extracts the ID from this field and skips the name lookup API call. Find it by opening the pipeline in ADO and copying the browser URL |

> **\* Name vs URL:** If the `url` column contains a valid `definitionId` query parameter (e.g., `https://dev.azure.com/myorg/MyProject/_build?definitionId=101`), the split script uses the ID directly and the `pipeline` name value is only used for informational labelling — it does not need to be exact. If `url` is empty or does not contain `definitionId`, the `pipeline` name must match exactly.

**Minimum example (name-only, no URL):**

```csv
org,teamproject,repo,pipeline
myorg,Platform,api-service,api-service-build
myorg,Platform,web-frontend,web-frontend-ci
```

**Recommended example (with URL for direct ID lookup):**

```csv
org,teamproject,repo,pipeline,url
myorg,Platform,api-service,api-service-build,https://dev.azure.com/myorg/Platform/_build?definitionId=101
myorg,Platform,web-frontend,web-frontend-ci,https://dev.azure.com/myorg/Platform/_build?definitionId=202
```

> **Tip — finding pipeline URLs in ADO:** In Azure DevOps, go to **Pipelines** → click a pipeline → copy the URL from the browser address bar. It will look like `https://dev.azure.com/myorg/MyProject/_build?definitionId=NNN`.

---

### Manually creating `classic_pipelines.csv` (batch rewire input)

The batch scripts (`batch/rewire-classicpipeline-batch.sh` and `.ps1`) read `classic_pipelines.csv` to rewire each classic pipeline to GitHub.

**Column layout:**

| Column | Required | How to find it |
|---|---|---|
| `org` | Yes | Your Azure DevOps organization name |
| `teamproject` | Yes | The ADO project name |
| `repo` | Yes | The ADO repository name the pipeline belongs to (used for `repos_with_status.csv` cross-reference) |
| `pipeline` | Yes* | The exact pipeline name. Can be left blank if `pipeline_id` is provided |
| `pipeline_id` | No* | The numeric pipeline definition ID. When provided, the name-to-ID lookup API call is skipped. Required if `pipeline` is left blank |
| `url` | No | Informational only. Ignored by the rewire scripts |
| `serviceConnection` | Yes | GUID of the GitHub service connection in Azure DevOps (see below) |
| `github_org` | Yes | The GitHub organization that owns the target repository |
| `github_repo` | Yes | The GitHub repository name to rewire the pipeline to |
| `default_branch` | No | Branch to set as default (defaults to `main` if omitted) |

> **\* pipeline vs pipeline_id:** At least one of these columns must be present in the CSV header. You can include both. If you include both, `pipeline_id` is used to skip the name lookup and `pipeline` is used for display only — the name does not need to be exact. If you omit the `pipeline` column entirely, the script will work fine as long as `pipeline_id` is present. If you omit `pipeline_id`, the script will perform a name lookup using `pipeline`. Each row must have a non-empty value in whichever column(s) you include — a row with both blank will be skipped with an error.

#### How to find the pipeline name and ID

1. In Azure DevOps, go to **Pipelines** (left sidebar)
2. The pipeline name is shown in the list — this is the exact value for the `pipeline` column
3. Click the pipeline — the URL contains `?definitionId=NNN` — that number is the `pipeline_id`

#### How to find the service connection GUID

1. In Azure DevOps, go to **Project Settings** (bottom-left) → **Service connections**
2. Click the GitHub service connection you want to use
3. The GUID is the last segment of the URL: `.../_settings/adminservices?resourceId=<GUID>`
4. Alternatively, open the service connection and copy the **Resource ID** shown on the page

> **Note:** The service connection must be of type **GitHub** and must already be authorized. The GUID placeholder `00000000-0000-0000-0000-000000000000` is rejected by the script.

**Example — by pipeline name only:**

```csv
org,teamproject,repo,pipeline,pipeline_id,url,serviceConnection,github_org,github_repo,default_branch
myorg,Platform,api-service,api-service-build,,https://dev.azure.com/myorg/Platform/_build?definitionId=101,3dfa8dac-601c-4b68-a4eb-29737c5ebf04,mycompany-gh,api-service,main
myorg,Platform,web-frontend,web-frontend-ci,,https://dev.azure.com/myorg/Platform/_build?definitionId=202,3dfa8dac-601c-4b68-a4eb-29737c5ebf04,mycompany-gh,web-frontend,main
```

**Example — by pipeline ID only (no name required):**

```csv
org,teamproject,repo,pipeline,pipeline_id,url,serviceConnection,github_org,github_repo,default_branch
myorg,Platform,api-service,,101,,3dfa8dac-601c-4b68-a4eb-29737c5ebf04,mycompany-gh,api-service,main
myorg,Platform,web-frontend,,202,,3dfa8dac-601c-4b68-a4eb-29737c5ebf04,mycompany-gh,web-frontend,main
```

**Example — mixed (name where known, ID where ambiguous):**

```csv
org,teamproject,repo,pipeline,pipeline_id,url,serviceConnection,github_org,github_repo,default_branch
myorg,Platform,api-service,api-service-build,,https://dev.azure.com/myorg/Platform/_build?definitionId=101,3dfa8dac-601c-4b68-a4eb-29737c5ebf04,mycompany-gh,api-service,main
myorg,Platform,web-frontend,build,202,https://dev.azure.com/myorg/Platform/_build?definitionId=202,3dfa8dac-601c-4b68-a4eb-29737c5ebf04,mycompany-gh,web-frontend,main
```

> **Tip:** When `pipeline_id` is provided, the script uses it directly and skips the name lookup — no API call is needed to resolve the ID. This is faster and avoids failures when two pipelines share the same name.

---

## Batch / CSV Mode

Use the scripts in the `batch/` folder to rewire many classic pipelines at once from a CSV file. This is the recommended approach for large migrations and integrates with the `repos_with_status.csv` artifact produced by the migration pipeline.

### CSV file: `classic_pipelines.csv`

Place this file in the `batch/` folder (or pass its path with `--csv` / `-CsvFile`).

The column layout mirrors the `pipelines.csv` format generated by `gh ado2gh generate-script --generate-archive-data` (ado2gh inventory), with two additional optional columns.

| Column | Required | Description |
|---|---|---|
| `org` | Yes | Azure DevOps organization name |
| `teamproject` | Yes | Azure DevOps project name |
| `repo` | Yes | Azure DevOps repository name — cross-referenced with `repos_with_status.csv` |
| `pipeline` | No* | Pipeline name (exact match). The entire column can be omitted if `pipeline_id` is present |
| `pipeline_id` | No* | Numeric pipeline definition ID. The entire column can be omitted if `pipeline` is present. When both are present, ID is used and name is display-only |
| `url` | No | Pipeline URL — informational only, populated automatically by `ado2gh generate-script` |
| `serviceConnection` | Yes | GUID of the GitHub service connection in Azure DevOps |
| `github_org` | Yes | Target GitHub organization |
| `github_repo` | Yes | Target GitHub repository name |
| `default_branch` | No | Default branch to set (defaults to `main`) |

> **Tip:** Start from the `pipelines.csv` generated by `ado2gh generate-script --generate-archive-data`. It already contains `org`, `teamproject`, `repo`, `pipeline`, and `url`. Add the `serviceConnection`, `github_org`, `github_repo`, and optionally `pipeline_id` and `default_branch` columns.

**Example `classic_pipelines.csv`:**

```csv
org,teamproject,repo,pipeline,pipeline_id,url,serviceConnection,github_org,github_repo,default_branch
myorg,Platform,api-service,api-service-build,,https://dev.azure.com/myorg/Platform/_build?definitionId=101,3dfa8dac-601c-4b68-a4eb-29737c5ebf04,mycompany-gh,api-service,main
myorg,Platform,web-frontend,web-frontend-ci,202,https://dev.azure.com/myorg/Platform/_build?definitionId=202,3dfa8dac-601c-4b68-a4eb-29737c5ebf04,mycompany-gh,web-frontend,main
myorg,Platform,data-pipeline,nightly-etl,,https://dev.azure.com/myorg/Platform/_build?definitionId=303,3dfa8dac-601c-4b68-a4eb-29737c5ebf04,mycompany-gh,data-pipeline,develop
```

---

### Using the batch scripts

#### Linux / macOS — Bash

```bash
chmod +x batch/rewire-classicpipeline-batch.sh
export ADO_PAT="your-ado-pat"

# Default: reads batch/classic_pipelines.csv
./batch/rewire-classicpipeline-batch.sh

# Custom CSV path
./batch/rewire-classicpipeline-batch.sh --csv /path/to/classic_pipelines.csv

# With migration status filter (only rewire successfully migrated repos)
./batch/rewire-classicpipeline-batch.sh --repos-status /path/to/repos_with_status.csv
```

#### Windows / macOS / Linux — PowerShell

```powershell
$env:ADO_PAT = "your-ado-pat"

# Default: reads batch/classic_pipelines.csv
.\batch\rewire-classicpipeline-batch.ps1

# Custom CSV path
.\batch\rewire-classicpipeline-batch.ps1 -CsvFile C:\migration\classic_pipelines.csv

# With migration status filter
.\batch\rewire-classicpipeline-batch.ps1 `
    -CsvFile         C:\migration\classic_pipelines.csv `
    -ReposStatusFile C:\migration\repos_with_status.csv
```

#### Batch script flags / parameters

| Bash flag | PowerShell parameter | Required | Description |
|---|---|---|---|
| `--csv` | `-CsvFile` | No | Path to `classic_pipelines.csv`. Defaults to `batch/classic_pipelines.csv` |
| `--repos-status` | `-ReposStatusFile` | No | Path to `repos_with_status.csv` to filter by successful migrations |

---

### Integration with the migration pipeline (repos_with_status.csv)

When running as part of the full ADO → GitHub migration pipeline, place `repos_with_status.csv` (published by Stage 3) alongside the batch scripts or pass its path explicitly. The batch scripts will then:

- **Process** only pipelines whose `repo` column appears in `repos_with_status.csv` with status `Success`
- **Skip** pipelines for repos that failed migration, logging each skip with a reason
- Exit with `SucceededWithIssues` (ADO pipeline-compatible) when any rows are skipped or failed, so downstream stages continue

If `repos_with_status.csv` is **not present**, all rows in `classic_pipelines.csv` are processed regardless of migration status.

---

### What the batch scripts do for each row

1. Check whether the repo migrated successfully (if `repos_with_status.csv` is available)
2. Resolve the pipeline name to a numeric ID via the Azure DevOps API
3. Fetch the full pipeline definition from Azure DevOps
4. Validate it is a classic pipeline (process type `1`) — YAML pipelines are skipped with a warning
5. Patch the repository section to point to the GitHub repository and service connection
6. PUT the updated definition back to Azure DevOps
7. Record the result (success / skipped / failed) and write a timestamped log file

---

## Split Utility: Classify pipelines.csv by Type

The `split/` folder contains a utility that takes the raw `pipelines.csv` generated by `ado2gh` and splits it into two files based on pipeline type — so you can hand each file to the appropriate rewiring tool.

| Script | Platform |
|---|---|
| `split/split-pipelines.sh` | Linux / macOS (Bash) |
| `split/split-pipelines.ps1` | Windows / macOS / Linux (PowerShell) |

### How it works

For each row in `pipelines.csv`, the script:

1. Extracts the definition ID from the `url` column (`?definitionId=NNN`) when available — skips an extra API round-trip
2. Falls back to a pipeline name lookup if no URL / definition ID is present
3. Calls `GET /build/definitions/{id}` and reads `process.type`:
   - `1` → **Classic** (Designer) pipeline
   - `2` → **YAML** pipeline
4. Routes the row to the appropriate output file

Both output files are written to the **same directory as the input file** and preserve all original columns.

> **Note:** Classic Release pipelines (under Pipelines → Releases) use a different API (`release/definitions`) and are **not** included in the ado2gh inventory CSV. Only build definitions are classified here.

### Usage

#### Linux / macOS — Bash

```bash
chmod +x split/split-pipelines.sh
export ADO_PAT="your-ado-pat"

# Default: reads split/pipelines.csv
./split/split-pipelines.sh

# Custom input file
./split/split-pipelines.sh --csv /path/to/pipelines.csv
```

#### Windows / macOS / Linux — PowerShell

```powershell
$env:ADO_PAT = "your-ado-pat"

# Default: reads split/pipelines.csv
.\split\split-pipelines.ps1

# Custom input file
.\split\split-pipelines.ps1 -CsvFile C:\migration\pipelines.csv
```

#### Flags / parameters

| Bash flag | PowerShell parameter | Required | Description |
|---|---|---|---|
| `--csv` | `-CsvFile` | No | Path to input `pipelines.csv`. Defaults to `split/pipelines.csv` |

### Output files

| File | Contents |
|---|---|
| `pipelines.csv` | YAML pipelines only — ready for `gh ado2gh rewire-pipeline` |
| `classic_pipelines.csv` | Classic pipelines only — ready for the `batch/` rewire scripts after column augmentation |

Both files use the **same column layout as the input** (all original columns are preserved).

### Recommended workflow

```
ado2gh generate-script → pipelines.csv
         │
         ▼
split/split-pipelines.sh (or .ps1)
         │
         ├─→ pipelines.csv        → gh ado2gh rewire-pipeline  (YAML)
         │
         └─→ classic_pipelines.csv → add serviceConnection, github_org,
                                     github_repo columns, then run:
                                     batch/rewire-classicpipeline-batch.sh
```

### After splitting: augment classic_pipelines.csv

The `classic_pipelines.csv` produced by the split utility contains the same columns as the ado2gh inventory output. Before passing it to the batch rewire scripts, add these columns:

| Column | Required | Description |
|---|---|---|
| `serviceConnection` | Yes | GUID of the GitHub service connection in Azure DevOps |
| `github_org` | Yes | Target GitHub organization |
| `github_repo` | Yes | Target GitHub repository name |
| `pipeline_id` | No | Numeric pipeline ID — skips the name-to-ID lookup; useful when names are ambiguous |
| `default_branch` | No | Default branch (defaults to `main` if omitted) |

---

## Utility Scripts

### Augment repos.csv

**Scripts:** `scripts/augment-repos-csv.sh` (Bash) and `scripts/augment-repos-csv.ps1` (PowerShell)

When `ado2gh generate-script --generate-archive-data` produces a `repos.csv`, it does not include the GitHub destination columns needed for migration. These scripts augment the file in place by appending three columns to every data row:

| Column added | Default value | Notes |
|---|---|---|
| `github_org` | *(blank)* | Fill in your GitHub organization name before running the migration |
| `github_repo` | Copied from column C | The third column of the CSV is used as the GitHub repository name |
| `gh_repo_visibility` | `private` | Set to `private` for all rows |

The file is overwritten safely using a temp file. Running the script a second time on an already-augmented file is safe — it detects the columns are already present and exits without making changes.

#### Linux / macOS — Bash

```bash
chmod +x scripts/augment-repos-csv.sh

# Default: reads/writes repos.csv in the scripts/ folder
./scripts/augment-repos-csv.sh

# Custom file path
./scripts/augment-repos-csv.sh --csv /path/to/repos.csv
```

#### Windows / macOS / Linux — PowerShell

```powershell
# Default: reads/writes repos.csv in the scripts/ folder
.\scripts\augment-repos-csv.ps1

# Custom file path
.\scripts\augment-repos-csv.ps1 -CsvFile C:\migration\repos.csv
```

#### After running

Open `repos.csv` and fill in the `github_org` column for each row. The `github_repo` and `gh_repo_visibility` columns are already populated and ready to use.
