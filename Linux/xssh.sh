#!/usr/bin/env bash
#===============================================================================
# xssh - Execute commands over SSH with host discovery and mass mode
#
# Refactored for improved robustness, portability, error forwarding, and
# bash autocompletion.

# --- Script Configuration & Initialization ---

# Exit immediately if a command exits with a non-zero status.
# Treat unset variables as an error.
# The return value of a pipeline is the status of the last command to exit
# with a non-zero status, or zero if no command exited with a non-zero status.
# Inherit traps by functions, command substitutions, and subshells.
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
    WARN)  color="\033[33m" ;; # Yellow
    ERROR) color="\033[31m" ;; # Red
  esac
  # Use stderr for WARN and ERROR levels
  local stream=1; [[ "$level" != "INFO" ]] && stream=2
  local line="${ts} [${SCRIPT_NAME}] [$level] ${msg}"
  printf '%b%s%b\n' "$color" "$line" "$reset" >&stream
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$line" >>"$LOG_FILE"
  fi
}

# Unset traps. Called before a clean exit to prevent false positives.
trap_off() {
  trap - ERR
}

# Generic error handler, triggered by 'set -e'.
err_handler() {
  log "ERROR" "Unexpected error on line $1: $2"
}

# Handle Ctrl+C interruptions.
sigint_handler() {
  log "ERROR" "Operation interrupted by user."
  trap_off
  exit 130
}

# Cleanup temporary files on script exit.
exit_handler() {
  if [[ -n "$XSSH_TMPDIR" && -d "$XSSH_TMPDIR" ]]; then
    rm -rf "$XSSH_TMPDIR"
  fi
}

trap 'err_handler $LINENO "$BASH_COMMAND"' ERR
trap 'sigint_handler' SIGINT
trap 'exit_handler' EXIT


# --- Helper Functions ---

# Replaces characters that are problematic in filenames.
sanitize_for_filename() {
  printf '%s' "$1" | sed 's/[^a-zA-Z0-9._-]/_/g'
}


# --- Usage & Autocompletion ---

usage() {
  cat <<'EOF'
Execute commands over SSH with host discovery and mass mode.

Usage:
  xssh [options] pattern [command]
  xssh -l                     # List all hosts from SSH config(s)
  xssh -V                     # List "alias<TAB>hostname" for all hosts

Options:
  -v, --verbose      Verbose mode.
  -X                 Enable X11 forwarding.
  -p port            Specify SSH port.
  -L arg             Specify local port forwarding.
  -D arg             Specify dynamic port forwarding.
  -l                 List all unique hostnames from SSH config files.
  -V                 Verbose list: provides "alias<TAB>hostname" for all hosts.
  --mass             Execute command in parallel on all matching hosts.
  --log FILE         Append logs to the specified file.
  --generate-completion  Generate the bash completion script.
  -h, --help         Show this help message.
EOF
}

