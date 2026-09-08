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
#   ./drive-backup.sh --discover-devices
#                                  List attached drives that are NOT mounted yet
#   ./drive-backup.sh --mount <id> Mount one of those drives, record it in
#                                  /etc/fstab so it comes back after a reboot,
#                                  and use it as the backup destination
#   ./drive-backup.sh --format-mount <id> --confirm-erase
#                                  As --mount, but first put a btrfs filesystem
#                                  on the drive. ERASES THE WHOLE DISK the drive
#                                  is on, every partition included.
#   ./drive-backup.sh --enable-schedule
#   ./drive-backup.sh --disable-schedule
#                                  Turn the daily backup and weekly verify
#                                  systemd timers on or off
#
# Everything except --discover, --discover-devices and --disable-schedule needs
# drive_backup_enabled="yes" in config.cfg. install.sh sets it on a Raspberry
# Pi; on any other system it is off until set by hand, so that a root process
# that mounts and formats drives cannot be reached where nobody wants it.

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

# The arguments exactly as given. The parse loop below consumes them with shift,
# so they are kept here for the re-exec under sudo further down.
original_args=("$@")

# State gathered as the script runs, reported in the summary and status.json
bytes_written=0
files_repaired=0
files_realigned=0
orphans=0
dest_ready=false
skipped=false
mysql_defaults_file=""
# Set by mount_device() and format_device() when they succeed
mounted_at=""
formatted_device=""
formatted_stale_specs=""

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

    local seen=""

    # Process substitution rather than a pipe, so the loop runs in this shell and
    # can remember which mountpoints it has already reported
    while read -r target source fstype options; do
        case "${fstype}" in
            ext2|ext3|ext4|xfs|btrfs|f2fs|vfat|exfat|msdos|ntfs|ntfs3|fuseblk|nfs|nfs4|cifs|smb3|smbfs) ;;
            *) continue ;;
        esac
        # Never offer the system's own filesystems as a backup destination
        case "${target}" in
            /|/boot|/boot/*|/usr|/usr/*|/var|/var/*|/etc|/etc/*|/home|/root|/root/*) continue ;;
            /run|/run/*|/snap/*|/proc/*|/sys/*|/dev|/dev/*|/tmp|/tmp/*) continue ;;
        esac
        # systemd gives services private /tmp and inaccessible directory mounts,
        # which show up here as duplicates of real mountpoints
        case "${source}" in
            *systemd-private*|*systemd/inaccessible*) continue ;;
        esac
        # The same mountpoint can appear more than once, from a bind mount say.
        # Report it once: a repeated entry would be a duplicate row, and a
        # duplicate key, in the interface.
        case " ${seen} " in *" ${target} "*) continue ;; esac
        seen="${seen} ${target}"

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
    done < <(findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS)
}

#-----------------------------------------------------------------------------------------------
# Attached drives that are not mounted yet
#
# discover_destinations() above only sees filesystems that are already mounted,
# which leaves the common case unsolved: a USB drive has just been plugged in and
# nothing has mounted it. The functions below find those drives, and mount one
# and record it in /etc/fstab so it comes back after a reboot.
#
# The same rule applies as to --set-path: the interface may only name a drive
# that this script's own discovery reported, and the mount is re-checked against
# that list here before anything privileged happens.
#-----------------------------------------------------------------------------------------------

# Run a command as root. The systemd timers already run this script as root; from
# the Emoncms interface it runs as the service-runner user, which has sudo.
# -n so that a system without the sudo rule fails immediately with a message
# rather than blocking forever on a password prompt no one can answer.
as_root() {
    if [ "${EUID}" -eq 0 ]; then
        "$@"
    else
        sudo -n "$@"
    fi
}

# A single lsblk field for one device. Asked for one at a time on purpose: with
# several fields a device with an empty value in the middle, no filesystem label
# say, shifts every later column along and the wrong value is read.
lsblk_field() {
    lsblk -dno "$2" "$1" 2>/dev/null | head -1 | sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//'
}

# Values reported here end up in tab separated output and then in a web page, so
# strip anything that would break the format. Labels and models come from the
# drive itself and are not to be trusted to be well behaved.
tsv_safe() {
    printf '%s' "$1" | tr -d '\000-\037' | cut -c1-64
}

# The disks the running system is using. Anything on one of these is never
# offered as a backup drive and never formatted, so a mistake here cannot reach
# the SD card the system boots from.
#
# Every mounted filesystem and every active swap device counts. Each is walked
# down to the disk it ultimately sits on, through partitions, LVM and device
# mapper alike, because the format action erases whole disks.
system_disks() {
    local src disk
    {
        findmnt -rno SOURCE | sed 's/\[.*\]//'
        awk 'NR>1 && $1 ~ /^\/dev\// {print $1}' /proc/swaps 2>/dev/null
    } | sort -u | while read -r src; do
        case "${src}" in /dev/*) ;; *) continue ;; esac
        # /dev/root and the like are not real device nodes, find the device by
        # its major:minor number instead
        if [ ! -b "${src}" ]; then
            src="/dev/block/$(findmnt -rno MAJ:MIN --source "${src}" 2>/dev/null | head -1)"
            [ -b "${src}" ] || continue
        fi
        # The inverse tree ends at the disk itself
        disk=$(lsblk -srno NAME "${src}" 2>/dev/null | tail -1)
        [ -z "${disk}" ] && disk=$(basename "$(readlink -f "${src}")")
        echo "${disk}"
    done | sort -u
}

# The disk a partition sits on, or the device itself if it is a whole disk
disk_of() {
    local dev="$1" parent
    parent=$(lsblk_field "${dev}" PKNAME)
    if [ -n "${parent}" ]; then
        echo "/dev/${parent}"
    else
        readlink -f "${dev}"
    fi
}

# Everything found on a disk, for the person about to erase it: one entry per
# partition with its filesystem, size and label, or the disk itself if it has
# no partition table. Reported alongside each drive in --discover-devices so
# the interface can say what the format action would destroy.
disk_contents() {
    local disk="$1" node fstype label size_b out="" item
    local nodes
    nodes=$(lsblk -pnro NAME "${disk}" 2>/dev/null)
    # With partitions, describe those and not the disk that holds them
    if [ "$(printf '%s\n' "${nodes}" | wc -l)" -gt 1 ]; then
        nodes=$(printf '%s\n' "${nodes}" | sed '1d')
    fi
    while read -r node; do
        [ -n "${node}" ] || continue
        fstype=$(lsblk_field "${node}" FSTYPE)
        label=$(tsv_safe "$(lsblk_field "${node}" LABEL)" | tr -d ';')
        size_b=$(lsblk -bdno SIZE "${node}" 2>/dev/null | head -1)
        item="$(basename "${node}") ($(human_bytes "${size_b:-0}"), ${fstype:-no filesystem}"
        [ -n "${label}" ] && item="${item}, ${label}"
        item="${item})"
        out="${out:+${out}; }${item}"
    done <<< "${nodes}"
    printf '%s' "${out}"
}

# A name for a drive that survives unplugging and replugging it. Kernel names
# like /dev/sda are assigned in the order drives appear, so a drive scanned as
# /dev/sda can be a different drive by the time the user confirms. /dev/disk/by-id
# is derived from the hardware itself, which matters most for the format action.
stable_id() {
    local dev="$1" real link uuid
    real=$(readlink -f "${dev}")

    # Prefer the descriptive id (usb-Samsung_Flash_Drive_...) over the bare wwn-
    local pass
    for pass in descriptive wwn; do
        for link in /dev/disk/by-id/*; do
            [ -e "${link}" ] || continue
            case "${link}" in
                */wwn-*|*/nvme-eui.*) [ "${pass}" == "wwn" ] || continue ;;
                *) [ "${pass}" == "descriptive" ] || continue ;;
            esac
            if [ "$(readlink -f "${link}")" == "${real}" ]; then
                echo "${link}"
                return 0
            fi
        done
    done

    uuid=$(lsblk_field "${dev}" UUID)
    if [ -n "${uuid}" ] && [ -e "/dev/disk/by-uuid/${uuid}" ]; then
        echo "/dev/disk/by-uuid/${uuid}"
        return 0
    fi

    echo "${real}"
}

