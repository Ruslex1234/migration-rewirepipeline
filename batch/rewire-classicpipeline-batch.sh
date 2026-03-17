#!/usr/bin/env bash
set -euo pipefail
#
# SYNOPSIS
#   Batch-rewires classic Azure DevOps pipelines to GitHub using classic_pipeline.csv.
#
# DESCRIPTION
#   Reads pipeline rows from classic_pipeline.csv and rewires each classic
#   (process type 1) pipeline to its corresponding GitHub repository via the
#   Azure DevOps REST API.
#
#   If repos_with_status.csv is present (Stage 3 output from the migration
#   pipeline), only pipelines whose ADO repo migrated successfully are
#   processed; all others are skipped with a warning.
#
# PREREQUISITES
#   - bash 4+
#   - curl
#   - jq
#   - python3
#   - ADO_PAT environment variable (Build: Read & Execute)
#
# USAGE
#   export ADO_PAT="your-ado-pat"
#
#   # Default: reads classic_pipeline.csv in the same directory
#   ./rewire-classicpipeline-batch.sh
#
#   # Custom CSV path
#   ./rewire-classicpipeline-batch.sh --csv /path/to/classic_pipeline.csv
#
#   # With migration status filter
#   ./rewire-classicpipeline-batch.sh --repos-status /path/to/repos_with_status.csv
#
# CSV FORMAT (classic_pipeline.csv)
#   Required columns : org, teamproject, repo, pipeline, serviceConnection,
#                      github_org, github_repo
#   Optional columns : pipeline_id  (numeric ID; takes precedence over pipeline name)
#                      default_branch (defaults to "main")
#                      url            (informational only, from ado2gh inventory)

# ── Configuration ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV_FILE="${SCRIPT_DIR}/classic_pipeline.csv"
REPOS_STATUS_FILE=""
REQUIRED_COLUMNS=("org" "teamproject" "repo" "pipeline" "serviceConnection" "github_org" "github_repo")
PLACEHOLDER_VALUES=("your-service-connection-id" "placeholder" "TODO" "TBD" "xxx" "00000000-0000-0000-0000-000000000000")

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
NC='\033[0m'

# ── Counters / result arrays ───────────────────────────────────────────────────
SUCCESS_COUNT=0
FAILURE_COUNT=0
SKIPPED_COUNT=0
declare -a RESULTS
declare -a FAILED_DETAILS
declare -a SKIPPED_DETAILS
declare -A MIGRATED_REPOS
FILTER_BY_STATUS=false
DETAILED_LOG=$(mktemp)

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --csv)           CSV_FILE="$2";           shift 2 ;;
        --repos-status)  REPOS_STATUS_FILE="$2";  shift 2 ;;
        -h|--help)       grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ── Helper: load repos_with_status.csv ────────────────────────────────────────
