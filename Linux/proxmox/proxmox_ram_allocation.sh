#!/usr/bin/env bash
set -euo pipefail
shopt -s lastpipe          # let mapfile read from pipes

# -----------------------------------------------------------------------------
#  CONFIGURATION
# -----------------------------------------------------------------------------
THRESHOLD=90               # Warn when >THRESHOLD % of host RAM is allocated

# -----------------------------------------------------------------------------
#  UTILITY FUNCTIONS
# -----------------------------------------------------------------------------
log() { printf '%b\n' "$*"; }
err() { log "ERROR: $*" >&2; exit 1; }

get_host_ram_mb() {
    free -m | awk '/^Mem:/ {print $2}'
}

# $1 = ID, $2 = qm|pct → echoes “name;ram”
get_config_values() {
    local id=$1 type=$2 cfg name ram

    if [[ $type == qm ]]; then
        cfg=$(qm config "$id")
        ram=$(awk -F': ' '/^memory:/  {print $2; exit}'  <<<"$cfg")
        name=$(awk -F': ' '/^name:/    {print $2; exit}'  <<<"$cfg")
    else                              # pct
        cfg=$(pct config "$id")
        ram=$(awk -F': ' '/^memory:/  {print $2; exit}'  <<<"$cfg")
        name=$(awk -F': ' '/^hostname:/{print $2; exit}'  <<<"$cfg")
        ram=${ram:-0}                 # 0 = unlimited/not set
    fi
    printf '%s;%s\n' "${name:-Unknown}" "${ram:-0}"
}

print_header() { printf "\n%-8s %-25s %-10s\n" "ID" "Name" "RAM (MB)"; }

collect_running_ids() {
    local tool=$1
    if [[ $tool == pct ]]; then
        mapfile -t ids < <(pct list | awk '$3=="running" && $1~/^[0-9]+$/{print $1}')
    else
        mapfile -t ids < <(qm  list | awk '$3=="running" && $1~/^[0-9]+$/{print $1}')
    fi
    printf '%s\n' "${ids[@]:-}"
}

# -----------------------------------------------------------------------------
#  MAIN
# -----------------------------------------------------------------------------
main() {
    local host_ram total=0 pct
    host_ram=$(get_host_ram_mb)
    [[ -n $host_ram && $host_ram -gt 0 ]] || err "Cannot read host RAM"

    # ---------- QEMU VMs ----------
    ids=$(collect_running_ids qm)
    if [[ -z $ids ]]; then
        log "No running QEMU VMs."
    else
        log "Running QEMU VMs:"
        print_header
        while read -r vmid; do
            [[ -z $vmid ]] && continue
            IFS=';' read -r name ram < <(get_config_values "$vmid" qm)
            printf "%-8s %-25s %-10s\n" "$vmid" "$name" "$ram"
            (( total += ram ))
        done <<<"$ids"
    fi

    # ---------- LXC containers ----------
    ids=$(collect_running_ids pct)
    if [[ -z $ids ]]; then
        log "\nNo running LXC containers."
    else
        log "\nRunning LXC containers:"
        print_header
        while read -r ctid; do
            [[ -z $ctid ]] && continue
            IFS=';' read -r name ram < <(get_config_values "$ctid" pct)
            printf "%-8s %-25s %-10s\n" "$ctid" "$name" "$ram"
            (( total += ram ))
        done <<<"$ids"
    fi

    # ---------- Summary ----------
    pct=$(( total * 100 / host_ram ))
    log "\nHost RAM:        $host_ram MB"
    log "Allocated RAM:   $total MB"
    log "Allocation ratio: $pct%"

    (( pct >= THRESHOLD )) && log "WARNING: allocation ≥ ${THRESHOLD}%!"
}

main "$@"