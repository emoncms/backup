#!/bin/bash

# Write efficient Emoncms backup to an attached drive: USB disk, or a NAS share
#
# Unlike emoncms-export.sh, which rebuilds and recompresses a complete tar archive
# on every run, this script maintains a directory *mirror* on the destination drive
# and only writes the bytes that have actually changed.
#
# It does this by exploiting the fact that the PHPFina and PHPTimeSeries feed
# engines are append only fixed record size stores: PHPFina .dat files are a
# sequence of 4 byte values, PHPTimeSeries feed_<id>.MYD files are a sequence of
# 9 byte records. Day to day the only new data is at the end of each file, so
# rsync --append-verify sends and writes just that tail.
#
# Two modes:
#
#   sync    (default) Append new feed data only. Minimal reads and writes.
#   verify            Full checksum comparison of every file, rewriting only
#                     the blocks that differ. Slower (reads everything on both
#                     sides) but detects damage that the sync mode cannot see.
#
# Run 'verify' periodically (weekly or monthly). It is needed because
# --append-verify skips any file whose size on the destination already matches
# the source, so a same size in place rewrite (PHPFina back filling padding, or
# the postprocess module rewriting history) is invisible to the sync mode.
#
# Usage:
#   ./drive-backup.sh --init       Prepare a destination drive (one time)
#   ./drive-backup.sh              Daily append mode backup
#   ./drive-backup.sh --verify     Full checksum verify and repair
#   ./drive-backup.sh --dry-run    Report what would be written, write nothing
#   ./drive-backup.sh --if-mounted Skip quietly if the drive is not plugged in,
#                                  rather than reporting it as a failure. Used by
#                                  the systemd timer.
#   ./drive-backup.sh --discover   List mounted drives that could hold a backup
#   ./drive-backup.sh --set-path <mountpoint>
#                                  Select a destination from that list and
#                                  prepare it. Used by the Emoncms interface.

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

# State gathered as the script runs, reported in the summary and status.json
bytes_written=0
files_repaired=0
files_realigned=0
orphans=0
dest_ready=false
skipped=false
mysql_defaults_file=""

# Exit handler used to ensure the exit message AJAX expects is found, whilst summarising if errors were found
# This also picks up the natural exit when reaching end of script
function finish() {
    local rc=$?

    # Never leave the temporary mysql credentials file behind
    if [ -n "${mysql_defaults_file}" ] && [ -f "${mysql_defaults_file}" ]; then
        rm -f "${mysql_defaults_file}"
    fi

    # The drive simply not being plugged in is a normal state, not a failure
    if [[ "${skipped}" == "true" ]]; then
        echo "=== Emoncms drive backup skipped ==="
# The strings output are identified in the interface to stop ongoing AJAX calls, please ammend in interface if changed here
        exit 0
    fi

    if [[ "${dest_ready}" == "true" ]]; then
        write_status_json
    fi

    if [[ "${errors}" == "false" && ${rc} == 0 ]]; then
        echo "=== Emoncms drive backup complete! ==="
# The strings output are identified in the interface to stop ongoing AJAX calls, please ammend in interface if changed here
    else
        echo "=== Emoncms drive backup completed with ERRORS! ==="
# The strings output are identified in the interface to stop ongoing AJAX calls, please ammend in interface if changed here
        # Exit non-zero so that systemd reports the run as failed rather than
        # silently succeeding, and so OnFailure= handlers can act on it
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

# Machine readable summary of the last run, read by the Emoncms interface
write_status_json() {
    local duration=$(( SECONDS - start_seconds ))
    local free_mb=$(df -Pm "${drive_backup_path}" 2>/dev/null | awk 'NR==2{print $4}')
    cat > "${drive_backup_path}/status.json" << EOF
{
    "last_run": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "hostname": "$(hostname)",
    "mode": "${mode}",
    "dry_run": ${dry_run},
    "duration_seconds": ${duration},
    "bytes_written": ${bytes_written},
    "files_repaired": ${files_repaired},
    "files_realigned": ${files_realigned},
    "orphans": ${orphans},
    "destination_free_mb": ${free_mb:-0},
    "errors": ${errors}
}
EOF
}

# Walk up from a path until an existing directory is found, used so the
# filesystem safety checks work even when the destination does not exist yet
existing_ancestor() {
    local p="$1"
    while [ ! -e "${p}" ] && [ "${p}" != "/" ]; do
        p=$(dirname "${p}")
    done
    echo "${p}"
}

# rsync --stats reports "Literal data: N bytes", the count of new bytes actually
# written to the destination. Sum it so we can report the real write volume.
# Note that rsync must not be given --human-readable, which would round this to
# a value that cannot be summed.
add_literal_data() {
    local literal
    literal=$(echo "$1" | grep -E "^Literal data:" | awk '{print $3}' | tr -d ',')
    if [[ "${literal}" =~ ^[0-9]+$ ]]; then
        bytes_written=$(( bytes_written + literal ))
    fi
}

human_bytes() {
    numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || echo "$1 bytes"
}

# Filesystems that cannot store unix ownership and permissions. Asking rsync to
# preserve them there produces an error per file and a failed run.
rsync_ownership_opts() {
    case "${drive_backup_preserve_permissions}" in
        yes) return 0 ;;
        no)  echo "--no-perms --no-owner --no-group"; return 0 ;;
    esac
    # auto
    case "${dest_fstype}" in
        cifs|smb3|smbfs|vfat|exfat|msdos|ntfs|ntfs3|fuseblk)
            echo "--no-perms --no-owner --no-group"
            ;;
    esac
}

