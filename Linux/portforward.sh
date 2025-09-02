#!/usr/bin/env bash
set -Eeuo pipefail

# Config
readonly PUBLIC_IFACE="${PUBLIC_IFACE:-ens18}"
declare -a FORWARDING_RULES=(
  "tcp:300.10.10.10:32400:10.0.1.106:32400"
  "tcp:300.10.10.10:58423:10.0.1.106:58423"
  "tcp:300.10.10.10:20000:20999:10.0.1.105:20000:20999"
  "udp:300.10.10.10:58423:10.0.1.106:58423"
  "udp:300.10.10.10:20000:20999:10.0.1.105:20000:20999"
)

# Internals
readonly NAT_CHAIN="SERVICE_FWD_NAT"
readonly FILTER_CHAIN="SERVICE_FWD_FILTER"
readonly IPTABLES_BIN="${IPTABLES_BIN:-iptables}"
readonly IP_BIN="${IP_BIN:-ip}"

log_info(){ echo "[INFO]  $*"; }
log_warn(){ echo "[WARN]  $*"; }
log_error(){ >&2 echo "[ERROR] $*"; }
log_header(){ echo; echo "--- $* ---"; }
run(){ "$@" || { log_error "Command failed: $*"; exit 1; }; }

normalize_port_expr(){ local p="${1// /}"; echo "${p//-/:}"; }

is_port_or_range_valid(){
  local p="$1"
  if [[ "$p" =~ ^[0-9]+$ ]]; then
    (( p>=1 && p<=65535 )) || return 1
  elif [[ "$p" =~ ^([0-9]+):([0-9]+)$ ]]; then
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
    (( a>=1 && a<=65535 && b>=1 && b<=65535 && a<=b )) || return 1
  fi
  return 0
}

detect_nft_backend(){ "$IPTABLES_BIN" -V 2>/dev/null | grep -qi "nf_tables" && echo "nft" || echo "legacy"; }

# --- Core Rule Management (Rewritten for correctness) ---

add_rule() {
    local desc="$1"; shift
    local -a rule_spec=("$@") # e.g., -t nat -A FORWARD ...
    local -a check_spec=("${rule_spec[@]}")
    check_spec[2]="-C" # Replace action flag (-A or -I) with -C for check
    
    # For -I, the check command doesn't use the rule number.
    if [[ "${check_spec[2]}" == "-I" ]]; then
      # Correctly build check spec for -I: iptables -t nat -C FORWARD ... (no rule number)
      check_spec=("${rule_spec[0]}" "${rule_spec[1]}" "-C" "${rule_spec[3]}" "${rule_spec[@]:4}")
    fi

    if ! "$IPTABLES_BIN" "${check_spec[@]}" &>/dev/null; then
        run "$IPTABLES_BIN" "${rule_spec[@]}"
        log_info "Added: $desc"
    else
        log_info "Exists: $desc"
    fi
}

delete_rule() {
    local desc="$1"; shift
    local -a rule_spec=("$@")
    local -a check_spec=("${rule_spec[@]}")
    check_spec[2]="-C" # Replace -D with -C

    # Loop to remove all instances of the rule
    while "$IPTABLES_BIN" "${check_spec[@]}" &>/dev/null; do
        run "$IPTABLES_BIN" "${rule_spec[@]}"
        log_info "Removed: $desc"
    done
}

ensure_chain_exists(){ local table="$1" chain="$2"; if ! "$IPTABLES_BIN" -t "$table" -nL "$chain" &>/dev/null; then run "$IPTABLES_BIN" -t "$table" -N "$chain"; fi; }

# --- High-Level Functions ---

validate_rule_tuple(){
  local proto="$1" pub_ip="$2" pub_port="$3" int_ip="$4" int_port="$5"
  [[ "$proto" == "tcp" || "$proto" == "udp" ]] || { log_error "Invalid proto: $proto"; return 1; }
  is_port_or_range_valid "$pub_port" || { log_error "Invalid public port: $pub_port"; return 1; }
  is_port_or_range_valid "$int_port" || { log_error "Invalid internal port: $int_port"; return 1; }
  if [[ "$pub_port" =~ : && "$int_port" =~ : && "$pub_port" != "$int_port" ]]; then log_warn "Different ranges not 1:1; prefer identical."; fi
}

enable_ip_forwarding(){ [[ "$(cat /proc/sys/net/ipv4/ip_forward)" -ne 1 ]] && run sysctl -w net.ipv4.ip_forward=1 || true; }

parse_rule(){
  local rule="$1"; local IFS=':'; read -r -a t <<< "$rule" || true
  local n="${#t[@]}"
  if [[ "$n" -eq 5 ]]; then echo "${t[0]}" "${t[1]}" "${t[2]}" "${t[3]}" "${t[4]}";
  elif [[ "$n" -eq 7 ]]; then echo "${t[0]}" "${t[1]}" "${t[2]}:${t[3]}" "${t[4]}" "${t[5]}:${t[6]}";
  else log_error "Invalid rule format (tokens=$n): $rule"; return 1; fi
}

to_destination_arg(){
  local int_ip="$1" int_port="$2"
  if [[ "$int_port" =~ : ]]; then local a="${int_port%:*}" b="${int_port#*:}"; echo "${int_ip}:${a}-${b}"; else echo "${int_ip}:${int_port}"; fi
}

