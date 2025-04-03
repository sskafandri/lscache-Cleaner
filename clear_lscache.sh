#!/bin/bash
#
# clear_lscache.sh
#
# This script clears only the content inside each cPanel account's lscache folder.
#
# Features:
#  • Uses command-line options to enable dry-run (-d), set deletion attempts (-n),
#    specify parallel jobs (-p), and set custom log file paths (-e for error log, -s for summary log).
#  • Uses signal trapping (SIGINT, SIGTERM) for a graceful shutdown.
#  • Processes deletion in parallel (with a configurable concurrency limit).
#  • Uses enhanced logging via log files and syslog (via logger).
#  • After deletion, verifies that the folder is empty; if not, logs a warning.
#  • Aggregates a final summary by partition (top-level folder) with account names,
#    total cache cleared and the count of accounts processed.
#
# Usage:
#   chmod +x clear_lscache.sh
#   sudo ./clear_lscache.sh [options]
#
# Options:
#   -d            Dry-run mode (do not actually delete files)
#   -n ATTEMPTS   Number of deletion attempts per account (default: 2)
#   -p JOBS       Number of parallel jobs (default: 4)
#   -e FILE       Error log file (default: /var/log/clear_lscache_errors.log)
#   -s FILE       Summary log file (default: /var/log/clear_lscache_summary.log)
#   -h            Display help
#

set -euo pipefail

# Default options
DRY_RUN=0
ATTEMPTS=2
PARALLEL=4
ERROR_LOG="/var/log/clear_lscache_errors.log"
SUMMARY_LOG="/var/log/clear_lscache_summary.log"

# Usage function
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -d            Dry-run mode (do not actually delete files)"
    echo "  -n ATTEMPTS   Number of deletion attempts per account (default: 2)"
    echo "  -p JOBS       Number of parallel jobs (default: 4)"
    echo "  -e FILE       Error log file (default: /var/log/clear_lscache_errors.log)"
    echo "  -s FILE       Summary log file (default: /var/log/clear_lscache_summary.log)"
    echo "  -h            Display this help message"
    exit 1
}

# Parse command-line options
while getopts "dn:p:e:s:h" opt; do
    case "${opt}" in
        d) DRY_RUN=1 ;;
        n) ATTEMPTS="${OPTARG}" ;;
        p) PARALLEL="${OPTARG}" ;;
        e) ERROR_LOG="${OPTARG}" ;;
        s) SUMMARY_LOG="${OPTARG}" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

# Ensure the script is run as root.
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
fi

# Prepare log files
: > "$ERROR_LOG"
echo "Clear lscache errors log - $(date)" >> "$ERROR_LOG"
: > "$SUMMARY_LOG"
echo "Clear lscache summary - $(date)" >> "$SUMMARY_LOG"

# Create a temporary file to hold per-account summary lines.
SUMMARY_TMP=$(mktemp)

# Declare an array for background job PIDs.
declare -a pids

# Global flag to indicate interruption.
INTERRUPTED=0

# Trap SIGINT and SIGTERM to gracefully shutdown.
cleanup() {
    INTERRUPTED=1
    echo "Signal received, terminating background jobs..."
    for pid in "${pids[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
    done
    wait
    aggregate_summary
    echo "Terminated due to signal." | tee -a "$ERROR_LOG"
    exit 1
}
trap cleanup SIGINT SIGTERM

# log_msg logs a message both to stdout and syslog.
log_msg() {
    local level="$1"
    local msg="$2"
    echo "$msg"
    logger -p "user.${level}" "$msg"
}

# Function to calculate the total size (in bytes) of all regular files in a directory.
get_cache_size_bytes() {
    local dir="$1"
    find "$dir" -type f -printf "%s\n" 2>/dev/null | awk '{sum+=$1} END {print sum+0}'
}