# Enumerate mounted filesystems that could plausibly hold a backup, one per line as
#   mountpoint<TAB>source<TAB>fstype<TAB>kind<TAB>free_mb<TAB>initialised<TAB>compressed<TAB>snapshots
#
# compressed and snapshots report what the destination filesystem can add on top
# of the incremental sync. Both come from copy on write filesystems rather than
# from anything this script does: compression there happens per extent below the
# append, and a CoW snapshot costs only the delta. Neither can be done to the
# mirror itself, because compressing a feed file or hard linking it would mean
# rewriting it whole on every run, which is the one thing this design avoids.
#
# This is the authority on which destinations may be selected. The Emoncms
# interface offers the user a choice from this list and --set-path accepts
# nothing that is not in it, so a compromised web interface cannot point a root
# process at a directory of its own choosing.
discover_destinations() {
    local target source fstype options kind free marker dev base removable

    findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS | while read -r target source fstype options; do
        case "${fstype}" in
            ext2|ext3|ext4|xfs|btrfs|f2fs|vfat|exfat|msdos|ntfs|ntfs3|fuseblk|nfs|nfs4|cifs|smb3|smbfs) ;;
            *) continue ;;
        esac
        # Never offer the system's own filesystems as a backup destination
        case "${target}" in
            /|/boot|/boot/*|/usr|/usr/*|/var|/var/*|/etc|/etc/*|/home|/run|/run/*|/snap/*|/proc/*|/sys/*) continue ;;
        esac

        kind="fixed"
        case "${source}" in
            //*|*:/*) kind="network" ;;
            /dev/*)
                dev=$(basename "${source}")
                base=$(lsblk -rno PKNAME "${source}" 2>/dev/null | head -1)
                removable=$(cat "/sys/block/${base:-$dev}/removable" 2>/dev/null)
                [ "${removable}" == "1" ] && kind="removable"
                ;;
        esac

        free=$(df -Pm "${target}" 2>/dev/null | awk 'NR==2{print $4}')

        marker="no"
        [ -f "${target}/emoncms/.emoncms-backup-target" ] && marker="yes"

        # Copy on write filesystems can compress transparently and snapshot cheaply
        local compressed="no" snapshots="no"
        case "${fstype}" in
            btrfs)
                snapshots="yes"
                case "${options}" in *compress=*|*compress-force=*) compressed="yes" ;; esac
                ;;
        esac

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${target}" "${source}" "${fstype}" "${kind}" "${free:-0}" "${marker}" \
            "${compressed}" "${snapshots}"
    done
}

# rsync --dry-run does not report Literal data, so for a dry run work the append
# volume out directly from the file sizes. Exact for the append case, and needs
# only a stat of each file.
estimate_append_bytes() {
    local engine="$1"
    local src_dir="${database_path}/${engine}"
    local dst_dir="${drive_backup_path}/${engine}"
    local total=0

    shopt -s nullglob
    local src_file
    for src_file in "${src_dir}"/*; do
        [ -f "${src_file}" ] || continue
        local name src_size dst_size=0
        name=$(basename "${src_file}")
        src_size=$(stat -c%s "${src_file}")
        if [ -f "${dst_dir}/${name}" ]; then
            dst_size=$(stat -c%s "${dst_dir}/${name}")
        fi
        if [ "${src_size}" -gt "${dst_size}" ]; then
            total=$(( total + src_size - dst_size ))
        fi
    done
    shopt -u nullglob

    echo "${total}"
}

# Keep the newest ${keep} dumps in a directory, removing any older ones.
# Dump filenames end in the ISO date so a plain reverse sort is newest first,
# and does not depend on modification times that a restore could disturb.
# Only this host's dumps are considered, so one drive can hold backups of
# several systems without them pruning each other.
prune_dumps() {
    local dir="$1" keep="$2" label="$3"
    local files=() sorted=()

    shopt -s nullglob
    files=( "${dir}"/emoncms-"$(hostname)"-*.sql.gz )
    shopt -u nullglob

    [ ${#files[@]} -eq 0 ] && return 0
    mapfile -t sorted < <(printf '%s\n' "${files[@]}" | sort -r)

    local i
    for (( i = keep; i < ${#sorted[@]}; i++ )); do
        echo "Removing expired ${label} dump $(basename "${sorted[i]}")"
        rm -f "${sorted[i]}"
    done
    return 0
}

#-----------------------------------------------------------------------------------------------
# Parse arguments
#-----------------------------------------------------------------------------------------------
mode="sync"
init=false
dry_run=false
if_mounted=false
discover=false
set_path=""

while [ $# -gt 0 ]; do
    arg="$1"
    case "${arg}" in
        --init)       init=true ;;
        --verify)     mode="verify" ;;
        --dry-run)    dry_run=true ;;
        --if-mounted) if_mounted=true ;;
        --discover)   discover=true ;;
        --set-path)
            shift
            if [ -z "$1" ]; then
                echo "Error: --set-path requires a mountpoint"
                exit 1
            fi
            set_path="$1"
            ;;
        --help|-h)
            # Print the header comment block, stopping at the blank line that ends it
            awk 'NR>2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
            trap - EXIT
            exit 0
            ;;
        *)
            echo "Error: unknown argument ${arg}"
            echo "Usage: $0 [--init] [--verify] [--dry-run] [--if-mounted] [--discover] [--set-path <mountpoint>]"
            exit 1
            ;;
    esac
    shift
done

script_location="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
config_location=${script_location}/config.cfg
path_conf=${script_location}/drive-backup-path.conf

# A plain query, answered without needing a configured or present destination
if [ "${discover}" == "true" ]; then
    discover_destinations
    trap - EXIT
    exit 0
fi

echo "=== Emoncms drive backup start ==="
date
echo "Backup module version:"
grep version "${script_location}/module.json"
echo "EUID: $EUID"
echo "Mode: ${mode}$([ "${dry_run}" == "true" ] && echo " (dry run)")"
echo "Reading ${config_location}...."

if [ ! -f "${config_location}" ]
then
    echo "ERROR: Backup config file ${config_location} does not exist"
    exit 1
fi

source "${config_location}"

# Defaults for settings added by this script. config.cfg is not tracked in git and
# is only generated on install, so an existing installation will not have them.
: "${drive_backup_path:=}"
: "${drive_backup_retain_daily_sql:=7}"
: "${drive_backup_retain_weekly_sql:=4}"
: "${drive_backup_weekly_day:=1}"
: "${drive_backup_min_free_mb:=256}"
: "${drive_backup_allow_same_filesystem:=no}"
: "${drive_backup_preserve_permissions:=auto}"
: "${drive_backup_probe_seconds:=20}"

#-----------------------------------------------------------------------------------------------
# A destination chosen in the Emoncms interface is kept in its own small file
# rather than in config.cfg, which is sourced as shell by this script running as
# root. The value is read with a plain text parser and checked against a strict
# pattern, so nothing in this file can ever be executed.
#-----------------------------------------------------------------------------------------------
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

#-----------------------------------------------------------------------------------------------
# --set-path: choose a destination from the discovered list
#
# The mountpoint has to appear in this script's own discovery output. The caller
# does not get to name an arbitrary directory, which is what makes it safe to
# expose this to the web interface.
#-----------------------------------------------------------------------------------------------
if [ -n "${set_path}" ]; then
    echo "Requested destination: ${set_path}"

    if ! discover_destinations | awk -F'\t' -v m="${set_path}" '$1==m {found=1} END{exit !found}'; then
        echo "ERROR: ${set_path} is not one of the drives available for backup"
        echo "Available:"
        discover_destinations | awk -F'\t' '{printf "  %s (%s, %s, %s MB free)\n", $1, $3, $4, $5}'
        exit 1
    fi

    drive_backup_path="${set_path%/}/emoncms"
    echo "Setting backup destination to ${drive_backup_path}"

    umask 022
    printf '# Written by drive-backup.sh --set-path, do not edit by hand\ndrive_backup_path=%s\n' \
        "${drive_backup_path}" > "${path_conf}"

    # Selecting a destination also prepares it, so the interface needs one action
    init=true
fi

echo "Location of databases: $database_path"
echo "Location of emonhub.conf: $emonhub_config_path"
echo "Location of Emoncms: $emoncms_location"
echo "Backup destination: $drive_backup_path"

if [ -z "${drive_backup_path}" ]; then
    if [ "${if_mounted}" == "true" ]; then
        echo "drive_backup_path is not set in ${config_location}, nothing to do."
        skipped=true
        exit 0
    fi
    echo "ERROR: drive_backup_path is not set in ${config_location}"
    echo "Add the following to ${config_location}, pointing at your mounted backup drive:"
    echo ""
    echo '    drive_backup_path="/media/backup/emoncms"'
    echo ""
    exit 1
fi

#-----------------------------------------------------------------------------------------------
# Only allow one run at a time. A first run copies the whole dataset and can take
# far longer than the interval between scheduled runs.
#-----------------------------------------------------------------------------------------------
lock_file="/tmp/emoncms-drive-backup.lock"
exec 200>"${lock_file}"
if ! flock -n 200; then
    # A first run copies the whole dataset and can still be going when the timer
    # next fires, which is expected rather than a failure
    if [ "${if_mounted}" == "true" ]; then
        echo "Another backup is already running, nothing to do."
        skipped=true
        exit 0
    fi
    echo "ERROR: another backup is already running (lock ${lock_file})"
    exit 1
fi

#-----------------------------------------------------------------------------------------------
# Safety check: refuse to write to the root filesystem
#
# The classic failure mode is the drive not being mounted, leaving an empty
# directory on the SD card that silently fills up with the whole dataset.
#-----------------------------------------------------------------------------------------------
check_path=$(existing_ancestor "${drive_backup_path}")
dest_device=$(findmnt -no SOURCE --target "${check_path}" 2>/dev/null)
root_device=$(findmnt -no SOURCE --target "/" 2>/dev/null)
dest_mountpoint=$(findmnt -no TARGET --target "${check_path}" 2>/dev/null)
dest_fstype=$(findmnt -no FSTYPE --target "${check_path}" 2>/dev/null)

echo "Destination filesystem: ${dest_device:-unknown} (${dest_fstype:-unknown}) mounted at ${dest_mountpoint:-unknown}"

#-----------------------------------------------------------------------------------------------
# A network share can be mounted but unreachable, and on a hard NFS mount any
# access then blocks in uninterruptible IO forever. Probe it with a timeout
# before doing anything that would hang the whole run.
#-----------------------------------------------------------------------------------------------
case "${dest_fstype}" in
    nfs|nfs4|cifs|smb3|smbfs|fuse.sshfs) dest_is_network=true ;;
    *) dest_is_network=false ;;
esac

if [ "${dest_is_network}" == "true" ]; then
    echo "Destination is a network share, checking it responds.."
    if ! timeout "${drive_backup_probe_seconds}" stat "${check_path}" > /dev/null 2>&1; then
        if [ "${if_mounted}" == "true" ]; then
            echo "Network share at ${drive_backup_path} is not responding, nothing to do."
            skipped=true
            exit 0
        fi
        echo "ERROR: ${drive_backup_path} did not respond within ${drive_backup_probe_seconds}s"
        echo "The share may be unreachable or the mount stale. Mount NFS shares with"
        echo "the 'soft' option so that a dead server returns an error instead of hanging."
        exit 1
    fi
    echo "-- responded"
fi

if [ -n "${dest_device}" ] && [ "${dest_device}" == "${root_device}" ]; then
    if [ "${drive_backup_allow_same_filesystem}" != "yes" ]; then
        if [ "${if_mounted}" == "true" ]; then
            echo "Backup drive is not mounted at ${drive_backup_path}, nothing to do."
            skipped=true
            exit 0
        fi
        echo "ERROR: ${drive_backup_path} is on the root filesystem (${root_device})"
        echo "The drive is probably not mounted. Refusing to run so that the"
        echo "system disk is not filled with a copy of the feed data."
        echo "If this is intentional set drive_backup_allow_same_filesystem=\"yes\" in ${config_location}"
        exit 1
    fi
    echo "WARNING: destination is on the root filesystem, allowed by drive_backup_allow_same_filesystem"
fi

#-----------------------------------------------------------------------------------------------
# --init: prepare the destination drive
#-----------------------------------------------------------------------------------------------
marker_file="${drive_backup_path}/.emoncms-backup-target"

if [ "${init}" == "true" ]; then
    echo "Initialising backup destination ${drive_backup_path}"
    mkdir -p "${drive_backup_path}"/{phpfina,phpfiwa,phptimeseries,config,sql/daily,sql/weekly}
    if [ ! -f "${marker_file}" ]; then
        {
            echo "# Emoncms backup destination marker"
            echo "# drive-backup.sh refuses to write to a directory without this file,"
            echo "# so that an unmounted drive cannot be silently backed up to the SD card."
            echo "created=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
            echo "created_by=$(hostname)"
        } > "${marker_file}"
    fi
    echo "Destination prepared:"
    ls -la "${drive_backup_path}"
    echo ""
    echo "Now run ${0} to take the first backup."
    echo "The first run copies the whole dataset, later runs append only new data."
    echo "=== Emoncms drive backup ready ==="
# The strings output are identified in the interface to stop ongoing AJAX calls, please ammend in interface if changed here
    trap - EXIT
    exit 0
fi

#-----------------------------------------------------------------------------------------------
# Safety check: destination must have been prepared with --init
#-----------------------------------------------------------------------------------------------
if [ ! -f "${marker_file}" ]; then
    if [ "${if_mounted}" == "true" ]; then
        echo "Backup drive is not mounted at ${drive_backup_path}, nothing to do."
        skipped=true
        exit 0
    fi
    echo "ERROR: ${marker_file} not found"
    echo "Either the drive is not mounted, or the destination has not been prepared."
    echo "If the drive is mounted and this is the correct destination, run:"
    echo ""
    echo "    ${0} --init"
    echo ""
    exit 1
fi

dest_ready=true
mkdir -p "${drive_backup_path}"/{phpfina,phpfiwa,phptimeseries,config,sql/daily,sql/weekly}

#-----------------------------------------------------------------------------------------------
# Free space check
#-----------------------------------------------------------------------------------------------
source_kb=0
for dir in phpfina phpfiwa phptimeseries; do
    if [ -d "${database_path}/${dir}" ]; then
        size=$(du -sk "${database_path}/${dir}" 2>/dev/null | awk '{print $1}')
        source_kb=$(( source_kb + ${size:-0} ))
    fi
done

dest_kb=0
for dir in phpfina phpfiwa phptimeseries; do
    if [ -d "${drive_backup_path}/${dir}" ]; then
        size=$(du -sk "${drive_backup_path}/${dir}" 2>/dev/null | awk '{print $1}')
        dest_kb=$(( dest_kb + ${size:-0} ))
    fi
done

avail_kb=$(df -Pk "${drive_backup_path}" | awk 'NR==2{print $4}')
needed_kb=$(( source_kb - dest_kb ))
if [ ${needed_kb} -lt 0 ]; then needed_kb=0; fi
needed_kb=$(( needed_kb + drive_backup_min_free_mb * 1024 ))

echo "Feed data source: $(( source_kb / 1024 )) MB, already on destination: $(( dest_kb / 1024 )) MB"
echo "Destination free: $(( avail_kb / 1024 )) MB, required: $(( needed_kb / 1024 )) MB"

if [ "${avail_kb}" -lt "${needed_kb}" ]; then
    echo "ERROR: not enough free space on ${drive_backup_path}"
    exit 1
fi

#-----------------------------------------------------------------------------------------------
# Be nice, this is a background maintenance task and the Pi should stay responsive
#-----------------------------------------------------------------------------------------------
if command -v ionice > /dev/null; then
    ionice -c 3 -p $$ > /dev/null 2>&1 || true
fi
renice -n 19 -p $$ > /dev/null 2>&1 || true

#-----------------------------------------------------------------------------------------------
# MYSQL dump
#
# --single-transaction takes a consistent snapshot without locking, so unlike
# emoncms-export.sh there is no need to stop feedwriter. The dump is small
# (feed, input, user and dashboard metadata) so writing a fresh one daily costs
# very little, and it is the part of the backup most worth versioning.
#-----------------------------------------------------------------------------------------------
echo ""
echo "--- Emoncms MYSQL database ---"

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
    mysql_defaults_file=$(mktemp /dev/shm/emoncms-backup-XXXXXX)
else
    mysql_defaults_file=$(mktemp)
fi
chmod 600 "${mysql_defaults_file}"
printf '[client]\nuser=%s\npassword=%s\n' "${username}" "${password}" > "${mysql_defaults_file}"

sql_daily_dir="${drive_backup_path}/sql/daily"
sql_filename="emoncms-$(hostname)-$(date +"%Y-%m-%d").sql.gz"
sql_target="${sql_daily_dir}/${sql_filename}"

if [ "${dry_run}" == "true" ]; then
    echo "would write ${sql_target}"
else
    # Dump to a temporary file first so an interrupted run cannot leave a
    # truncated dump in place of yesterday's good one
    if mysqldump --defaults-file="${mysql_defaults_file}" --single-transaction --quick \
        "${database}" 2>/dev/null | gzip -c > "${sql_target}.part"
    then
        mv -f "${sql_target}.part" "${sql_target}"
        sql_size=$(stat -c%s "${sql_target}")
        bytes_written=$(( bytes_written + sql_size ))
        echo "Wrote ${sql_target} ($(human_bytes ${sql_size}))"
    else
        echo "Error: failed to export mysql data"
        rm -f "${sql_target}.part"
    fi
fi

rm -f "${mysql_defaults_file}"
mysql_defaults_file=""

#-----------------------------------------------------------------------------------------------
# Rotate SQL dumps
#
# The weekly copy is a hard link, so keeping a longer history of the database
# costs no additional writes or space on filesystems that support it.
#-----------------------------------------------------------------------------------------------
if [ "${dry_run}" == "false" ]; then
    sql_weekly_dir="${drive_backup_path}/sql/weekly"

    if [ "$(date +%u)" == "${drive_backup_weekly_day}" ] && [ -f "${sql_target}" ]; then
        if ! ln -f "${sql_target}" "${sql_weekly_dir}/${sql_filename}" 2>/dev/null; then
            # Destination filesystem does not support hard links (eg FAT/exFAT)
            cp -f "${sql_target}" "${sql_weekly_dir}/${sql_filename}"
        fi
        echo "Retained weekly copy ${sql_weekly_dir}/${sql_filename}"
    fi

    prune_dumps "${sql_daily_dir}" "${drive_backup_retain_daily_sql}" "daily"
    prune_dumps "${sql_weekly_dir}" "${drive_backup_retain_weekly_sql}" "weekly"
fi

#-----------------------------------------------------------------------------------------------
# Configuration files
#
# Newer systems use settings.ini rather than settings.php, only look for
# settings.php if there is no settings.ini
#-----------------------------------------------------------------------------------------------
echo ""
echo "--- Configuration files ---"

declare -a config_files
config_files=("${emonhub_config_path}/emonhub.conf" "${emoncms_location}/settings.ini")
if [ ! -f "${emoncms_location}/settings.ini" ]; then
    config_files+=("${emoncms_location}/settings.php")
fi

for file in "${config_files[@]}"; do
    if [ -f "${file}" ]; then
        # rsync rather than cp so an unchanged config file is not rewritten
        out=$(rsync -a --stats $([ "${dry_run}" == "true" ] && echo "--dry-run") \
              "${file}" "${drive_backup_path}/config/" 2>&1)
        add_literal_data "${out}"
        echo "-- ${file}"
    else
        echo "no ${file} to backup"
    fi
done

#-----------------------------------------------------------------------------------------------
# Repair pass
#
# rsync --append skips any file whose size on the destination is already equal to
# or greater than the source. A feed that has been deleted and its id reused, or
# data trimmed, therefore leaves a stale longer file on the destination that
# would never be corrected, sitting alongside a new .meta. Detect those and
# remove them so that the rsync below copies them again in full.
#
# Not needed in verify mode, where rsync compares by checksum instead.
#-----------------------------------------------------------------------------------------------
repair_destination() {
    local engine="$1"
    local src_dir="${database_path}/${engine}"
    local dst_dir="${drive_backup_path}/${engine}"
    local pattern="$2"

    [ -d "${dst_dir}" ] || return 0

    shopt -s nullglob
    for dst_file in "${dst_dir}"/${pattern}; do
        local name
        name=$(basename "${dst_file}")
        local src_file="${src_dir}/${name}"

        if [ ! -f "${src_file}" ]; then
            # Feed removed from the live system. Left in place rather than
            # deleted, a backup should not throw data away on its own.
            orphans=$(( orphans + 1 ))
            continue
        fi

        local src_size dst_size
        src_size=$(stat -c%s "${src_file}")
        dst_size=$(stat -c%s "${dst_file}")

        local reason=""
        if [ "${dst_size}" -gt "${src_size}" ]; then
            reason="destination larger than source (${dst_size} > ${src_size})"
        fi

        # PHPFina and PHPFiwa carry a .meta alongside each .dat holding the feed
        # start time and interval. If that has changed the feed was recreated and
        # the existing .dat no longer belongs to it.
        local src_meta="${src_file%.dat}.meta"
        local dst_meta="${dst_file%.dat}.meta"
        if [ -z "${reason}" ] && [ -f "${src_meta}" ] && [ -f "${dst_meta}" ]; then
            if ! cmp -s "${src_meta}" "${dst_meta}"; then
                reason="feed metadata changed, feed recreated"
            fi
        fi

        if [ -n "${reason}" ]; then
            echo "-- repairing ${engine}/${name}: ${reason}"
            files_repaired=$(( files_repaired + 1 ))
            if [ "${dry_run}" == "false" ]; then
                rm -f "${dst_file}" "${dst_meta}"
            fi
        fi
    done
    shopt -u nullglob
}

#-----------------------------------------------------------------------------------------------
# Alignment pass
#
# The feed engines append while the backup is reading, so a copy can catch a
# partially written record at the end of a file. Truncating the destination back
# to a whole number of records keeps the next append aligned. The removed partial
# record is written again on the following run.
#-----------------------------------------------------------------------------------------------
realign_destination() {
    local engine="$1"
    local pattern="$2"
    local record_size="$3"
    local dst_dir="${drive_backup_path}/${engine}"

    [ -d "${dst_dir}" ] || return 0

    shopt -s nullglob
    for dst_file in "${dst_dir}"/${pattern}; do
        local size remainder
        size=$(stat -c%s "${dst_file}")
        remainder=$(( size % record_size ))
        if [ "${remainder}" -ne 0 ]; then
            echo "-- realigning ${engine}/$(basename "${dst_file}"): ${size} bytes is not a multiple of ${record_size}"
            files_realigned=$(( files_realigned + 1 ))
            if [ "${dry_run}" == "false" ]; then
                truncate -s $(( size - remainder )) "${dst_file}"
            fi
        fi
    done
    shopt -u nullglob
}

#-----------------------------------------------------------------------------------------------
# Feed data
#
# sync mode:   --append-verify sends only the bytes past the end of the
#              destination file, and writes only those bytes. The checksum
#              verification step catches a destination whose leading data no
#              longer matches the source and resends that file in full.
#
# verify mode: --checksum compares every file by content and --no-whole-file
#              forces the delta transfer algorithm, so only the blocks that
#              actually differ are written. --no-whole-file is required because
#              rsync defaults to --whole-file for local transfers, which would
#              rewrite each differing file in its entirety.
#-----------------------------------------------------------------------------------------------
echo ""
echo "--- Feed data (${mode}) ---"

declare -a rsync_opts
rsync_opts=(-a --stats)
if [ "${mode}" == "verify" ]; then
    rsync_opts+=(--inplace --no-whole-file --checksum)
else
    rsync_opts+=(--inplace --append-verify)
fi
if [ "${dry_run}" == "true" ]; then
    rsync_opts+=(--dry-run)
fi

# -a implies -p -o -g. A CIFS share mounted with fixed uid/gid/file_mode, or any
# FAT filesystem, cannot store unix ownership or permissions, and rsync then
# reports a failure for every single file. Ownership is not worth preserving on
# the backup anyway: drive-restore.sh sets it correctly on the way back in.
ownership_opts=$(rsync_ownership_opts)
if [ -n "${ownership_opts}" ]; then
    if [ "${drive_backup_preserve_permissions}" == "no" ]; then
        echo "Note: syncing without unix ownership, set by drive_backup_preserve_permissions"
    else
        echo "Note: ${dest_fstype:-destination} cannot store unix ownership, syncing without it"
    fi
fi
rsync_opts+=(${ownership_opts})

# engine:file pattern:record size in bytes
for engine_spec in "phpfina:*.dat:4" "phpfiwa:*.dat:4" "phptimeseries:feed_*.MYD:9"; do
    IFS=":" read -r engine pattern record_size <<< "${engine_spec}"

    if [ ! -d "${database_path}/${engine}" ]; then
        echo "no ${database_path}/${engine} directory to backup"
        continue
    fi

    echo "-- ${engine}"

    if [ "${mode}" == "sync" ]; then
        # Realign first: a partial trailing record left by a previous run is
        # cheaper to truncate than to let the repair pass recopy the whole file
        realign_destination "${engine}" "${pattern}" "${record_size}"
        repair_destination "${engine}" "${pattern}"
    fi

    out=$(rsync "${rsync_opts[@]}" "${database_path}/${engine}/" "${drive_backup_path}/${engine}/" 2>&1)
    rsync_rc=$?
    if [ ${rsync_rc} -ne 0 ]; then
        echo "Error: rsync of ${engine} failed with code ${rsync_rc}"
        echo "${out}"
    fi
    echo "${out}" | grep -E "^(Number of regular files transferred|Literal data|Matched data):" | sed 's/^/   /'

    if [ "${dry_run}" == "true" ] && [ "${mode}" == "sync" ]; then
        estimated=$(estimate_append_bytes "${engine}")
        echo "   Would append: ${estimated} bytes"
        bytes_written=$(( bytes_written + estimated ))
    else
        add_literal_data "${out}"
    fi

    if [ "${dry_run}" == "false" ]; then
        realign_destination "${engine}" "${pattern}" "${record_size}"
    fi
done

#-----------------------------------------------------------------------------------------------
# Summary
#-----------------------------------------------------------------------------------------------
echo ""
echo "--- Summary ---"
date
echo "Mode:            ${mode}$([ "${dry_run}" == "true" ] && echo " (dry run, nothing written)")"
echo "Duration:        $(( SECONDS - start_seconds ))s"
if [ "${dry_run}" == "true" ]; then
    echo "Bytes to write:  $(human_bytes ${bytes_written}) (feed data estimate, excludes MYSQL dump)"
else
    echo "Bytes written:   $(human_bytes ${bytes_written})"
fi
echo "Files repaired:  ${files_repaired}"
echo "Files realigned: ${files_realigned}"
echo "Orphaned files:  ${orphans} (present on backup, no longer in Emoncms)"
echo "Destination:     ${drive_backup_path} ($(df -Pm "${drive_backup_path}" | awk 'NR==2{print $4}') MB free)"

if [ "${mode}" == "sync" ]; then
    echo ""
    echo "Note: sync mode cannot detect a source file that was rewritten in place"
    echo "without changing size. Run '${0} --verify' periodically to check and repair."
fi

# The exit trap will pickup the natural exit, write status.json and display the string to stop ongoing AJAX calls
