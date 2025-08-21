#!/usr/bin/env bash
#===============================================================================
# xssh - Execute commands over SSH with host discovery and mass mode
#
# Refactored for improved robustness, portability, and error handling.
#===============================================================================

set -Eeuo pipefail

# --- Constants & Globals ---
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SSH_MAIN_CONFIG="${HOME}/.ssh/config"

# Global state variables
LOG_FILE=""
VERBOSE_MODE=false
MASS_MODE=false
LIST_ALL_MODE=false
LIST_VERBOSE_MODE=false
SSH_OPTIONS=()
SSH_CONFIG_FILES=()
PATTERN=""
COMMAND=()
USERNAME=""
HOSTS=()
XSSH_TMPDIR=""

# --- Core Utilities & Trap Handling ---

log() {
  local level="$1"; shift
  local msg="$*"
  local ts; ts="$(date +"%Y-%m-%dT%H:%M:%S%z")"
  local reset="\033[0m"; local color=""
  case "$level" in
    WARN) color="\033[33m" ;;
    ERROR) color="\033[31m" ;;
  esac
  local stream=1; [[ "$level" != "INFO" ]] && stream=2
  local line="${ts} [${SCRIPT_NAME}] [$level] ${msg}"
  printf '%b%s%b\n' "$color" "$line" "$reset" >&stream
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$line" >>"$LOG_FILE"
  fi
}

trap_off() {
  trap - ERR
}

err_handler() {
  log "ERROR" "Unexpected error on line $1: $2"
}

sigint_handler() {
  log "ERROR" "Operation interrupted."
  trap_off
  exit 130
}

exit_handler() {
  if [[ -n "$XSSH_TMPDIR" && -d "$XSSH_TMPDIR" ]]; then
    rm -rf "$XSSH_TMPDIR"
  fi
}

trap 'err_handler $LINENO "$BASH_COMMAND"' ERR
trap 'sigint_handler' SIGINT
trap 'exit_handler' EXIT

# --- Helper Functions ---

sanitize_for_filename() {
  # Replace characters that are problematic in filenames.
  # Keeps alphanumeric, dots, hyphens, and underscores. Replaces others with an underscore.
  printf '%s' "$1" | sed 's/[^a-zA-Z0-9._-]/_/g'
}

# --- Usage & Help ---

usage() {
  cat <<'EOF'
Usage:
  xssh [options] pattern [command]
  xssh -l                     # List all hosts from SSH config(s)
  xssh -V                     # List "alias<TAB>hostname" for all hosts

Options:
  -v                 Verbose mode.
  -X                 X11 forwarding.
  -p port            SSH port.
  -L arg             Local port forwarding.
  -D arg             Dynamic port forwarding.
  -l                 List all hosts (no connect).
  -V                 Verbose list: alias<TAB>hostname.
  --log FILE         Append logs to file.
  --mass             Execute command on multiple hosts.
  -h, --help         Show help.
EOF
}

