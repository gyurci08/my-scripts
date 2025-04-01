#!/bin/bash

# Check if SSH config file exists
if [ ! -f ~/.ssh/config ]; then
    echo "SSH config file not found."
    exit 1
fi

# Check if an argument was provided
if [ -z "$1" ]; then
    echo "Please provide a pattern to search for."
    echo "Usage: $0 <pattern> [ssh options]"
    exit 1
fi

# Extract username if provided
if [[ $1 =~ "@" ]]; then
    # Extract username and hostname
    USERNAME=${1%@*}
    HOST_PATTERN=${1#*@}
else
    USERNAME=""
    HOST_PATTERN=$1
fi

# Get the hosts from the SSH config
HOSTS=$(awk -v pattern="$HOST_PATTERN" '
    # Remove leading/trailing whitespace
    { sub(/^ +/, ""); sub(/ +$/, ""); }

    # Skip empty lines or comments
    /^$/ || /^#/ { next }

    # Handle Hostname lines and associate them with the current host
    /^Hostname/ {
        if (current_host) {
            hostnames[current_host] = $2
        }
    }

    # Handle Host lines
    /^Host/ {
        split($0, hosts, " ")
        for (i=2; i<=NF; i++) {
            if (hosts[i] !~ /\*/) {
                current_host = hosts[i]
                hosts_array[hosts[i]] # Store host without *
            }
        }
    }

    END {
        for (host in hosts_array) {
            if (tolower(host) ~ pattern && host !~ /\*$/) {
                if (hostnames[host]) {
                    if (!(hostnames[host] in printed)) {
                        print hostnames[host] # Print Hostname if available
                        printed[hostnames[host]] = 1
                    }
                } else {
                    if (!(host in printed)) {
                        print host # Otherwise, print Host entry itself
                        printed[host] = 1
                    }
                }
            }
        }
    }
' ~/.ssh/config)

# Check if hosts were found
if [ -z "$HOSTS" ]; then
    echo "No hosts found matching the pattern."
    exit 1
fi

# Check if multiple hosts are found and no command is provided
if [ $(echo "$HOSTS" | wc -w) -gt 1 ] && [ ${#} -eq 1 ]; then
    echo "Multiple hosts found:"
    for HOST in $HOSTS; do
        echo "- $HOST"
    done
    echo "Please specify a command to proceed."
    exit 1
fi

# Check if multiple hosts are found and prompt for confirmation
if [ $(echo "$HOSTS" | wc -w) -gt 1 ]; then
    echo "Multiple hosts found:"
    echo "The following hosts will be affected:"
    for HOST in $HOSTS; do
        echo "- $HOST"
    done
    read -p "Are you sure you want to execute the command on all these hosts? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo "Operation cancelled."
        exit 1
    fi
fi

# Loop through each host and execute the ssh command
for HOST in $HOSTS; do
    echo "Connecting to $HOST..."
    # Pass the host and any additional ssh options to ssh
    if [ -n "$USERNAME" ]; then
        ssh -l "$USERNAME" "$HOST" "${@:2}"
    else
        ssh "$HOST" "${@:2}"
    fi
done
