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
    # Convert pattern to lowercase once
    BEGIN { lp = tolower(pattern) }

    # Remove leading whitespace and skip empty lines
    {sub(/^ +/, ""); if (NF == 0) next}

    # Handle Host lines
    /^Host/ {
        if (NF == 2) {                             # Only one Host
            single_host = $2
            lc_str = tolower(single_host)
            if (lc_str !~ /\*/ && lc_str ~ lp) {
                if (!seen[single_host]) {
                    known_host = single_host
                }
            }
        } else { # Multiple Hosts
            for (i = 2; i <= NF; i++) {
                lc_str = tolower($i)
                if (lc_str !~ /\*/ && lc_str ~ lp && !seen[$i]) {
                    print $i
                    seen[$i] = 1
                }
            }
        }
    }

    # Handle Hostname lines
    /^Hostname/ {
        hostname = $2
        if (single_host != "") {                   # If there was only one Host
            lc_str = tolower(hostname)
            if (lc_str !~ /\*/ && lc_str ~ lp && !seen[hostname]) {
                print hostname
                seen[hostname] = 1
                known_host = ""
            }
        }
    }

    END {
        if (known_host != "" && !seen[known_host]) {
            print known_host
            seen[known_host] = 1
        }
    }
' ~/.ssh/config
)

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
