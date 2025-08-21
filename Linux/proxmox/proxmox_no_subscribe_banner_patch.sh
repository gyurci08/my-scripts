#!/usr/bin/env bash
set -euo pipefail

####
# Hide or restore the “No valid subscription” banner in Proxmox VE ≥8.x.
#####

# -----------------------------------------------------------------------------
#  CONFIGURATION
# -----------------------------------------------------------------------------
TARGET_FILE="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
BACKUP_DIR="/var/backups/proxmox_banner"  # Directory for timestamped backups
RETENTION_DAYS=30                          # Keep backups for at least 30 days
LOG_FILE="/var/log/proxmox_banner_patch.log"

# -----------------------------------------------------------------------------
#  UTILITY FUNCTIONS
# -----------------------------------------------------------------------------
log() {
    echo "$(date '+%F %T') - $*" | tee -a "$LOG_FILE"
}
err() {
    echo "$(date '+%F %T') - ERROR: $*" | tee -a "$LOG_FILE" >&2
    exit 1
}

check_root() {
    [[ $EUID -eq 0 ]] || err "This script must be run as root."
}

check_dependencies() {
    local dependencies=(sed systemctl cp mkdir stat grep find shred apt)
    local missing=()

    for cmd in "${dependencies[@]}"; do
        command -v "$cmd" &> /dev/null || missing+=("$cmd")
    done

    [[ ${#missing[@]} -eq 0 ]] || err "Missing dependencies: ${missing[*]}. Install them and try again."
}

check_file_exists() {
    [[ -f "$TARGET_FILE" ]] || err "Target file not found: $TARGET_FILE"
}

manage_backups() {
    mkdir -p "$BACKUP_DIR" || err "Failed to create backup directory: $BACKUP_DIR"

    # Verify backup directory permissions (drwxr-x--- or stricter)
    local mode=$(stat -c %a "$BACKUP_DIR")
    (( mode & 0077 )) && err "Backup directory permissions too open: $mode. Set to 750 or stricter."

    # Create timestamped backup
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local new_backup="${BACKUP_DIR}/$(basename "$TARGET_FILE").backup.$timestamp"
    log "Creating backup: $new_backup"
    cp -p "$TARGET_FILE" "$new_backup" || err "Backup failed"

    # Clean up old backups
    log "Cleaning backups older than $RETENTION_DAYS days..."
    find "$BACKUP_DIR" -type f -name "$(basename "$TARGET_FILE").backup.*" -mtime +$RETENTION_DAYS -exec shred -u {} +
}

determine_patch_status() {
    if grep -q "!== 'active'" "$TARGET_FILE" || grep -q "status.toLowerCase()\s*!=\s*'active'" "$TARGET_FILE"; then
        echo "not_applied"
    elif grep -q "== 'active'" "$TARGET_FILE"; then
        echo "applied"
    else
        echo "unknown"
    fi
}

resolve_patch_logic() {
    if grep -q "!== 'active'" "$TARGET_FILE"; then
        SED_EXPR="s/(res\.data\.status\.toLowerCase\(\))[[:space:]]*!==[[:space:]]*'active'/\1 == 'active'/g"
        return 0
    elif grep -q "status.toLowerCase()\s*!=\s*'active'" "$TARGET_FILE"; then
        SED_EXPR="s/(res\.data\.status\.toLowerCase\(\))[[:space:]]*!=[[:space:]]*'active'/\1 == 'active'/g"
        return 0
    else
        return 1
    fi
}

verify_patch() {
    ! grep -q "!== 'active'" "$TARGET_FILE" && ! grep -q "!= 'active'" "$TARGET_FILE" && grep -q "== 'active'" "$TARGET_FILE"
}

apply_patch() {
    local status=$(determine_patch_status)
    if [[ $status == "applied" ]]; then
        log "Patch is already applied – nothing to do."
        return 0
    elif [[ $status == "unknown" ]]; then
        log "Unknown banner logic detected – skipping patch to avoid issues."
        return 0
    fi

    if ! resolve_patch_logic; then
        log "Failed to resolve patch logic – nothing to do."
        return 0
    fi

    manage_backups
    log "Applying patch with: $SED_EXPR"
    sed -i "$SED_EXPR" "$TARGET_FILE" || err "Patch failed"

    if verify_patch; then
        log "Patch applied successfully."
    else
        log "Verification failed – restoring backup."
        restore_from_backup
        err "Patch verification failed."
    fi

    systemctl restart pveproxy.service || err "Failed to restart pveproxy"
    log "pveproxy restarted."
}

restore_from_backup() {
    local latest_backup=$(find "$BACKUP_DIR" -type f -name "$(basename "$TARGET_FILE").backup.*" -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
    [[ -n $latest_backup ]] || err "No backups found to restore."

    log "Restoring: $latest_backup"
    cp -p "$latest_backup" "$TARGET_FILE" || err "Restore failed"
}

revert_patch() {
    if [[ -d "$BACKUP_DIR" && $(find "$BACKUP_DIR" -type f -name "*.backup.*" | wc -l) -gt 0 ]]; then
        restore_from_backup
    else
        log "No backups – reinstalling proxmox-widget-toolkit"
        apt update >/dev/null 2>&1
        apt --reinstall install -y proxmox-widget-toolkit || err "Reinstall failed"
    fi

    systemctl restart pveproxy.service || err "Failed to restart pveproxy"
    log "Revert completed."
}

check_patch_status() {
    local status=$(determine_patch_status)
    case "$status" in
        applied)     echo "Patch status: Applied" ;;
        not_applied) echo "Patch status: Not applied" ;;
        unknown)     echo "Patch status: Unknown (banner logic may have changed)" ;;
    esac
}

# -----------------------------------------------------------------------------
#  MAIN
# -----------------------------------------------------------------------------
main() {
    check_root
    check_dependencies
    check_file_exists

    case "${1:-patch}" in
        patch)  apply_patch  ;;
        revert) revert_patch ;;
        status) check_patch_status ;;
        *)      echo "Usage: $0 [patch|revert|status]"; exit 1 ;;
    esac
}

main "$@"
