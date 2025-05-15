#!/usr/bin/env python3
# SSH Multi-Host Command Executor (xssh)
# Author: gyurci08 (adapted to Python)
# Last Modified: 2025-05-11
# Description: Executes SSH commands on single or multiple hosts based on patterns.

import os
import sys
import argparse
import logging
import re
import subprocess
import threading
import tempfile
import paramiko
from typing import List, Dict, Tuple, Optional
from datetime import datetime

# Constants
SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
SCRIPT_NAME = os.path.basename(__file__)
SSH_CONFIG_FILE = os.path.expanduser("~/.ssh/config")

# Global Variables
LOG_FILE = ""
DEBUG_MODE = False
VERBOSE_MODE = False
MASS_MODE = False
SUDO_MODE = False
USERNAME = ""
PATTERN = ""
HOSTS = []
SSH_OPTIONS = []
COMMAND = []

# Logging Setup
def setup_logging():
    log_level = logging.DEBUG if DEBUG_MODE else logging.INFO
    logging.basicConfig(level=log_level, format="%(asctime)s - [%(levelname)s] - %(message)s")
    if LOG_FILE:
        handler = logging.FileHandler(LOG_FILE)
        handler.setFormatter(logging.Formatter("%(asctime)s - [%(levelname)s] - %(message)s"))
        logging.getLogger().addHandler(handler)

def log(level: str, message: str):
    if level == "DEBUG" and not DEBUG_MODE:
        return
    if level == "ERROR":
        logging.error(message)
    elif level == "DEBUG":
        logging.debug(message)
    else:
        logging.info(message)

def log_debug(action: str, host: str):
    log("DEBUG", f"{action} on {host}")

# Usage Information
def usage():
    print(f"""Usage: {SCRIPT_NAME} [options] pattern [command]

Options:
  -d          Enable debug mode.
  -v          Enable verbose mode.
  -X          Enable X11 forwarding.
  -p port     Specify SSH port.
  -L [bind_address:]port:host:hostport
              Specify local port forwarding.
  -D [bind_address:]port
              Specify dynamic port forwarding.
  -l file     Specify log file (optional).
  --mass      Enable mass mode for executing commands on multiple hosts.
  --sudo      Execute commands with sudo on remote hosts (requires tty).

Restricted Commands (mass mode only):
  shutdown, poweroff, reboot

Examples:
  {SCRIPT_NAME} user@host ls -l
  {SCRIPT_NAME} -l /path/to/logfile user@host ls -l
  {SCRIPT_NAME} --mass pattern ls -l
  {SCRIPT_NAME} --sudo user@host cat /root/file
  {SCRIPT_NAME} user@host 'bash -c "cat <(echo remote_data)"'
""")

# Argument Parsing and Validation
def parse_arguments() -> Tuple[List[str], List[str]]:
    parser = argparse.ArgumentParser(description="SSH Multi-Host Command Executor", add_help=False)
    parser.add_argument("-d", action="store_true", dest="debug", help="Enable debug mode.")
    parser.add_argument("-v", action="store_true", dest="verbose", help="Enable verbose mode.")
    parser.add_argument("-X", action="store_true", dest="x11", help="Enable X11 forwarding.")
    parser.add_argument("-p", type=str, dest="port", help="Specify SSH port.")
    parser.add_argument("-L", type=str, dest="local_forward", help="Specify local port forwarding.")
    parser.add_argument("-D", type=str, dest="dynamic_forward", help="Specify dynamic port forwarding.")
    parser.add_argument("-l", type=str, dest="log_file", help="Specify log file (optional).")
    parser.add_argument("--mass", action="store_true", dest="mass", help="Enable mass mode for multiple hosts.")
    parser.add_argument("--sudo", action="store_true", dest="sudo", help="Execute commands with sudo on remote hosts.")
    parser.add_argument("pattern", type=str, help="Pattern or host to connect to.")
    parser.add_argument("command", nargs="*", help="Command to execute on remote hosts.")
    return parser.parse_args()

