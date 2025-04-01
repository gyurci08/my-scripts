#!/usr/bin/env bash
set -Eeuo pipefail

## CONSTANTS ###################################################################
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SSH_CONFIG_FILE="${HOME}/.ssh/config"
DEBUG_MODE=false
MASS_MODE=false

## LOGGING FUNCTIONS ###########################################################
log() {
    local level="$1"; shift
    local message="$1"
    [[ "$level" == "DEBUG" && "$DEBUG_MODE" != true ]] && return
    printf "%s - [%s] - %s\n" "$(date +"%Y-%m-%dT%H:%M:%S%z")" "$level" "$message"
}

## FUNCTIONS ###################################################################
parse_arguments() {
    local ssh_options=()
    while getopts ":dXp:L:D:-:" opt; do
        case ${opt} in
            d) DEBUG_MODE=true ;;
            X) ssh_options+=("-X") ;;
            p|L|D) ssh_options+=("-${opt}" "${OPTARG}") ;;
            -)
                case "${OPTARG}" in
                    mass) MASS_MODE=true ;;  # Enable mass mode
                    *) log "ERROR" "Invalid long option --${OPTARG}" && exit 1 ;;
                esac ;;
            \?) log "ERROR" "Invalid option -${OPTARG}" && exit 1 ;;
            :) log "ERROR" "Option -${OPTARG} requires an argument." && exit 1 ;;
        esac
    done
    shift $((OPTIND - 1))

    [[ $# -lt 1 ]] && log "ERROR" "No pattern provided." && exit 1

    PATTERN="$1"
    shift || true
    COMMAND=("$@")
    SSH_OPTIONS=("${ssh_options[@]}")

    log "DEBUG" "Arguments parsed successfully."
}

validate_prerequisites() {
    [[ ! -f "${SSH_CONFIG_FILE}" ]] && log "WARN" "SSH config file not found. Proceeding without it."
    [[ -z "${PATTERN:-}" ]] && log "ERROR" "No pattern provided." && exit 1
    log "DEBUG" "Prerequisites validated."
}

extract_hosts() {
    local host_pattern="${PATTERN}"

    if [[ "${host_pattern}" =~ "@" ]]; then
        USERNAME="${host_pattern%@*}"
        HOST_PATTERN="${host_pattern#*@}"
        log "DEBUG" "Extracted username: ${USERNAME}, host pattern: ${HOST_PATTERN}"
    else
        USERNAME=""
        HOST_PATTERN="${host_pattern}"
        log "DEBUG" "Host pattern: ${HOST_PATTERN}"
    fi

HOSTS=$(awk -v pattern="$HOST_PATTERN" '
    # Remove leading/trailing whitespace
    { sub(/^ +/, ""); sub(/ +$/, ""); }

    # Skip empty lines or comments
    /^$/ || /^#/ { next }

    # Handle Hostname lines and associate them with the current host
    /^Hostname/ {
        if (current_host) {
            hostnames[current_host] = $2
        }
    }

    # Handle Host lines
    /^Host/ {
        split($0, hosts, " ")
        for (i=2; i<=NF; i++) {
            if (hosts[i] !~ /\*/) {
                current_host = hosts[i]
                hosts_array[hosts[i]] # Store host without *
            }
        }
    }

    END {
        for (host in hosts_array) {
            if (tolower(host) ~ pattern && host !~ /\*$/) {
                if (hostnames[host]) {
                    if (!(hostnames[host] in printed)) {
                        print hostnames[host] # Print Hostname if available
                        printed[hostnames[host]] = 1
                    }
                } else {
                    if (!(host in printed)) {
                        print host # Otherwise, print Host entry itself
                        printed[host] = 1
                    }
                }
            }
        }
    }
' ~/.ssh/config
)

    HOST_COUNT=$(echo "$HOSTS" | wc -l)

    if [[ $HOST_COUNT -gt 1 ]]; then
        if [[ "$MASS_MODE" != true ]]; then
            log "ERROR" "Multiple hosts detected. Use --mass flag to execute commands on multiple hosts." && exit 1
        fi

        if [[ ${#COMMAND[@]} -eq 0 ]]; then
            log "ERROR" "--mass requires a command to be provided." && exit 1
        fi
    fi

    if [[ -z "${HOSTS}" ]]; then
        log "WARN" "No hosts found matching '${HOST_PATTERN}'. Falling back to direct connection."
        HOSTS="${HOST_PATTERN}"  # Fallback to the provided input as the host.
    fi

    log "DEBUG" "Matching hosts: $(echo "${HOSTS}" | tr '\n' ' ')"
}

execute_ssh_command() {
    for HOST in ${HOSTS}; do
        local ssh_command=("ssh" "-q" "-o" "LogLevel=error")
        [[ -n "${USERNAME}" ]] && ssh_command+=("-l" "${USERNAME}")
        ssh_command+=("${SSH_OPTIONS[@]}" "${HOST}")

        if [[ ${#COMMAND[@]} -gt 0 ]]; then
            ssh_command+=("${COMMAND[@]}")
            log "DEBUG" "Executing command: ${ssh_command[*]}"

            # Execute command and handle errors gracefully
            if ! "${ssh_command[@]}"; then
                log "ERROR" "Command failed on ${HOST}"
                continue  # Proceed to the next host
            fi
        else
            log "DEBUG" "Opening interactive session: ${ssh_command[*]}"

            # Open interactive session and handle errors gracefully
            if ! "${ssh_command[@]}"; then
                log "ERROR" "Session failed on ${HOST}"
                continue  # Proceed to the next host
            fi
        fi

        log "DEBUG" "Command executed successfully on ${HOST}"
    done

    log "DEBUG" "All commands attempted."
}


## MAIN EXECUTION ##############################################################
trap 'log "ERROR" "Operation interrupted."; exit 130' SIGINT

parse_arguments "$@"
validate_prerequisites
extract_hosts
execute_ssh_command
