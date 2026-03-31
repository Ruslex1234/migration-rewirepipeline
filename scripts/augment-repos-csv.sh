#!/usr/bin/env bash
set -euo pipefail
#
# SYNOPSIS
#   Augments repos.csv with three new columns: github_org, github_repo,
#   gh_repo_visibility.
#
# DESCRIPTION
#   Reads an existing repos.csv file and appends three columns to every
#   data row:
#     github_org          — set via --github-org, or left blank
#     github_repo         — column C value with optional prefix/suffix applied
#     gh_repo_visibility  — "private" by default; override with --visibility
#
#   The original file is overwritten with the augmented version.
#   If the three columns already exist in the header they are not added
#   again, preventing duplicates on repeated runs.
#
# USAGE
#   ./augment-repos-csv.sh [options]
#
# OPTIONS
#   --csv <path>                  Path to repos.csv (default: repos.csv next to this script)
#   --visibility <value>          Visibility value written to gh_repo_visibility.
#                                 Must be one of: private, public, internal (all lowercase).
#                                 Use "off" to leave the field blank.
#                                 Default: private
#   --github-org <value>          Value to set for github_org on every row.
#                                 Default: blank (fill in later)
#   --github-repo-prefix <value>  Text prepended to the column C value for github_repo.
#   --github-repo-suffix <value>  Text appended to the column C value for github_repo.
#
# EXAMPLES
#   ./augment-repos-csv.sh
#   ./augment-repos-csv.sh --csv /path/to/repos.csv --visibility public
#   ./augment-repos-csv.sh --visibility off
#   ./augment-repos-csv.sh --github-org my-gh-org --github-repo-prefix migrated- --github-repo-suffix -prod
#
# PREREQUISITES
#   - bash 4+
#   - python3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV_FILE="${SCRIPT_DIR}/repos.csv"
VISIBILITY="private"
GITHUB_ORG=""
REPO_PREFIX=""
REPO_SUFFIX=""

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --csv)                  CSV_FILE="$2";    shift 2 ;;
        --visibility)           VISIBILITY="$2";  shift 2 ;;
        --github-org)           GITHUB_ORG="$2";  shift 2 ;;
        --github-repo-prefix)   REPO_PREFIX="$2"; shift 2 ;;
        --github-repo-suffix)   REPO_SUFFIX="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ── Validate --visibility ──────────────────────────────────────────────────────
VALID_VISIBILITY=("private" "public" "internal" "off")
VISIBILITY_VALID=false
for v in "${VALID_VISIBILITY[@]}"; do
    [[ "$VISIBILITY" == "$v" ]] && VISIBILITY_VALID=true && break
done

if [[ "$VISIBILITY_VALID" == false ]]; then
    # Check if it looks like a casing issue
    VISIBILITY_LOWER=$(echo "$VISIBILITY" | tr '[:upper:]' '[:lower:]')
    for v in "${VALID_VISIBILITY[@]}"; do
        if [[ "$VISIBILITY_LOWER" == "$v" ]]; then
            echo "ERROR: --visibility value '$VISIBILITY' must be all lowercase. Did you mean '$VISIBILITY_LOWER'?" >&2
            exit 1
        fi
    done
    echo "ERROR: --visibility '$VISIBILITY' is not valid. Allowed values: private, public, internal, off" >&2
    exit 1
fi

# ── Validate input file ────────────────────────────────────────────────────────
if [[ ! -f "$CSV_FILE" ]]; then
    echo "ERROR: CSV file not found: $CSV_FILE" >&2
    echo "   Place repos.csv in the scripts/ folder or use --csv <path>" >&2
    exit 1
fi

ROW_COUNT=$(( $(wc -l < "$CSV_FILE") - 1 ))
if [[ "$ROW_COUNT" -le 0 ]]; then
    echo "WARNING: No data rows found in: $CSV_FILE (file is empty or header-only)"
    exit 0
fi

echo "Input      : $CSV_FILE ($ROW_COUNT data row(s))"
echo "github_org : ${GITHUB_ORG:-"(blank — fill in later)"}"
echo "repo prefix: ${REPO_PREFIX:-"(none)"}"
echo "repo suffix: ${REPO_SUFFIX:-"(none)"}"
echo "visibility : ${VISIBILITY}"

# ── Augment via Python (handles quoted fields correctly) ───────────────────────
python3 - "$CSV_FILE" "$VISIBILITY" "$GITHUB_ORG" "$REPO_PREFIX" "$REPO_SUFFIX" <<'PYEOF'
import csv
import sys
import os

csv_path   = sys.argv[1]
visibility = sys.argv[2]   # "off" means blank
github_org = sys.argv[3]
prefix     = sys.argv[4]
suffix     = sys.argv[5]
tmp_path   = csv_path + ".tmp"

NEW_COLS = ["github_org", "github_repo", "gh_repo_visibility"]

with open(csv_path, newline="", encoding="utf-8-sig") as f_in, \
     open(tmp_path,  "w", newline="", encoding="utf-8") as f_out:

    reader = csv.reader(f_in)
    writer = csv.writer(f_out, lineterminator="\n")

    header = next(reader)

    existing   = {c.strip().lower() for c in header}
    cols_to_add = [c for c in NEW_COLS if c not in existing]

    if not cols_to_add:
        print("INFO: All three columns already present -- no changes made.")
        os.remove(tmp_path)
        sys.exit(0)

    writer.writerow(header + cols_to_add)

    for row in reader:
        col_c_value = row[2].strip() if len(row) > 2 else ""
        github_repo = f"{prefix}{col_c_value}{suffix}"

        extra = []
        for col in cols_to_add:
            if col == "github_org":
                extra.append(github_org)
            elif col == "github_repo":
                extra.append(github_repo)
            elif col == "gh_repo_visibility":
                extra.append("" if visibility == "off" else visibility)

        writer.writerow(row + extra)

os.replace(tmp_path, csv_path)
print(f"Done -- columns added: {', '.join(cols_to_add)}")
PYEOF