def validate_input(args):
    global MASS_MODE, SUDO_MODE, DEBUG_MODE, VERBOSE_MODE, LOG_FILE, PATTERN, COMMAND, SSH_OPTIONS
    MASS_MODE = args.mass
    SUDO_MODE = args.sudo
    DEBUG_MODE = args.debug
    VERBOSE_MODE = args.verbose
    LOG_FILE = args.log_file if args.log_file else ""
    PATTERN = args.pattern
    COMMAND = args.command
    SSH_OPTIONS = []
    if args.x11:
        SSH_OPTIONS.append("-X")
    if args.port:
        SSH_OPTIONS.extend(["-p", args.port])
    if args.local_forward:
        SSH_OPTIONS.extend(["-L", args.local_forward])
    if args.dynamic_forward:
        SSH_OPTIONS.extend(["-D", args.dynamic_forward])
    if MASS_MODE and not COMMAND:
        log("ERROR", "--mass requires a command to be provided.")
        sys.exit(1)
    if MASS_MODE and COMMAND:
        validate_command()

def validate_command():
    forbidden_commands = ["shutdown", "poweroff", "reboot"]
    cmd_str = " ".join(COMMAND)
    for cmd in forbidden_commands:
        if cmd in cmd_str:
            log("ERROR", f"The command '{cmd}' is not allowed in mass mode.")
            sys.exit(1)

def validate_prerequisites():
    if not os.path.isfile(SSH_CONFIG_FILE):
        log("WARN", "SSH config file not found. Proceeding without it.")
    log("DEBUG", "Prerequisites validated.")

# Host Extraction
def extract_hosts():
    global HOSTS, USERNAME
    host_pattern = PATTERN
    if "@" in host_pattern:
        USERNAME, host_pattern = host_pattern.split("@", 1)
        log("DEBUG", f"Extracted username: {USERNAME}, host pattern: {host_pattern}")
    else:
        USERNAME = ""
        log("DEBUG", f"Host pattern: {host_pattern}")

    HOSTS = []
    if os.path.isfile(SSH_CONFIG_FILE):
        with open(SSH_CONFIG_FILE, "r") as f:
            lines = f.readlines()
            current_host = ""
            hostnames = {}
            hosts_set = set()
            for line in lines:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("Host "):
                    parts = line.split()
                    for h in parts[1:]:
                        if "*" not in h:
                            current_host = h
                            hosts_set.add(h)
                elif line.startswith("Hostname "):
                    if current_host:
                        hostnames[current_host] = line.split()[1]
            printed = set()
            for host in sorted(hosts_set, key=lambda x: x.split(".")):
                if host_pattern.lower() in host.lower() and "*" not in host:
                    hostname = hostnames.get(host, host)
                    if hostname not in printed:
                        HOSTS.append(hostname)
                        printed.add(hostname)

    host_count = len(HOSTS)
    if host_count > 1 and not MASS_MODE:
        print("Multiple hosts detected:")
        for host in HOSTS:
            print(f"- {host}")
        print("Use --mass flag to execute commands on multiple hosts.")
        sys.exit(1)
    if not HOSTS:
        log("WARN", f"No hosts found matching '{host_pattern}'. Falling back to direct connection.")
        HOSTS = [host_pattern]
    log("DEBUG", f"Matching hosts: {', '.join(HOSTS)}")

# Process Substitution Handling
def handle_process_substitution(cmd: str) -> str:
    """
    Handle Bash-style process substitution <(command) by creating a temporary FIFO or file descriptor.
    Inspired by search results on process substitution in Python.
    """
    def create_subprocess(cmd_part: str) -> str:
        fifo_path = os.path.join(tempfile.gettempdir(), f"xssh_fifo_{os.getpid()}_{id(cmd_part)}")
        os.mkfifo(fifo_path)
        def write_to_fifo():
            with open(fifo_path, "w") as f:
                result = subprocess.run(cmd_part, shell=True, text=True, capture_output=True)
                f.write(result.stdout)
        threading.Thread(target=write_to_fifo, daemon=True).start()
        return fifo_path

    pattern = r"<(\([^()]*\))"
    matches = re.findall(pattern, cmd)
    for match in matches:
        fifo_path = create_subprocess(match)
        cmd = cmd.replace(f"<({match})", fifo_path)
    return cmd

