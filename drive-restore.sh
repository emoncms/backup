#!/bin/bash

# Restore Emoncms from a drive-backup.sh mirror on an attached drive.
#
# drive-backup.sh maintains a directory mirror rather than a tar archive, so
# emoncms-import.sh cannot read it. This is the matching restore.
#
# It copies the feed data back, imports one of the retained MYSQL snapshots and
# restores emonhub.conf. Emoncms settings.ini / settings.php are deliberately
# NOT restored: they hold database credentials and paths belonging to the system
# the backup came from, which are not necessarily correct here.
#
# CAUTION: this overwrites the Emoncms database and feed data on this system.
# The current database is dumped to the backup_location first so that a mistaken
# restore can be undone, but feed data is overwritten in place.
#
# Usage:
#   ./drive-restore.sh --list         Show the snapshots available on the drive
#   ./drive-restore.sh                Restore the newest snapshot, asks to confirm
#   ./drive-restore.sh --sql <name>   Restore a specific snapshot
#   ./drive-restore.sh --dry-run      Report what would be done, change nothing
#   ./drive-restore.sh --delete       Also remove feed files not present in the
#                                   backup, making the restore an exact mirror
#   ./drive-restore.sh --yes          Do not ask to confirm. Required when not run
#                                   from a terminal, as the Emoncms interface does.

# Set the shell to trigger errors when commands within a pipe have a non-zero return code
set -o pipefail

# The errors variable is set when error_handler() is called, the variable is used by the finish() function for success or failure messages
errors=false

# This error handler function display information of what happened and where, but does NOT stop the script execution
error_handler() {
    echo "Error: RC=$1 occurred on line $2"
    errors=true
}

# Set trap for ERR to pass the return code and line number to error_handler()
trap 'error_handler $? $LINENO' ERR

start_seconds=$SECONDS
cancelled=false
mysql_defaults_file=""
services_stopped=false

# Exit handler used to ensure the exit message AJAX expects is found, whilst summarising if errors were found
# This also picks up the natural exit when reaching end of script
function finish() {
    local rc=$?

    # Never leave the temporary mysql credentials file behind
    if [ -n "${mysql_defaults_file}" ] && [ -f "${mysql_defaults_file}" ]; then
        rm -f "${mysql_defaults_file}"
    fi

    # A restore that failed part way through must not leave the system with its
    # services down, whatever went wrong
    if [ "${services_stopped}" == "true" ]; then
        start_services
    fi

    if [ "${cancelled}" == "true" ]; then
        echo "=== Emoncms drive restore cancelled ==="
# The strings output are identified in the interface to stop ongoing AJAX calls, please ammend in interface if changed here
        exit 0
    fi

    if [[ "${errors}" == "false" && ${rc} == 0 ]]; then
        echo "=== Emoncms drive restore complete! ==="
# The strings output are identified in the interface to stop ongoing AJAX calls, please ammend in interface if changed here
    else
        echo "=== Emoncms drive restore completed with ERRORS! ==="
# The strings output are identified in the interface to stop ongoing AJAX calls, please ammend in interface if changed here
        if [ ${rc} -eq 0 ]; then
            exit 1
        fi
    fi
}

# Set trap for whenever EXIT is called to call finish()
trap finish EXIT

#-----------------------------------------------------------------------------------------------
# Helper functions
#-----------------------------------------------------------------------------------------------

# Walk up from a path until an existing directory is found
existing_ancestor() {
    local p="$1"
    while [ ! -e "${p}" ] && [ "${p}" != "/" ]; do
        p=$(dirname "${p}")
    done
    echo "${p}"
}

# The backup may live on a filesystem that cannot store unix ownership, in which
# case it was written without it. Reading back is unaffected, but rsync must not
# be asked to reproduce ownership that is not there. Correct ownership is applied
# explicitly after each engine is restored.
rsync_ownership_opts() {
    case "${drive_backup_preserve_permissions}" in
        yes) return 0 ;;
        no)  echo "--no-perms --no-owner --no-group"; return 0 ;;
    esac
    case "${dest_fstype}" in
        cifs|smb3|smbfs|vfat|exfat|msdos|ntfs|ntfs3|fuseblk)
            echo "--no-perms --no-owner --no-group"
            ;;
    esac
}

