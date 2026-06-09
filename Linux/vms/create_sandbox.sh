#!/usr/bin/env bash
set -Eeuo pipefail

## CONSTANTS ###################################################################
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly VM_SANDBOX_DIR="${HOME}/vm-sandbox"
readonly LIBVIRT_IMAGE_DIR="/var/lib/libvirt/images"
readonly USER_DATA_FILE="${VM_SANDBOX_DIR}/user-data"
readonly META_DATA_FILE="${VM_SANDBOX_DIR}/meta-data"
readonly REQUIRED_BINS=("wget" "virt-install" "cloud-localds" "virsh" "sudo")

## DISTRO-SPECIFIC VARS (set by configure_distro) ##############################
IMAGE_URL=""
LOCAL_IMAGE_FILE=""
DEFAULT_SSH_USER=""
DEFAULT_SSH_PASSWORD=""
OS_VARIANT=""
VM_NAME_BASE=""
LOG_PREFIX="[CLOUD_VM]"

## DEFAULTS ####################################################################
DEFAULT_VM_RAM_MB=2048
DEFAULT_VM_VCPUS=2
DEFAULT_VM_DISK_GB=20

## DYNAMIC VARIABLES ##########################################################
DISTRO="opensuse"
NON_INTERACTIVE=false
VM_NAME=""
VM_RAM_MB=""
VM_VCPUS=""
VM_DISK_GB=""
SSH_USER=""
SSH_PASSWORD=""
SSH_PUB_KEY="${SSH_PUB_KEY:-}"
LIBVIRT_IMAGE_FILE=""
CLOUD_INIT_ISO=""

## FUNCTIONS ###################################################################

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [-d|--distro DISTRO] [-y|--yes] [-h|--help]

Create a cloud VM using libvirt/KVM.

Options:
  -d, --distro  Distro to install (default: opensuse)
                Supported: opensuse, almalinux8, almalinux9
  -y, --yes     Non-interactive mode, use all defaults (SSH_PUB_KEY env var required)
  -h, --help    Show this help message

Environment variables:
  SSH_PUB_KEY   SSH public key to inject into the VM
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--distro)
                shift
                [[ $# -eq 0 ]] && { echo "ERROR: --distro requires an argument" >&2; exit 1; }
                DISTRO="$1"
                ;;
            -y|--yes) NON_INTERACTIVE=true ;;
            -h|--help) usage ;;
            *) log_error "Unknown argument: $1"; usage ;;
        esac
        shift
    done
}

configure_distro() {
    case "$DISTRO" in
        opensuse)
            IMAGE_URL="https://download.opensuse.org/repositories/Cloud:/Images:/Leap_15.6/images/openSUSE-Leap-15.6.x86_64-NoCloud.qcow2"
            LOCAL_IMAGE_FILE="${VM_SANDBOX_DIR}/opensuse-leap-15.6.qcow2"
            DEFAULT_SSH_USER="opensuse"
            DEFAULT_SSH_PASSWORD="opensuse"
            OS_VARIANT="opensuse15.3"
            VM_NAME_BASE="opensuse-cloud"
            LOG_PREFIX="[OPENSUSE_CLOUD_VM]"
            ;;
        almalinux9)
            IMAGE_URL="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
            LOCAL_IMAGE_FILE="${VM_SANDBOX_DIR}/almalinux-9-cloud.qcow2"
            DEFAULT_SSH_USER="almalinux"
            DEFAULT_SSH_PASSWORD="almalinux"
            OS_VARIANT="almalinux9"
            VM_NAME_BASE="almalinux9-cloud"
            LOG_PREFIX="[ALMALINUX9_CLOUD_VM]"
            ;;
        *)
            echo "ERROR: Unknown distro '$DISTRO'. Supported: opensuse, almalinux9, almalinux8" >&2
            exit 1
            ;;
    esac
}

find_unique_vm_name() {
    local name="$VM_NAME_BASE"
    local counter=1

    while virsh dominfo "$name" &>/dev/null; do
        name="${VM_NAME_BASE}-${counter}"
        ((counter++))
    done

    echo "$name"
}

