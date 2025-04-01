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

# Get the hosts from the SSH config
HOSTS=$(awk -v pattern="$1" '
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
    echo "$HOSTS"
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
    # Check if username is included
    if [[ $HOST =~ "@" ]]; then
        # Extract username and hostname
        USERNAME=${HOST%@*}
        HOSTNAME=${HOST#*@}
        # Pass the host and any additional ssh options to ssh
        ssh -l "$USERNAME" "$HOSTNAME" "${@:2}"
    else
        # Pass the host and any additional ssh options to ssh
        ssh "$HOST" "${@:2}"
    fi
done
