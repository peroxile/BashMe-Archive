#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

# Configuration 
readonly BACKUP_ROOT="/mnt/backups"
readonly LOG_DIR="/var/log/backup-system"
readonly STATE_DIR="/var/lib/backup_system"
readonly LOCK_DIR="/run/backup-system"
readonly RETENTION_DAYS=30
# readonly CHUNK_SIZE=1073741824 #1GB

# Initialize logging 
mkdir -p "$LOG_DIR" "$STATE_DIR" "$LOCK_DIR"
readonly LOG_FILE="$LOG_DIR/backup-$(date +%Y%m%d-%H%M%S).log"
readonly MANIFEST_FILE="$STATE_DIR/manifest-$(date +%Y%m%d).json"


Init_manifest() {
    cat > "$MANIFEST_FILE" <<EOF
{
    "timestamp": $(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "version": "1.0",
    "files": [],
    "checksums": {} 
}
EOF
}

compute_checksum() {
    local file="$1"
    sha256sum "$file" | awk '{print $1}'
}

backup_with_verification() {
    local source="$1"
    local dest="$2"

    log "INFO" "Backing up: $source -> $dest"

    # Create atomic backup with temp file
    local temp_dest="${dest}.tmp.$$"

    if cp -p "$source" "$temp_dest" 2>>"$LOG_FILE"; then
        local src_checksum
        src_checksum=$(compute_checksum "$source")
        local dst_checksum
        dst_checksum=$(compute_checksum "$temp_dest")

        if [[ "$src_checksum" == "$dst_checksum" ]]; then
            mv "$temp_dest" "$dest"
            log "INFO" "Backup verified: $source"
            return 0
        else
            rm -f "$temp_dest"
            log "ERROR" "Checksum mismatch for $source"
            return 1
        fi
    else
        rm -f "$temp_dest"
        log "ERROR" "Failed to backup $source"
        return 1
    fi
}

