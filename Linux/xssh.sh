#!/usr/bin/env bash
#===============================================================================
# xssh - Execute commands over SSH with host discovery and mass mode
#
# Refactored for improved robustness, maintainability, and error handling.
#===============================================================================

# --- Script Configuration & Initialization ---

# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error when performing parameter expansion.
# The return value of a pipeline is the status of the last command to exit
# with a non-zero status, or zero if no command exited with a non-zero status.
# Inherit traps by functions, command substitutions, and subshells.
set -Eeuo pipefail

# --- Constants & Globals ---
readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SSH_MAIN_CONFIG="${HOME}/.ssh/config"

# --- Global State Variables ---
LIST_MODE=""
VERBOSE_MODE=false
MASS_MODE=false
LOG_FILE=""
XSSH_TMPDIR=""
SSH_CONFIG_FILES=()
SSH_OPTIONS=()
HOSTS=()
PATTERN=""
COMMAND=()

# --- Core Utilities & Trap Handling ---

log() {
  local level="$1"; shift
  local msg="$*"
  local ts; ts="$(date +"%Y-%m-%dT%H:%M:%S%z")"
  local reset="\033[0m"; local color=""
  case "$level" in
    WARN)  color="\033[33m" ;; # Yellow
    ERROR) color="\033[31m" ;; # Red
  esac
  local stream=1
  if [[ "$level" != "INFO" ]]; then
    stream=2
  fi
  local line="${ts} [${SCRIPT_NAME}] [$level] ${msg}"
  printf '%b%s%b\n' "$color" "$line" "$reset" >&"$stream"
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$line" >>"$LOG_FILE"
  fi
}

# Unset traps. Called before a clean, controlled exit to prevent false positives.
trap_off() {
  trap - ERR
}

# Generic error handler for unexpected script errors.
err_handler() {
  local exit_code=$?
  log "ERROR" "Unexpected script error on line $1 (Command: $2, Exit Code: $exit_code)"
}

# Handle Ctrl+C interruptions.
sigint_handler() {
  # When jobs are running in the background, we need to kill them all.
  if [[ -n "${XSSH_TMPDIR:-}" && -d "$XSSH_TMPDIR" ]]; then
    pkill -P $$ # Kill all child processes of this script.
  fi
  log "ERROR" "Operation interrupted by user (SIGINT)."
  trap_off
  exit 130
}

# Cleanup temporary files on script exit.
exit_handler() {
  if [[ -n "$XSSH_TMPDIR" && -d "$XSSH_TMPDIR" ]]; then
    if "$VERBOSE_MODE"; then
      log "INFO" "Cleaning up temporary directory: $XSSH_TMPDIR"
    fi
    rm -rf "$XSSH_TMPDIR"
  fi
}

trap 'err_handler $LINENO "$BASH_COMMAND"' ERR
trap 'sigint_handler' SIGINT
trap 'exit_handler' EXIT

# --- Helper Functions ---

sanitize_for_filename() {
  printf '%s' "$1" | sed 's/[^a-zA-Z0-9._-]/_/g'
}

# --- Usage & Autocompletion ---

usage() {
  cat <<'EOF'
Execute commands over SSH with host discovery and mass mode.
Any standard ssh options (e.g., -p, -X, -i) can be passed directly.

Usage:
  xssh [xssh-options] [ssh-options] pattern [command]
  xssh -l                     # List all host aliases from SSH config(s)
  xssh -V                     # List "alias<TAB>Hostname" for all hosts

xssh Options:
  -v, --verbose      Verbose mode.
  -l                 List all unique host aliases from SSH config files.
  -V                 Verbose list: provides "alias<TAB>Hostname" for all hosts.
  --mass             Execute command in parallel on all matching hosts.
  --log FILE         Append logs to the specified file.
  --generate-completion  Generate the bash completion script.
  -h, --help         Show this help message.
EOF
}