# process_directory processes one lscache directory.
# It computes the current cache size, then (if not dry-run) attempts deletion,
# verifies the folder is empty, and writes a summary line: group<TAB>account<TAB>cleared_bytes.
process_directory() {
    local lscache_dir="$1"
    local account group cleared_bytes size_bytes attempt success

    # Derive account and group.
    account=$(basename "$(dirname "$lscache_dir")")
    group=$(echo "$lscache_dir" | cut -d '/' -f2)  # e.g. "home", "home2", etc.

    # Compute current cache size (sum of file sizes) before deletion.
    size_bytes=$(get_cache_size_bytes "$lscache_dir")
    
    if [[ $DRY_RUN -eq 1 ]]; then
        log_msg "info" "Dry-run: [$lscache_dir] Would clear $(numfmt --to=iec-i "$size_bytes")"
        cleared_bytes="$size_bytes"
    else
        success=0
        attempt=0
        while [[ $attempt -lt $ATTEMPTS && $success -eq 0 ]]; do
            attempt=$((attempt+1))
            if pushd "$lscache_dir" > /dev/null; then
                # Enable dotglob and nullglob to include hidden files.
                shopt -s dotglob nullglob
                items=( * )
                if [[ ${#items[@]} -gt 0 ]]; then
                    if rm -rf -- "${items[@]}"; then
                        success=1
                    else
                        success=0
                    fi
                else
                    success=1
                fi
                shopt -u dotglob nullglob
                popd > /dev/null
            else
                log_msg "err" "Error: Cannot change directory to $lscache_dir. Skipping."
                echo -e "$group\t$account\t0" >> "$SUMMARY_TMP"
                return 1
            fi

            if [[ $success -eq 0 ]]; then
                log_msg "warning" "Attempt $attempt failed for $lscache_dir, retrying..."
                sleep 1
            fi
        done

        if [[ $success -eq 0 ]]; then
            log_msg "err" "Error: Failed to clear contents of $lscache_dir after $ATTEMPTS attempts"
            echo -e "$group\t$account\t0" >> "$SUMMARY_TMP"
            return 1
        fi

        # Post-deletion verification: ensure directory is empty.
        if find "$lscache_dir" -mindepth 1 -print -quit | grep -q .; then
            log_msg "warning" "Warning: $lscache_dir is not empty after deletion."
        fi
        cleared_bytes="$size_bytes"
        log_msg "info" "Successfully cleared $lscache_dir: Cache size cleared: $(numfmt --to=iec-i "$cleared_bytes")"
    fi

    # Write summary line: group<tab>account<tab>cleared_bytes
    echo -e "$group\t$account\t$cleared_bytes" >> "$SUMMARY_TMP"
}

# limit_jobs waits until the number of background jobs is less than PARALLEL.
limit_jobs() {
    while (( $(jobs -rp | wc -l) >= PARALLEL )); do
        sleep 0.5
    done
}

# Aggregate the summary from the temporary file and print a report.
aggregate_summary() {
    declare -A partition_report
    declare -A partition_sizes
    declare -A partition_counts

    # Read the temporary summary file line by line.
    while IFS=$'\t' read -r group account bytes; do
        # Append this account's line to the group's report.
        if [[ -z "${partition_report[$group]:-}" ]]; then
            partition_report[$group]="$account: $(numfmt --to=iec-i "$bytes")"
        else
            partition_report[$group]+=$'\n'"$account: $(numfmt --to=iec-i "$bytes")"
        fi
        # Sum up the sizes per group.
        partition_sizes[$group]=$(( ${partition_sizes[$group]:-0} + bytes ))
        # Count the number of accounts processed per group.
        partition_counts[$group]=$(( ${partition_counts[$group]:-0} + 1 ))
    done < "$SUMMARY_TMP"

    echo ""
    echo "Cache deletion summary (per partition):" | tee -a "$SUMMARY_LOG"
    for grp in "${!partition_report[@]}"; do
        # Capitalize first letter for display.
        grp_title="$(tr '[:lower:]' '[:upper:]' <<< "${grp:0:1}")${grp:1}"
        echo "$grp_title:" | tee -a "$SUMMARY_LOG"
        echo "--------------------------------" | tee -a "$SUMMARY_LOG"
        echo "${partition_report[$grp]}" | tee -a "$SUMMARY_LOG"
        echo "Total cache cleared: $(numfmt --to=iec-i "${partition_sizes[$grp]}")" | tee -a "$SUMMARY_LOG"
        echo "Accounts processed: ${partition_counts[$grp]}" | tee -a "$SUMMARY_LOG"
        echo "*******************************" | tee -a "$SUMMARY_LOG"
    done
}

# Main script execution

echo "Disk usage BEFORE cleanup:"
df -h

# Find all lscache directories under typical cPanel home directories.
mapfile -d '' lscache_dirs < <(find /home* -maxdepth 2 -type d -name "lscache" -print0)

total_dirs=${#lscache_dirs[@]}
echo "Found $total_dirs lscache directories."

# Process each directory in parallel.
for dir in "${lscache_dirs[@]}"; do
    # If interrupted, break out.
    if [[ $INTERRUPTED -eq 1 ]]; then
        break
    fi
    limit_jobs
    process_directory "$dir" &
    pids+=("$!")
done

# Wait for all background jobs to finish.
wait

echo "Disk usage AFTER cleanup:"
df -h

# Aggregate and print the summary.
aggregate_summary

# Append the summary to the summary log file.
cat "$SUMMARY_TMP" >> "$SUMMARY_LOG"
rm -f "$SUMMARY_TMP"

echo "Operation completed successfully."
