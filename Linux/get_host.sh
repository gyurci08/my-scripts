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