generate_completion_script() {
  cat <<'EOF'
# Bash completion for xssh
# To install: source <(xssh --generate-completion)
_xssh_completion() {
    local cur prev words cword
    _get_comp_words_by_ref -n : cur prev words cword
    local xssh_opts="-v -l -V --mass --log --help --generate-completion"
    local xssh_opts_with_arg="--log"
    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "${xssh_opts}" -- "$cur") )
        return 0
    fi
    case "$prev" in
        --log) return 0 ;;
    esac
    local i=1; local pattern_found=false
    while [[ $i -lt $cword ]]; do
        local word="${words[i]}"
        if [[ " ${xssh_opts_with_arg} " =~ " ${word} " ]]; then
            ((i++))
        elif [[ "$word" != -* ]]; then
            pattern_found=true; break
        fi
        ((i++))
    done
    if [[ "$pattern_found" == true ]]; then
        COMPREPLY=( $(compgen -f -- "$cur") )
    else
        local host_list; host_list=$(xssh -l 2>/dev/null)
        if [[ -n "$host_list" ]]; then
            COMPREPLY=( $(compgen -W "${host_list}" -- "$cur") )
        fi
    fi
}
complete -F _xssh_completion xssh
EOF
}

# --- Business Logic ---

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      -v|--verbose) VERBOSE_MODE=true; shift ;;
      -l) LIST_MODE="simple"; shift ;;
      -V) LIST_MODE="verbose"; shift ;;
      --mass) MASS_MODE=true; shift ;;
      --log)
        if [[ -z "${2-}" ]]; then log "ERROR" "--log requires a file path."; trap_off; exit 2; fi
        LOG_FILE="$2"; shift 2 ;;
      --log=*) LOG_FILE="${1#*=}"; shift ;;
      --generate-completion) generate_completion_script; exit 0 ;;
      --) shift; break ;;
      -*)
          SSH_OPTIONS+=("$1"); shift
          if [[ $# -gt 0 && "${1:0:1}" != "-" ]]; then SSH_OPTIONS+=("$1"); shift; fi
          ;;
      *)
          PATTERN="$1"; shift; COMMAND=("$@"); return 0 ;;
    esac
  done
  if [[ -z "$LIST_MODE" && -z "$PATTERN" ]]; then
    log "ERROR" "No host pattern provided."; usage >&2; trap_off; exit 2
  fi
}

