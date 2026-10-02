#!/bin/bash
#
# Undo macos-optimization.command
# https://github.com/wasim-osman/macos-optimization
#
# Double-click to run, or:
#   ./restore-defaults.command
#
# This is a thin wrapper so the undo can live in the Dock on its own, without
# anyone having to remember the --undo flag. All the work happens in
# macos-optimization.command; this file only locates it and forwards.

set -uo pipefail

# Resolve the sibling script through symlinks so this still works if
# restore-defaults.command is linked somewhere else on the Dock.
source_path="${BASH_SOURCE[0]}"
while [[ -L "$source_path" ]]; do
    link_target=$(readlink "$source_path")
    case "$link_target" in
        /*) source_path="$link_target" ;;
        *)  source_path="$(dirname "$source_path")/$link_target" ;;
    esac
done
script_dir="$(cd "$(dirname "$source_path")" && pwd)"
target="$script_dir/macos-optimization.command"

if [[ ! -f "$target" ]]; then
    printf '\nerror: cannot find macos-optimization.command next to this file.\n'
    printf 'expected: %s\n\n' "$target" >&2
    printf 'Clone the repo again, or download both files into the same folder:\n'
    printf '  https://github.com/wasim-osman/macos-optimization\n\n' >&2
    read -r -p "Press Enter to close..." _
    exit 1
fi

if [[ ! -x "$target" ]]; then
    chmod +x "$target" 2>/dev/null \
        || { printf '\nerror: %s is not executable.\nTry: chmod +x "%s"\n\n' "$target" "$target" >&2
             read -r -p "Press Enter to close..." _
             exit 1; }
fi

exec "$target" --undo