generate_completion_script() {
  # This function prints the bash completion script to stdout with clear instructions.
  cat <<'EOF'
# Bash completion for xssh
#
# To install, use one of the methods below.
#
# --- Method 1: Immediate (for the current session only) ---
# Run the following command to enable completion immediately:
#
#   source <(xssh --generate-completion)
#
# --- Method 2: Permanent (recommended for daily use) ---
# Add the completion script to your bash profile to make it permanent.
#
#  1. Save the script:
#     xssh --generate-completion > ~/.xssh-completion.sh
#
#  2. Add this line to the end of your ~/.bashrc or ~/.bash_profile file:
#     source ~/.xssh-completion.sh
#
# --- Method 3: System-Wide (for all users) ---
# If you have root privileges, you can install it for all users:
#
#   xssh --generate-completion | sudo tee /etc/bash_completion.d/xssh
#
# --- Completion Script ---

_xssh_completion() {
    local cur prev words cword
    _get_comp_words_by_ref -n : cur prev words cword

    local SCRIPT_NAME; SCRIPT_NAME="$(basename "${words[0]}")"
    local opts="-v -X -p -L -D -l -V --mass --log --help --generate-completion"

    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "${opts}" -- "$cur") )
        return 0
    fi

    case "$prev" in
        -p|-L|-D|--log)
            return 0 # No suggestions for option arguments
            ;;
    esac

    # Find the first positional argument (the pattern)
    local i=1
    while [[ $i -lt $cword ]]; do
        if [[ "${words[i]}" != -* ]]; then
            # We are past the host pattern; suggest file paths for the command
            COMPREPLY=( $(compgen -f -- "$cur") )
            return 0
        fi
        # Skip arguments for options like -p 22
        case "${words[i]}" in
          -p|-L|-D|--log) ((i++));;
        esac
        ((i++))
    done

    # If we are here, we are completing the host pattern.
    # Use xssh -V to get "alias<TAB>hostname" and complete on both.
    # Stderr is redirected to hide script logs during completion.
    local host_list
    host_list=$(xssh -V 2>/dev/null | awk '{print $1; print $2}')
    if [[ -n "$host_list" ]]; then
        COMPREPLY=( $(compgen -W "${host_list}" -- "$cur") )
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
      -X) SSH_OPTIONS+=("-X"); shift ;;
      -p|-L|-D) [[ -z "${2-}" ]] && { log "ERROR" "Option $1 needs an argument."; return 2; }; SSH_OPTIONS+=("$1" "$2"); shift 2 ;;
      -l) LIST_ALL_MODE=true; shift ;;
      -V) LIST_VERBOSE_MODE=true; LIST_ALL_MODE=true; shift ;;
      --mass) MASS_MODE=true; shift ;;
      --log) [[ -z "${2-}" ]] && { log "ERROR" "--log needs a file path."; return 2; }; LOG_FILE="$2"; shift 2 ;;
      --log=*) LOG_FILE="${1#*=}"; shift ;;
      --generate-completion) generate_completion_script; exit 0 ;;
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
  # Recursively parse 'Include' directives.
  awk '/^[[:space:]]*[Ii][Nn][Cc][Ll][Uu][Dd][Ee][[:space:]]+/{$1="";print $0}' "$config_file" |
  while read -r line; do
    # shellcheck disable=SC2086 # Word splitting is intentional for glob patterns
    for pattern in $line; do
      pattern="${pattern/#\~/$HOME}"
      [[ "$pattern" != /* ]] && pattern="${base_dir}/${pattern}"
      # Recursively resolve for glob patterns, e.g., conf.d/*
      for f in $pattern; do resolve_ssh_configs "$f"; done
    done
  done
}

parse_ssh_host_data() {
  local m="$1" p="${2:-}"; shift 2; local f=("$@")
  # AWK script to parse SSH config files for host aliases and hostnames.
  # PORTABILITY: Using tolower() for case-insensitivity.
  awk -v m="$m" -v p="$p" '
    function flush(a){for(a in b)all[a]=(a in h?h[a]:a);delete b;delete h}
    FNR==1{flush()}
    /^[[:space:]]*#/||/^[[:space:]]*$/{next}
    tolower($1)=="host"{flush();for(i=2;i<=NF;i++)if($i!="*")b[$i]=1;next}
    tolower($1)=="match"{flush()} # Skip match blocks
    tolower($1)=="hostname"{for(a in b)h[a]=$2;next}
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
    # mapfile (or readarray) is a bash v4+ feature.
    mapfile -t HOSTS < <(parse_ssh_host_data "extract" "$pattern" "${SSH_CONFIG_FILES[@]}" | sort -u)
  fi
  if (( ${#HOSTS[@]} == 0 )); then
    HOSTS=("$pattern")
  fi
  if (( ${#HOSTS[@]} > 1 )) && ! "$MASS_MODE"; then
    log "ERROR" "Pattern matched multiple hosts. Use --mass to execute on all."
    printf '%s\n' "${HOSTS[@]/#/- }" >&2
    return 1
  fi
}

ssh_exec() {
  local host="$1"; shift
  # Removed -q and -o LogLevel=ERROR to allow SSH to show its own connection errors.
  local cmd=(ssh -o ConnectTimeout=5)
  [[ -n "$USERNAME" ]] && cmd+=("-l" "$USERNAME")
  ((${#SSH_OPTIONS[@]} > 0)) && cmd+=("${SSH_OPTIONS[@]}")
  cmd+=("$host")
  ((${#} > 0)) && cmd+=("$@")
  "${cmd[@]}"
}

execute_serial() {
  for host in "${HOSTS[@]}"; do
    "$VERBOSE_MODE" && log "INFO" "Connecting to $host (${COMMAND[*]:-interactive session})..."
    # Handle command failure without 'set -e' exiting the script.
    ssh_exec "$host" "${COMMAND[@]}" || log "WARN" "SSH command failed for host: $host"
  done
}

execute_parallel() {
  if (( ${#COMMAND[@]} == 0 )); then
    log "ERROR" "A command is required for --mass mode."
    usage >&2
    return 2
  fi

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
      
      # If ssh_exec fails, 'set -e' terminates this subshell.
      # The detailed error from ssh itself is captured in the .err file.
      ssh_exec "$host" "${COMMAND[@]}" >>"$out" 2>>"$err"
    ) &
    pids+=($!)
  done

  # Wait for all background jobs.
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done

  # Use mapfile -d '' to read null-delimited output from find.
  # This correctly handles all filenames and creates an empty array if no files are found.
  local out_files=()
  mapfile -d '' -t out_files < <(find "$XSSH_TMPDIR" -name "*.out" -type f -print0 | sort -z)
  if (( ${#out_files[@]} > 0 )); then
    for f in "${out_files[@]}"; do
      # Use `cat --` to prevent filenames starting with `-` from being treated as options.
      [[ -s "$f" ]] && cat -- "$f"
    done
  fi

  # Apply the same robust file-gathering logic for error files.
  local err_files=()
  mapfile -d '' -t err_files < <(find "$XSSH_TMPDIR" -name "*.err" -type f -size +0c -print0 | sort -z)
  if (( ${#err_files[@]} > 0 )); then
    log "WARN" "Errors were reported by one or more hosts:"
    # Use `cat --` and pass the array directly.
    cat -- "${err_files[@]}" >&2
  fi
}


# --- Main Controller ---

main() {
  parse_arguments "$@" || exit $?

  # Resolve SSH config files once at the beginning.
  mapfile -t SSH_CONFIG_FILES < <(resolve_ssh_configs "$SSH_MAIN_CONFIG" | sort -u)

  if "$LIST_ALL_MODE"; then
    do_list_all
    trap_off
    exit 0
  fi

  command -v ssh >/dev/null || { log "ERROR" "'ssh' command not found in PATH."; trap_off; exit 1; }
  
  extract_hosts || { trap_off; exit 1; }

  if "$MASS_MODE"; then
    execute_parallel
  else
    execute_serial
  fi
  
  trap_off
}

# Pass all script arguments to the main function.
main "$@"