cmd_init(){
  log_header "Init"
  log_info "iptables backend: $(detect_nft_backend)"
  ensure_chain_exists "nat" "$NAT_CHAIN"
  ensure_chain_exists "filter" "$FILTER_CHAIN"
  add_rule "Jump PREROUTING -> $NAT_CHAIN" -t nat -I PREROUTING 1 -i "$PUBLIC_IFACE" -j "$NAT_CHAIN"
  add_rule "Jump FORWARD -> $FILTER_CHAIN" -t filter -I FORWARD 1 -j "$FILTER_CHAIN"
  add_rule "POSTROUTING MASQUERADE on $PUBLIC_IFACE" -t nat -A POSTROUTING -o "$PUBLIC_IFACE" -j MASQUERADE
  enable_ip_forwarding
}

cmd_apply(){
  log_header "Apply"
  cmd_init
  for rule in "${FORWARDING_RULES[@]}"; do
    read -r proto pub_ip pub_port_raw int_ip int_port_raw < <(parse_rule "$rule")
    local pub_port int_port; pub_port="$(normalize_port_expr "$pub_port_raw")"; int_port="$(normalize_port_expr "$int_port_raw")"
    validate_rule_tuple "$proto" "$pub_ip" "$pub_port" "$int_ip" "$int_port"
    local to_dest; to_dest="$(to_destination_arg "$int_ip" "$int_port")"
    add_rule "DNAT $proto $pub_ip:$pub_port -> $to_dest" -t nat -A "$NAT_CHAIN" -p "$proto" -d "$pub_ip" --dport "$pub_port" -j DNAT --to-destination "$to_dest"
    add_rule "FORWARD $proto -> ${int_ip}:${int_port}" -t filter -A "$FILTER_CHAIN" -p "$proto" -d "$int_ip" --dport "$int_port" -j ACCEPT
  done
  log_info "Applied."
}

cmd_remove(){
  log_header "Remove"
  for rule in "${FORWARDING_RULES[@]}"; do
    read -r proto pub_ip pub_port_raw int_ip int_port_raw < <(parse_rule "$rule")
    local pub_port int_port; pub_port="$(normalize_port_expr "$pub_port_raw")"; int_port="$(normalize_port_expr "$int_port_raw")"
    validate_rule_tuple "$proto" "$pub_ip" "$pub_port" "$int_ip" "$int_port" || true
    local to_dest; to_dest="$(to_destination_arg "$int_ip" "$int_port")"
    delete_rule "DNAT $proto $pub_ip:$pub_port -> $to_dest" -t nat -D "$NAT_CHAIN" -p "$proto" -d "$pub_ip" --dport "$pub_port" -j DNAT --to-destination "$to_dest"
    delete_rule "FORWARD $proto -> ${int_ip}:${int_port}" -t filter -D "$FILTER_CHAIN" -p "$proto" -d "$int_ip" --dport "$int_port" -j ACCEPT
  done
  log_info "Removed."
}

cmd_purge(){
  log_header "Purge"
  delete_rule "Jump PREROUTING -> $NAT_CHAIN" -t nat -D PREROUTING -i "$PUBLIC_IFACE" -j "$NAT_CHAIN"
  delete_rule "Jump FORWARD -> $FILTER_CHAIN" -t filter -D FORWARD -j "$FILTER_CHAIN"
  
  if "$IPTABLES_BIN" -t nat -nL "$NAT_CHAIN" &>/dev/null; then run "$IPTABLES_BIN" -t nat -F "$NAT_CHAIN"; fi
  if "$IPTABLES_BIN" -t filter -nL "$FILTER_CHAIN" &>/dev/null; then run "$IPTABLES_BIN" -t filter -F "$FILTER_CHAIN"; fi
  if "$IPTABLES_BIN" -t nat -nL "$NAT_CHAIN" &>/dev/null; then run "$IPTABLES_BIN" -t nat -X "$NAT_CHAIN"; fi
  if "$IPTABLES_BIN" -t filter -nL "$FILTER_CHAIN" &>/dev/null; then run "$IPTABLES_BIN" -t filter -X "$FILTER_CHAIN"; fi
  log_info "Flushed and deleted custom chains."

  delete_rule "POSTROUTING MASQUERADE on $PUBLIC_IFACE" -t nat -D POSTROUTING -o "$PUBLIC_IFACE" -j MASQUERADE
  log_info "Purge complete."
}

cmd_list(){
  log_header "List"
  echo "--- NAT ($NAT_CHAIN) ---"; "$IPTABLES_BIN" -t nat -nL "$NAT_CHAIN" --line-numbers -v || true
  echo; echo "--- FILTER ($FILTER_CHAIN) ---"; "$IPTABLES_BIN" -nL "$FILTER_CHAIN" --line-numbers -v || true
}

main(){
  [[ $EUID -eq 0 ]] || { log_error "Run as root"; exit 1; }
  command -v "$IPTABLES_BIN" &>/dev/null || { log_error "iptables not found"; exit 1; }
  command -v "$IP_BIN" &>/dev/null || { log_error "ip not found"; exit 1; }
  "$IP_BIN" link show "$PUBLIC_IFACE" &>/dev/null || { log_error "Missing iface: $PUBLIC_IFACE"; exit 1; }
  case "${1:-}" in
    apply)  cmd_apply ;;
    remove) cmd_remove ;;
    purge)  cmd_purge ;;
    list)   cmd_list  ;;
    *) echo "Usage: $0 <apply|remove|purge|list>"; exit 1 ;;
  esac
}
main "$@"
