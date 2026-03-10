#!/usr/bin/env bash
#
# SYNOPSIS
#   Rewires a classic Azure DevOps pipeline to point to a GitHub repository.
#   Mirrors gh ado2gh rewire-pipeline behavior for classic (process type 1) pipelines.
#
# PREREQUISITES
#   - bash 4+
#   - curl
#   - jq
#   - Azure DevOps PAT with Build (Read & Execute)
#   - Existing GitHub service connection in Azure DevOps
#
# USAGE
#   export ADO_PAT="your-ado-pat"
#
#   # By pipeline name:
#   ./rewire-classicpipeline.sh \
#     --ado-org        my-ado-org \
#     --ado-project    MyProject \
#     --pipeline-name  "my-classic-pipeline" \
#     --github-org     my-github-org \
#     --github-repo    my-repo \
#     --service-connection-id 8846673b-b6bc-4f7c-aeeb-6d7447b2334d
#
#   # By pipeline ID:
#   ./rewire-classicpipeline.sh \
#     --ado-org        my-ado-org \
#     --ado-project    MyProject \
#     --pipeline-id    42 \
#     --github-org     my-github-org \
#     --github-repo    my-repo \
#     --service-connection-id 8846673b-b6bc-4f7c-aeeb-6d7447b2334d

set -euo pipefail

# ── Helpers ─────────────────────────────────────────────────────────────────
usage() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

err()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

# ── Argument parsing ─────────────────────────────────────────────────────────
ADO_ORG=""
ADO_PROJECT=""
PIPELINE_NAME=""
PIPELINE_ID=""
GITHUB_ORG=""
GITHUB_REPO=""
SERVICE_CONNECTION_ID=""
DEFAULT_BRANCH="main"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ado-org)                ADO_ORG="$2";                shift 2 ;;
        --ado-project)            ADO_PROJECT="$2";            shift 2 ;;
        --pipeline-name)          PIPELINE_NAME="$2";          shift 2 ;;
        --pipeline-id)            PIPELINE_ID="$2";            shift 2 ;;
        --github-org)             GITHUB_ORG="$2";             shift 2 ;;
        --github-repo)            GITHUB_REPO="$2";            shift 2 ;;
        --service-connection-id)  SERVICE_CONNECTION_ID="$2";  shift 2 ;;
        --default-branch)         DEFAULT_BRANCH="$2";         shift 2 ;;
        -h|--help)                usage ;;
        *) err "Unknown argument: $1" ;;
    esac
done

# ── Validate required args ───────────────────────────────────────────────────
[[ -n "$ADO_ORG" ]]               || err "--ado-org is required"
[[ -n "$ADO_PROJECT" ]]           || err "--ado-project is required"
[[ -n "$GITHUB_ORG" ]]            || err "--github-org is required"
[[ -n "$GITHUB_REPO" ]]           || err "--github-repo is required"
[[ -n "$SERVICE_CONNECTION_ID" ]] || err "--service-connection-id is required"

if [[ -n "$PIPELINE_NAME" && -n "$PIPELINE_ID" ]]; then
    err "Provide either --pipeline-name or --pipeline-id, not both"
fi
if [[ -z "$PIPELINE_NAME" && -z "$PIPELINE_ID" ]]; then
    err "One of --pipeline-name or --pipeline-id is required"
fi

# ── Auth ─────────────────────────────────────────────────────────────────────
[[ -n "${ADO_PAT:-}" ]] || err "ADO_PAT environment variable is not set"

AUTH_HEADER="Authorization: Basic $(printf ':%s' "$ADO_PAT" | base64 -w 0)"
API_BASE="https://dev.azure.com/${ADO_ORG}/${ADO_PROJECT}/_apis"