# Is this device, or any partition on it, mounted right now
device_is_mounted() {
    local dev="$1" mp
    while read -r mp; do
        [ -n "${mp}" ] && return 0
    done < <(lsblk -nro MOUNTPOINT "${dev}" 2>/dev/null)
    return 1
}

# Enumerate attached drives that are not mounted, one per line as
#   id<TAB>device<TAB>size_mb<TAB>fstype<TAB>label<TAB>model<TAB>kind<TAB>state
#     <TAB>disk<TAB>disk_size_mb<TAB>disk_contents
#
# state is one of:
#   available     has a filesystem that can be mounted and used as it is
#   infstab       already has an /etc/fstab entry, so it is configured but not
#                 mounted: the drive was unplugged, or the entry is wrong
#   nofilesystem  nothing on it to mount, it has to be formatted first
#   nomedia       a card reader with no card in it. Listed so the interface can
#                 say so; it cannot be mounted or formatted
#
# The last three columns describe the whole disk the device sits on, which is
# what --format-mount erases: a used SD card carries a boot partition and a
# root partition, and formatting one of them would leave a mixed card. The
# interface shows disk_contents to whoever is about to confirm the erase.
#
# This is the authority on which drives may be mounted or formatted, in the same
# way discover_destinations() is the authority on which may be selected.
discover_devices() {
    local sys_disks dev kname type fstype id spec label model size_b size_mb
    local parent ro kind state children disk disk_size_b disk_size_mb

    sys_disks=" $(system_disks | tr '\n' ' ') "

    while read -r dev; do
        [ -n "${dev}" ] || continue
        [ -b "${dev}" ] || continue

        type=$(lsblk_field "${dev}" TYPE)
        case "${type}" in disk|part) ;; *) continue ;; esac

        # A read only device cannot hold a backup
        [ "$(lsblk_field "${dev}" RO)" == "1" ] && continue

        kname=$(basename "$(readlink -f "${dev}")")
        parent=$(lsblk_field "${dev}" PKNAME)
        [ -z "${parent}" ] && parent="${kname}"
        case " ${sys_disks} " in *" ${parent} "*) continue ;; esac

        # A disk that has been partitioned is offered as its partitions, not as
        # the whole disk, which could not be mounted anyway
        if [ "${type}" == "disk" ]; then
            children=$(lsblk -nro NAME "${dev}" 2>/dev/null | wc -l)
            [ "${children}" -gt 1 ] && continue
        fi

        # Anything already mounted belongs in the discover_destinations() list
        device_is_mounted "${dev}" && continue

        fstype=$(lsblk_field "${dev}" FSTYPE)
        case "${fstype}" in
            ext2|ext3|ext4|xfs|btrfs|f2fs|vfat|exfat|msdos|ntfs|ntfs3) state="available" ;;
            "") state="nofilesystem" ;;
            # swap, LVM and RAID members, encrypted volumes and optical media are
            # not something this module should be reformatting or mounting
            *) continue ;;
        esac

        size_b=$(lsblk -bdno SIZE "${dev}" 2>/dev/null | head -1)
        size_mb=$(( ${size_b:-0} / 1048576 ))
        if [ "${size_mb}" -eq 0 ] && [ "${type}" == "disk" ] && [ "$(lsblk_field "${dev}" RM)" == "1" ]; then
            # A card reader with no card in it: a removable disk of size zero.
            # Reported so the interface can say the reader is there but empty,
            # rather than leaving the user wondering why nothing was found.
            state="nomedia"
        elif [ "${size_mb}" -lt 512 ]; then
            # Below this it is a boot or recovery partition rather than a backup
            # drive, and offering it would only be a way to pick the wrong thing
            continue
        fi

        id=$(stable_id "${dev}")
        if [ "${state}" == "available" ]; then
            spec=$(fstab_spec_for "${dev}" "${id}" || true)
            if [ -n "${spec}" ] && fstab_has_spec "${spec}"; then
                state="infstab"
            fi
        fi

        kind="fixed"
        [ "$(lsblk_field "${dev}" RM)" == "1" ] && kind="removable"
        [ "$(lsblk_field "${dev}" HOTPLUG)" == "1" ] && kind="removable"

        label=$(lsblk_field "${dev}" LABEL)
        model=$(lsblk_field "${dev}" MODEL)
        # A partition carries no model of its own, it belongs to the disk
        [ -z "${model}" ] && [ -n "${parent}" ] && model=$(lsblk_field "/dev/${parent}" MODEL)

        disk="/dev/${parent}"
        disk_size_b=$(lsblk -bdno SIZE "${disk}" 2>/dev/null | head -1)
        disk_size_mb=$(( ${disk_size_b:-0} / 1048576 ))

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${id}" "${dev}" "${size_mb}" "${fstype}" \
            "$(tsv_safe "${label}")" "$(tsv_safe "${model}")" "${kind}" "${state}" \
            "${disk}" "${disk_size_mb}" "$(disk_contents "${disk}" | tr -d '\000-\037' | cut -c1-512)"

    done < <(lsblk -pnro NAME 2>/dev/null)

    # Finding no drives is an answer, not a failure
    return 0
}