detect_ssh_pubkey() {
    if [[ -n "$SSH_PUB_KEY" ]]; then
        echo "$SSH_PUB_KEY"
        return
    fi
    local key_file
    for key_file in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
        if [[ -f "$key_file" ]]; then
            cat "$key_file"
            return
        fi
    done
    echo ""
}

log_header() {
    printf '\n%*s\n' "${COLUMNS:-60}" '' | tr ' ' '='
    echo "${LOG_PREFIX} ➤ $*"
    printf '%*s\n' "${COLUMNS:-60}" '' | tr ' ' '='
}

log_info() {
    echo "$(date +"%Y-%m-%dT%H:%M:%S%:z") - [INFO]  ${LOG_PREFIX} $*"
}

log_error() {
    echo "$(date +"%Y-%m-%dT%H:%M:%S%:z") - [ERROR] ${LOG_PREFIX} $*" >&2
}

prompt() {
    local question="$1"
    local default="$2"
    local varname="$3"
    local secret="${4:-false}"

    if [[ "$NON_INTERACTIVE" == true ]]; then
        printf -v "$varname" '%s' "$default"
        return
    fi

    local display_default=""
    [[ -n "$default" ]] && display_default=" [${default}]"

    if [[ "$secret" == true ]]; then
        read -rsp "${question}${display_default}: " input
        echo
    else
        read -rp "${question}${display_default}: " input
    fi

    printf -v "$varname" '%s' "${input:-$default}"
}

validate_integer() {
    local value="$1"
    local label="$2"
    if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
        log_error "$label must be a positive integer, got: '$value'"
        exit 1
    fi
}

validate_non_empty() {
    local value="$1"
    local label="$2"
    if [[ -z "$value" ]]; then
        log_error "$label cannot be empty"
        exit 1
    fi
}

gather_inputs() {
    local default_vm_name
    default_vm_name="$(find_unique_vm_name)"
    local detected_key
    detected_key="$(detect_ssh_pubkey)"

    echo ""
    echo "Configure your ${DISTRO} cloud VM:"
    echo "  Press Enter to accept [default] values."
    echo ""

    prompt "VM name"          "$default_vm_name"         VM_NAME
    prompt "RAM (MB)"         "$DEFAULT_VM_RAM_MB"        VM_RAM_MB
    prompt "vCPUs"            "$DEFAULT_VM_VCPUS"         VM_VCPUS
    prompt "Disk size (GB)"   "$DEFAULT_VM_DISK_GB"       VM_DISK_GB
    prompt "SSH user"         "$DEFAULT_SSH_USER"         SSH_USER
    prompt "SSH password"     "$DEFAULT_SSH_PASSWORD"     SSH_PASSWORD  true
    prompt "SSH public key"   "$detected_key"             SSH_PUB_KEY

    validate_non_empty "$VM_NAME"       "VM name"
    validate_integer   "$VM_RAM_MB"     "RAM"
    validate_integer   "$VM_VCPUS"      "vCPUs"
    validate_integer   "$VM_DISK_GB"    "Disk size"
    validate_non_empty "$SSH_USER"      "SSH user"
    validate_non_empty "$SSH_PUB_KEY"   "SSH public key"
}

confirm_summary() {
    [[ "$NON_INTERACTIVE" == true ]] && return

    echo ""
    echo "Summary:"
    printf "  %-20s %s\n" "Distro:"        "$DISTRO"
    printf "  %-20s %s\n" "VM Name:"       "$VM_NAME"
    printf "  %-20s %s MB\n" "RAM:"         "$VM_RAM_MB"
    printf "  %-20s %s\n" "vCPUs:"         "$VM_VCPUS"
    printf "  %-20s %s GB\n" "Disk:"        "$VM_DISK_GB"
    printf "  %-20s %s\n" "SSH User:"      "$SSH_USER"
    printf "  %-20s %s\n" "SSH Password:"  "********"
    printf "  %-20s %s\n" "SSH Key:"       "${SSH_PUB_KEY:0:60}..."
    echo ""

    read -rp "Proceed? [Y/n]: " confirm
    case "${confirm,,}" in
        n|no) echo "Aborted."; exit 0 ;;
    esac
}

validate_binaries() {
    for bin in "${REQUIRED_BINS[@]}"; do
        if ! command -v "$bin" &>/dev/null; then
            log_error "Required binary '$bin' is not installed or not in PATH"
            exit 1
        fi
    done
}

