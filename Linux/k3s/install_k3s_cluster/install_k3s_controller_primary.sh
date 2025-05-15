#!/usr/bin/env bash
set -Eeuo pipefail
trap 'on_exit' EXIT

## CONSTANTS ###################################################################
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly LOG_PREFIX="[K3S-PRIMARY]"
readonly KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
readonly INGRESS_NGINX_BASE_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx"

## CONFIGURATION VARIABLES #####################################################
K3S_TOKEN="${K3S_TOKEN:-changeme}"
K3S_SERVER_IP="${K3S_SERVER_IP:-10.1.0.10}"
K3S_TLS_SAN="${K3S_TLS_SAN:-$K3S_SERVER_IP}"
K3S_CLUSTER_CIDR="${K3S_CLUSTER_CIDR:-172.17.0.0/16}"
K3S_SERVICE_CIDR="${K3S_SERVICE_CIDR:-172.18.0.0/16}"
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.8.2}"

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

setup_kubeconfig() {
    local user_home=$(eval echo ~${SUDO_USER:-$USER})
    mkdir -p "$user_home/.kube"
    sudo cp "$KUBECONFIG_PATH" "$user_home/.kube/config"
    sudo chown $(id -u):$(id -g) "$user_home/.kube/config"
    chmod 600 "$user_home/.kube/config"
    export KUBECONFIG="$user_home/.kube/config"
}

wait_for_api() {
    local timeout=300
    log_info "Waiting for Kubernetes API (timeout: ${timeout}s)"
    for ((i=0; i<timeout; i++)); do
        if kubectl get nodes &>/dev/null; then
            log_info "Kubernetes API available after ${i}s"
            return 0
        fi
        sleep 1
    done
    log_error "Timeout waiting for Kubernetes API"
    exit 1
}

install_k3s() {
    log_header "Installing K3s control plane"
    curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_TOKEN" sh -s - server \
        --cluster-init \
        --tls-san="$K3S_TLS_SAN" \
        --disable traefik \
        --cluster-cidr="$K3S_CLUSTER_CIDR" \
        --service-cidr="$K3S_SERVICE_CIDR" \
        --write-kubeconfig-mode 644

    systemctl is-active k3s || {
        log_error "K3s service failed to start"
        journalctl -u k3s --no-pager -n 50
        exit 1
    }
}

install_ingress() {
    log_header "Deploying Ingress Controller"
    kubectl apply -f "$INGRESS_NGINX_BASE_URL/$INGRESS_NGINX_VERSION/deploy/static/provider/cloud/deploy.yaml"
    kubectl -n ingress-nginx wait --for=condition=Available deployment/ingress-nginx-controller --timeout=5m
}

## MAIN ########################################################################

main() {
    install_dependencies
    install_k3s
    setup_kubeconfig
    wait_for_api
    install_ingress
    log_header "Cluster deployment completed"
}

main "$@"
