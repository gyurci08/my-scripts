#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
#
# Port Forwarding Controller (TCP & UDP with Range Support)
#
# Description:
#   Manages iptables NAT prerouting rules for port forwarding. This script
#   allows defining forwarding rules in a simple array format, supporting
#   single ports, port ranges, and applying rules to TCP, UDP, or both.
#
# Features:
#   - Define all forwardings in the `FORWARDINGS` array.
#   - Rule Format: "<proto>:<src_ip>:<src_port_range>:<dst_ip>:<dst_port_range>"
#     - <proto>: "tcp", "udp", or "all" (for both).
#     - <src_ip>: The public-facing IP to match on, or "any" for all IPs.
#     - <src_port_range>: A single port ("80") or a range ("3000-4000").
#     - <dst_ip>: The internal IP to forward traffic to.
#     - <dst_port_range>: The target port or range. Must match the type
#       (single or range) of the source port.
#
# Usage:
#   Run as root.
#   ./script.sh add | remove | list
#
###############################################################################

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly LOG_PREFIX="[SERVICE_FORWARD]"
readonly IPTABLES_BIN="iptables"
readonly IFACE="ens18" # IMPORTANT: Adjust to your public-facing network interface

#===[ CONFIGURATION: DEFINE PORT FORWARDING RULES HERE ]======================#
# Format: "protocol:src_ip:src_port(s):dst_ip:dst_port(s)"
#=============================================================================#
declare -a FORWARDINGS=(
    #-- Forward Plex port for TCP
    "tcp:160.255.300.10:32400:10.0.1.106:32400"
    #-- Forward Transmission peer port for both TCP and UDP
    "all:185.255.300.10:1111:10.0.1.106:1111"
    #-- Forward a port range for both TCP and UDP
    "all:185.255.300.10:20000-20999:10.0.1.105:20000-20999"
)

#---[ Logging Functions ]-----------------------------------------------------#
log_info()   { echo "$(date +%FT%T%z) ${LOG_PREFIX} [INFO] $*"; }
log_error()  { >&2 echo "$(date +%FT%T%z) ${LOG_PREFIX} [ERROR] $*"; }
log_header() { echo -e "\n====================  $*  ====================\n"; }

#---[ System Check Functions ]------------------------------------------------#
ensure_root() {
    (( EUID == 0 )) || { log_error "This script must be run as root."; exit 1; }
}

ensure_bin() {
    command -v "$1" &>/dev/null || { log_error "Missing required binary: $1. Please install it."; exit 1; }
}

#---[ Core Logic Functions ]--------------------------------------------------#
# Parses a rule string and executes a callback function with the parsed components.
process_rule() {
    local rule_string="$1"
    local callback="$2"
    local action="$3"
    
    IFS=':' read -r proto src_ip src_port dst_ip dst_port <<< "$rule_string"
    # Validate rule format
    if [[ -z "$proto" || -z "$src_ip" || -z "$src_port" || -z "$dst_ip" || -z "$dst_port" ]]; then
        log_error "Skipping malformed rule: $rule_string"
        return 1
    fi
    
    # Handle 'any' src_ip
    [[ "$src_ip" == "any" ]] && src_ip="0.0.0.0/0"
    
    # Convert source port range from 'start-end' to 'start:end' for the --dport flag.
    # The destination port is left as 'start-end' for the --to-destination flag.
    local ipt_src_port="${src_port//-/:}"
    
    local final_rc=0
    if [[ "$proto" == "all" ]]; then
        "$callback" "tcp" "$src_ip" "$ipt_src_port" "$dst_ip" "$dst_port" "$action" || final_rc=$?
        "$callback" "udp" "$src_ip" "$ipt_src_port" "$dst_ip" "$dst_port" "$action" || final_rc=$?
    else
        "$callback" "$proto" "$src_ip" "$ipt_src_port" "$dst_ip" "$dst_port" "$action" || final_rc=$?
    fi
    return $final_rc
}

# Generic function to handle all iptables operations (add, remove, check).
manage_rule() {
    local proto="$1" src_ip="$2" src_port="$3" dst_ip="$4" dst_port="$5" action="$6"
    # Display rule uses hyphens for ranges for readability.
    local rule_desc="$proto ${src_ip//0.0.0.0\/0/any}:${src_port//:/-} -> ${dst_ip}:${dst_port}"
    
    # Determine iptables operation flag (-A, -D, -C)
    local op_flag=""
    case "$action" in
        add) op_flag="-A" ;;
        remove) op_flag="-D" ;;
        check) op_flag="-C" ;;
    esac
    
    # Build the iptables command in an array to handle arguments safely
    local ipt_cmd=(
        "$IPTABLES_BIN" -t nat "$op_flag" PREROUTING -i "$IFACE"
        -p "$proto" --destination "$src_ip" --dport "$src_port"
        -j DNAT --to-destination "${dst_ip}:${dst_port}"
    )

    case "$action" in
        add)
            if ! "${ipt_cmd[@]/-A/-C}" 2>/dev/null; then
                if "${ipt_cmd[@]}"; then
                    log_info "Added:  $rule_desc"
                else
                    log_error "Failed to add: $rule_desc"
                    return 1
                fi
            else
                log_info "Exists: $rule_desc"
            fi
            ;;
        remove)
            if "${ipt_cmd[@]/-D/-C}" 2>/dev/null; then
                if "${ipt_cmd[@]}"; then
                    log_info "Removed: $rule_desc"
                else
                    log_error "Failed to remove: $rule_desc"
                    return 1
                fi
            else
                log_info "Absent: $rule_desc"
            fi
            ;;
        check)
            if "${ipt_cmd[@]}" 2>/dev/null; then
                printf "%-4s %-25s -> %s\n" "$proto" "${src_ip//0.0.0.0\/0/any}:${src_port//:/-}" "${dst_ip}:${dst_port}"
                return 0 # Rule exists
            fi
            return 1 # Rule does not exist
            ;;
    esac
    return 0
}

#---[ User Command Functions ]------------------------------------------------#
add_all() {
    log_header "Adding All Defined Port Forwardings"
    for rule in "${FORWARDINGS[@]}"; do
        process_rule "$rule" "manage_rule" "add"
    done
}

remove_all() {
    log_header "Removing All Defined Port Forwardings"
    for rule in "${FORWARDINGS[@]}"; do
        process_rule "$rule" "manage_rule" "remove"
    done
}

list_all() {
    log_header "Listing Active Defined Port Forwardings"
    local found_any=false
    for rule in "${FORWARDINGS[@]}"; do
        if process_rule "$rule" "manage_rule" "check"; then
            found_any=true
        fi
    done
    
    if ! $found_any; then
        log_info "None of the defined forwarding rules are currently active."
    fi
}

show_usage() {
    cat <<USAGE
Usage: ${SCRIPT_NAME} <command>

Commands:
  add       Adds all port forwarding rules defined in the script.
            Rules that already exist will be skipped.

  remove    Removes all port forwarding rules defined in the script.
            Rules that do not exist will be skipped.

  list      Checks for and displays which of the defined rules are active.

  --help, -h  Show this help message.
USAGE
    exit 1
}

#---[ Main Execution ]--------------------------------------------------------#
main() {
    ensure_root
    ensure_bin "$IPTABLES_BIN"

    case "${1:-}" in
        add)          add_all ;;
        remove)       remove_all ;;
        list)         list_all ;;
        ""|--help|-h) show_usage ;;
        *)
            log_error "Invalid command: '$1'"
            show_usage
            ;;
    esac
}

# Pass all script arguments to the main function to be processed.
main "$@"