prepare_sandbox_dir() {
    if [[ ! -d "$VM_SANDBOX_DIR" ]]; then
        log_info "Creating VM sandbox directory at $VM_SANDBOX_DIR"
        mkdir -p "$VM_SANDBOX_DIR"
    else
        log_info "Using existing VM sandbox directory: $VM_SANDBOX_DIR"
    fi
}

download_image() {
    if [[ -f "$LOCAL_IMAGE_FILE" ]]; then
        log_info "Base image already exists at $LOCAL_IMAGE_FILE, skipping download."
    else
        log_info "Downloading ${DISTRO} cloud image to $LOCAL_IMAGE_FILE ..."
        wget --show-progress -O "$LOCAL_IMAGE_FILE" "$IMAGE_URL"
        log_info "Download completed."
    fi
}

copy_image_to_libvirt() {
    if [[ -f "$LIBVIRT_IMAGE_FILE" ]]; then
        log_info "Libvirt image already exists at $LIBVIRT_IMAGE_FILE, skipping copy."
    else
        log_info "Copying and resizing image to libvirt storage: $LIBVIRT_IMAGE_FILE"
        sudo cp "$LOCAL_IMAGE_FILE" "$LIBVIRT_IMAGE_FILE"
        sudo qemu-img resize "$LIBVIRT_IMAGE_FILE" "${VM_DISK_GB}G"
        sudo chown libvirt-qemu:kvm "$LIBVIRT_IMAGE_FILE"
        sudo chmod 640 "$LIBVIRT_IMAGE_FILE"
        log_info "Image copied, resized to ${VM_DISK_GB}GB, and permissions set."
    fi
}

create_cloud_init_iso() {
    log_info "Creating cloud-init user-data and meta-data files..."

    cat > "$USER_DATA_FILE" <<EOF
#cloud-config
password: $SSH_PASSWORD
chpasswd:
  list: |
    $SSH_USER:$SSH_PASSWORD
  expire: False
ssh_pwauth: True
users:
  - name: $SSH_USER
    ssh-authorized-keys:
      - $SSH_PUB_KEY
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    shell: /bin/bash
    lock_passwd: false
ssh:
  allow_password_authentication: true
EOF

    cat > "$META_DATA_FILE" <<EOF
instance-id: iid-${VM_NAME}
local-hostname: ${VM_NAME}
EOF

    log_info "Generating cloud-init ISO at $CLOUD_INIT_ISO ..."
    cloud-localds "$CLOUD_INIT_ISO" "$USER_DATA_FILE" "$META_DATA_FILE"
    log_info "Cloud-init ISO created."
}

import_and_start_vm() {
    log_info "Starting VM import and launch with virt-install..."

    virt-install \
        --name "$VM_NAME" \
        --ram "$VM_RAM_MB" \
        --vcpus "$VM_VCPUS" \
        --disk path="$LIBVIRT_IMAGE_FILE",format=qcow2,bus=virtio \
        --disk path="$CLOUD_INIT_ISO",device=cdrom \
        --import \
        --os-variant "$OS_VARIANT" \
        --network network=default \
        --graphics none \
        --noautoconsole

    log_info "VM '$VM_NAME' started."
}

## MAIN ########################################################################

parse_args "$@"
configure_distro
log_header "${DISTRO} Cloud VM Setup"

validate_binaries
gather_inputs
confirm_summary

LIBVIRT_IMAGE_FILE="${LIBVIRT_IMAGE_DIR}/${VM_NAME}.qcow2"
CLOUD_INIT_ISO="${VM_SANDBOX_DIR}/${VM_NAME}-cloud-init.iso"
prepare_sandbox_dir
download_image
copy_image_to_libvirt
create_cloud_init_iso
import_and_start_vm

log_header "Setup complete!"
log_info "Distro:    $DISTRO"
log_info "VM Name:   $VM_NAME"
log_info "Disk:      $LIBVIRT_IMAGE_FILE"
log_info "SSH:       ssh ${SSH_USER}@<VM_IP>"
log_info "Tip: run 'virsh domifaddr $VM_NAME' once the VM boots to get the IP."
