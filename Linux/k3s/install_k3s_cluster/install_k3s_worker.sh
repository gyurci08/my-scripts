#!/usr/bin/env bash
set -Eeuo pipefail
trap 'on_exit' EXIT

## CONSTANTS ###################################################################
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly LOG_PREFIX="[K3S-WORKER]"

## CONFIGURATION VARIABLES #####################################################
K3S_TOKEN="${K3S_TOKEN:-changeme}"               # Must match cluster token
K3S_SERVER_IP="${K3S_SERVER_IP:-10.1.0.10}"     # Any control plane node IP

## FUNCTIONS ###################################################################

log_header() {
    printf '\n%*s\n' "${COLUMNS:-60}" '' | tr ' ' '='
    echo "${LOG_PREFIX} ➤ $*"
    printf '%*s\n' "${COLUMNS:-60}" '' | tr ' ' '='
}

log_info() {
    echo "$(date +"%Y-%m-%dT%H:%M:%S%:z") - [INFO] ${LOG_PREFIX} $*"
}

log_error() {
    echo "$(date +"%Y-%m-%dT%H:%M:%S%:z") - [ERROR] ${LOG_PREFIX} $*" >&2
}

on_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Installation failed. Check logs for details."
    fi
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$ID"
    else
        log_error "Cannot detect OS"
        exit 1
    fi
}

install_dependencies() {
    local os=$(check_os)
    log_info "Installing dependencies for $os"

    case $os in
        ubuntu|debian)
            sudo apt-get update
            sudo apt-get install -y curl
            ;;
        opensuse*|sles)
            sudo zypper --non-interactive install curl
            ;;
        *)
            log_error "Unsupported OS: $os"
            exit 1
            ;;
    esac
}

join_cluster() {
    log_header "Joining cluster as worker node"

    curl -sfL https://get.k3s.io | \
    K3S_URL="https://${K3S_SERVER_IP}:6443" \
    K3S_TOKEN="$K3S_TOKEN" sh -s - agent
}

## MAIN ########################################################################

main() {
    install_dependencies
    join_cluster
    log_header "Worker node joined successfully"
}

main "$@"
