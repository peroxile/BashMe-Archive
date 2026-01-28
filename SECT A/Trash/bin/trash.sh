#!/usr/bin/env bash 

set -euo pipefail
# set -x

TRASH="$HOME/.local/share/Trash"

INPUT="${1:-}"

# Validate input 
if [[ ! "$INPUT" =~ ^([0-9]+)([mhd])$ ]]; then
    echo "Invalid format. Use: <number>[m|h|d]" >&2
    exit 1
fi

VALUE="${BASH_REMATCH[1]}"
UNIT="${BASH_REMATCH[2]}"

# Convert to minutes
case "$UNIT" in
    m) MINUTES="$VALUE" ;;
    h) MINUTES=$(( VALUE * 60 )) ;;
    d) MINUTES=$(( VALUE * 1440 )) ;;
esac


# Delete files 

find "$TRASH/files" -mindepth 1 -mmin +"$MINUTES" -exec rm -rf {} +
find "$TRASH/info" -mindepth 1 -mindepth 1 -mmin +"$MINUTES" -exec rm -f {} +

