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
#     github_org          — left blank for the user to fill in
#     github_repo         — copied from column C (the third column)
#     gh_repo_visibility  — set to "private" for all rows
#
#   The original file is overwritten with the augmented version.
#   If the three columns already exist in the header they are not added
#   again, preventing duplicates on repeated runs.
#
# USAGE
#   # Default: reads/writes repos.csv in the same directory as this script
#   ./augment-repos-csv.sh
#
#   # Custom file path
#   ./augment-repos-csv.sh --csv /path/to/repos.csv
#
# PREREQUISITES
#   - bash 4+
#   - python3  (used for reliable CSV parsing)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CSV_FILE="${SCRIPT_DIR}/repos.csv"

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --csv)   CSV_FILE="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ── Validate input file ────────────────────────────────────────────────────────
if [[ ! -f "$CSV_FILE" ]]; then
    echo "❌ ERROR: CSV file not found: $CSV_FILE" >&2
    echo "   Place repos.csv in the scripts/ folder or use --csv <path>" >&2
    exit 1
fi

ROW_COUNT=$(( $(wc -l < "$CSV_FILE") - 1 ))
if [[ "$ROW_COUNT" -le 0 ]]; then
    echo "⚠️  No data rows found in: $CSV_FILE (file is empty or header-only)"
    exit 0
fi

echo "📂 Input : $CSV_FILE ($ROW_COUNT data row(s))"

# ── Augment via Python (handles quoted fields correctly) ───────────────────────
python3 - "$CSV_FILE" <<'PYEOF'
import csv
import sys
import os

csv_path = sys.argv[1]
tmp_path  = csv_path + ".tmp"

NEW_COLS = ["github_org", "github_repo", "gh_repo_visibility"]

with open(csv_path, newline="", encoding="utf-8-sig") as f_in, \
     open(tmp_path,  "w", newline="", encoding="utf-8") as f_out:

    reader = csv.reader(f_in)
    writer = csv.writer(f_out, lineterminator="\n")

    header = next(reader)

    # Detect which new columns are already present
    existing = {c.strip().lower() for c in header}
    cols_to_add = [c for c in NEW_COLS if c not in existing]

    if not cols_to_add:
        print("ℹ️  All three columns already present — no changes made.")
        os.remove(tmp_path)
        sys.exit(0)

    writer.writerow(header + cols_to_add)

    for row in reader:
        # Column C is index 2; fall back to empty string if row is short
        col_c_value = row[2].strip() if len(row) > 2 else ""

        extra = []
        for col in cols_to_add:
            if col == "github_org":
                extra.append("")                # blank — user fills in later
            elif col == "github_repo":
                extra.append(col_c_value)       # copy from column C
            elif col == "gh_repo_visibility":
                extra.append("private")

        writer.writerow(row + extra)

os.replace(tmp_path, csv_path)
print(f"✅ Done — columns added: {', '.join(cols_to_add)}")
PYEOF