# Remote Command Wrapping
def wrap_remote_command() -> str:
    if not COMMAND:
        return ""
    cmd_str = " ".join(COMMAND)
    cmd_str = handle_process_substitution(cmd_str)  # Handle process substitution
    if len(COMMAND) == 1:
        if SUDO_MODE:
            return f"sudo {cmd_str}"
        return cmd_str
    if any(char in cmd_str for char in "&|;><$(){}[]*") or len(COMMAND) > 1:
        quoted_cmd = " ".join(f"'{c}'" for c in COMMAND)
        if SUDO_MODE:
            return f"sudo sh -c {quoted_cmd}"
        return f"sh -c {quoted_cmd}"
    if SUDO_MODE:
        return f"sudo {cmd_str}"
    return cmd_str

# SSH Execution with Paramiko
def execute_ssh(host: str, output_file: str, verbose_prefix: str) -> int:
    exit_code = 0
    if VERBOSE_MODE and verbose_prefix:
        with open(output_file, "w") as f:
            f.write(f"{verbose_prefix}\n")

    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        connect_kwargs = {"hostname": host, "timeout": 5}
        if USERNAME:
            connect_kwargs["username"] = USERNAME
        # Workaround for "No authentication methods available" error
        # Attempt to use a dummy key if no other auth method is specified
        connect_kwargs["pkey"] = paramiko.ecdsakey.ECDSAKey.generate()
        # Allow agent and look for keys in default locations
        connect_kwargs["allow_agent"] = True
        connect_kwargs["look_for_keys"] = True
        ssh.connect(**connect_kwargs)
        remote_cmd = wrap_remote_command()
        if remote_cmd:
            log("DEBUG", f"Executing command on {host}: {remote_cmd}")
            if SUDO_MODE:
                stdin, stdout, stderr = ssh.exec_command(remote_cmd, get_pty=True)
            else:
                stdin, stdout, stderr = ssh.exec_command(remote_cmd)
            output = stdout.read().decode() + stderr.read().decode()
            with open(output_file, "a") as f:
                f.write(output)
            exit_status = stdout.channel.recv_exit_status()
            if exit_status != 0:
                exit_code = exit_status
                log("ERROR", f"Command failed on {host} with exit code {exit_code}")
            elif "error" in output.lower() or "not found" in output.lower():
                exit_code = 127
                log("ERROR", f"Command failed on {host} due to error in output (exit code set to {exit_code})")
        else:
            log("DEBUG", f"Opening interactive session on {host}")
            log("WARN", "Interactive sessions are not supported in this Python version.")
            exit_code = 1
    except Exception as e:
        exit_code = 1
        log("ERROR", f"SSH connection failed on {host}: {str(e)}")
        with open(output_file, "a") as f:
            f.write(f"Connection failed on {host}: {str(e)}\n")
    finally:
        ssh.close()
    if exit_code == 0:
        log_debug("Command executed successfully", host)
    return exit_code


def execute_ssh_command():
    for host in HOSTS:
        if VERBOSE_MODE:
            print(f"Executing command on {host}:")
        execute_ssh(host, "/dev/stdout", "")
        log("DEBUG", "All commands attempted.")

def parallel_execute():
    if MASS_MODE:
        tmpdir = tempfile.mkdtemp()
        threads = []
        for host in HOSTS:
            tmpfile = os.path.join(tmpdir, f"{host}.out")
            prefix = f"--- {host} ---" if VERBOSE_MODE else ""
            thread = threading.Thread(target=execute_ssh, args=(host, tmpfile, prefix))
            thread.start()
            threads.append(thread)
        for thread in threads:
            thread.join()
        for file in os.listdir(tmpdir):
            with open(os.path.join(tmpdir, file), "r") as f:
                print(f.read())
        os.rmdir(tmpdir)

# Main Execution
if __name__ == "__main__":
    args = parse_arguments()
    if args.pattern in ["-h", "--help"]:
        usage()
        sys.exit(0)
    validate_input(args)
    setup_logging()
    validate_prerequisites()
    extract_hosts()
    if MASS_MODE:
        parallel_execute()
    else:
        execute_ssh_command()