# --- Business Logic ---

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      -v) VERBOSE_MODE=true; shift ;;
      -X) SSH_OPTIONS+=("-X"); shift ;;
      -p|-L|-D) [[ -z "${2-}" ]] && { log "ERROR" "Option $1 needs an argument."; return 2; }; SSH_OPTIONS+=("$1" "$2"); shift 2 ;;
      -l) LIST_ALL_MODE=true; shift ;;
      -V) LIST_VERBOSE_MODE=true; LIST_ALL_MODE=true; shift ;;
      --mass) MASS_MODE=true; shift ;;
      --log) [[ -z "${2-}" ]] && { log "ERROR" "--log needs a file path."; return 2; }; LOG_FILE="$2"; shift 2 ;;
      --log=*) LOG_FILE="${1#*=}"; shift ;;
      --) shift; break ;;
      -*) log "ERROR" "Unknown option: $1"; usage >&2; return 2 ;;
      *) break ;;
    esac
  done
  if "$LIST_ALL_MODE"; then return 0; fi
  if [[ $# -eq 0 ]]; then log "ERROR" "No host pattern provided."; usage >&2; return 2; fi
  PATTERN="$1"; shift; COMMAND=("$@"); return 0
}

resolve_ssh_configs() {
  local config_file="$1"
  [[ -f "$config_file" ]] || return 0
  printf '%s\n' "$config_file"
  local base_dir; base_dir="$(dirname "$config_file")"
  awk 'BEGIN{IGNORECASE=1}/^[[:space:]]*include[[:space:]]+/{$1="";print $0}' "$config_file" |
  while read -r line; do
    # shellcheck disable=SC2043
    for pattern in $line; do # Word splitting is intentional here
      pattern="${pattern/#\~/$HOME}"
      [[ "$pattern" != /* ]] && pattern="${base_dir}/${pattern}"
      # Recursively resolve for glob patterns
      for f in $pattern; do resolve_ssh_configs "$f"; done
    done
  done
}

parse_ssh_host_data() {
  local m="$1" p="${2:-}"; shift 2; local f=("$@")
  # AWK FIX: Changed loop variable 'h' in the final 'else' block to 'host' to avoid conflict
  # with the array 'h' used for storing HostName values. This resolves the fatal error.
  awk -v m="$m" -v p="$p" '
    function flush(a){for(a in b)all[a]=(a in h?h[a]:a);delete b;delete h}
    BEGIN{IGNORECASE=1}FNR==1{flush()}
    /^[[:space:]]*#/||/^[[:space:]]*$/{next}
    tolower($1)=="host"{flush();for(i=2;i<=NF;i++)if($i!="*")b[$i]=1;next}
    tolower($1)=="match"{flush()}tolower($1)=="hostname"{for(a in b)h[a]=$2;next}
    END{flush();if(m=="extract"){for(a in all)if(a~p)print all[a]}
    else if(m=="list_verbose"){for(a in all)if(a!~/[*?]/)printf "%s\t%s\n",a,all[a]}
    else{for(a in all)if(a!~/[*?]/)s[all[a]]=1;for(host in s)print host}}' "${f[@]}"
}

do_list_all() {
  (( ${#SSH_CONFIG_FILES[@]} == 0 )) && return 0
  local mode="list"; "$LIST_VERBOSE_MODE" && mode="list_verbose"
  parse_ssh_host_data "$mode" "" "${SSH_CONFIG_FILES[@]}" | sort -u
}

extract_hosts() {
  local pattern="$PATTERN"
  if [[ "$pattern" == *"@"* ]]; then USERNAME="${pattern%@*}"; pattern="${pattern#*@}"; fi
  if (( ${#SSH_CONFIG_FILES[@]} > 0 )); then
    mapfile -t HOSTS < <(parse_ssh_host_data "extract" "$pattern" "${SSH_CONFIG_FILES[@]}" | sort -u)
  fi
  if (( ${#HOSTS[@]} == 0 )); then
    HOSTS=("$pattern")
  fi
  if (( ${#HOSTS[@]} > 1 )) && ! "$MASS_MODE"; then
    log "ERROR" "Pattern matched multiple hosts. Use --mass."
    printf '%s\n' "${HOSTS[@]/#/- }" >&2
    return 1
  fi
}

ssh_exec() {
  local host="$1"; shift
  local cmd=(ssh -q -o LogLevel=ERROR -o ConnectTimeout=5)
  [[ -n "$USERNAME" ]] && cmd+=("-l" "$USERNAME")
  ((${#SSH_OPTIONS[@]} > 0)) && cmd+=("${SSH_OPTIONS[@]}")
  cmd+=("$host")
  ((${#} > 0)) && cmd+=("$@")
  "${cmd[@]}"
}

execute_serial() {
  for host in "${HOSTS[@]}"; do
    "$VERBOSE_MODE" && log "INFO" "Connecting to $host (${COMMAND[*]:-interactive})..."
    if ! ssh_exec "$host" "${COMMAND[@]}"; then
      log "ERROR" "SSH failed on host: $host"
    fi
  done
}

execute_parallel() {
  if (( ${#COMMAND[@]} == 0 )); then
    log "ERROR" "Command required for --mass mode."
    usage >&2
    return 2
  fi

  # PORTABILITY: Use portable mktemp syntax
  XSSH_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/xssh.XXXXXX")"
  
  local pids=()
  for host in "${HOSTS[@]}"; do
    (
      local safe_host; safe_host="$(sanitize_for_filename "$host")"
      local out="$XSSH_TMPDIR/$safe_host.out"
      local err="$XSSH_TMPDIR/$safe_host.err"
      
      if "$VERBOSE_MODE"; then
        printf -- '--- %s ---\n' "$host" >"$out"
      fi
      
      # ROBUSTNESS: Redirect errors to a per-host file to avoid interleaved output
      if ! ssh_exec "$host" "${COMMAND[@]}" >>"$out" 2>>"$err"; then
        printf 'SSH command failed on host: %s\n' "$host" >> "$err"
      fi
    ) &
    pids+=($!)
  done

  # Wait for all background jobs to complete.
  # Ignore non-zero exit codes from 'wait' as failed SSH commands are expected.
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done

  # Aggregate and display outputs, sorted by host name.
  # Using find + sort + a loop is robust and portable.
  mapfile -t out_files < <(find "$XSSH_TMPDIR" -name "*.out" -type f | sort)
  if (( ${#out_files[@]} > 0 )); then
    for f in "${out_files[@]}"; do
      # Only cat files with content to avoid extra newlines.
      [[ -s "$f" ]] && cat "$f"
    done
  fi

  # Aggregate and display errors
  mapfile -t err_files < <(find "$XSSH_TMPDIR" -name "*.err" -type f -size +0c | sort)
  if (( ${#err_files[@]} > 0 )); then
    log "WARN" "Errors were reported by one or more hosts:"
    cat "${err_files[@]}" >&2
  fi
}

# --- Main Controller ---

main() {
  parse_arguments "$@" || exit $?

  # EFFICIENCY: Resolve SSH config files once at the beginning
  mapfile -t SSH_CONFIG_FILES < <(resolve_ssh_configs "$SSH_MAIN_CONFIG" | sort -u)

  if "$LIST_ALL_MODE"; then
    do_list_all
    trap_off
    exit 0
  fi

  command -v ssh >/dev/null || { log "ERROR" "'ssh' not found."; trap_off; exit 1; }
  
  extract_hosts || { trap_off; exit 1; }

  if "$MASS_MODE"; then
    execute_parallel
  else
    execute_serial
  fi
  
  trap_off
}

main "$@"
