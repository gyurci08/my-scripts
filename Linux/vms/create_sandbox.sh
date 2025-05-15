#!/usr/bin/env bash
set -Eeuo pipefail

## CONSTANTS ###################################################################
readonly SCRIPT_DIR="$(dirname "$(realpath -s "${BASH_SOURCE[0]}")")"
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly CURRENT_DATE="$(date +%Y-%m-%d_%H-%M-%S)"
readonly LOG_PREFIX="[OPEN_SUSE_CLOUD_VM]"
readonly VM_SANDBOX_DIR="${HOME}/vm-sandbox"
readonly IMAGE_URL="https://download.opensuse.org/repositories/Cloud:/Images:/Leap_15.6/images/openSUSE-Leap-15.6.x86_64-NoCloud.qcow2"
readonly LOCAL_IMAGE_FILE="${VM_SANDBOX_DIR}/opensuse-cloud.qcow2"
readonly LIBVIRT_IMAGE_DIR="/var/lib/libvirt/images"
readonly USER_DATA_FILE="${VM_SANDBOX_DIR}/user-data"
readonly META_DATA_FILE="${VM_SANDBOX_DIR}/meta-data"
readonly REQUIRED_BINS=("wget" "virt-install" "cloud-localds" "virsh" "sudo")

# Customize these:
readonly VM_RAM_MB=2048
readonly VM_VCPUS=2
readonly SSH_USER="opensuse"
readonly SSH_PASSWORD="opensuse"
readonly SSH_PUB_KEY="${SSH_PUB_KEY:?Please export SSH_PUB_KEY with your public SSH key}"

## DYNAMIC VARIABLES ##########################################################
VM_NAME=""
LIBVIRT_IMAGE_FILE=""
CLOUD_INIT_ISO=""

## FUNCTIONS ###################################################################

find_unique_vm_name() {
    local base_name="opensuse-cloud"
    local name="$base_name"
    local counter=1

    while virsh dominfo "$name" &>/dev/null; do
        name="${base_name}-${counter}"
        ((counter++))
    done

    echo "$name"
}

log_header() {
    printf '\n%*s\n' "${COLUMNS:-50}" '' | tr ' ' '='
    echo "${LOG_PREFIX} ➤ $*"
    printf '%*s\n' "${COLUMNS:-50}" '' | tr ' ' '='
}

log_info() {
    echo "$(date +"%Y-%m-%dT%H:%M:%S%:z") - [INFO] ${LOG_PREFIX} $*"
}

log_error() {
    echo "$(date +"%Y-%m-%dT%H:%M:%S%:z") - [ERROR] ${LOG_PREFIX} $*" >&2
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
        log_info "Using existing VM sandbox directory at $VM_SANDBOX_DIR"
    fi
}

download_image() {
    if [[ -f "$LOCAL_IMAGE_FILE" ]]; then
        log_info "Base image already exists at $LOCAL_IMAGE_FILE, skipping download."
    else
        log_info "Downloading openSUSE cloud image to $LOCAL_IMAGE_FILE ..."
        wget -O "$LOCAL_IMAGE_FILE" "$IMAGE_URL"
        log_info "Download completed."
    fi
}

copy_image_to_libvirt() {
    if [[ -f "$LIBVIRT_IMAGE_FILE" ]]; then
        log_info "Libvirt image already exists at $LIBVIRT_IMAGE_FILE, skipping copy."
    else
        log_info "Copying image to libvirt storage pool directory: $LIBVIRT_IMAGE_FILE"
        sudo cp "$LOCAL_IMAGE_FILE" "$LIBVIRT_IMAGE_FILE"
        sudo chown libvirt-qemu:kvm "$LIBVIRT_IMAGE_FILE"
        sudo chmod 640 "$LIBVIRT_IMAGE_FILE"
        log_info "Image copied and permissions set."
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

    log_info "Generating cloud-init ISO image at $CLOUD_INIT_ISO ..."
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
        --os-variant opensuse15.3 \
        --network network=default \
        --graphics none \
        --noautoconsole

    log_info "VM '$VM_NAME' started."
}

## MAIN ########################################################################

log_header "Starting openSUSE Cloud VM Setup"

# Determine unique VM name and paths
VM_NAME="$(find_unique_vm_name)"
LIBVIRT_IMAGE_FILE="${LIBVIRT_IMAGE_DIR}/${VM_NAME}.qcow2"
CLOUD_INIT_ISO="${VM_SANDBOX_DIR}/${VM_NAME}-cloud-init.iso"

validate_binaries
prepare_sandbox_dir
download_image
copy_image_to_libvirt
create_cloud_init_iso
import_and_start_vm

log_header "Setup complete! You can SSH into the VM using:"
log_info "ssh $SSH_USER@<VM_IP> (replace <VM_IP> with the VM's IP address)"
log_info "VM Name: $VM_NAME"
log_info "Disk Image: $LIBVIRT_IMAGE_FILE"
