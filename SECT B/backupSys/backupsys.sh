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

# Initial logging 

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


# 2.  Execution Safety - Prevent dangerous operations

acquire_lock() {
    local lock_file="$LOCK_DIR/backup.lock"
    local timeout=300
    local elapsed=0

    while [[ -f "$lock_file" ]] && [[ $elapsed -lt $timeout ]]; do 
        log "WARN" "Waiting for existing backup to complete..."
        sleep 5
        ((elapsed+=5))
    done

    if [[ -f "$lock_file" ]]; then 
        log "ERROR" "Timeout acquiring lock"
        return 1
    fi 

    echo $$ > "$lock_file"
}

release_lock() {
    rm -f "$LOCK_DIR/backup.lock"
}

# Handle interruptions gracefully 
trap_handler() {
    local signal=$?
    log "WARN" "Received signal $signal, cleaning up..."
    release_lock
    exit "$signal"
}

trap trap_handler EXIT INT TERM

validate_paths() {
    local -n paths=$1

  for path in "${paths[@]}"; do 
        if [[ ! -e "$path" ]]; then 
            log "ERROR" "Path does not exist: $path"
            return 1
        fi

        # Prevent backing up critical system paths
        if [[ "$path" =~ ^/(proc|sys|dev|run|tmp)$ ]]; then
            log "ERROR" "Cannot backup system path: $path"
            return 1
        fi
    done
    return 0
}

# 3. Scope Control - Manage what gets backed up 

create_backup_manifest() {
    local -n sources=$1
    local backup_list=()

    for source in "${sources[@]}"; do
        if [[ -d "$source" ]]; then
            # Find files, excluding transient paths
            while IFS= read -r file; do 
                if [[ ! "$file" =~ (\.tmp|\.cache|\.lock|/proc|/sys) ]]; then
                    backup_list+=("$file")
                fi
            done < <(find "$source" -type f ! -path '*/\.*' 2>/dev/null | head -10000)
        else
            backup_list+=("$source")
        fi
    done 

    printf '%s\n' "${backup_list[@]}"
}


prevent_unbounded_recursion() {
    local dir="$1"
    local max_depth=20
    local current_depth

    current_depth=$(echo "$dir" | tr -cd '/' | wc -c)

    if [[ $current_depth -gt $max_depth ]]; then
        log "WARN" "Directory depth exceeds limit: $dir"
        return 1
    fi
    return 0
}


# 4. Security & LifeCycle - Encryption and access control

encrypt_backup() {
    local source="$1"
    local dest="$2"
    local key_file="$STATE_DIR/backup.key"

    if [[ ! -f "$key_file" ]]; then
        log "INFO" "Generating encryption key..."
        openssl rand -base64 32 > "$key_file"
        chmod 600 "$key_file"
    fi

    log "INFO" "Encrypting backup: $source"
    openssl enc -aes-256-cbc -in "$source" -out "${dest}.enc" \
        -K "$(xxd -p -c 256 < "$key_file")" -S "$(openssl rand -hex 8)"
    rm -f "$source"
    log "INFO" "Backup encrypted and original removed"
}

set_restrictive_permissions() {
    local file="$1"
    chmod 600 "$file"

    # Verify ownership
    local owner
    owner=$(stat -c '%U' "$file" 2>/dev/null || stat -f '%Su' "$file" 2>/dev/null)

    if [[ "$owner" != "root" && "$EUID" -eq 0 ]]; then
        chown root:root "$file"
    fi
}

manage_retention() {
    local target_dir="$1"
    local days="$RETENTION_DAYS"

    log "INFO" "Enforcing retention policy $days days" 

    find "$target_dir" -name "backup-*" -type d -mtime +"$days" | while read -r old_backup; do
        log "INFO" "Removing expired backup: $old_backup"
        rm -rf "$old_backup"
    done
}

enable_audit_logging() {
    local audit_log="$LOG_DIR/audit.log"

    exec 3>>"$audit_log"
    log "AUDIT" "Backup operation initiated by user: ${SUDO_USER:-$USER}"
    log "AUDIT" "Backup destination: $BACKUP_ROOT"

}

# Utility functions

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

main() {
    log "INFO" "=== Critical Backup System started ==="

    # Initialize 
    init_manifest
    enable_audit_logging
    acquire_lock

    # Define sources to backup
    local sources=(
        "/home"
        "/etc"
        "/var/lib"
    )

    # Execute backup pipeline
    log "INFO" "Validating backup sources..."
    validate_paths sources || exit 1

    log "INFO" "Creating backup manifest..."
    local -a backup_files
    mapfile -t backup_files < <(create_backup_manifest sources)

    log "INFO" "Processing ${#backup_files[@]} files"

    local backup_dir
    backup_dir="$BACKUP_ROOT/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"

    local success_count=0
    local fail_count=0

    for file in "${backup_files[@]}"; do
        prevent_unbounded_recursion "$file" || continue

        local rel_path="${file#/}"
        local dest="$backup_dir/$rel_path"
        local dest_dir="${dest%/*}"

        mkdir -p "$dest_dir"

        if backup_with_verification "$file" "$dest"; then
            ((success_count++))
            set_restrictive_permissions "$dest"
        else 
            ((fail_count++))
        fi
    done


    # Encrypt sensitive backups
    local sensitive_dirs=("$backup_dir/etc" "$backup_dir/home")
    for dir in "${sensitive_dirs[@]}"; do 
        if [[ -d "$dir" ]]; then
            local archive="${dir}.tar.gz"
            tar -czf "$archive" -C "$dir" . 2>>"$LOG_FILE" && \
            encrypt_backup "$archive" "${archive%.gz}" || \
            log "WARN" "Failed to encrypt $dir"
        fi
    done

    # Manage retention
    manage_retention "$BACKUP_ROOT"
    
    log "INFO" "=== Backup Complete ==="
    log "INFO" "Success: $success_count | Failed: $fail_count"
    log "AUDIT" "Backup operation completed successfully"

    [[ $fail_count -eq 0 ]] && return 0 || return 1
}

# Run main function
main "$@"