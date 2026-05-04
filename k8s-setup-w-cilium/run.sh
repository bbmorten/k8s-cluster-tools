#!/bin/bash

# This script runs an Ansible command to check the uptime of nodes.
# It supports debug mode for verbosity, syntax-check mode to validate playbooks,
# and check mode to perform a dry run without making changes.

# Usage:
#   ./run.sh PLAYBOOK_FILE [--debug=true] [--syntax-check] [--check]
#
# Arguments:
#   PLAYBOOK_FILE  Path to the Ansible playbook file to execute (required)
#
# Options:
#   --debug=true   Enable debug mode (adds -vvvv to the Ansible command for increased verbosity)
#   --syntax-check Perform a syntax check on the playbook (validates the playbook's syntax)
#   --check        Run the playbook in check mode (dry-run without making changes)

# Check passed arguments and set flags accordingly
# Initialize variables
playbook_file=""
debug_mode=false
syntax_check=false
check_mode=false

# Parse all arguments
for arg in "$@"; do
    if [[ "$arg" == "--debug=true" ]]; then
        debug_mode=true
    elif [[ "$arg" == "--syntax-check" ]]; then
        syntax_check=true
    elif [[ "$arg" == "--check" ]]; then
        check_mode=true
    elif [[ "$arg" != --* && "$playbook_file" == "" ]]; then
        # First non-option argument is the playbook file
        playbook_file="$arg"
    fi
done

# Check if playbook file was provided
if [[ -z "$playbook_file" ]]; then
    echo "Error: No playbook file specified"
    echo "Usage: $0 PLAYBOOK_FILE [--debug=true] [--syntax-check] [--check]"
    exit 1
fi

# Check if the playbook file exists
if [[ ! -f "$playbook_file" ]]; then
    echo "Error: Playbook file '$playbook_file' not found"
    exit 1
fi

# Get the directory where the script is located (absolute path)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set the Ansible config environment variable
export ANSIBLE_CONFIG="${SCRIPT_DIR}/ansible.cfg"

# -----------------------------------------------------------------------------
# Logging — tee all stdout/stderr to logs/run-<playbook>-<timestamp>.log
# -----------------------------------------------------------------------------
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
ts="$(date +%Y%m%d-%H%M%S)"
playbook_tag="$(basename "${playbook_file%.*}")"
LOG_FILE="${LOG_DIR}/run-${playbook_tag}-${ts}.log"

# Ansible verbose/structured output alongside the terminal log
export ANSIBLE_LOG_PATH="${LOG_DIR}/ansible-${playbook_tag}-${ts}.log"

# Redirect all subsequent output to both terminal and log file
exec > >(tee -a "$LOG_FILE") 2>&1

echo "==================================================================="
echo "run.sh start: $(date -Iseconds)"
echo "  host:       $(hostname)"
echo "  user:       $(whoami)"
echo "  cwd:        $(pwd)"
echo "  playbook:   $playbook_file"
echo "  flags:      debug=$debug_mode syntax_check=$syntax_check check_mode=$check_mode"
echo "  log:        $LOG_FILE"
echo "  ansible:    $ANSIBLE_LOG_PATH"
echo "==================================================================="

trap 'rc=$?; echo "==================================================================="; echo "run.sh end:   $(date -Iseconds)  exit=$rc"; echo "==================================================================="' EXIT

# Base Ansible command with the provided playbook file
ansible_command="ansible-playbook -b -K $playbook_file "

# Add options based on flags
if [ "$syntax_check" = true ]; then
    ansible_command+=" --syntax-check"
    echo "Running in syntax-check mode"
elif [ "$check_mode" = true ]; then
    ansible_command+=" --check"
    echo "Running in check mode (dry-run)"
fi

# Add debug verbosity if requested
if [ "$debug_mode" = true ]; then
    ansible_command+=" -vvvv"
    echo "Debug mode enabled"
fi

# Execute the Ansible command
echo "Running Ansible command: $ansible_command"
eval "$ansible_command"

# Display a message about the execution mode
if [ "$syntax_check" = true ]; then
    echo "Syntax check completed."
elif [ "$check_mode" = true ]; then
    echo "Check mode completed. No changes were made."
else
    echo "Playbook execution completed."
fi