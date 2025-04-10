#!/usr/bin/env bash
set -Eeuo pipefail

## CONSTANTS ###################################################################
readonly SCRIPT_DIR="$(dirname "$(realpath -s "${BASH_SOURCE[0]}")")"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SSH_CONFIG_FILE="${HOME}/.ssh/config"
LOG_FILE=""
DEBUG_MODE=false
MASS_MODE=false

## LOGGING FUNCTIONS ###########################################################
log() {
    local level="$1"; shift
    local message="$1"
    if [[ "$level" == "DEBUG" && "$DEBUG_MODE" == true ]]; then
        echo "$message"
    fi
    [[ "$level" == "DEBUG" && "$DEBUG_MODE" != true ]] && return
    if [[ -n "$LOG_FILE" ]]; then
        printf "%s - [%s] - %s\n" "$(date +"%Y-%m-%dT%H:%M:%S%z")" "$level" "$message" >> "$LOG_FILE"
    fi
    if [[ "$level" == "ERROR" ]]; then
        echo "$message" >&2
    fi
}

## FUNCTIONS ###################################################################
usage() {
    cat << EOF
Usage: $SCRIPT_NAME [options] pattern [command]

Options:
  -d          Enable debug mode.
  -X          Enable X11 forwarding.
  -p port     Specify SSH port.
  -L [bind_address:]port:host:hostport
             Specify local port forwarding.
  -D [bind_address:]port
             Specify dynamic port forwarding.
  -l file     Specify log file (optional).
  --mass      Enable mass mode for executing commands on multiple hosts.

Restricted Commands (mass mode only):
  shutdown, poweroff, reboot

Examples:
  $SCRIPT_NAME user@host ls -l
  $SCRIPT_NAME -l /path/to/logfile user@host ls -l
  $SCRIPT_NAME --mass pattern ls -l

EOF
}

parse_arguments() {
    local ssh_options=()
    while getopts ":dXp:L:D:l:-:" opt; do
        case ${opt} in
            d) DEBUG_MODE=true ;;
            X) ssh_options+=("-X") ;;
            p|L|D) ssh_options+=("-${opt}" "${OPTARG}") ;;
            l) LOG_FILE="${OPTARG}" ;;
            -)
                case "${OPTARG}" in
                    mass) MASS_MODE=true ;;
                    *) log "ERROR" "Invalid long option --${OPTARG}" && usage && exit 1 ;;
                esac ;;
            \?) log "ERROR" "Invalid option -${OPTARG}" && usage && exit 1 ;;
            :) log "ERROR" "Option -${OPTARG} requires an argument." && usage && exit 1 ;;
        esac
    done
    shift $((OPTIND - 1))

    if [[ $# -lt 1 ]]; then
        log "ERROR" "No pattern provided."
        usage
        exit 1
    fi

    PATTERN="$1"
    shift || true
    COMMAND=("$@")
    SSH_OPTIONS=("${ssh_options[@]}")

    log "DEBUG" "Arguments parsed successfully."
    
    # Validate only in mass mode
    if [[ "$MASS_MODE" == true && ${#COMMAND[@]} -gt 0 ]]; then
        validate_command
    fi
}

validate_prerequisites() {
    [[ ! -f "${SSH_CONFIG_FILE}" ]] && log "WARN" "SSH config file not found. Proceeding without it."
    [[ -z "${PATTERN:-}" ]] && log "ERROR" "No pattern provided." && exit 1
    log "DEBUG" "Prerequisites validated."
}

validate_command() {
    local forbidden_commands=("shutdown" "poweroff" "reboot")
    for cmd in "${forbidden_commands[@]}"; do
        if [[ "${COMMAND[*]}" =~ $cmd ]]; then
            log "ERROR" "The command '${cmd}' is not allowed in mass mode."
            exit 1
        fi
    done
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
    ' ${SSH_CONFIG_FILE} | sort -V
)

    HOST_COUNT=$(echo "$HOSTS" | wc -l)
    
    if [[ $HOST_COUNT -gt 1 ]]; then 
        if [[ "$MASS_MODE" != true ]]; then
            echo "Multiple hosts detected:"
            for host in $HOSTS; do
                echo "- $host"
            done
            echo "Use --mass flag to execute commands on multiple hosts."
            exit 1
        fi

        if [[ ${#COMMAND[@]} -eq 0 ]]; then 
            log "ERROR" "--mass requires a command to be provided."
            exit 1 
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
        if [[ "$MASS_MODE" != true ]]; then
            echo -ne "\033]30;${USERNAME}@${HOST}\007"
        fi

        local ssh_command=("ssh" "-q" "-o" "LogLevel=error" "-o" "ConnectTimeout=5")
        if [[ -n "${USERNAME}" ]]; then
            ssh_command+=("-l" "${USERNAME}")
        fi
        ssh_command+=("${SSH_OPTIONS[@]}" "${HOST}")

        if [[ ${#COMMAND[@]} -gt 0 ]]; then
            ssh_command+=("${COMMAND[@]}")
            log "DEBUG" "Executing command: ${ssh_command[*]}"
            
            if ! "${ssh_command[@]}"; then
                log "ERROR" "Command failed on ${HOST}"
                continue
            fi
        else
            log "DEBUG" "Opening interactive session: ${ssh_command[*]}"
            
            if ! "${ssh_command[@]}"; then
                log "ERROR" "Session failed on ${HOST}"
                continue
            fi
        fi

        if [[ "$MASS_MODE" != true ]]; then
            # Reset tab name after session
            echo -ne "\033]30;\007"
        fi

        log "DEBUG" "Command executed successfully on ${HOST}"
    done

    log "DEBUG" "All commands attempted."
}

## Parallel Execution (Optional)
parallel_execute() {
    if [[ "$MASS_MODE" == true ]]; then
        for HOST in ${HOSTS}; do
            (
                execute_ssh_command_single_host "$HOST"
            ) &
        done
        wait
    fi
}

execute_ssh_command_single_host() {
    local HOST="$1"
    local ssh_command=("ssh" "-q" "-o" "LogLevel=error")
    if [[ -n "${USERNAME}" ]]; then
        ssh_command+=("-l" "${USERNAME}")
    fi
    ssh_command+=("${SSH_OPTIONS[@]}" "${HOST}")

    if [[ ${#COMMAND[@]} -gt 0 ]]; then
        ssh_command+=("${COMMAND[@]}")
        log "DEBUG" "Executing command on ${HOST}: ${ssh_command[*]}"
        
        if ! "${ssh_command[@]}"; then
            log "ERROR" "Command failed on ${HOST}"
        fi
    else
        log "DEBUG" "Opening interactive session on ${HOST}: ${ssh_command[*]}"
        
        if ! "${ssh_command[@]}"; then
            log "ERROR" "Session failed on ${HOST}"
        fi
    fi

    log "DEBUG" "Command executed on ${HOST}"
}

## MAIN EXECUTION ##############################################################
trap 'log "ERROR" "Operation interrupted."; exit 130' SIGINT

parse_arguments "$@"
if [[ -z "${PATTERN:-}" ]]; then
    log "ERROR" "No pattern provided."
    usage
    exit 1
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi

validate_prerequisites
extract_hosts

if [[ "$MASS_MODE" == true ]]; then
    parallel_execute
else
    execute_ssh_command
fi