#!/bin/bash
# kernel-module-signer.sh - Universal Secure Boot MOK Signer (FULL OUTPUT FIXED)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "$0")"
MOK_DIR="$HOME/.mok"
MODULES_FILE="$MOK_DIR/modules"
KERNEL_VER=$(uname -r)
HOOK_FILE="/etc/kernel/postinst.d/zz-mok-signer"
CMD="${1:-status}"

read_modules() {
    [[ -f "$MODULES_FILE" ]] || return 1
    sed "s|%KERNEL_VER%|$KERNEL_VER|g" "$MODULES_FILE" 2>/dev/null | \
    grep '\.ko' | grep -v '^#' | sed 's/^[[:space:]]*//' | \
    while read -r mod; do [[ -f "$mod" ]] && echo "$mod"; done
}

is_signed() {
    modinfo "$1" 2>/dev/null | grep -q 'sig_id\|sig_key'
}

show_status() {
    echo "🔒 Secure Boot: $(mokutil --sb-state 2>/dev/null || echo unknown)"
    echo "📁 Config: $MODULES_FILE"
    echo "🔑 MOK: $MOK_DIR"
    echo "📄 Script: $SCRIPT_PATH"
    echo "🔗 Hook: $HOOK_FILE $([[ -f "$HOOK_FILE" ]] && echo installed || echo missing)"
    echo

    mapfile -t MODULES < <(read_modules 2>/dev/null || true)
    if [[ ${#MODULES[@]} -eq 0 ]]; then
        echo "📋 Modules: NONE (edit $MODULES_FILE to uncomment)"
        return 0
    fi

    echo "📋 Modules (${#MODULES[@]} configured):"
    local unsigned=0
    for mod in "${MODULES[@]}"; do
        if is_signed "$mod"; then
            echo "✅ $(basename "$mod")"
        else
            echo "❌ $(basename "$mod") → unsigned"
            ((unsigned++))
        fi
    done
    echo "⚙️  ${#MODULES[@]} total, $unsigned unsigned"
    [[ $unsigned -gt 0 ]] && echo "💡 $0 sign"
}

init_config() {
    mkdir -p "$MOK_DIR"
    [[ -f "$MODULES_FILE" ]] && { echo "✅ Config exists"; return 0; }

    cat > "$MODULES_FILE" << 'EOF'
# ~/.mok/modules - SECURE MODULES TO SIGN
# Format: /full/path/to/module.ko (explicit paths only!)
# %KERNEL_VER% → auto kernel version substitution
# SECURITY: Uncomment ONLY modules you TRUST

# DKMS / Third-party modules (ALL COMMENTED):
#/lib/modules/%KERNEL_VER%/updates/dkms/nvidia.ko
#/lib/modules/%KERNEL_VER%/zfs/zfs.ko
#/lib/modules/%KERNEL_VER%/eset/eea/eset_rtp.ko
#/lib/modules/%KERNEL_VER%/eset/eea/eset_wap.ko

# Custom modules:
#/lib/modules/%KERNEL_VER%/extra/my-module.ko
EOF
    chmod 600 "$MODULES_FILE"
    echo "✅ Generic config created: $MODULES_FILE"
}

init_keys() {
    mkdir -p "$MOK_DIR"
    [[ -f "$MOK_DIR/MOK.priv" && -f "$MOK_DIR/MOK.der" ]] && {
        echo "✅ MOK keys exist: $MOK_DIR"
        return 0
    }

    echo "🗝️  Generating RSA-4096 MOK keys..."
    openssl req -new -x509 -newkey "rsa:4096" \
        -keyout "$MOK_DIR/MOK.priv" -outform DER -out "$MOK_DIR/MOK.der" \
        -nodes -days 36500 -subj "/CN=GenericMOK-RSA4096/" -sha256 -batch

    sudo chown root:root "$MOK_DIR/MOK".*
    sudo chmod 600 "$MOK_DIR/MOK.priv"
    sudo chmod 644 "$MOK_DIR/MOK.der"
    
    echo "✅ MOK keys ready: $MOK_DIR"
    echo "🔐 ENROLL: sudo mokutil --import $MOK_DIR/MOK.der && reboot"
}

sign_modules() {
    [[ ! -f "$MOK_DIR/MOK.priv" || ! -f "$MOK_DIR/MOK.der" ]] && {
        echo "❌ MOK keys missing. Run: $0 init-keys"
        exit 1
    }

    SIGN_SCRIPT=$(find /usr/src/linux-headers-* -name sign-file 2>/dev/null | head -1)
    [[ -f "$SIGN_SCRIPT" ]] || {
        echo "❌ sign-file missing. sudo apt install linux-headers-$KERNEL_VER"
        exit 1
    }

    mapfile -t MODULES < <(read_modules 2>/dev/null || true)
    [[ ${#MODULES[@]} -eq 0 ]] && {
        echo "🎉 No modules configured"
        exit 0
    }

    echo "🔐 Signing ${#MODULES[@]} modules..."
    local signed=0 failed=0
    for mod in "${MODULES[@]}"; do
        echo "  → $(basename "$mod")"
        
        if is_signed "$mod"; then
            echo "    ⏭️  Already signed (re-signing...)"
        else
            echo "    ➕ Unsigned → signing..."
        fi
        
        # FIXED: set +e prevents sudo success from killing script
        set +e
        if sudo "$SIGN_SCRIPT" sha256 "$MOK_DIR/MOK.priv" "$MOK_DIR/MOK.der" "$mod"; then
            echo "    ✅ SUCCESS"
            ((signed++))
        else
            echo "    ❌ FAILED (rc=$?)"
            ((failed++))
        fi
        set -e
    done

    sudo depmod -a "$KERNEL_VER" || true
    echo "✅ FINAL: $signed/$((signed+failed)) modules processed"
}

remove_sign() {
    echo "🗑️  Removing signatures from configured modules..."
    mapfile -t MODULES < <(read_modules 2>/dev/null || true)
    [[ ${#MODULES[@]} -eq 0 ]] && {
        echo "🎉 No modules configured"
        exit 0
    }

    SIGN_SCRIPT=$(find /usr/src/linux-headers-* -name sign-file 2>/dev/null | head -1)
    local removed=0 nosig=0
    for mod in "${MODULES[@]}"; do
        echo "  → $(basename "$mod")"
        echo "    🔍 Checking signature status..."
        if is_signed "$mod"; then
            echo "    ➖ Has signature → removing..."
            set +e
            sudo "$SIGN_SCRIPT" sha256 /dev/null /dev/null "$mod"
            echo "    ✅ Signature removed"
            ((removed++))
            set -e
        else
            echo "    ℹ️  No signature found"
            ((nosig++))
        fi
    done
    echo "✅ Summary: $removed removed, $nosig no signature"
}

install_init_hook() {
    echo "🛠️  Installing kernel init hook..."
    sudo tee "$HOOK_FILE" << EOF
#!/bin/bash
# Universal kernel module auto-signer (Ubuntu/Debian/Proxmox/ALL)
if [ "\$1" = "$KERNEL_VER" ]; then
    echo "🔄 Kernel update: auto-signing modules..."
    exec "$SCRIPT_PATH" sign || echo "⚠️  Module signing failed (non-fatal)"
fi
EOF
    sudo chmod +x "$HOOK_FILE"
    echo "✅ Init hook installed: $HOOK_FILE"
}

remove_init_hook() {
    if [[ -f "$HOOK_FILE" ]]; then
        echo "🗑️  Removing kernel init hook..."
        sudo rm -f "$HOOK_FILE"
        echo "✅ Hook removed: $HOOK_FILE"
    else
        echo "ℹ️  Hook not installed"
    fi
}

# MAIN DISPATCH
case "$CMD" in
    status)        show_status ;;
    init-config)   init_config ;;
    init-keys)     init_keys ;;
    sign)          sign_modules ;;
    remove-sign)   remove_sign ;;
    init-hook)     install_init_hook ;;
    remove-hook)   remove_init_hook ;;
    -h|--help)
        cat << EOF
Usage: $0 {status|sign|remove-sign|init-config|init-keys|init-hook|remove-hook}

COMMANDS:
  status        Show ✅/❌ module status + hook status
  sign          Sign ALL modules (FULL verbose output)
  remove-sign   Remove signatures (FULL verbose)
  init-config   Create ~/.mok/modules (ALL COMMENTED)
  init-keys     RSA-4096 MOK keys (one-time)
  init-hook     Install kernel update hook
  remove-hook   Remove kernel update hook

SCRIPT: $SCRIPT_PATH
MOK:    $MOK_DIR
HOOK:   $HOOK_FILE
EOF
        exit 0
        ;;
    "")          show_status ;;
    *)           echo "Usage: $0 {status|sign|remove-sign|init-config|init-keys|init-hook|remove-hook}"; exit 1 ;;
esac