# Services are stopped for the whole restore, feed data must not be written
# while it is being replaced
stop_services() {
    [ -f "/.dockerenv" ] && return 0
    echo "Stopping services.."
    local svc
    for svc in emonhub feedwriter mqtt_input emoncms_mqtt; do
        if [ "$(systemctl show ${svc} | grep LoadState | cut -d= -f2)" == "loaded" ]; then
            echo "-- stopping ${svc}"
            sudo systemctl stop ${svc}
        fi
    done
    services_stopped=true
}

start_services() {
    services_stopped=false
    [ -f "/.dockerenv" ] && return 0
    echo "Restarting services.."
    local svc
    for svc in emonhub feedwriter mqtt_input emoncms_mqtt; do
        if [ "$(systemctl show ${svc} | grep LoadState | cut -d= -f2)" == "loaded" ]; then
            echo "-- starting ${svc}"
            sudo systemctl start ${svc}
        fi
    done
}

# List the MYSQL snapshots held on the drive, newest first
list_snapshots() {
    local period file
    shopt -s nullglob
    for period in daily weekly; do
        local files=( "${drive_backup_path}/sql/${period}"/*.sql.gz )
        [ ${#files[@]} -eq 0 ] && continue
        local sorted=()
        mapfile -t sorted < <(printf '%s\n' "${files[@]}" | sort -r)
        for file in "${sorted[@]}"; do
            printf '  %-8s %-48s %s\n' "${period}" "$(basename "${file}")" \
                "$(du -h "${file}" | cut -f1)"
        done
    done
    shopt -u nullglob
}

# Resolve a snapshot name to a full path, or pick the newest if none was given.
# The name reaches this script from the Emoncms interface, so it is treated as
# untrusted: basename only, and it has to actually be one of the files on the drive.
resolve_snapshot() {
    local requested="$1"
    local period files sorted

    if [ -n "${requested}" ]; then
        if [ "${requested}" != "$(basename "${requested}")" ]; then
            echo "ERROR: snapshot name must not contain a path: ${requested}" >&2
            return 1
        fi
        for period in daily weekly; do
            if [ -f "${drive_backup_path}/sql/${period}/${requested}" ]; then
                echo "${drive_backup_path}/sql/${period}/${requested}"
                return 0
            fi
        done
        echo "ERROR: snapshot ${requested} not found on the backup drive" >&2
        return 1
    fi

    # No snapshot requested, use the newest daily, falling back to weekly
    shopt -s nullglob
    for period in daily weekly; do
        files=( "${drive_backup_path}/sql/${period}"/*.sql.gz )
        if [ ${#files[@]} -gt 0 ]; then
            mapfile -t sorted < <(printf '%s\n' "${files[@]}" | sort -r)
            shopt -u nullglob
            echo "${sorted[0]}"
            return 0
        fi
    done
    shopt -u nullglob

    echo "ERROR: no MYSQL snapshots found on the backup drive" >&2
    return 1
}

#-----------------------------------------------------------------------------------------------
# Parse arguments
#-----------------------------------------------------------------------------------------------
requested_sql=""
do_list=false
dry_run=false
assume_yes=false
delete_extra=false

while [ $# -gt 0 ]; do
    case "$1" in
        --list)    do_list=true ;;
        --dry-run) dry_run=true ;;
        --yes|-y)  assume_yes=true ;;
        --delete)  delete_extra=true ;;
        --sql)
            shift
            if [ -z "$1" ]; then
                echo "Error: --sql requires a snapshot filename"
                exit 1
            fi
            requested_sql="$1"
            ;;
        --help|-h)
            # Print the header comment block, stopping at the blank line that ends it
            awk 'NR>2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
            trap - EXIT
            exit 0
            ;;
        *)
            echo "Error: unknown argument $1"
            echo "Usage: $0 [--list] [--sql <name>] [--delete] [--dry-run] [--yes]"
            exit 1
            ;;
    esac
    shift
done

script_location="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
config_location=${script_location}/config.cfg

echo "=== Emoncms drive restore start ==="
date
echo "Backup module version:"
grep version "${script_location}/module.json"
echo "EUID: $EUID"
echo "Reading ${config_location}...."

if [ ! -f "${config_location}" ]
then
    echo "ERROR: Backup config file ${config_location} does not exist"
    exit 1
fi

source "${config_location}"

: "${drive_backup_path:=}"
: "${drive_backup_preserve_permissions:=auto}"
: "${drive_backup_probe_seconds:=20}"

# A destination chosen in the Emoncms interface is kept in its own small file
# rather than in config.cfg, which is sourced as shell by this script running as
# root. Read as plain text and pattern checked, never executed.
path_conf=${script_location}/drive-backup-path.conf
if [ -f "${path_conf}" ]; then
    ui_path=$(grep -m1 '^drive_backup_path=' "${path_conf}" 2>/dev/null | cut -d= -f2-)
    if [ -n "${ui_path}" ]; then
        if [[ "${ui_path}" =~ ^/[A-Za-z0-9._@/+-]+$ ]]; then
            drive_backup_path="${ui_path}"
        else
            echo "WARNING: ignoring invalid drive_backup_path in ${path_conf}"
        fi
    fi
fi

echo "Location of databases: $database_path"
echo "Location of emonhub.conf: $emonhub_config_path"
echo "Location of Emoncms: $emoncms_location"
echo "Restore source: $drive_backup_path"

if [ -z "${drive_backup_path}" ]; then
    echo "ERROR: drive_backup_path is not set in ${config_location}, nothing to restore from"
    exit 1
fi

#-----------------------------------------------------------------------------------------------
# The backup drive must be present. This is the same marker file drive-backup.sh
# writes, so a drive that is not mounted is detected on exactly the same basis.
#-----------------------------------------------------------------------------------------------
check_path=$(existing_ancestor "${drive_backup_path}")
dest_fstype=$(findmnt -no FSTYPE --target "${check_path}" 2>/dev/null)

# A network share can be mounted but unreachable, and on a hard NFS mount any
# access then blocks in uninterruptible IO forever. Probe before committing.
case "${dest_fstype}" in
    nfs|nfs4|cifs|smb3|smbfs|fuse.sshfs)
        echo "Source is a network share (${dest_fstype}), checking it responds.."
        if ! timeout "${drive_backup_probe_seconds}" stat "${check_path}" > /dev/null 2>&1; then
            echo "ERROR: ${drive_backup_path} did not respond within ${drive_backup_probe_seconds}s"
            echo "The share may be unreachable or the mount stale."
            exit 1
        fi
        echo "-- responded"
        ;;
esac

if [ ! -f "${drive_backup_path}/.emoncms-backup-target" ]; then
    echo "ERROR: no Emoncms backup found at ${drive_backup_path}"
    echo "The drive is probably not mounted."
    exit 1
fi

#-----------------------------------------------------------------------------------------------
# --list: show what is on the drive and stop
#-----------------------------------------------------------------------------------------------
if [ "${do_list}" == "true" ]; then
    echo ""
    echo "MYSQL snapshots available on ${drive_backup_path}:"
    list_snapshots
    echo ""
    if [ -f "${drive_backup_path}/status.json" ]; then
        echo "Last backup run:"
        cat "${drive_backup_path}/status.json"
    fi
    trap - EXIT
    exit 0
fi

#-----------------------------------------------------------------------------------------------
# Share the backup lock, a restore must never run while a backup is writing
#-----------------------------------------------------------------------------------------------
lock_file="/tmp/emoncms-drive-backup.lock"
exec 200>"${lock_file}"
if ! flock -n 200; then
    echo "ERROR: a backup or restore is already running (lock ${lock_file})"
    exit 1
fi

#-----------------------------------------------------------------------------------------------
# Choose and check the snapshot
#-----------------------------------------------------------------------------------------------
sql_file=$(resolve_snapshot "${requested_sql}")
if [ -z "${sql_file}" ]; then
    exit 1
fi

echo ""
echo "Snapshot: ${sql_file}"
echo "Verifying the archive is intact.."
if ! gzip -t "${sql_file}"; then
    echo "ERROR: ${sql_file} is corrupt, refusing to restore from it"
    echo "Run ${0} --list to choose another snapshot"
    exit 1
fi
echo "-- ok"

#-----------------------------------------------------------------------------------------------
# Confirm
#-----------------------------------------------------------------------------------------------
echo ""
echo "This will REPLACE the Emoncms database and feed data on this system:"
echo "  database    <- $(basename "${sql_file}")"
for engine in phpfina phpfiwa phptimeseries; do
    if [ -d "${drive_backup_path}/${engine}" ]; then
        count=$(find "${drive_backup_path}/${engine}" -maxdepth 1 -type f | wc -l)
        size=$(du -sh "${drive_backup_path}/${engine}" 2>/dev/null | cut -f1)
        if [ "${count}" -gt 0 ]; then
            echo "  ${engine} <- ${count} files, ${size}  ->  ${database_path}/${engine}"
        fi
    fi
done
if [ "${delete_extra}" == "true" ]; then
    echo "  feed files not present in the backup will be DELETED"
fi
echo ""

if [ "${dry_run}" == "true" ]; then
    echo "Dry run, nothing has been changed."
    trap - EXIT
    exit 0
fi

if [ "${assume_yes}" != "true" ]; then
    if [ ! -t 0 ]; then
        # Running from service-runner, cron or a pipe. Refuse rather than
        # destroy data without anyone having confirmed it.
        echo "ERROR: refusing to restore without confirmation when not run from a terminal."
        echo "Pass --yes if this really is what you intend."
        exit 1
    fi
    read -r -p "Type RESTORE to continue: " reply
    if [ "${reply}" != "RESTORE" ]; then
        echo "Not confirmed, nothing has been changed."
        cancelled=true
        exit 0
    fi
fi

#-----------------------------------------------------------------------------------------------
# MYSQL authentication
#-----------------------------------------------------------------------------------------------
if [ ! -f "${script_location}/get_emoncms_mysql_auth.php" ]; then
    echo "Error: cannot read MYSQL authentication details, ${script_location}/get_emoncms_mysql_auth.php missing"
    exit 1
fi

auth=$(echo "${emoncms_location}" | php "${script_location}/get_emoncms_mysql_auth.php" php)
IFS=":" read username password database <<< "$auth"

if [ -z "${username}" ]; then
    echo "Error: Cannot read MYSQL authentication details from Emoncms settings"
    exit 1
fi

# Pass the credentials in a private file rather than on the command line, where
# they would be visible to any user via ps
if [ -d /dev/shm ] && [ -w /dev/shm ]; then
    mysql_defaults_file=$(mktemp /dev/shm/emoncms-restore-XXXXXX)
else
    mysql_defaults_file=$(mktemp)
fi
chmod 600 "${mysql_defaults_file}"
printf '[client]\nuser=%s\npassword=%s\n' "${username}" "${password}" > "${mysql_defaults_file}"

#-----------------------------------------------------------------------------------------------
# Dump the current database first, so that a restore started by mistake can be undone
#-----------------------------------------------------------------------------------------------
echo ""
echo "--- Saving the current database before overwriting it ---"
if [ -n "${backup_location}" ] && [ -d "${backup_location}" ]; then
    rescue_file="${backup_location}/pre-restore-$(date +"%Y-%m-%d-%H%M%S").sql.gz"
    if mysqldump --defaults-file="${mysql_defaults_file}" --single-transaction --quick \
        "${database}" 2>/dev/null | gzip -c > "${rescue_file}"
    then
        echo "Current database saved to ${rescue_file}"
        echo "If this restore was a mistake, put it back with:"
        echo "  gunzip -c ${rescue_file} | mysql -u${username} -p ${database}"
    else
        echo "WARNING: could not save the current database, continuing anyway"
        rm -f "${rescue_file}"
    fi
else
    echo "WARNING: backup_location ${backup_location} not available, current database not saved"
fi

#-----------------------------------------------------------------------------------------------
# Stop services for the duration of the restore
#-----------------------------------------------------------------------------------------------
echo ""
stop_services

#-----------------------------------------------------------------------------------------------
# Restore the database
#-----------------------------------------------------------------------------------------------
echo ""
echo "--- Restoring Emoncms MYSQL database ---"
if gunzip -c "${sql_file}" | mysql --defaults-file="${mysql_defaults_file}" "${database}"; then
    echo "Database restored from $(basename "${sql_file}")"
else
    echo "Error: failed to import mysql data"
    exit 1
fi

rm -f "${mysql_defaults_file}"
mysql_defaults_file=""

#-----------------------------------------------------------------------------------------------
# Restore feed data
#
# --inplace --no-whole-file writes only the parts of each file that differ,
# which makes restoring onto a system that already holds most of the data far
# cheaper than a plain copy. rsync defaults to --whole-file for local transfers,
# so --no-whole-file is needed to get the delta algorithm.
#
# --append is deliberately NOT used here. A restore has to reproduce the backup
# exactly, including any file that is shorter than the one already on disk.
#-----------------------------------------------------------------------------------------------
echo ""
echo "--- Restoring feed data ---"

declare -a rsync_opts
rsync_opts=(-a --inplace --no-whole-file --stats)
if [ "${delete_extra}" == "true" ]; then
    rsync_opts+=(--delete)
fi
ownership_opts=$(rsync_ownership_opts)
if [ -n "${ownership_opts}" ]; then
    if [ "${drive_backup_preserve_permissions}" == "no" ]; then
        echo "Note: ignoring backup ownership, set by drive_backup_preserve_permissions"
    else
        echo "Note: ${dest_fstype:-source} does not store unix ownership"
    fi
    echo "      correct ownership is applied after each engine is restored"
fi
rsync_opts+=(${ownership_opts})

for engine in phpfina phpfiwa phptimeseries; do
    if [ ! -d "${drive_backup_path}/${engine}" ]; then
        echo "no ${engine} in the backup"
        continue
    fi

    echo "-- ${engine}"
    mkdir -p "${database_path}/${engine}"

    out=$(rsync "${rsync_opts[@]}" "${drive_backup_path}/${engine}/" "${database_path}/${engine}/" 2>&1)
    if [ $? -ne 0 ]; then
        echo "Error: rsync of ${engine} failed"
        echo "${out}"
    fi
    echo "${out}" | grep -E "^(Number of regular files transferred|Literal data|Matched data):" | sed 's/^/   /'

    if [ ! -f "/.dockerenv" ]; then
        sudo chown -R www-data:root "${database_path}/${engine}"
    fi
done

#-----------------------------------------------------------------------------------------------
# Restore emonhub.conf
#
# Emoncms settings.ini / settings.php are held in the backup for reference but
# are not restored, they describe the system the backup was taken from.
#-----------------------------------------------------------------------------------------------
echo ""
echo "--- Restoring configuration ---"
if [ -f "${drive_backup_path}/config/emonhub.conf" ]; then
    if [ -d "${emonhub_config_path}" ]; then
        if [ -f "/.dockerenv" ]; then
            cp -fv "${drive_backup_path}/config/emonhub.conf" "${emonhub_config_path}/emonhub.conf"
            chmod 666 "${emonhub_config_path}/emonhub.conf"
        else
            sudo cp -fv "${drive_backup_path}/config/emonhub.conf" "${emonhub_config_path}/emonhub.conf"
            sudo chmod 666 "${emonhub_config_path}/emonhub.conf"
        fi
    else
        echo "WARNING: emonhub.conf found in backup, but no emonHub directory (${emonhub_config_path}) found"
    fi
else
    echo "no emonhub.conf in the backup"
fi

if [ -f "${drive_backup_path}/config/settings.ini" ] || [ -f "${drive_backup_path}/config/settings.php" ]; then
    echo "Note: Emoncms settings from the backup are held in ${drive_backup_path}/config/"
    echo "      but are not restored automatically, they belong to the source system."
fi

#-----------------------------------------------------------------------------------------------
# Clear redis and bring the system back up
#-----------------------------------------------------------------------------------------------
echo ""
echo "Flushing redis"
redis-cli "flushall" 2>&1

if [ -f /opt/openenergymonitor/EmonScripts/common/emoncmsdbupdate.php ]; then
    echo "Updating Emoncms Database.."
    php /opt/openenergymonitor/EmonScripts/common/emoncmsdbupdate.php
fi

echo ""
start_services

if [ ! -f "/.dockerenv" ]; then
    echo "Restarting apache"
    sudo systemctl restart apache2
fi

#-----------------------------------------------------------------------------------------------
# Summary
#-----------------------------------------------------------------------------------------------
echo ""
echo "--- Summary ---"
date
echo "Restored from: ${drive_backup_path}"
echo "Snapshot:      $(basename "${sql_file}")"
echo "Duration:      $(( SECONDS - start_seconds ))s"
echo ""
echo "Log out and log back in using the account details from the restored data."

# The exit trap will pickup the natural exit and display the string to stop ongoing AJAX calls
