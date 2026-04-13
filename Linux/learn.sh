#!/usr/bin/env bash
# Export Git project structure and text file contents in an AI-friendly format

set -euo pipefail

MAX_SIZE=200000  # 200 KB

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: Not inside a Git repository."
    exit 1
fi

FILES="$(git ls-files --cached --others --exclude-standard)"

if [ -z "$FILES" ]; then
    echo "BEGIN_REPOSITORY"
    echo "REPOSITORY_STATUS: empty"
    echo "END_REPOSITORY"
    exit 0
fi

print_structure() {
    echo "BEGIN_PROJECT_STRUCTURE"
    if command -v tree >/dev/null 2>&1; then
        if tree --help 2>/dev/null | grep -q -- '--gitignore'; then
            tree --gitignore
        else
            tree -I .git
        fi
    else
        printf '%s\n' "$FILES"
    fi
    echo "END_PROJECT_STRUCTURE"
}

print_file() {
    local file="$1"

    echo "BEGIN_FILE path=\"$file\""
    cat "$file"
    echo
    echo "END_FILE"
}

print_skipped_file() {
    local file="$1"
    local reason="$2"

    echo "BEGIN_SKIPPED_FILE path=\"$file\" reason=\"$reason\""
    echo "END_SKIPPED_FILE"
}

echo "BEGIN_REPOSITORY"

print_structure

echo "BEGIN_FILE_CONTENTS"

while IFS= read -r file; do
    [ -z "$file" ] && continue

    if [ ! -f "$file" ]; then
        print_skipped_file "$file" "not_a_regular_file"
        continue
    fi

    size="$(wc -c < "$file")"

    if [ "$size" -gt "$MAX_SIZE" ]; then
        print_skipped_file "$file" "too_large"
        continue
    fi

    if ! grep -Iq . "$file"; then
        print_skipped_file "$file" "binary_or_non_text"
        continue
    fi

    print_file "$file"
done <<EOF
$FILES
EOF

echo "END_FILE_CONTENTS"
echo "END_REPOSITORY"