# ── Resolve pipeline name to ID ──────────────────────────────────────────────
if [[ -n "$PIPELINE_NAME" ]]; then
    echo "Resolving pipeline name '${PIPELINE_NAME}' to ID..."

    ENCODED_NAME=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$PIPELINE_NAME")
    LIST_URL="${API_BASE}/build/definitions?api-version=7.1&name=${ENCODED_NAME}"

    LIST_JSON=$(curl -sf -H "$AUTH_HEADER" "$LIST_URL") \
        || err "Failed to query pipeline list"

    COUNT=$(echo "$LIST_JSON" | jq '.count')

    if [[ "$COUNT" -eq 0 ]]; then
        err "No pipeline found with name: '${PIPELINE_NAME}'"
    fi

    if [[ "$COUNT" -gt 1 ]]; then
        warn "Multiple pipelines matched '${PIPELINE_NAME}':"
        echo "$LIST_JSON" | jq -r '.value[] | "  ID: \(.id)  Name: \(.name)"' >&2
        err "Provide a more specific name or use --pipeline-id instead"
    fi

    PIPELINE_ID=$(echo "$LIST_JSON" | jq -r '.value[0].id')
    echo "  Resolved '${PIPELINE_NAME}' to pipeline ID: ${PIPELINE_ID}"
fi

# ── Fetch full pipeline definition ───────────────────────────────────────────
DEF_URL="${API_BASE}/build/definitions/${PIPELINE_ID}?api-version=6.0"

echo "Fetching pipeline definition (ID: ${PIPELINE_ID})..."

DEFINITION=$(curl -sf -H "$AUTH_HEADER" "$DEF_URL") \
    || err "Failed to fetch pipeline definition"

CURRENT_REPO=$(echo "$DEFINITION"  | jq -r '.repository.name')
CURRENT_TYPE=$(echo "$DEFINITION"  | jq -r '.repository.type')
PROCESS_TYPE=$(echo "$DEFINITION"  | jq -r '.process.type')
PIPELINE_LABEL=$(echo "$DEFINITION" | jq -r '.name')

echo ""
echo "Pipeline:     ${PIPELINE_LABEL} (ID: ${PIPELINE_ID})"
echo "Current repo: ${CURRENT_REPO} (type: ${CURRENT_TYPE})"

if [[ "$PROCESS_TYPE" -eq 1 ]]; then
    echo "Process type: ${PROCESS_TYPE} (classic)"
else
    echo "Process type: ${PROCESS_TYPE} (YAML - consider gh ado2gh rewire-pipeline instead)"
    warn "This is a YAML pipeline. Use 'gh ado2gh rewire-pipeline' for YAML."
    read -rp "Continue anyway? (y/N) " CONFIRM
    [[ "$CONFIRM" =~ ^[yY]$ ]] || { echo "Aborted."; exit 0; }
fi

# ── Build updated repository payload ─────────────────────────────────────────
echo ""
echo "Rewiring to: ${GITHUB_ORG}/${GITHUB_REPO} (GitHub)..."

UPDATED_DEFINITION=$(echo "$DEFINITION" | jq \
    --arg githubOrg  "$GITHUB_ORG" \
    --arg githubRepo "$GITHUB_REPO" \
    --arg svcId      "$SERVICE_CONNECTION_ID" \
    --arg branch     "$DEFAULT_BRANCH" \
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
    }')

# ── Push updated definition ───────────────────────────────────────────────────
RESULT=$(curl -sf \
    -X PUT \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "$UPDATED_DEFINITION" \
    "$DEF_URL") \
    || err "Pipeline update failed"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Successfully rewired pipeline!"
echo "  Pipeline:   $(echo "$RESULT" | jq -r '.name') (ID: ${PIPELINE_ID})"
echo "  Revision:   $(echo "$RESULT" | jq -r '.revision')"
echo "  Repository: $(echo "$RESULT" | jq -r '.repository.name') (type: $(echo "$RESULT" | jq -r '.repository.type'))"
echo "  Branch:     $(echo "$RESULT" | jq -r '.repository.defaultBranch')"
