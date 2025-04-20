#!/bin/bash

VM_NAME="$1"

if [ -z "$VM_NAME" ]; then
  echo "Usage: $0 <VM_NAME>"
  exit 1
fi

# Power on the VM if it's not already running
if ! virsh domstate "$VM_NAME" | grep -q running; then
  virsh start "$VM_NAME"
fi

# Open the console in virt-manager
virt-manager --connect qemu:///system --show-domain-console "$VM_NAME"
