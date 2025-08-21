#!/bin/bash
#
# backup.sh
# A modular script to create compressed backups from a configuration file.
#
# Usage:
# 1. Create and fill out settings.conf in the same directory.
#    - IMPORTANT: SOURCE_DIRS and EXCLUDE_PATTERNS must be declared as Bash arrays.
#    - Example:
#      SOURCE_DIRS=("/etc/proxmox" "/etc/kubernetes/manifests")
#      EXCLUDE_PATTERNS=("*.log" "cache/*")
# 2. Make the script executable: chmod +x backup.sh
# 3. Run the script: ./backup.sh

# --- Strict Mode ---
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error when substituting.
# -o pipefail: A pipeline's exit code is the last command's to exit with a non-zero status.
set -euo pipefail

# --- Script Globals ---
# Use a robust method to get the script's directory.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
CONFIG_FILE="${SCRIPT_DIR}/settings.conf"


# --- Functions ---

# Standardized logging function
# Usage: log "LEVEL" "message"
log() {
    local level="$1"
    shift
    # Log to stderr to separate logs from potential script output.
    echo "$(date +"%Y-%m-%dT%H:%M:%S%z") [${level}] $*" >&2
}

# Load and validate the configuration from settings.conf
load_and_validate_config() {
    log "INFO" "Loading configuration from ${CONFIG_FILE}..."

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        log "ERROR" "Configuration file not found: ${CONFIG_FILE}"
        exit 1
    fi
    if [[ ! -r "${CONFIG_FILE}" ]]; then
        log "ERROR" "Configuration file is not readable: ${CONFIG_FILE}"
        exit 1
    fi

    # SECURITY: Sourcing executes code from the config file. Ensure it is trusted and
    # has appropriate permissions (e.g., not writable by non-admin users).
    # shellcheck source=settings.conf
    source "${CONFIG_FILE}"

    # --- Configuration Validation ---
    if [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
        log "ERROR" "SOURCE_DIRS array is empty in config. Nothing to back up."
        exit 1
    fi

    if [[ -z "${BACKUP_DEST:-}" ]]; then
        log "ERROR" "BACKUP_DEST is not defined in config."
        exit 1
    fi

    if ! [[ "${RETENTION_DAYS:-}" =~ ^[0-9]+$ ]]; then
        log "ERROR" "RETENTION_DAYS must be a non-negative integer. Found: '${RETENTION_DAYS:-}'"
        exit 1
    fi

    if [[ -z "${COMPRESSION_FORMAT:-}" ]]; then
        log "ERROR" "COMPRESSION_FORMAT is not defined in config."
        exit 1
    fi

    # Normalize DRY_RUN to lowercase. This requires Bash 4+.
    DRY_RUN=${DRY_RUN:-"false"}
    DRY_RUN="${DRY_RUN,,}"
}

# Create the compressed archive
create_archive() {
    log "INFO" "Starting backup creation..."

    if ! mkdir -p "${BACKUP_DEST}"; then
        log "ERROR" "Could not create backup destination directory: ${BACKUP_DEST}"
        exit 1
    fi
    if ! [[ -w "${BACKUP_DEST}" ]]; then
        log "ERROR" "Backup destination is not writable: ${BACKUP_DEST}"
        exit 1
    fi

    local compression_flag=""
    local compression_ext=""
    case "${COMPRESSION_FORMAT}" in
        gz)  compression_flag="-z"; compression_ext="gz" ;;
        bz2) compression_flag="-j"; compression_ext="bz2" ;;
        xz)  compression_flag="-J"; compression_ext="xz" ;;
        *)
            log "ERROR" "Unsupported compression format: '${COMPRESSION_FORMAT}'. Use 'gz', 'bz2', or 'xz'."
            exit 1
            ;;
    esac

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local archive_name="${FILENAME_PREFIX}_${timestamp}.tar.${compression_ext}"
    local full_archive_path="${BACKUP_DEST}/${archive_name}"

    # Build the tar command in an array for safety, clarity, and to prevent word-splitting issues.
    local tar_cmd=(tar --create --verbose "${compression_flag}" "--file=${full_archive_path}")

    if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
        for pattern in "${EXCLUDE_PATTERNS[@]}"; do
            tar_cmd+=("--exclude=${pattern}")
        done
    fi

    # Add source directories. The "--" marks the end of options, preventing issues with
    # filenames that start with a dash.
    tar_cmd+=("--")
    tar_cmd+=("${SOURCE_DIRS[@]}")

    log "INFO" "Creating archive: ${full_archive_path}"
    log "INFO" "Sources: ${SOURCE_DIRS[*]}"
    [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]] && log "INFO" "Exclusions: ${EXCLUDE_PATTERNS[*]}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "WARN" "DRY RUN: The following command would be executed:"
        # printf with %q quotes arguments for safe shell re-use, making the output clear.
        printf "    %q " "${tar_cmd[@]}"; echo >&2
        log "WARN" "DRY RUN: No archive will be created."
        return
    fi

    if ! "${tar_cmd[@]}"; then
        log "ERROR" "tar command failed with exit code $?. Backup may be incomplete or corrupted."
        log "INFO" "Removing potentially incomplete archive: ${full_archive_path}"
        rm -f "${full_archive_path}"
        exit 1
    fi

    log "SUCCESS" "Archive created successfully: ${full_archive_path}"
}