load_migrated_repos() {
    local status_file="$1"
    FILTER_BY_STATUS=true
    echo -e "${YELLOW}Loading successfully migrated repositories from: $status_file${NC}"

    while IFS=',' read -r _org _tp repo _gorg _grepo _vis status; do
        repo=$(echo "$repo"     | sed 's/^"//;s/"$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
        status=$(echo "$status" | sed 's/^"//;s/"$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ "$status" == "Success" ]] && MIGRATED_REPOS["$repo"]=1
    done < <(tail -n +2 "$status_file")

    echo -e "${GREEN}✅ Loaded ${#MIGRATED_REPOS[@]} successfully migrated repositories${NC}"

    if [[ ${#MIGRATED_REPOS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}⚠️  No successful migrations found — all pipelines will be skipped${NC}"
    fi
}

# ── Core rewiring function ─────────────────────────────────────────────────────
# Returns 0=success, 1=error, 2=skipped (YAML pipeline)
rewire_classic_pipeline() {
    local ado_org="$1"
    local ado_project="$2"
    local pipeline_id="$3"
    local github_org="$4"
    local github_repo="$5"
    local service_conn_id="$6"
    local default_branch="$7"

    local auth_header="Authorization: Basic $(printf ':%s' "$ADO_PAT" | base64 -w 0)"
    local def_url="https://dev.azure.com/${ado_org}/${ado_project}/_apis/build/definitions/${pipeline_id}?api-version=6.0"

    local definition
    definition=$(curl -sf -H "$auth_header" "$def_url") || return 1

    local process_type
    process_type=$(echo "$definition" | jq -r '.process.type')

    if [[ "$process_type" -ne 1 ]]; then
        echo "Process type $process_type detected (YAML) — use gh ado2gh rewire-pipeline for YAML pipelines"
        return 2
    fi

    local updated_definition
    updated_definition=$(echo "$definition" | jq \
        --arg githubOrg  "$github_org" \
        --arg githubRepo "$github_repo" \
        --arg svcId      "$service_conn_id" \
        --arg branch     "$default_branch" \
        '.repository = {
            properties: {
                apiUrl:             ("https://api.github.com/repos/" + $githubOrg + "/" + $githubRepo),
                branchesUrl:        ("https://api.github.com/repos/" + $githubOrg + "/" + $githubRepo + "/branches"),
                cloneUrl:           ("https://github.com/" + $githubOrg + "/" + $githubRepo + ".git"),
                connectedServiceId: $svcId,
                defaultBranch:      $branch,
                fullName:           ($githubOrg + "/" + $githubRepo),
                manageUrl:          ("https://github.com/" + $githubOrg + "/" + $githubRepo),
                orgName:            $githubOrg,
                refsUrl:            ("https://api.github.com/repos/" + $githubOrg + "/" + $githubRepo + "/git/refs"),
                safeRepository:     ($githubOrg + "/" + $githubRepo),
                shortName:          $githubRepo,
                reportBuildStatus:  "true"
            },
            id:                ($githubOrg + "/" + $githubRepo),
            type:              "GitHub",
            name:              ($githubOrg + "/" + $githubRepo),
            url:               ("https://github.com/" + $githubOrg + "/" + $githubRepo + ".git"),
            defaultBranch:     $branch,
            clean:             "false",
            checkoutSubmodules: "false"
        }') || return 1

    curl -sf \
        -X PUT \
        -H "$auth_header" \
        -H "Content-Type: application/json" \
        -d "$updated_definition" \
        "$def_url" > /dev/null || return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════
echo -e "\n${CYAN}========================================${NC}"
echo -e "${CYAN}  ADO2GH: Batch Rewire Classic Pipelines${NC}"
echo -e "${CYAN}========================================${NC}\n"

# Auto-detect repos_with_status.csv
if [[ -z "$REPOS_STATUS_FILE" ]]; then
    for candidate in "${SCRIPT_DIR}/repos_with_status.csv" "${SCRIPT_DIR}/../repos_with_status.csv"; do
        if [[ -f "$candidate" ]]; then
            REPOS_STATUS_FILE="$candidate"
            break
        fi
    done
fi

if [[ -n "$REPOS_STATUS_FILE" ]]; then
    if [[ -f "$REPOS_STATUS_FILE" ]]; then
        load_migrated_repos "$REPOS_STATUS_FILE"
    else
        echo -e "${YELLOW}⚠️  repos_with_status.csv not found at: $REPOS_STATUS_FILE — processing all rows${NC}"
    fi
else
    echo -e "${GRAY}ℹ️  No repos_with_status.csv detected — processing all rows in CSV${NC}"
fi

# ── Step 1: Validate ADO_PAT ──────────────────────────────────────────────────
echo -e "${YELLOW}[Step 1/4] Validating ADO_PAT...${NC}"
if [[ -z "${ADO_PAT:-}" ]]; then
    echo -e "${RED}❌ ERROR: ADO_PAT environment variable is not set${NC}"
    exit 1
fi
echo -e "${GREEN}✅ ADO_PAT validated${NC}"

# ── Step 2: Validate CSV file ─────────────────────────────────────────────────
echo -e "\n${YELLOW}[Step 2/4] Validating classic_pipeline.csv...${NC}"
if [[ ! -f "$CSV_FILE" ]]; then
    echo -e "${RED}❌ ERROR: CSV file not found: $CSV_FILE${NC}"
    echo -e "${YELLOW}   Use --csv <path> or place classic_pipeline.csv in the batch/ folder${NC}"
    exit 1
fi

PIPELINE_COUNT=$(( $(wc -l < "$CSV_FILE") - 1 ))
if [[ "$PIPELINE_COUNT" -le 0 ]]; then
    echo -e "${YELLOW}⚠️  No pipelines found in CSV (only header or empty file)${NC}"
    exit 0
fi
echo -e "${GREEN}✅ File loaded: $PIPELINE_COUNT pipeline(s) found${NC}"

# ── Step 3: Validate columns and service connection IDs ───────────────────────
echo -e "\n${YELLOW}[Step 3/4] Validating CSV columns and data...${NC}"

IFS=',' read -ra CSV_COLUMNS <<< "$(head -n 1 "$CSV_FILE")"
for i in "${!CSV_COLUMNS[@]}"; do
    CSV_COLUMNS[$i]=$(echo "${CSV_COLUMNS[$i]}" | sed 's/^"//;s/"$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
done

MISSING_COLUMNS=()
for req_col in "${REQUIRED_COLUMNS[@]}"; do
    found=false
    for csv_col in "${CSV_COLUMNS[@]}"; do
        [[ "$csv_col" == "$req_col" ]] && found=true && break
    done
    [[ "$found" == false ]] && MISSING_COLUMNS+=("$req_col")
done

if [[ ${#MISSING_COLUMNS[@]} -gt 0 ]]; then
    echo -e "${RED}❌ ERROR: CSV missing required columns: ${MISSING_COLUMNS[*]}${NC}"
    echo -e "${YELLOW}   Required : ${REQUIRED_COLUMNS[*]}${NC}"
    echo -e "${GRAY}   Found    : ${CSV_COLUMNS[*]}${NC}"
    exit 1
fi
echo -e "${GREEN}✅ All required columns present${NC}"

declare -A COL_INDEX
for i in "${!CSV_COLUMNS[@]}"; do
    COL_INDEX["${CSV_COLUMNS[$i]}"]=$i
done

echo -e "${GRAY}   Validating service connection IDs...${NC}"
INVALID_ROWS=()
ROW_NUM=1
while IFS= read -r line; do
    ROW_NUM=$((ROW_NUM + 1))
    IFS=',' read -ra fields <<< "$line"
    for i in "${!fields[@]}"; do
        fields[$i]=$(echo "${fields[$i]}" | sed 's/^"//;s/"$//')
    done
    SVC="${fields[${COL_INDEX["serviceConnection"]}]:-}"
    PL="${fields[${COL_INDEX["pipeline"]}]:-}"
    if [[ -z "$SVC" ]]; then
        INVALID_ROWS+=("Row $ROW_NUM: '${PL}' — empty serviceConnection")
    else
        for ph in "${PLACEHOLDER_VALUES[@]}"; do
            if [[ "$SVC" == "$ph" ]]; then
                INVALID_ROWS+=("Row $ROW_NUM: '${PL}' — placeholder value: '$SVC'")
                break
            fi
        done
    fi
done < <(tail -n +2 "$CSV_FILE")

if [[ ${#INVALID_ROWS[@]} -gt 0 ]]; then
    echo -e "\n${RED}❌ ERROR: Invalid service connection IDs found:${NC}"
    for inv in "${INVALID_ROWS[@]}"; do echo -e "${YELLOW}      $inv${NC}"; done
    echo -e "\n${CYAN}   💡 Fix: Azure DevOps → Project Settings → Service Connections → copy the GUID${NC}"
    exit 1
fi
echo -e "${GREEN}✅ All service connection IDs validated${NC}"

# ── Step 4: Rewire pipelines ──────────────────────────────────────────────────
echo -e "\n${YELLOW}[Step 4/4] Rewiring classic pipelines to GitHub...${NC}"

while IFS= read -r line; do
    IFS=',' read -ra fields <<< "$line"
    for i in "${!fields[@]}"; do
        fields[$i]=$(echo "${fields[$i]}" | sed 's/^"//;s/"$//')
    done

    ADO_ORG="${fields[${COL_INDEX["org"]}]:-}"
    ADO_PROJECT="${fields[${COL_INDEX["teamproject"]}]:-}"
    ADO_REPO="${fields[${COL_INDEX["repo"]}]:-}"
    PIPELINE_NAME="${fields[${COL_INDEX["pipeline"]}]:-}"
    GITHUB_ORG="${fields[${COL_INDEX["github_org"]}]:-}"
    GITHUB_REPO="${fields[${COL_INDEX["github_repo"]}]:-}"
    SERVICE_CONN_ID="${fields[${COL_INDEX["serviceConnection"]}]:-}"

    # Optional columns
    PIPELINE_ID_CSV=""
    if [[ -n "${COL_INDEX["pipeline_id"]+x}" ]]; then
        PIPELINE_ID_CSV="${fields[${COL_INDEX["pipeline_id"]}]:-}"
    fi
    DEFAULT_BRANCH="main"
    if [[ -n "${COL_INDEX["default_branch"]+x}" ]]; then
        val="${fields[${COL_INDEX["default_branch"]}]:-}"
        [[ -n "$val" ]] && DEFAULT_BRANCH="$val"
    fi

    # Human-readable label for logs
    if [[ -n "$PIPELINE_ID_CSV" ]]; then
        PIPELINE_LABEL="'${PIPELINE_NAME}' (ID: ${PIPELINE_ID_CSV})"
    else
        PIPELINE_LABEL="'${PIPELINE_NAME}'"
    fi

    echo -e "\n${GRAY}   🔍 Checking: ${PIPELINE_LABEL} — repo: '${ADO_REPO}'${NC}"

    # Optional status filter
    if [[ "$FILTER_BY_STATUS" == true ]] && [[ -z "${MIGRATED_REPOS[$ADO_REPO]+x}" ]]; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        echo -e "${YELLOW}   ⏭️  Skipped: ${PIPELINE_LABEL}${NC}"
        echo -e "${GRAY}      Reason: '${ADO_REPO}' not found in repos_with_status.csv as Success${NC}"
        SKIPPED_DETAILS+=("$ADO_PROJECT/${PIPELINE_LABEL}: repo '${ADO_REPO}' not successfully migrated")
        continue
    fi

    echo -e "${CYAN}   🔄 Processing: ${PIPELINE_LABEL}${NC}"
    echo -e "${GRAY}      ADO:    ${ADO_ORG}/${ADO_PROJECT}${NC}"
    echo -e "${GRAY}      GitHub: ${GITHUB_ORG}/${GITHUB_REPO} (branch: ${DEFAULT_BRANCH})${NC}"
    echo -e "${GRAY}      Svc:    ${SERVICE_CONN_ID}${NC}"

    # Resolve name → ID if pipeline_id not supplied
    RESOLVED_ID="$PIPELINE_ID_CSV"
    if [[ -z "$RESOLVED_ID" ]]; then
        echo -e "${GRAY}      Resolving pipeline name to ID...${NC}"
        AUTH_HEADER="Authorization: Basic $(printf ':%s' "$ADO_PAT" | base64 -w 0)"
        ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$PIPELINE_NAME")
        LIST_URL="https://dev.azure.com/${ADO_ORG}/${ADO_PROJECT}/_apis/build/definitions?api-version=7.1&name=${ENCODED}"

        LIST_JSON=$(curl -sf -H "$AUTH_HEADER" "$LIST_URL" 2>/dev/null) || {
            FAILURE_COUNT=$((FAILURE_COUNT + 1))
            ERR="Failed to query pipeline list for '${PIPELINE_NAME}'"
            echo -e "${RED}      ❌ FAILED: $ERR${NC}"
            RESULTS+=("❌ FAILED | $ADO_PROJECT/${PIPELINE_LABEL}")
            FAILED_DETAILS+=("$ADO_PROJECT/${PIPELINE_LABEL}: $ERR")
            continue
        }

        COUNT=$(echo "$LIST_JSON" | jq '.count')
        if [[ "$COUNT" -eq 0 ]]; then
            FAILURE_COUNT=$((FAILURE_COUNT + 1))
            ERR="No pipeline found with name '${PIPELINE_NAME}'"
            echo -e "${RED}      ❌ FAILED: $ERR${NC}"
            RESULTS+=("❌ FAILED | $ADO_PROJECT/${PIPELINE_LABEL}")
            FAILED_DETAILS+=("$ADO_PROJECT/${PIPELINE_LABEL}: $ERR")
            continue
        fi
        if [[ "$COUNT" -gt 1 ]]; then
            FAILURE_COUNT=$((FAILURE_COUNT + 1))
            ERR="Multiple pipelines matched '${PIPELINE_NAME}' — add pipeline_id column to disambiguate"
            echo -e "${RED}      ❌ FAILED: $ERR${NC}"
            RESULTS+=("❌ FAILED | $ADO_PROJECT/${PIPELINE_LABEL}")
            FAILED_DETAILS+=("$ADO_PROJECT/${PIPELINE_LABEL}: $ERR")
            continue
        fi

        RESOLVED_ID=$(echo "$LIST_JSON" | jq -r '.value[0].id')
        echo -e "${GRAY}      Resolved to pipeline ID: ${RESOLVED_ID}${NC}"
    fi

    # Rewire
    TMP_OUT=$(mktemp)
    EXIT_CODE=0
    rewire_classic_pipeline \
        "$ADO_ORG" "$ADO_PROJECT" "$RESOLVED_ID" \
        "$GITHUB_ORG" "$GITHUB_REPO" "$SERVICE_CONN_ID" "$DEFAULT_BRANCH" \
        >"$TMP_OUT" 2>&1 || EXIT_CODE=$?

    OUT_CONTENT=$(cat "$TMP_OUT")
    rm -f "$TMP_OUT"
    [[ -n "$OUT_CONTENT" ]] && echo "$OUT_CONTENT" | sed 's/^/      /' | tee -a "$DETAILED_LOG"

    if [[ "$EXIT_CODE" -eq 2 ]]; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        echo -e "${YELLOW}      ⏭️  SKIPPED (YAML pipeline)${NC}"
        SKIPPED_DETAILS+=("$ADO_PROJECT/${PIPELINE_LABEL}: YAML pipeline — use gh ado2gh rewire-pipeline instead")
        RESULTS+=("⏭️  SKIPPED (YAML) | $ADO_PROJECT/${PIPELINE_LABEL}")
    elif [[ "$EXIT_CODE" -eq 0 ]]; then
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        echo -e "${GREEN}      ✅ SUCCESS${NC}"
        RESULTS+=("✅ SUCCESS | $ADO_PROJECT/${PIPELINE_LABEL} → ${GITHUB_ORG}/${GITHUB_REPO}")
    else
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        ERR=$(echo "$OUT_CONTENT" | grep -i "error\|fail\|curl" | head -n 2 | tr '\n' ' ')
        [[ -z "$ERR" ]] && ERR="Unknown error (exit ${EXIT_CODE})"
        echo -e "${RED}      ❌ FAILED: $ERR${NC}"
        RESULTS+=("❌ FAILED | $ADO_PROJECT/${PIPELINE_LABEL} → ${GITHUB_ORG}/${GITHUB_REPO}")
        FAILED_DETAILS+=("$ADO_PROJECT/${PIPELINE_LABEL}: $ERR")
    fi

    sleep 1

done < <(tail -n +2 "$CSV_FILE")

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}========================================${NC}"
echo -e "${CYAN}  Batch Rewiring Summary${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "Total Pipelines : ${PIPELINE_COUNT}"
echo -e "${GREEN}Successful      : ${SUCCESS_COUNT}${NC}"
echo -e "${YELLOW}Skipped         : ${SKIPPED_COUNT}${NC}"
echo -e "${RED}Failed          : ${FAILURE_COUNT}${NC}"

echo -e "\n${CYAN}📋 Detailed Results:${NC}"
for r in "${RESULTS[@]:-}"; do echo -e "${GRAY}   $r${NC}"; done

if [[ ${#SKIPPED_DETAILS[@]} -gt 0 ]]; then
    echo -e "\n${YELLOW}⏭️  Skipped:${NC}"
    for d in "${SKIPPED_DETAILS[@]}"; do echo -e "${GRAY}   • $d${NC}"; done
fi

if [[ ${#FAILED_DETAILS[@]} -gt 0 ]]; then
    echo -e "\n${RED}❌ Failed:${NC}"
    for d in "${FAILED_DETAILS[@]}"; do echo -e "${GRAY}   • $d${NC}"; done
fi

# ── Write log file ────────────────────────────────────────────────────────────
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
LOG_FILE="${SCRIPT_DIR}/classic-rewiring-$(date "+%Y%m%d-%H%M%S").txt"

{
    echo "Classic Pipeline Batch Rewiring Log - ${TIMESTAMP}"
    echo "========================================"
    echo "Total Pipelines : ${PIPELINE_COUNT}"
    echo "Successful      : ${SUCCESS_COUNT}"
    echo "Skipped         : ${SKIPPED_COUNT}"
    echo "Failed          : ${FAILURE_COUNT}"
    echo ""
    echo "Results:"
    printf '%s\n' "${RESULTS[@]:-None}"
    echo ""
    echo "Skipped Details:"
    printf '%s\n' "${SKIPPED_DETAILS[@]:-None}"
    echo ""
    echo "Failed Details:"
    printf '%s\n' "${FAILED_DETAILS[@]:-None}"
    echo ""
    echo "========================================"
    echo "Detailed Command Output:"
    echo "========================================"
    if [[ -f "$DETAILED_LOG" && -s "$DETAILED_LOG" ]]; then
        cat "$DETAILED_LOG"
    else
        echo "No detailed output captured"
    fi
} > "$LOG_FILE"

rm -f "$DETAILED_LOG"
echo -e "\n${GRAY}📄 Log saved: $LOG_FILE${NC}"

# ── Exit ──────────────────────────────────────────────────────────────────────
if [[ "$FAILURE_COUNT" -eq 0 && "$SKIPPED_COUNT" -eq 0 ]]; then
    echo -e "\n${GREEN}✅ All classic pipelines rewired successfully${NC}"
    exit 0
elif [[ "$FAILURE_COUNT" -eq 0 ]]; then
    echo -e "\n${GREEN}✅ Rewiring completed (${SKIPPED_COUNT} skipped)${NC}"
    echo "##vso[task.complete result=SucceededWithIssues]Rewiring completed with ${SKIPPED_COUNT} skipped"
    exit 0
else
    echo -e "\n${YELLOW}⚠️  Rewiring completed with issues: ${SUCCESS_COUNT} succeeded, ${SKIPPED_COUNT} skipped, ${FAILURE_COUNT} failed${NC}"
    echo "##[warning]${FAILURE_COUNT} pipeline(s) failed rewiring"
    echo "##vso[task.complete result=SucceededWithIssues]${SUCCESS_COUNT} succeeded, ${SKIPPED_COUNT} skipped, ${FAILURE_COUNT} failed"
    exit 0
fi