resolve_ssh_configs() {
  local config_file="$1"
  [[ -r "$config_file" ]] || return 0
  printf '%s\n' "$config_file"
  local base_dir; base_dir="$(dirname "$config_file")"
  awk '/^[[:space:]]*[Ii][Nn][Cc][Ll][Uu][Dd][Ee][[:space:]]+/{$1="";print $0}' "$config_file" |
  while read -r line; do
    # shellcheck disable=SC2086
    for pattern in $line; do
      pattern="${pattern/#\~/$HOME}"
      [[ "$pattern" != /* ]] && pattern="${base_dir}/${pattern}"
      for f in $pattern; do resolve_ssh_configs "$f"; done
    done
  done
}

parse_ssh_host_data() {
  local mode="$1" pattern="${2:-}"; shift 2; local files=("$@")
  awk -v mode="$mode" -v pattern="$pattern" '
    function flush_block(alias) {
      for (alias in b) {
        all_aliases[alias] = 1
        hostnames[alias] = (current_hostname != "") ? current_hostname : alias
      }
      delete b; current_hostname = ""
    }
    FNR == 1 { flush_block() }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    tolower($1) == "host" || tolower($1) == "match" {
      flush_block()
      if (tolower($1) == "host") {
        for (i = 2; i <= NF; i++) if ($i != "*") b[$i] = 1
      }
      next
    }
    (length(b) > 0) && tolower($1) == "hostname" { current_hostname = $2; next }
    END {
      flush_block()
      if (mode == "list_verbose") {
        for (alias in hostnames) if (alias !~ /[*?]/) printf "%s\t%s\n", alias, hostnames[alias]
      } else if (mode == "extract") {
        for (alias in all_aliases) if (alias ~ pattern) print alias
      } else {
        for (alias in all_aliases) if (alias !~ /[*?]/) s[alias] = 1
        for (host in s) print host
      }
    }
  ' "${files[@]}"
}

do_list_all() {
  (( ${#SSH_CONFIG_FILES[@]} == 0 )) && return 0
  local mode="simple"; [[ "$LIST_MODE" == "verbose" ]] && mode="list_verbose"
  parse_ssh_host_data "$mode" "" "${SSH_CONFIG_FILES[@]}" | sort -u
}

extract_hosts() {
  if (( ${#SSH_CONFIG_FILES[@]} > 0 )); then
    mapfile -t HOSTS < <(parse_ssh_host_data "extract" "$PATTERN" "${SSH_CONFIG_FILES[@]}" | sort -u)
  fi
  if (( ${#HOSTS[@]} == 0 )); then HOSTS=("$PATTERN"); fi
  if (( ${#HOSTS[@]} > 1 )) && ! "$MASS_MODE"; then
    log "ERROR" "Pattern matched multiple hosts. Use --mass or refine your pattern."
    printf 'Matched hosts:\n' >&2; printf -- '- %s\n' "${HOSTS[@]}" >&2
    trap_off; exit 1
  fi
}

ssh_exec() {
  local host="$1"; shift
  local cmd=(ssh -o ConnectTimeout=5)
  if (( ${#SSH_OPTIONS[@]} > 0 )); then cmd+=("${SSH_OPTIONS[@]}"); fi
  cmd+=("$host")
  if (( $# > 0 )); then cmd+=("$@"); fi
  if ! "$MASS_MODE" && [[ -t 1 ]]; then exec "${cmd[@]}"; else "${cmd[@]}"; fi
}

execute_serial() {
  for host in "${HOSTS[@]}"; do
    if "$VERBOSE_MODE"; then
      log "INFO" "Connecting to ${host} (${COMMAND[*]:-interactive session})..."
    fi
    ssh_exec "$host" "${COMMAND[@]}" || log "WARN" "SSH command failed for host: ${host} (Exit code: $?)"
  done
}

_run_parallel_task() {
    # CRITICAL: This function runs in a backgrounded subshell. We MUST disable
    # the parent's ERR trap. Otherwise, an expected remote command failure
    # (e.g., grep not finding a match) would trigger the main err_handler.
    trap '' ERR

    local host="$1"
    local safe_host; safe_host="$(sanitize_for_filename "$host")"
    local out="$XSSH_TMPDIR/$safe_host.out"
    local err="$XSSH_TMPDIR/$safe_host.err"
    if "$VERBOSE_MODE"; then printf -- '--- %s ---\n' "$host" >"$out"; fi

    # The subshell will exit with the status of ssh_exec.
    ssh_exec "$host" "${COMMAND[@]}" >>"$out" 2>>"$err"
}

execute_parallel() {
  if (( ${#COMMAND[@]} == 0 )); then
    log "ERROR" "A command is required for --mass mode."; usage >&2; trap_off; exit 2
  fi

  XSSH_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/xssh.XXXXXX")"
  if "$VERBOSE_MODE"; then log "INFO" "Using temporary directory for parallel output: $XSSH_TMPDIR"; fi

  local pids=()
  for host in "${HOSTS[@]}"; do
    _run_parallel_task "$host" &
    pids+=($!)
  done

  local failed_pids=0
  # CRITICAL: Temporarily disable both the ERR trap and exit-on-error.
  # This allows the `wait` command to report a failure without triggering the trap or exiting the script.
  trap_off
  set +e
  for pid in "${pids[@]}"; do
    wait "$pid"
    if [[ $? -ne 0 ]]; then
      ((failed_pids++))
    fi
  done
  # CRITICAL: Restore the trap and exit-on-error settings.
  set -e
  trap 'err_handler $LINENO "$BASH_COMMAND"' ERR

  # Aggregate and print output and errors.
  local out_files=(); mapfile -d '' -t out_files < <(find "$XSSH_TMPDIR" -name "*.out" -type f -size +0c -print0 | sort -z)
  if (( ${#out_files[@]} > 0 )); then for f in "${out_files[@]}"; do cat -- "$f"; done; fi

  local err_files=(); mapfile -d '' -t err_files < <(find "$XSSH_TMPDIR" -name "*.err" -type f -size +0c -print0 | sort -z)
  if (( ${#err_files[@]} > 0 )); then
    log "WARN" "Errors were reported by one or more hosts:"; cat -- "${err_files[@]}" >&2
  fi

  if (( failed_pids > 0 )); then
    log "WARN" "${failed_pids} of ${#pids[@]} remote commands failed."
    trap_off; exit 3 # Exit with a specific code for partial failure
  fi
}

# --- Main Controller ---

main() {
  parse_arguments "$@" || { trap_off; exit $?; }
  mapfile -t SSH_CONFIG_FILES < <(resolve_ssh_configs "$SSH_MAIN_CONFIG" | sort -u)
  if [[ -n "$LIST_MODE" ]]; then
    do_list_all; trap_off; exit 0
  fi
  command -v ssh >/dev/null || { log "ERROR" "'ssh' command not found in PATH."; trap_off; exit 127; }
  extract_hosts
  if "$MASS_MODE"; then execute_parallel; else execute_serial; fi
  trap_off
}

main "$@"
