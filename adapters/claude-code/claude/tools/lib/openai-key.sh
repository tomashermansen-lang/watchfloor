#!/bin/bash
# openai-key.sh — single-source-of-truth helper for the OpenAI API key.
#
# Reads OPENAI_API_KEY from secrets/openai.env in the dotfiles repo. Fails
# loudly with a setup hint if the file is missing, empty, or still contains
# the placeholder. Designed to be sourced — exports OPENAI_API_KEY on success.
#
# Usage (sourced):
#   source claude/tools/lib/openai-key.sh   # exports OPENAI_API_KEY or returns 1
#
# Usage (script):
#   bash claude/tools/lib/openai-key.sh && echo "ok"

set -uo pipefail

_openai_key_repo_dir() {
    # Resolve the dotfiles repo dir from this file's location.
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # lib/ → tools/ → claude/ → repo
    (cd "$lib_dir/../../.." && pwd)
}

load_openai_key() {
    local repo_dir env_file
    repo_dir=$(_openai_key_repo_dir)
    env_file="$repo_dir/secrets/openai.env"

    if [[ ! -f "$env_file" ]]; then
        cat >&2 <<EOF
Error: OPENAI_API_KEY not configured.

Missing file: $env_file

To set it up:
  cp $repo_dir/secrets/openai.env.example $env_file
  # Then edit $env_file and paste in your real key.
EOF
        return 1
    fi

    # Source the file in a subshell-safe manner. set -a marks all subsequent
    # variable assignments for export.
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a

    if [[ -z "${OPENAI_API_KEY:-}" ]] || [[ "$OPENAI_API_KEY" == "sk-replace-me" ]]; then
        cat >&2 <<EOF
Error: OPENAI_API_KEY is empty or still the placeholder.

File: $env_file
Edit it and paste in your real key from https://platform.openai.com/api-keys.
EOF
        return 1
    fi

    export OPENAI_API_KEY
    return 0
}

# If executed directly (not sourced), run the loader for a quick check.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if load_openai_key; then
        echo "OPENAI_API_KEY loaded (length: ${#OPENAI_API_KEY})"
    else
        exit 1
    fi
fi