# How this filesystem should be named in the first column of /etc/fstab.
#
# A filesystem UUID is the best answer: it follows the drive to another USB port
# and is unaffected by other disks being added or repartitioned. Not every
# filesystem has one. FAT has only a short volume serial and some drives report
# none at all, so fall back to the partition's own UUID from the partition table,
# and finally to the /dev/disk/by-id path the drive was chosen by, which is
# derived from the hardware and is stable in the same way.
#
# Only reads udev and the blkid cache, so this works as the web server user and
# gives the same answer as the privileged path below.
fstab_spec_for() {
    local dev="$1" id="$2" uuid partuuid

    uuid=$(lsblk_field "${dev}" UUID)
    [ -z "${uuid}" ] && uuid=$(blkid -s UUID -o value "${dev}" 2>/dev/null || true)
    if [ -n "${uuid}" ]; then
        echo "UUID=${uuid}"
        return 0
    fi

    partuuid=$(lsblk_field "${dev}" PARTUUID)
    [ -z "${partuuid}" ] && partuuid=$(blkid -s PARTUUID -o value "${dev}" 2>/dev/null || true)
    if [ -n "${partuuid}" ]; then
        echo "PARTUUID=${partuuid}"
        return 0
    fi

    case "${id}" in
        /dev/disk/by-id/*) echo "${id}"; return 0 ;;
    esac
    return 1
}

# Is this filesystem already named in /etc/fstab
fstab_has_spec() {
    local spec="$1"
    [ -n "${spec}" ] || return 1
    [ -f /etc/fstab ] || return 1
    awk -v s="${spec}" '
        /^[[:space:]]*#/ {next}
        NF >= 2 && tolower($1) == tolower(s) {found=1}
        END {exit !found}' /etc/fstab
}

# The mountpoint /etc/fstab already gives this filesystem, if any
fstab_mountpoint_for_spec() {
    local spec="$1"
    [ -n "${spec}" ] || return 0
    [ -f /etc/fstab ] || return 0
    awk -v s="${spec}" '
        /^[[:space:]]*#/ {next}
        NF >= 2 && tolower($1) == tolower(s) {print $2; exit}' /etc/fstab
}

# Mount options for a backup drive.
#
#   noatime   reading every file on each run would otherwise write a metadata
#             update per file, which on a flash drive is wear for nothing
#   nofail    a drive that is not plugged in must not stop the system booting
#   x-systemd.device-timeout   and must not delay the boot by 90s either
fstab_options_for() {
    local fstype="$1"
    local common="noatime,nofail,x-systemd.device-timeout=10"
    case "${fstype}" in
        btrfs)
            # Compresses as it writes, which on feed data is worth about 80%
            echo "defaults,${common},compress=zstd"
            ;;
        vfat|msdos|exfat|ntfs|ntfs3)
            # These cannot store unix ownership, so it is fixed at mount time.
            # drive-restore.sh sets ownership correctly on the way back in.
            echo "defaults,${common},uid=root,gid=root,umask=0022"
            ;;
        *)
            echo "defaults,${common}"
            ;;
    esac
}

# ext filesystems are worth a boot time fsck pass, the others either have no
# fsck or should not be checked automatically
fstab_pass_for() {
    case "$1" in
        ext2|ext3|ext4) echo 2 ;;
        *) echo 0 ;;
    esac
}

# A free mountpoint under /media. One fixed name, numbered if it is taken, so
# that what ends up in fstab is predictable and matches the documentation.
choose_mountpoint() {
    local base="/media/emoncms-backup" candidate n
    for n in "" -2 -3 -4 -5 -6 -7 -8 -9; do
        candidate="${base}${n}"
        # Already used by another fstab entry
        if [ -f /etc/fstab ] && awk -v p="${candidate}" '
                /^[[:space:]]*#/ {next} $2==p {found=1} END{exit !found}' /etc/fstab; then
            continue
        fi
        # Something is mounted there
        mountpoint -q "${candidate}" 2>/dev/null && continue
        # Exists and has something in it, which mounting over would hide
        if [ -d "${candidate}" ] && [ -n "$(ls -A "${candidate}" 2>/dev/null)" ]; then
            continue
        fi
        echo "${candidate}"
        return 0
    done
    return 1
}

# Remove /etc/fstab entries whose first column is one of the given specs, one
# per line. Used after a format, when the entries that named the old
# filesystems on the disk can no longer match anything. A comment line this
# module wrote above an entry goes with it. Same backup and atomic write as
# adding an entry.
fstab_remove_specs() {
    local specs="$1" backup tmp
    [ -n "${specs}" ] || return 0
    [ -f /etc/fstab ] || return 0

    echo "Removing /etc/fstab entries for the filesystems that were on the disk:"
    printf '%s\n' "${specs}" | sed '/^$/d; s/^/    /'

    backup="/etc/fstab.emoncms-backup.$(date +%Y%m%d%H%M%S).bak"
    as_root cp -a /etc/fstab "${backup}" || return 1
    echo "Previous /etc/fstab saved as ${backup}"

    tmp=$(mktemp) || return 1
    awk -v specs="${specs}" '
        BEGIN { n = split(specs, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") drop[tolower(a[i])] = 1 }
        /^# Added by the Emoncms backup module/ { held = $0; have = 1; next }
        !/^[[:space:]]*#/ && NF >= 2 && (tolower($1) in drop) { have = 0; next }
        { if (have) { print held; have = 0 } print }
        END { if (have) print held }' /etc/fstab > "${tmp}" || { rm -f "${tmp}"; return 1; }
    if ! as_root cp "${tmp}" /etc/fstab; then
        rm -f "${tmp}"
        echo "ERROR: could not write /etc/fstab"
        return 1
    fi
    rm -f "${tmp}"
    as_root chmod 644 /etc/fstab
    as_root systemctl daemon-reload 2>/dev/null || true
    return 0
}

# Put a btrfs filesystem on a drive. Destructive: the WHOLE DISK the device sits
# on is erased, every partition on it included. Reached only from --format-mount
# with --confirm-erase, on a drive discover_devices() reported, which by
# construction is not on any disk the system is using. That is checked again
# here, on the disk itself, immediately before anything is written.
#
# btrfs rather than ext4 because a backup drive is exactly where it pays:
# every block is checksummed so bit rot on an SD card is detected instead of
# restored, and feed data compresses by about 80% with compress=zstd.
#
# Sets formatted_device to the new partition and formatted_stale_specs to the
# /etc/fstab specs that named filesystems that no longer exist.
format_device() {
    local dev="$1" disk node part spec stale=""

    disk=$(disk_of "${dev}")
    if [ -z "${disk}" ] || [ ! -b "${disk}" ]; then
        echo "ERROR: cannot find the disk that ${dev} is on"
        return 1
    fi

    # The disk is what gets erased, so it is the disk that has to be clear of
    # anything the system is using, whatever discover_devices() said moments ago
    case " $(system_disks | tr '\n' ' ') " in
        *" $(basename "${disk}") "*)
            echo "ERROR: ${disk} holds a filesystem or swap the system is using, refusing to erase it"
            return 1
            ;;
    esac
    if device_is_mounted "${disk}"; then
        echo "ERROR: something on ${disk} is mounted, refusing to erase it"
        return 1
    fi

    if ! command -v parted > /dev/null; then
        echo "ERROR: parted is not installed, cannot partition ${disk}"
        echo "Install it with: sudo apt-get install -y parted"
        return 1
    fi
    if ! command -v mkfs.btrfs > /dev/null; then
        echo "ERROR: mkfs.btrfs is not installed, cannot format ${disk}"
        echo "Install it with: sudo apt-get install -y btrfs-progs"
        return 1
    fi
    if ! grep -qw btrfs /proc/filesystems && ! as_root modprobe btrfs 2>/dev/null; then
        echo "ERROR: this kernel has no btrfs support, cannot use ${disk}"
        return 1
    fi

    echo "Disk to erase: ${disk} ($(lsblk_field "${disk}" MODEL), $(human_bytes "$(lsblk -bdno SIZE "${disk}" 2>/dev/null | head -1)"))"
    echo "Currently holding: $(disk_contents "${disk}")"

    # /etc/fstab entries for the filesystems about to be destroyed would never
    # match again. Collect them now, while the filesystems still have UUIDs.
    while read -r node; do
        [ -n "${node}" ] || continue
        spec=$(fstab_spec_for "${node}" "$(stable_id "${node}")" || true)
        [ -n "${spec}" ] && fstab_has_spec "${spec}" && stale="${stale}${spec}"$'\n'
    done < <(lsblk -pnro NAME "${disk}" 2>/dev/null)

    # Wipe the filesystem signatures inside each partition before the partition
    # table, so that nothing can be recognised at its old offset afterwards
    echo "Removing every filesystem signature on ${disk}"
    while read -r node; do
        [ -n "${node}" ] || continue
        [ "${node}" == "${disk}" ] && continue
        as_root wipefs -a "${node}" > /dev/null 2>&1 || true
    done < <(lsblk -pnro NAME "${disk}" 2>/dev/null | tac)
    as_root wipefs -a "${disk}" > /dev/null || return 1

    echo "Creating a GPT partition table and a single partition on ${disk}"
    as_root parted -s "${disk}" mklabel gpt mkpart primary btrfs 1MiB 100% || return 1
    as_root udevadm settle || true
    sleep 2

    part=$(lsblk -pnro NAME "${disk}" 2>/dev/null | sed -n '2p')
    if [ -z "${part}" ] || [ ! -b "${part}" ]; then
        echo "ERROR: no partition appeared on ${disk} after partitioning"
        return 1
    fi
    echo "Created ${part}"

    echo "Creating a btrfs filesystem on ${part}"
    # Single device, so mkfs.btrfs keeps two copies of the metadata by default,
    # which is worth having on flash. Data is compressed at mount time instead,
    # see fstab_options_for().
    as_root mkfs.btrfs -f -L emoncms-backup "${part}" || return 1
    as_root udevadm settle || true

    formatted_device="${part}"
    formatted_stale_specs="${stale}"
    return 0
}

# Does the destination actually accept a write?
#
# A drive that is unplugged and plugged back in comes back as a new device and
# leaves the old mount in place. That mount is still listed, and reads can still
# be answered from the kernel's caches, so the marker file check above can pass
# on a destination where every write will fail with an I/O error. Writing a few
# bytes and forcing them out to the device is the only way to know.
probe_destination_writable() {
    local probe="${drive_backup_path}/.emoncms-backup-probe"
    local content="emoncms-backup-probe-$$"

    echo "${content}" > "${probe}" 2>/dev/null || return 1
    # Without this the write sits in the page cache and the error surfaces
    # later, part way through the backup, rather than here
    sync -f "${probe}" 2>/dev/null || { rm -f "${probe}" 2>/dev/null; return 1; }
    [ "$(cat "${probe}" 2>/dev/null)" == "${content}" ] || { rm -f "${probe}" 2>/dev/null; return 1; }
    rm -f "${probe}" 2>/dev/null || return 1
    return 0
}

# Turn the daily backup and weekly verify timers on or off.
#
# install.sh only enables them when drive_backup_path is already set, which on a
# fresh install it is not, so a drive chosen afterwards would be backed up only
# when someone presses the button. The interface can say that backups are not
# scheduled, so it needs to be able to do something about it too.
set_schedule() {
    local action="$1"
    local units="emoncms-drive-backup.timer emoncms-drive-backup-verify.timer"
    local unit missing=false

    for unit in ${units}; do
        if ! systemctl list-unit-files "${unit}" 2>/dev/null | grep -q "^${unit}"; then
            echo "ERROR: ${unit} is not installed"
            missing=true
        fi
    done
    if [ "${missing}" == "true" ]; then
        echo "Run ${script_location}/install.sh to install the systemd units."
        return 1
    fi

    if [ "${action}" == "enable" ]; then
        echo "Enabling ${units}"
        # --now so the timer starts counting immediately rather than at the next
        # boot, which is what someone pressing this in the interface means
        as_root systemctl enable --now ${units} || return 1
        echo "Daily backup and weekly verify are now scheduled."
    else
        echo "Disabling ${units}"
        as_root systemctl disable --now ${units} || return 1
        echo "Backups will now only run when started by hand."
    fi

    systemctl list-timers 'emoncms-drive-backup*' --no-pager 2>/dev/null || true
    return 0
}

# Mount a drive and record it in /etc/fstab so it returns after a reboot.
# Sets mounted_at on success.
mount_device() {
    local id="$1" do_format="$2"
    local row dev state fstype uuid spec mountpoint options pass line backup existing

    echo "Requested drive: ${id}"

    # The caller does not get to name an arbitrary device. It has to be one this
    # script's own discovery just reported, which is what makes it safe to reach
    # from the web interface.
    row=$(discover_devices | awk -F'\t' -v i="${id}" '$1==i {print; exit}')
    if [ -z "${row}" ]; then
        echo "ERROR: ${id} is not one of the drives available to set up"
        echo "Available:"
        discover_devices | awk -F'\t' '{printf "  %s (%s, %s MB, %s, %s)\n", $1, $2, $3, ($4==""?"no filesystem":$4), $8}'
        return 1
    fi

    dev=$(printf '%s' "${row}" | cut -f2)
    fstype=$(printf '%s' "${row}" | cut -f4)
    state=$(printf '%s' "${row}" | cut -f8)

    echo "Device: ${dev}"
    echo "Filesystem: ${fstype:-none}"
    echo "State: ${state}"

    if [ "${state}" == "nomedia" ]; then
        echo "ERROR: ${dev} is a card reader with no card in it"
        return 1
    fi

    if [ "${do_format}" != "true" ]; then
        case "${fstype}" in
            vfat|msdos)
                echo "NOTE: FAT cannot hold a file larger than 4 GB and cannot store unix"
                echo "      ownership. Feed files are well below 4 GB and drive-restore.sh sets"
                echo "      ownership on the way back in, so this works, but a drive formatted"
                echo "      as btrfs is a better long term choice."
                ;;
        esac
    fi

    if [ "${do_format}" == "true" ]; then
        echo ""
        echo "--- Formatting the disk that holds ${dev}, everything on it is being erased ---"
        formatted_device=""
        formatted_stale_specs=""
        format_device "${dev}" || return 1
        dev="${formatted_device}"
        fstype="btrfs"
        # The by-id name of the partition just created, not of the device that
        # was scanned and confirmed, which may no longer exist
        id=$(stable_id "${dev}")
        # Entries for the filesystems that were on the disk are now stale. Take
        # them out before looking for one to reuse, or a stale entry with the
        # wrong filesystem type would be found and used.
        fstab_remove_specs "${formatted_stale_specs}" || return 1
    elif [ "${state}" == "nofilesystem" ]; then
        echo "ERROR: ${dev} has no filesystem, so there is nothing to mount"
        echo "Format it first, or use a drive that already has a filesystem."
        return 1
    fi

    # fstab names the filesystem by UUID rather than by /dev/sda1, which is
    # assigned in the order drives are found and changes when another is added
    spec=$(fstab_spec_for "${dev}" "${id}" || true)
    if [ -z "${spec}" ]; then
        # A filesystem created moments ago is not in the udev database or the
        # blkid cache yet, so probe the device itself
        uuid=$(as_root blkid -p -s UUID -o value "${dev}" 2>/dev/null || true)
        [ -n "${uuid}" ] && spec="UUID=${uuid}"
    fi
    if [ -z "${spec}" ]; then
        echo "ERROR: ${dev} has no UUID, partition UUID or by-id name to identify it by,"
        echo "       so no stable /etc/fstab entry can be written for it."
        return 1
    fi
    echo "Identified in /etc/fstab as: ${spec}"

    # Already in fstab: use the mountpoint it names rather than adding a second
    # entry for the same filesystem, which is how fstab files end up broken
    existing=$(fstab_mountpoint_for_spec "${spec}")
    if [ -n "${existing}" ]; then
        echo "Already in /etc/fstab, mounted at ${existing}"
        mountpoint="${existing}"
        as_root mkdir -p "${mountpoint}"
    else
        mountpoint=$(choose_mountpoint)
        if [ -z "${mountpoint}" ]; then
            echo "ERROR: could not find a free mountpoint under /media"
            return 1
        fi
        options=$(fstab_options_for "${fstype}")
        pass=$(fstab_pass_for "${fstype}")
        line=$(printf '%s\t%s\t%s\t%s\t0\t%s' "${spec}" "${mountpoint}" "${fstype}" "${options}" "${pass}")

        echo "Mountpoint: ${mountpoint}"
        echo "Adding to /etc/fstab:"
        echo "    ${line}"

        as_root mkdir -p "${mountpoint}" || return 1

        backup="/etc/fstab.emoncms-backup.$(date +%Y%m%d%H%M%S).bak"
        as_root cp -a /etc/fstab "${backup}" || return 1
        echo "Previous /etc/fstab saved as ${backup}"

        # Written through a temporary file and copied into place, so that a
        # failure part way through cannot leave the system with a truncated
        # fstab and an unbootable configuration
        local tmp
        tmp=$(mktemp) || return 1
        {
            cat /etc/fstab
            echo ""
            echo "# Added by the Emoncms backup module on $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
            echo "${line}"
        } > "${tmp}"
        if ! as_root cp "${tmp}" /etc/fstab; then
            rm -f "${tmp}"
            echo "ERROR: could not write /etc/fstab"
            return 1
        fi
        rm -f "${tmp}"
        as_root chmod 644 /etc/fstab
    fi

    # systemd generates a .mount unit per fstab entry at daemon-reload, and
    # mounts by mountpoint alone only once it has seen the new entry
    as_root systemctl daemon-reload 2>/dev/null || true

    echo "Mounting ${mountpoint}"
    if ! as_root mount "${mountpoint}"; then
        echo "ERROR: could not mount ${dev} at ${mountpoint}"
        if [ -n "${backup}" ] && [ -f "${backup}" ]; then
            echo "Restoring the previous /etc/fstab"
            as_root cp "${backup}" /etc/fstab
            as_root systemctl daemon-reload 2>/dev/null || true
            as_root rmdir "${mountpoint}" 2>/dev/null || true
        fi
        return 1
    fi

    if ! mountpoint -q "${mountpoint}"; then
        echo "ERROR: ${mountpoint} is still not a mount point after mounting"
        return 1
    fi

    # The backup runs as root from the timer but the interface reads the drive as
    # the web user, so the mountpoint itself has to be traversable by both
    as_root chmod 755 "${mountpoint}" 2>/dev/null || true

    echo "Mounted:"
    findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS "${mountpoint}"
    echo "It will be mounted again automatically after a reboot."

    mounted_at="${mountpoint}"
    return 0
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
discover_devices_only=false
set_path=""
mount_id=""
mount_format=false
confirm_erase=false
schedule_action=""

while [ $# -gt 0 ]; do
    arg="$1"
    case "${arg}" in
        --init)       init=true ;;
        --verify)     mode="verify" ;;
        --dry-run)    dry_run=true ;;
        --if-mounted) if_mounted=true ;;
        --discover)   discover=true ;;
        --discover-devices) discover_devices_only=true ;;
        --confirm-erase)    confirm_erase=true ;;
        --enable-schedule)  schedule_action="enable" ;;
        --disable-schedule) schedule_action="disable" ;;
        --set-path)
            shift
            if [ -z "$1" ]; then
                echo "Error: --set-path requires a mountpoint"
                exit 1
            fi
            set_path="$1"
            ;;
        --mount|--format-mount)
            [ "${arg}" == "--format-mount" ] && mount_format=true
            shift
            if [ -z "$1" ]; then
                echo "Error: ${arg} requires a drive identifier from --discover-devices"
                exit 1
            fi
            mount_id="$1"
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
            echo "       $0 [--discover-devices] [--mount <id>] [--format-mount <id> --confirm-erase]"
            echo "       $0 [--enable-schedule] [--disable-schedule]"
            exit 1
            ;;
    esac
    shift
done

script_location="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
config_location=${script_location}/config.cfg
path_conf=${script_location}/drive-backup-path.conf

# Plain queries, answered without needing a configured or present destination
if [ "${discover_devices_only}" == "true" ]; then
    discover_devices
    trap - EXIT
    exit 0
fi

if [ "${discover}" == "true" ]; then
    discover_destinations
    trap - EXIT
    exit 0
fi

#-----------------------------------------------------------------------------------------------
# Is the drive backup enabled at all?
#
# Checked here, before anything runs as root, and read from config.cfg as plain
# text rather than by sourcing it: sourcing happens further down, in the copy of
# this script that runs as root. config.cfg is not writable from the web
# interface, so this is the one switch a compromised web tier cannot flip, and
# it is what makes the service-runner whitelist entries for this script inert on
# a system where the feature is not wanted.
#
# Turning the timers off is always allowed. Nothing else past the read only
# queries above is.
#-----------------------------------------------------------------------------------------------
drive_backup_enabled=$(grep -m1 '^drive_backup_enabled=' "${config_location}" 2>/dev/null \
    | cut -d= -f2- | tr -d "\"' " | tr 'A-Z' 'a-z' || true)
if [ "${drive_backup_enabled}" != "yes" ] && [ "${schedule_action}" != "disable" ]; then
    echo "=== Emoncms drive backup start ==="
    echo "ERROR: backup to an attached drive is not enabled on this system."
    echo "Set drive_backup_enabled=\"yes\" in ${config_location} to use it."
    exit 1
fi

#-----------------------------------------------------------------------------------------------
# Everything past this point needs root
#
# The systemd timers run this script as root. Started from the Emoncms interface
# it arrives as the service-runner user instead, which cannot read every feed
# file, cannot write a mirror that keeps their ownership, and cannot mount a
# drive or write to /etc/fstab. Re-exec under sudo rather than run on and report
# a permission error for every file.
#
# The read only queries above are deliberately before this. They are run directly
# by the web server user, which has no sudo rights and needs none.
#-----------------------------------------------------------------------------------------------
if [ "${EUID}" -ne 0 ]; then
    if ! sudo -n true 2>/dev/null; then
        echo "=== Emoncms drive backup start ==="
        echo "ERROR: this needs to run as root, and $(id -un) cannot use sudo without a password."
        echo "Run it with sudo, or let the emoncms-drive-backup systemd timer run it."
        exit 1
    fi
    # exec, so that the caller waits on the real run and reads its output. The
    # EXIT trap belongs to the process being replaced, so the completion message
    # comes from the copy running as root.
    exec sudo -n "$0" "${original_args[@]}"
fi

echo "=== Emoncms drive backup start ==="
date
echo "Backup module version:"
grep version "${script_location}/module.json"
echo "EUID: $EUID"

# Turning the schedule on or off is about the timers, not about any particular
# destination, so it needs nothing from the config and is answered here
if [ -n "${schedule_action}" ]; then
    if set_schedule "${schedule_action}"; then
        echo "=== Emoncms drive backup schedule updated ==="
# The strings output are identified in the interface to stop ongoing AJAX calls, please ammend in interface if changed here
        trap - EXIT
        exit 0
    fi
    # finish() reports this as a failed run
    exit 1
fi

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
: "${drive_backup_enabled:=no}"
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
# --mount / --format-mount: set up a drive that is plugged in but not mounted
#
# Mounting it and writing the /etc/fstab entry is the part users find hardest and
# get wrong most often, usually by mounting by hand and never adding it to fstab,
# so the backup silently stops working at the next reboot.
#
# Once mounted the drive is an ordinary destination, so this hands straight over
# to --set-path below rather than repeating what it does.
#-----------------------------------------------------------------------------------------------
if [ -n "${mount_id}" ]; then
    if ! [[ "${mount_id}" =~ ^/dev/[A-Za-z0-9._:@/+-]+$ ]]; then
        echo "ERROR: ${mount_id} is not a valid drive identifier"
        exit 1
    fi

    if [ "${mount_format}" == "true" ] && [ "${confirm_erase}" != "true" ]; then
        echo "ERROR: --format-mount erases the drive and requires --confirm-erase"
        exit 1
    fi

    if ! mount_device "${mount_id}" "${mount_format}"; then
        exit 1
    fi

    # Now that it is mounted it appears in discover_destinations(), and choosing
    # it goes through exactly the same checks as any other destination
    set_path="${mounted_at}"
    echo ""
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

    # Choosing a destination is a request for backups to happen, not just for the
    # one that follows. install.sh could not enable the timers because nothing
    # was configured when it ran, so this is the first moment they can be.
    set_schedule enable || echo "WARNING: the backup timers could not be enabled"

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
# The lock is shared with drive-restore.sh, and between root, which the timers
# and the interface run a backup as, and the web user, which the interface runs
# a restore as. flock works on a descriptor opened for reading, so the file only
# has to be readable by whoever comes second, not writable: a root-owned lock
# left in /tmp by a timer run would refuse the web user a write open.
if [ ! -e "${lock_file}" ]; then
    ( umask 022; : > "${lock_file}" ) 2>/dev/null || true
fi
if [ ! -r "${lock_file}" ]; then
    echo "ERROR: cannot read the lock file ${lock_file}"
    exit 1
fi
exec 200<"${lock_file}"
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

#-----------------------------------------------------------------------------------------------
# Safety check: the destination has to accept a write, not merely be present
#
# Reported as a failure rather than a skipped run even under --if-mounted. A
# drive that is plugged in but not working is not the same as one that is not
# plugged in: it will never back up again until someone is told about it.
#-----------------------------------------------------------------------------------------------
echo "Checking the destination accepts writes.."
if ! probe_destination_writable; then
    echo "ERROR: ${drive_backup_path} is mounted but will not accept a write"
    echo ""
    echo "The usual cause is the drive having been unplugged and plugged back in."
    echo "It comes back as a new device, and the old mount is left in place"
    echo "answering every access with an I/O error. Remounting fixes it:"
    echo ""
    echo "    sudo umount -l ${dest_mountpoint:-${drive_backup_path}}"
    echo "    sudo mount ${dest_mountpoint:-${drive_backup_path}}"
    echo ""
    echo "If that does not help, unplug the drive and plug it back in. If it keeps"
    echo "happening, check 'sudo dmesg' for I/O errors: the drive, the cable or the"
    echo "USB port may be at fault, and a drive that is failing should be replaced."
    exit 1
fi
echo "-- writable"

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
        # A hard link costs no space and no writes. FAT and exFAT cannot make
        # one, so fall back to a copy there.
        if ln -f "${sql_target}" "${sql_weekly_dir}/${sql_filename}" 2>/dev/null ||
           cp -f "${sql_target}" "${sql_weekly_dir}/${sql_filename}"; then
            echo "Retained weekly copy ${sql_weekly_dir}/${sql_filename}"
        else
            # Reported here rather than left to the ERR trap, which can only say
            # which line failed. Saying the copy was retained when it was not is
            # worse than saying nothing.
            echo "Error: could not retain the weekly copy in ${sql_weekly_dir}"
            errors=true
        fi
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
#-----------------------------------------------------------------------------------------------
# -a implies -p -o -g. A CIFS share mounted with fixed uid/gid/file_mode, or any
# FAT filesystem, cannot store unix ownership or permissions, and rsync then
# reports a failure for every single file. Ownership is not worth preserving on
# the backup anyway: drive-restore.sh sets it correctly on the way back in.
#
# Worked out here rather than with the feed data below, because the config files
# are copied first and are subject to exactly the same limitation.
#-----------------------------------------------------------------------------------------------
ownership_opts=$(rsync_ownership_opts)
if [ -n "${ownership_opts}" ]; then
    if [ "${drive_backup_preserve_permissions}" == "no" ]; then
        echo "Note: syncing without unix ownership, set by drive_backup_preserve_permissions"
    else
        echo "Note: ${dest_fstype:-destination} cannot store unix ownership, syncing without it"
    fi
fi

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
        out=$(rsync -a --stats ${ownership_opts} $([ "${dry_run}" == "true" ] && echo "--dry-run") \
              "${file}" "${drive_backup_path}/config/" 2>&1)
        rsync_rc=$?
        echo "-- ${file}"
        if [ ${rsync_rc} -ne 0 ]; then
            echo "Error: rsync of ${file} failed with code ${rsync_rc}"
            echo "${out}"
        fi
        add_literal_data "${out}"
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

# Set above, before the config files, which need the same treatment
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
