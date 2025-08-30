#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
#
# Production-Ready Port Forwarding Controller (for iptables-nft)
#
# Description:
#   A robust script to manage iptables NAT rules on a modern system with the
#   iptables-nft compatibility layer.
#
# Features:
#   - NAT PREROUTING: Redirects incoming UDP traffic.
#   - Hairpin NAT: Optionally allows internal clients to use the public IP.
#   - Interface Validation: Checks that the specified network interface exists.
#
# Usage:
#   Run as root.
#   ./script.sh add | remove | list
#
###############################################################################

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE}")"
readonly LOG_PREFIX="[SERVICE_FORWARD_UDP]"
readonly IPTABLES_BIN="iptables"
readonly IP_BIN="ip"
readonly IFACE="ens18" # IMPORTANT: Adjust to your public-facing network interface

#===[ CONFIGURATION: DEFINE YOUR UDP FORWARDING RULES HERE ]==================#
declare -a FORWARDINGS=(
    "udp:185.65.68.179:58423:10.0.1.106:58423"
    "udp:185.65.68.179:20001-20999:10.0.1.105:20001-20999"
)

readonly INTERNAL_NET_CIDR="10.0.1.0/24"

#---[ Logging & System Check Functions ]--------------------------------------#
log_info()   { echo "$(date +%FT%T%z) ${LOG_PREFIX} [INFO] $*"; }
log_error()  { >&2 echo "$(date +%FT%T%z) ${LOG_PREFIX} [ERROR] $*"; }
log_header() { echo -e "\n====================  $*  ====================\n"; }

ensure_root() { (( EUID == 0 )) || { log_error "This script must be run as root."; exit 1; }; }
ensure_bin() { command -v "$1" &>/dev/null || { log_error "Missing required binary: $1."; exit 1; }; }
ensure_interface() { "$IP_BIN" link show "$IFACE" &>/dev/null || { log_error "Network interface '$IFACE' not found."; exit 1; }; }

#---[ Core Rule Processing & Management ]-------------------------------------#

manage_rule() {
    local action="$1" desc="$2"; shift 2
    local op_flag=$([[ "$action" == "add" ]] && echo "-A" || echo "-D")
    local cmd_args=("$@")
    local check_args=("${cmd_args[@]/$op_flag/-C}")

    if ! "$IPTABLES_BIN" "${check_args[@]}" &>/dev/null; then
        if [[ "$action" == "add" ]]; then
            "$IPTABLES_BIN" "${cmd_args[@]}" && log_info "Added   $desc" || log_error "FAILED to add   $desc"
        else
            log_info "Absent  $desc"
        fi
    else
        if [[ "$action" == "remove" ]]; then
            "$IPTABLES_BIN" "${cmd_args[@]}" && log_info "Removed $desc" || log_error "FAILED to remove $desc"
        else
            log_info "Exists  $desc"
        fi
    fi
}

process_rule() {
    local rule_string="$1" callback="$2" action="$3"
    IFS=':' read -r proto src_ip src_port dst_ip dst_port <<< "$rule_string"
    if [[ -z "$proto" || -z "$src_ip" || -z "$src_port" || -z "$dst_ip" || -z "$dst_port" ]]; then
        log_error "Skipping malformed rule: $rule_string"
        return
    fi
    "$callback" "$proto" "$src_ip" "$src_port" "$dst_ip" "$dst_port" "$action"
}

handle_nat_rule() {
    local proto="$1" src_ip="$2" src_port="$3" dst_ip="$4" dst_port="$5" action="$6"
    [[ "$src_ip" == "any" ]] && src_ip="0.0.0.0/0"
    manage_rule "$action" "NAT rule for $proto to $dst_ip:$dst_port" \
        -t nat -A PREROUTING -i "$IFACE" -p "$proto" --destination "$src_ip" --dport "${src_port//-/:}" \
        -j DNAT --to-destination "${dst_ip}:${dst_port}"
}

handle_hairpin_nat() {
    local action="$1"
    if [[ -n "$INTERNAL_NET_CIDR" ]]; then
        manage_rule "$action" "Hairpin NAT rule" \
            -t nat -A POSTROUTING -s "$INTERNAL_NET_CIDR" -d "$INTERNAL_NET_CIDR" -j MASQUERADE
    fi
}

#---[ User Command Functions ]------------------------------------------------#
apply_all_rules() {
    log_header "Applying UDP NAT Rules"
    for rule in "${FORWARDINGS[@]}"; do
        process_rule "$rule" "handle_nat_rule" "add"
    done
    handle_hairpin_nat "add"
}

remove_all_rules() {
    log_header "Removing UDP NAT Rules"
    for rule in "${FORWARDINGS[@]}"; do
        process_rule "$rule" "handle_nat_rule" "remove"
    done
    handle_hairpin_nat "remove"
}

list_all_rules() {
    log_header "Listing Active Defined UDP NAT Rules"
    local found_any=false
    for rule in "${FORWARDINGS[@]}"; do
        IFS=':' read -r proto src_ip src_port dst_ip dst_port <<< "$rule"
        local check_src_ip="$src_ip"
        [[ "$check_src_ip" == "any" ]] && check_src_ip="0.0.0.0/0"
        if "$IPTABLES_BIN" -t nat -C PREROUTING -i "$IFACE" -p "$proto" --destination "$check_src_ip" --dport "${src_port//-/:}" -j DNAT --to-destination "${dst_ip}:${dst_port}" &>/dev/null; then
            printf " [ACTIVE] %-4s %s:%s -> %s:%s\n" "$proto" "$src_ip" "$src_port" "$dst_ip" "$dst_port"
            found_any=true
        fi
    done

    if [[ -n "$INTERNAL_NET_CIDR" ]]; then
        if "$IPTABLES_BIN" -t nat -C POSTROUTING -s "$INTERNAL_NET_CIDR" -d "$INTERNAL_NET_CIDR" -j MASQUERADE &>/dev/null; then
            printf " [ACTIVE] Hairpin NAT rule for %s\n" "$INTERNAL_NET_CIDR"
            found_any=true
        fi
    fi

    if ! $found_any; then
        log_info "No active rules defined in this script were found."
    fi
}

#---[ Main Execution ]--------------------------------------------------------#
main() {
    ensure_root
    ensure_bin "$IPTABLES_BIN"
    ensure_bin "$IP_BIN"
    ensure_interface

    case "${1:-}" in
        add)    apply_all_rules ;;
        remove) remove_all_rules ;;
        list)   list_all_rules ;;
        *)      echo "Usage: $SCRIPT_NAME <add|remove|list>"; exit 1 ;;
    esac
}

main "$@"
