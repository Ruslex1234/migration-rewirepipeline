#!/usr/bin/env bash
set -euo pipefail
#
# SYNOPSIS
#   Splits an ado2gh pipelines.csv into YAML and Classic pipeline files.
#
# DESCRIPTION
#   Reads each row from pipelines.csv, queries the Azure DevOps
#   build/definitions API to check process.type, then routes rows to:
#     - pipelines.csv        (YAML pipelines,    process.type = 2)
#     - classic_pipeline.csv (Classic pipelines, process.type = 1)
#
#   Both output files are written to the same directory as the input file.
#   The definition ID is extracted from the 'url' column when available
#   (skips an extra name-lookup API call). Falls back to a name lookup
#   when no URL or definitionId is present.
#
# PREREQUISITES
#   - bash 4+
#   - curl
#   - jq
#   - python3
#   - ADO_PAT environment variable (Build: Read scope)
#
# USAGE
#   export ADO_PAT="your-ado-pat"
#
#   # Default: reads pipelines.csv in the same directory as this script
#   ./split-pipelines.sh
#
#   # Custom input file
#   ./split-pipelines.sh --csv /path/to/my-pipelines.csv
#
# OUTPUTS (written to the same directory as the input file)
#   pipelines.csv        — YAML pipelines only
#   classic_pipeline.csv — Classic pipelines only
#
# NOTE
#   After splitting, add the serviceConnection, github_org, github_repo, and
#   (optionally) default_branch columns to classic_pipeline.csv before using
#   it with batch/rewire-classicpipeline-batch.sh.

# ── Configuration ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_CSV="${SCRIPT_DIR}/pipelines.csv"

# ── Colors ─────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
RED='\033[0;31m'
NC='\033[0m'

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --csv)       INPUT_CSV="$2"; shift 2 ;;
        -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ── Validate inputs ────────────────────────────────────────────────────────────
if [[ -z "${ADO_PAT:-}" ]]; then
    echo -e "${RED}ERROR: ADO_PAT environment variable is not set${NC}" >&2
    exit 1
fi

if [[ ! -f "$INPUT_CSV" ]]; then
    echo -e "${RED}ERROR: Input file not found: $INPUT_CSV${NC}" >&2
    echo -e "${YELLOW}  Use --csv <path> or place pipelines.csv in the split/ folder${NC}" >&2
    exit 1
fi

OUTPUT_DIR="$(cd "$(dirname "$INPUT_CSV")" && pwd)"
YAML_OUT="${OUTPUT_DIR}/pipelines.csv"
CLASSIC_OUT="${OUTPUT_DIR}/classic_pipeline.csv"

AUTH="Authorization: Basic $(printf ':%s' "$ADO_PAT" | base64 -w 0)"

# ── Parse header ───────────────────────────────────────────────────────────────
HEADER=$(head -n 1 "$INPUT_CSV")
IFS=',' read -ra COL_NAMES <<< "$HEADER"
for i in "${!COL_NAMES[@]}"; do
    COL_NAMES[$i]=$(echo "${COL_NAMES[$i]}" | sed 's/^"//;s/"$//;s/^[[:space:]]*//;s/[[:space:]]*$//')
done

declare -A COL_INDEX
for i in "${!COL_NAMES[@]}"; do
    COL_INDEX["${COL_NAMES[$i]}"]=$i
done

for col in org teamproject pipeline; do
    if [[ -z "${COL_INDEX[$col]+x}" ]]; then
        echo -e "${RED}ERROR: Required column '$col' not found in CSV header${NC}" >&2
        echo -e "${GRAY}  Found columns: ${COL_NAMES[*]}${NC}" >&2
        exit 1
    fi
done

HAS_URL_COL=false
[[ -n "${COL_INDEX["url"]+x}" ]] && HAS_URL_COL=true

# ── Process rows ───────────────────────────────────────────────────────────────
echo -e "\n${CYAN}========================================${NC}"
echo -e "${CYAN}  Split pipelines.csv by process type${NC}"
echo -e "${CYAN}========================================${NC}\n"
echo -e "${GRAY}Input : $INPUT_CSV${NC}"
echo -e "${GRAY}Output: $OUTPUT_DIR${NC}\n"

