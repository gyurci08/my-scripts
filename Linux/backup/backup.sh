#!/bin/bash
#
# backup.sh
# Modular backup script with proper glob expansion from configuration.
#
# Usage:
# - Ensure settings.conf is in the same directory, with arrays:
#   SOURCE_DIRS=( "/path/to/files*" "/some/dir" )
#   EXCLUDE_PATTERNS=( "*.log" ... )
# - Make executable: chmod +x backup.sh
# - Run: ./backup.sh

set -euo pipefail
IFS=$'\n\t'

# Get script directory robustly
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
CONFIG_FILE="${SCRIPT_DIR}/settings.conf"

log() {
    local level="$1"; shift
    echo "$(date +"%Y-%m-%dT%H:%M:%S%z") [${level}] $*" >&2
}

load_and_validate_config() {
    log INFO "Loading configuration from ${CONFIG_FILE}..."

    if [[ ! -f "${CONFIG_FILE}" ]]; then
        log ERROR "Config file not found: ${CONFIG_FILE}"
        exit 1
    fi
    if [[ ! -r "${CONFIG_FILE}" ]]; then
        log ERROR "Config file not readable: ${CONFIG_FILE}"
        exit 1
    fi

    # Security note: Make sure config file has limited write permissions

    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"

    # Validate arrays exist
    if ! declare -p SOURCE_DIRS &>/dev/null || [[ ${#SOURCE_DIRS[@]} -eq 0 ]]; then
        log ERROR "SOURCE_DIRS is undefined or empty in config."
        exit 1
    fi
    if ! declare -p BACKUP_DEST &>/dev/null || [[ -z "${BACKUP_DEST}" ]]; then
        log ERROR "BACKUP_DEST is undefined or empty in config."
        exit 1
    fi
    if ! declare -p RETENTION_DAYS &>/dev/null || ! [[ "${RETENTION_DAYS}" =~ ^[0-9]+$ ]]; then
        log ERROR "RETENTION_DAYS must be a non-negative integer."
        exit 1
    fi
    if ! declare -p COMPRESSION_FORMAT &>/dev/null || [[ -z "${COMPRESSION_FORMAT}" ]]; then
        log ERROR "COMPRESSION_FORMAT is undefined."
        exit 1
    fi

    DRY_RUN="${DRY_RUN:-false}"
    # Normalize: lowercase (POSIX-compliant)
    DRY_RUN="$(printf '%s' "${DRY_RUN}" | tr '[:upper:]' '[:lower:]')"
}

# Expand globs in SOURCE_DIRS into a flat array of paths for tar
# Excludes nonexisting paths automatically and warns
expand_source_paths() {
    local expanded=()
    for pattern in "${SOURCE_DIRS[@]}"; do
        # Perform globbing and handle zero matches safely
        shopt -s nullglob
        # Use an array to handle multiple matches per pattern
        matches=()
        # shellcheck disable=SC2207
        matches=( $pattern )
        shopt -u nullglob

        if [[ ${#matches[@]} -eq 0 ]]; then
            log WARN "No matches found for pattern '${pattern}'"
            continue
        fi

        expanded+=("${matches[@]}")
    done

    if [[ ${#expanded[@]} -eq 0 ]]; then
        log ERROR "No valid source files or directories found after glob expansion."
        exit 1
    fi

    SOURCE_PATHS=("${expanded[@]}")
}

create_archive() {
    log INFO "Starting backup creation..."

    if ! mkdir -p "${BACKUP_DEST}"; then
        log ERROR "Failed to create backup destination directory: ${BACKUP_DEST}"
        exit 1
    fi
    if [[ ! -w "${BACKUP_DEST}" ]]; then
        log ERROR "Backup destination is not writable: ${BACKUP_DEST}"
        exit 1
    fi

    local compression_flag
    local compression_ext
    case "${COMPRESSION_FORMAT}" in
        gz)  compression_flag="-z"; compression_ext="gz" ;;
        bz2) compression_flag="-j"; compression_ext="bz2" ;;
        xz)  compression_flag="-J"; compression_ext="xz" ;;
        *)
            log ERROR "Unsupported compression format: '${COMPRESSION_FORMAT}'. Use 'gz', 'bz2', or 'xz'."
            exit 1
            ;;
    esac

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local archive_name="${FILENAME_PREFIX}_${timestamp}.tar.${compression_ext}"
    local full_archive_path="${BACKUP_DEST}/${archive_name}"

    # Build tar command
    local tar_cmd=(tar --create --verbose "${compression_flag}" --file="${full_archive_path}")

    # Add exclude patterns
    if [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]]; then
        for pattern in "${EXCLUDE_PATTERNS[@]}"; do
            tar_cmd+=(--exclude="${pattern}")
        done
    fi

    # Add source paths with trailing '--' to separate options from paths
    tar_cmd+=(--)
    tar_cmd+=("${SOURCE_PATHS[@]}")

    log INFO "Creating archive: ${full_archive_path}"
    log INFO "Sources: ${SOURCE_PATHS[*]}"
    [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]] && log INFO "Exclusions: ${EXCLUDE_PATTERNS[*]}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log WARN "DRY RUN: Command that would be executed:"
        printf "    %q " "${tar_cmd[@]}"
        echo
        log WARN "DRY RUN: No archive will be created."
        return
    fi

    if ! "${tar_cmd[@]}"; then
        log ERROR "tar command failed; removing incomplete archive: ${full_archive_path}"
        rm -f "${full_archive_path}"
        exit 1
    fi

    log SUCCESS "Archive created successfully: ${full_archive_path}"
}

cleanup_old_backups() {
    if (( RETENTION_DAYS <= 0 )); then
        log INFO "Retention policy disabled (RETENTION_DAYS <= 0). Skipping cleanup."
        return
    fi

    log INFO "Looking for backups older than ${RETENTION_DAYS} days in ${BACKUP_DEST}..."

    local find_days=$(( RETENTION_DAYS - 1 ))
    if (( find_days < 0 )); then
        log INFO "Retention period less than one day; no cleanup performed."
        return
    fi

    local old_backups=()
    while IFS= read -r -d '' file; do
        old_backups+=("$file")
    done < <(find "${BACKUP_DEST}" -maxdepth 1 -type f -name "${FILENAME_PREFIX}_*.tar.*" -mtime "+${find_days}" -print0)

    if [[ ${#old_backups[@]} -eq 0 ]]; then
        log INFO "No old backup files found to clean up."
        return
    fi

    log INFO "Found ${#old_backups[@]} old backup(s) to delete."

    if [[ "${DRY_RUN}" == "true" ]]; then
        log WARN "DRY RUN: The following files would be deleted:"
        for f in "${old_backups[@]}"; do
            echo "    - $f" >&2
        done
        log WARN "DRY RUN: No files deleted."
        return
    fi

    log INFO "Deleting old backup files..."
    for f in "${old_backups[@]}"; do
        log INFO "Deleting $f"
        rm -f -- "$f"
    done

    log SUCCESS "Cleanup complete: Deleted ${#old_backups[@]} files."
}

main() {
    trap 'log INFO "Backup script finished."' EXIT
    log INFO "Backup script started."

    load_and_validate_config
    expand_source_paths
    create_archive
    cleanup_old_backups
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