# Clean up old backups based on the retention policy
cleanup_old_backups() {
    if [[ ${RETENTION_DAYS} -le 0 ]]; then
        log "INFO" "Retention policy is disabled (RETENTION_DAYS <= 0). Skipping cleanup."
        return
    fi

    log "INFO" "Searching for backups in '${BACKUP_DEST}' older than ${RETENTION_DAYS} days..."

    # `find -mtime +N` matches files modified more than (N+1)*24 hours ago.
    # To delete files older than RETENTION_DAYS, we use `+<RETENTION_DAYS - 1>`.
    # E.g., for 7 days retention, we delete files >7 days old, matching `-mtime +6`.
    local find_days=$((RETENTION_DAYS - 1))
    if (( find_days < 0 )); then
        log "INFO" "Retention period is less than one day, no cleanup will be performed."
        return
    fi

    # Use a process substitution and a while loop with `find -print0` for maximum robustness.
    # This correctly handles all filenames, including those with spaces or special characters.
    local old_backups=()
    while IFS= read -r -d '' file; do
        old_backups+=("$file")
    done < <(find "${BACKUP_DEST}" -maxdepth 1 -type f -name "${FILENAME_PREFIX}_*.tar.*" -mtime "+${find_days}" -print0)

    if [[ ${#old_backups[@]} -eq 0 ]]; then
        log "INFO" "No old backups found to clean up."
        return
    fi

    log "INFO" "Found ${#old_backups[@]} old backup(s) for deletion."

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "WARN" "DRY RUN: The following ${#old_backups[@]} file(s) would be deleted:"
        printf "    - %s\n" "${old_backups[@]}" >&2
        log "WARN" "DRY RUN: No files will be deleted."
        return
    fi

    log "INFO" "Deleting ${#old_backups[@]} old backup(s)..."
    printf "    - Deleting %s\n" "${old_backups[@]}" >&2

    if ! rm -f "${old_backups[@]}"; then
        log "ERROR" "Failed to delete one or more old backup files."
        exit 1
    fi

    log "SUCCESS" "Cleanup of ${#old_backups[@]} file(s) complete."
}

# --- Main Execution ---
main() {
    # Trap ensures the final log message is always printed on script exit,
    # regardless of success or failure (due to 'set -e').
    trap 'log "INFO" "Backup script finished."' EXIT

    log "INFO" "Backup script started."

    load_and_validate_config
    create_archive
    cleanup_old_backups
}

# This guard prevents the script from running automatically when sourced.
# It allows you to 'source ./backup.sh' in an interactive shell to use its functions
# without triggering a backup.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
