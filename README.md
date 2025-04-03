# lscache-Cleaner

clear_lscache.sh - Version 2

A robust Bash script to clear the contents of the "lscache" folders for all cPanel accounts across multiple partitions on a WHM server. This script processes deletions in parallel, includes enhanced logging (both to log files and syslog), supports dry-run mode, and provides a final summary report per partition with details about the cache cleared and the number of accounts processed.

Features:
-----------
- Parallel Processing: Process multiple lscache directories concurrently with a configurable parallel job limit.
- Configurable Attempts: Set the number of deletion attempts per account.
- Dry-Run Mode: Optionally run the script in dry-run mode to see what would be deleted.
- Enhanced Logging: Writes errors and summary information for customizable log files and logs them to syslog.
- Graceful Shutdown: Handles SIGINT/SIGTERM to terminate background jobs gracefully and print a summary.
- Post-Deletion Verification: Checks that each lscache folder is empty after deletion and logs warnings if not.
- Final Summary: Aggregates a per-partition summary report with the total cache cleared and count of processed cPanel accounts.

Prerequisites:
--------------
- The script must be run as root.
- GNU utilities are required (e.g., GNU du, find, numfmt).
- A compatible Bash shell (version 4.0 or later is recommended for associative arrays).

Usage:
------
Make the script executable and run it with your desired options:

```wget https://raw.githubusercontent.com/thekugelblitz/clear_lscache/main/clear_lscache.sh -O clear_lscache.sh```


    chmod +x clear_lscache.sh
    sudo ./clear_lscache.sh [options]

Options:
--------

-d
Enable dry-run mode (do not actually delete files).

-n ATTEMPTS
Set the number of deletion attempts per account (default: 2).

-p JOBS
Set the number of parallel jobs (default: 4).

-e FILE
Specify the error log file (default: /var/log/clear_lscache_errors.log).

-s FILE
Specify the summary log file (default: /var/log/clear_lscache_summary.log).

-h
Display the help message.

Example:
--------
To run the script in dry-run mode with 3 deletion attempts and 6 parallel jobs using custom log files:

    sudo ./clear_lscache.sh -d -n 3 -p 6 -e /path/to/error.log -s /path/to/summary.log

Output:
-------
The script displays disk usage before and after cleanup, processes each lscache directory with detailed logging, and prints a final summary report similar to:

```
Cache deletion summary (per partition):

Home:
--------------------------------
account1: 7.4Mi
account2: 0
...
Total cache cleared: 155Mi
Accounts processed: 3
*******************************

Home2:
--------------------------------
accountX: 1.2Gi
...
Total cache cleared: 935Mi
Accounts processed: 172
*******************************
```

Contribution:
-------------
Developed by Dhruval Joshi from HostingSpell (https://hostingspell.com)
GitHub Profile: https://github.com/thekugelblitz
-(Optimized with the help of GPT4)

License:
--------
This script is released under the **GNU GENERAL PUBLIC LICENSE Version 3**. You are free to modify and use it for commercial or personal use. I would appreciate your contribution! 😊

---

Notes:
------
- Test the script in a non-production environment before deploying it live.
- Monitor the log files for any errors or warnings after execution.