declare -a YAML_ROWS CLASSIC_ROWS UNKNOWN_ROWS FAILED_ROWS
TOTAL=0

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    TOTAL=$((TOTAL + 1))

    # Parse fields
    IFS=',' read -ra fields <<< "$line"
    for i in "${!fields[@]}"; do
        fields[$i]=$(echo "${fields[$i]}" | sed 's/^"//;s/"$//')
    done

    ORG="${fields[${COL_INDEX["org"]}]:-}"
    PROJECT="${fields[${COL_INDEX["teamproject"]}]:-}"
    PIPELINE_NAME="${fields[${COL_INDEX["pipeline"]}]:-}"

    URL_VAL=""
    if [[ "$HAS_URL_COL" == true ]]; then
        URL_VAL="${fields[${COL_INDEX["url"]}]:-}"
    fi

    # Extract definitionId from URL if present
    DEF_ID=""
    if [[ -n "$URL_VAL" ]]; then
        DEF_ID=$(echo "$URL_VAL" | grep -oE 'definitionId=[0-9]+' | cut -d= -f2 || true)
    fi

    # Fall back to name lookup
    if [[ -z "$DEF_ID" ]]; then
        ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$PIPELINE_NAME")
        LIST_URL="https://dev.azure.com/${ORG}/${PROJECT}/_apis/build/definitions?api-version=7.1&name=${ENCODED}"
        LIST_JSON=$(curl -sf -H "$AUTH" "$LIST_URL" 2>/dev/null) || {
            echo -e "${RED}  ❌ FAILED (API error)   : $PIPELINE_NAME${NC}"
            FAILED_ROWS+=("$line")
            continue
        }
        COUNT=$(echo "$LIST_JSON" | jq '.count')
        if [[ "$COUNT" -eq 0 ]]; then
            echo -e "${YELLOW}  ⚠️  NOT FOUND           : $PIPELINE_NAME${NC}"
            UNKNOWN_ROWS+=("$line")
            continue
        fi
        if [[ "$COUNT" -gt 1 ]]; then
            echo -e "${YELLOW}  ⚠️  AMBIGUOUS ($COUNT matches): $PIPELINE_NAME${NC}"
            UNKNOWN_ROWS+=("$line")
            continue
        fi
        DEF_ID=$(echo "$LIST_JSON" | jq -r '.value[0].id')
    fi

    # Fetch full definition
    DEF_URL="https://dev.azure.com/${ORG}/${PROJECT}/_apis/build/definitions/${DEF_ID}?api-version=6.0"
    DEF_JSON=$(curl -sf -H "$AUTH" "$DEF_URL" 2>/dev/null) || {
        echo -e "${RED}  ❌ FAILED (definition fetch): $PIPELINE_NAME${NC}"
        FAILED_ROWS+=("$line")
        continue
    }

    PROCESS_TYPE=$(echo "$DEF_JSON" | jq -r '.process.type')

    case "$PROCESS_TYPE" in
        2)
            echo -e "${GREEN}  ✅ YAML              : $PIPELINE_NAME${NC}"
            YAML_ROWS+=("$line")
            ;;
        1)
            echo -e "${CYAN}  🔧 CLASSIC           : $PIPELINE_NAME${NC}"
            CLASSIC_ROWS+=("$line")
            ;;
        *)
            echo -e "${YELLOW}  ❓ UNKNOWN (type=$PROCESS_TYPE): $PIPELINE_NAME${NC}"
            UNKNOWN_ROWS+=("$line")
            ;;
    esac

    sleep 0.3

done < <(tail -n +2 "$INPUT_CSV")

# ── Write output files ─────────────────────────────────────────────────────────
echo -e "\n${YELLOW}Writing output files...${NC}"

{
    echo "$HEADER"
    for row in "${YAML_ROWS[@]+"${YAML_ROWS[@]}"}"; do echo "$row"; done
} > "$YAML_OUT"

{
    echo "$HEADER"
    for row in "${CLASSIC_ROWS[@]+"${CLASSIC_ROWS[@]}"}"; do echo "$row"; done
} > "$CLASSIC_OUT"

# ── Summary ────────────────────────────────────────────────────────────────────
echo -e "\n${CYAN}========================================${NC}"
echo -e "${CYAN}  Summary${NC}"
echo -e "${CYAN}========================================${NC}"
echo -e "Total processed : ${TOTAL}"
echo -e "${GREEN}YAML            : ${#YAML_ROWS[@]}${NC}"
echo -e "${CYAN}Classic         : ${#CLASSIC_ROWS[@]}${NC}"
[[ ${#UNKNOWN_ROWS[@]} -gt 0 ]] && echo -e "${YELLOW}Unknown / skipped: ${#UNKNOWN_ROWS[@]}${NC}"
[[ ${#FAILED_ROWS[@]}  -gt 0 ]] && echo -e "${RED}Failed           : ${#FAILED_ROWS[@]}${NC}"

echo -e "\n${GRAY}Output files:${NC}"
echo -e "${GRAY}  YAML    → $YAML_OUT    (${#YAML_ROWS[@]} pipeline(s))${NC}"
echo -e "${GRAY}  Classic → $CLASSIC_OUT (${#CLASSIC_ROWS[@]} pipeline(s))${NC}"

if [[ ${#CLASSIC_ROWS[@]} -gt 0 ]]; then
    echo -e "\n${YELLOW}Next step for classic_pipeline.csv:${NC}"
    echo -e "${GRAY}  Add columns: serviceConnection, github_org, github_repo${NC}"
    echo -e "${GRAY}  Optional  : default_branch (defaults to 'main' if omitted)${NC}"
    echo -e "${GRAY}  Then run  : batch/rewire-classicpipeline-batch.sh${NC}"
fi

if [[ ${#FAILED_ROWS[@]} -gt 0 ]]; then
    echo -e "\n${RED}The following pipelines could not be classified:${NC}"
    for row in "${FAILED_ROWS[@]}"; do
        IFS=',' read -ra f <<< "$row"
        echo -e "${GRAY}  • ${f[${COL_INDEX["pipeline"]}]:-$row}${NC}"
    done
fi
