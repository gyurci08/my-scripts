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
    {sub(/^ +/, "")} # Remove leading whitespace
    $1 == "Host" { host = $2; hostname = "" }
    $1 == "Hostname" { hostname = $2 }
    $0 == "" || $1 == "Host " {
        if (hostname != "" && hostname !~ /\*/ && hostname ~ pattern && !seen[hostname]) {
            print hostname
            seen[hostname] = 1
        } else if (hostname == "" && host !~ /\*/ && host ~ pattern && !seen[host]) {
            print host
            seen[host] = 1
        }
    }
' ~/.ssh/config

