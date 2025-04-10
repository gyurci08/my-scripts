#!/bin/bash

# Check if the SSH config file exists
if [ ! -f ~/.ssh/config ]; then
    echo "SSH config file not found."
    exit 1
fi

# Check if an argument was provided
if [ -z "$1" ]; then
    echo "Please provide a pattern to search for."
    echo "Usage: $0 <pattern>"
    exit 1
fi

awk -v pattern="$1" '
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
' ~/.ssh/config | sort -V
