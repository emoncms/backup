# Emoncms backup export and import tool for backup and migration

* Export a compressed archive containing Emoncms Inputs, Feed data, Dashboards & config

* Backup contains the Emoncms MYSQL database, phpfina, phptimeseries data files, emonhub.conf and emoncms.conf

* Import compressed archive into another Emoncms account

## User Guide

[Backup module User Guide](https://guide.openenergymonitor.org/setup/import/)

Via Emoncms module web interface [(see video screencast guide)](https://www.youtube.com/watch?v=5U_tOlsWjXM) or manual (see below for manual instructions):

## Install

**Requirements**

- Latest emoncms master or stable branch, installed in /var/www/emoncms
- Emoncms with redis enabled
- Emoncms with service-runner service running (see: [Emoncms: Install Service-runner](https://github.com/emoncms/emoncms/blob/master/scripts/services/install-service-runner-update.md))

If you have not done so already, install the EmonScripts repository:

    cd /opt/openenergymonitor
    git clone https://github.com/openenergymonitor/EmonScripts.git
 
Install this module in /opt/emoncms/modules:

    cd /opt/emoncms/modules
    git clone https://github.com/emoncms/backup.git
    
Run backup module installation script to modify php.ini and setup uploads folder:

    cd backup
    ./install.sh

## Manual Export Instructions

Run `./emoncms-export.sh`

## Manual Import Instructions

If importing large backup files browser upload method may fail. In this case follow:

1. Copy `emoncms-backup-xxx.tar.gz` backup file to `data_source_path` in `config.cfg`
2. Run `./emoncms-import.sh`


## Write efficient backup to an attached drive

`emoncms-export.sh` rebuilds and recompresses a complete archive on every run, so
it writes roughly twice the size of the dataset each time. That is fine for an
occasional migration but unsuitable for a daily backup to a USB flash drive,
both for speed and for flash wear.

`drive-backup.sh` instead maintains a directory *mirror* on the drive and writes
only what has changed. The destination can be a USB disk or a NAS share. The PHPFina and PHPTimeSeries engines are append only
fixed record size stores (4 and 9 bytes per record), so from one day to the next
the only new feed data is at the end of each file. `rsync --append-verify` sends
and writes just that tail.

On a system with 83 feeds and 738 MB of PHPFina data:

| | written per run |
|---|---|
| `emoncms-export.sh` (tar + gzip) | ~1.5 GB |
| `drive-backup.sh` feed data | 1.8 MB |
| `drive-backup.sh` MYSQL dump | 1.1 MB |

The MYSQL dump uses `--single-transaction`, so unlike the archive export there is
no need to stop `feedwriter`.

### Setup

The quickest route is the **Backup** tab of the backup module in Emoncms: plug
the drive in, press **Scan for drives**, and it offers to set up what it finds.
Confirming mounts the drive, adds it to `/etc/fstab` so it is mounted again after
a reboot, selects it as the backup destination and prepares it. A drive with no
filesystem on it is offered separately, with a typed confirmation, and is
partitioned and formatted as ext4 first.

Only drives that are plugged in and not already mounted are offered, and never
anything on a disk the running system is using, so the SD card cannot be picked
by mistake. See [Setting up a drive from the interface](#setting-up-a-drive-from-the-interface)
below for what it does and does not do.

To do it by hand instead:

**1. Mount the drive.**

For a USB disk, use `noatime` so that reading every file on each run does not
generate a metadata write per file, and `nofail` so a missing drive cannot hang
boot:

    UUID=xxxx  /media/backup  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10  0  2

For a NAS, mount the share. Use `soft` on NFS so an unreachable server returns an
error instead of blocking forever, and `nofail` so boot is not delayed:

    nas:/volume/emoncms  /media/backup  nfs   defaults,soft,timeo=50,retrans=2,nofail,noatime  0  0
    //nas/emoncms        /media/backup  cifs  credentials=/etc/emoncms-nas.cred,nofail,noatime,uid=root,gid=root  0  0

**2. Choose it as the backup destination.**

Either in the Emoncms interface, on the backup module's **Drive Backup** tab,
which lists the drives it found and prepares the one you pick; or from a shell:

    ./drive-backup.sh --discover              # list what is available
    ./drive-backup.sh --set-path /media/backup

Or set it by hand in `config.cfg` and prepare it yourself:

    drive_backup_path="/media/backup/emoncms"
    ./drive-backup.sh --init

### Usage

    ./drive-backup.sh              # append new data only, for daily use
    ./drive-backup.sh --verify     # full checksum check and repair
    ./drive-backup.sh --dry-run    # report what would be written, write nothing
    ./drive-backup.sh --if-mounted # skip quietly if the drive is unavailable
    ./drive-backup.sh --discover   # list mounted drives that could hold a backup
    ./drive-backup.sh --set-path <mountpoint>   # select one and prepare it

    ./drive-backup.sh --discover-devices        # list drives that are not mounted
    ./drive-backup.sh --mount <id>              # mount one, add it to fstab, use it
    ./drive-backup.sh --format-mount <id> --confirm-erase   # ERASES the drive first

    ./drive-backup.sh --enable-schedule    # turn the daily and weekly timers on
    ./drive-backup.sh --disable-schedule   # and off again

`<id>` is the identifier in the first column of `--discover-devices`, normally a
`/dev/disk/by-id/` path. It is used rather than `/dev/sda1` because kernel names
are handed out in the order drives are found, so the drive that was `/dev/sda`
during a scan can be a different drive by the time the user confirms.

The first run copies the whole dataset; later runs append only new data.

Run `--verify` periodically, weekly or monthly. It is needed because
`--append-verify` skips any file whose size on the destination already matches
the source, so a same size in place rewrite (PHPFina back filling padding, or the
postprocess module rewriting history) is invisible to the default mode. Verify
compares every file by checksum and rewrites only the blocks that differ, so it
is thorough without being wasteful.

### Scheduling

`install.sh` installs two systemd timers. They are enabled automatically if
`drive_backup_path` is already set when it runs, which on a fresh install it is
not. Choosing a destination enables them, whether that is done in the interface
or with `--set-path`, so in the normal case there is nothing to do.

They can also be turned on and off from the **Run now** card in the interface, or
from a shell:

    ./drive-backup.sh --enable-schedule
    ./drive-backup.sh --disable-schedule

which is equivalent to:

    sudo systemctl enable --now emoncms-drive-backup.timer emoncms-drive-backup-verify.timer

| Timer | Schedule | Runs |
|---|---|---|
| `emoncms-drive-backup.timer` | daily | append new feed data |
| `emoncms-drive-backup-verify.timer` | Sundays 04:00 | full checksum verify and repair |

Both use `Persistent=true`, so a backup missed while the system was powered off
runs on the next boot rather than being skipped, and `RandomizedDelaySec=1h` so
that several systems on one site do not all wake at once.

The timers run the script with `--if-mounted`, which treats an absent drive as a
skipped run rather than a failure. You can unplug the drive without filling the
journal with errors, and the next run after plugging it back in catches up with
everything missed in between.

Check status and see the schedule:

    systemctl list-timers 'emoncms-drive-backup*'
    systemctl status emoncms-drive-backup
    journalctl -u emoncms-drive-backup -o cat

Each run also writes `/var/log/emoncms/drivebackup.log` (and
`drivebackup-verify.log`), overwritten each time, holding the output of the most
recent run.

Run one immediately without waiting for the timer:

    sudo systemctl start emoncms-drive-backup

### Emoncms interface

The backup module has two tabs, **Backup** and **Restore**.

Backup opens with a single line saying whether the data is actually protected:
green only when a recent backup exists *and* the daily timer is running, amber
when the drive is disconnected, when backups are falling behind, or when nothing
is scheduled, red when the last run failed, when the backup is more than a week
old, or when the drive is mounted but not answering.

Below that the tab is in two parts, because it does two different jobs:

**Automatic backup** is the ongoing protection. One card holds everything about
it: where the copy goes, how full the drive is, when it last ran and what it
wrote, when it runs next, and the buttons to back up, verify, or turn the daily
schedule on and off. The explanations sit inside it as disclosures, next to what
they explain, rather than at the foot of the page. A second card lists the
restore points held on the drive.

When there is no working destination, or **Change drive** is pressed, a single
card offers every drive that could be used: those already mounted alongside those
that are plugged in and still need setting up, in one list, each row offering
whatever that drive needs next. Pressing **Scan for drives** looks again.

**Portable copy** is the occasional one: build an archive and download it. It is
kept apart from the drive backup rather than sitting in the middle of it.

Every run reports whether it worked in the header of its log.

Restore gathers all three recovery paths in one place: the backup drive, an
uploaded `.tar.gz` archive, and an old emonSD card in a USB reader. Each requires
ticking a confirmation box.

#### Setting up a drive from the interface

**Scan for drives** runs `--discover-devices`, which lists attached block devices
that are not mounted. A device is only offered if it is not on any disk carrying
a mounted filesystem, is not read only, is at least 512 MB, and either holds a
filesystem that can be mounted or holds nothing at all. Swap, LVM and RAID
members and encrypted volumes are never listed.

Confirming runs `--mount <id>`, which:

1. re-checks the identifier against its own `--discover-devices` output, exactly
   as `--set-path` re-checks a mountpoint, so the interface cannot name a device
   of its own choosing
2. works out how to name the filesystem in `/etc/fstab`: its UUID where it has
   one, otherwise its `PARTUUID`, otherwise the `/dev/disk/by-id/` path it was
   chosen by. FAT has only a short volume serial and some drives report none at
   all, so a UUID cannot be assumed. If that name is already in `/etc/fstab` the
   mountpoint that entry gives is used, rather than a second entry being added
   for the same filesystem
3. otherwise picks the first free `/media/emoncms-backup`, `-2`, `-3` ... and
   appends an entry with `noatime,nofail,x-systemd.device-timeout=10`, plus
   `compress=zstd` on btrfs and fixed `uid`/`gid` on filesystems that cannot
   store unix ownership
4. copies `/etc/fstab` to `/etc/fstab.emoncms-backup.<timestamp>.bak` first, and
   restores it if the drive then fails to mount, so a drive that will not mount
   cannot leave an entry behind that breaks the next boot
5. hands over to `--set-path`, so selecting and preparing the destination goes
   through the same code as choosing an already mounted drive

`--format-mount <id> --confirm-erase` additionally writes a GPT label, a single
partition and an ext4 filesystem labelled `emoncms-backup`, with `-m 0` so none
of the drive is reserved for root. It refuses to run on a device that already
has a filesystem, so it can only ever erase a drive that appeared as
`nofilesystem` in the scan. The interface asks for `ERASE` to be typed and sends
that word with the request; the module checks it before queueing anything.

#### Running as root

Everything past the read only queries needs root: reading every feed file,
writing a mirror that keeps their ownership, mounting a drive and writing
`/etc/fstab`. The systemd timers run the script as root already. Started from the
Emoncms interface it arrives as the `service-runner` user instead, so it re-execs
itself under `sudo -n` rather than running on and reporting a permission error
for every file. Without passwordless sudo it stops with a message instead of
waiting for a prompt no one can answer.

`--discover` and `--discover-devices` are deliberately before that point. They are
run directly by the web server user, which has no sudo rights and needs none.

The destination chosen in the interface is written to `drive-backup-path.conf`
rather than to `config.cfg`, and it takes precedence over `config.cfg`.
`config.cfg` is sourced as shell by scripts running as root, so it is
deliberately not writable from the web interface. The interface can only select
a mountpoint that `drive-backup.sh --discover` reported, and `--set-path`
re-checks that the mountpoint is in that list before accepting it, so choosing a
destination can never point a root process at an arbitrary directory. The tab needs `service-runner` to be running, and the
`backup-drive-sync`, `backup-drive-verify`, `backup-drive-setpath`,
`backup-drive-mount`, `backup-drive-schedule` and `backup-drive-restore` actions to
be present in its whitelist (they are in Emoncms core).

### Layout on the drive

    /media/backup/emoncms/
        .emoncms-backup-target      marker, the script refuses to write without it
        phpfina/  phpfiwa/  phptimeseries/
        config/                     settings.ini (or settings.php), emonhub.conf
        sql/daily/                  last 7 MYSQL dumps
        sql/weekly/                 last 4, hard linked so they cost no extra space
        status.json                 result of the last run

### Restoring

`emoncms-import.sh` reads a `.tar.gz` archive and cannot read this mirror, so
restoring uses `drive-restore.sh`:

    ./drive-restore.sh --list        # show the snapshots on the drive
    ./drive-restore.sh               # restore the newest, asks you to confirm
    ./drive-restore.sh --sql <name>  # restore a specific snapshot
    ./drive-restore.sh --dry-run     # report what would be done, change nothing
    ./drive-restore.sh --delete      # also remove feed files not in the backup

It stops the Emoncms services, imports the chosen MYSQL snapshot, copies the
feed data back, restores `emonhub.conf`, flushes redis and restarts everything.

Before overwriting anything it dumps the current database to `backup_location`
as `pre-restore-<date>.sql.gz`, so a restore started by mistake can be undone:

    gunzip -c <backup_location>/pre-restore-<date>.sql.gz | mysql -u<user> -p <database>

Feed data is overwritten in place and is not covered by that safety net.

Emoncms `settings.ini` / `settings.php` are held in the backup for reference but
are **not** restored. They contain the database credentials and paths of the
system the backup was taken from, which are not necessarily correct on the
system being restored to.

By default feed files present on this system but absent from the backup are left
alone. Pass `--delete` to make the restore an exact mirror of the backup instead.

The restore refuses to run without `--yes` when it is not attached to a terminal,
so it cannot destroy data from a cron job or a stray script without someone
having asked for it. The Emoncms interface passes `--yes` after its own
confirmation.

The same lock file is shared with `drive-backup.sh`, so a backup and a restore can
never run at the same time.

### Backing up to a NAS

Everything above works unchanged with an NFS or SMB share as the destination.
Three things differ from a local disk:

**Ownership.** `rsync -a` preserves unix ownership and permissions. A CIFS share
mounted with a fixed `uid`/`gid`/`file_mode`, and any FAT, exFAT or NTFS
filesystem, cannot store them, and rsync then reports a failure for every file.
`drive_backup_preserve_permissions="auto"` (the default) detects those
filesystems and syncs without ownership. Nothing is lost by this:
`drive-restore.sh` sets ownership correctly on the way back in regardless. Set it
to `yes` or `no` to force the behaviour.

**Reachability.** A share can be mounted but unreachable, and on a hard NFS mount
any access then blocks in uninterruptible IO indefinitely, which would hang the
systemd unit forever. Both scripts probe a network destination first and give up
after `drive_backup_probe_seconds` (default 20). Under the timer this counts as a
skipped run, exactly like an unplugged USB drive. Mount NFS shares with `soft` as
well, so that reads during the run fail rather than hang.

**Compression and restore points come from the filesystem.** Neither can be done
to the mirror itself: compressing a feed file, or hard linking it into a dated
snapshot directory, both mean rewriting the whole file on every run, which is
exactly the cost this design exists to avoid. A copy on write filesystem gives
both for free, because compression happens per extent below the append and a
snapshot costs only the delta. Formatting the backup drive as btrfs and mounting
it with `compress=zstd` is worth doing: measured on real PHPFina data, feed files
compress by roughly 80%. The interface reports which of these the chosen drive
supports.

**Verify cost.** Verify reads every byte on both sides. Over gigabit ethernet a
3 GB dataset is around half a minute of transfer; over wifi or 100 Mbit it is
minutes. For a network destination consider running it monthly instead of weekly:

    sudo systemctl edit emoncms-drive-backup-verify.timer

    [Timer]
    OnCalendar=
    OnCalendar=monthly

The daily append run is unaffected: it transfers only the new readings, a few
megabytes, so the saving over pushing a full archive across the network every
night is far larger than on a local disk.

### A drive that was unplugged and plugged back in

Unplugging a USB drive and plugging it back in does not restore the mount. The
drive comes back as a new device and the old mount is left behind, still listed
by `findmnt` and still answering reads out of the kernel's caches, but failing
every write with `Input/output error`. Nothing in the mount table says anything
is wrong.

Checking the marker file is not enough to catch this, because that check can be
satisfied from cache. So before writing anything the script writes a few bytes to
the destination, forces them out to the device with `sync -f`, reads them back and
removes them. If that fails it stops and says so, with the two commands that fix
it:

    sudo umount -l /media/emoncms-backup
    sudo mount /media/emoncms-backup

This is reported as a failed run rather than a skipped one, even under
`--if-mounted`. A drive that is plugged in but not working is not the same as a
drive that is absent: left alone it would never back up again, and nobody would
be told.

The interface reports the same state separately from a disconnected drive, since
"reconnect the drive" is the wrong advice here, and it is what the disconnected
message says.

### Safety

The script refuses to run if the destination is missing its marker file or is on
the root filesystem, which is what happens when the USB drive is not mounted. Both
checks exist to stop an unmounted drive quietly filling the system disk with a
copy of the feed data. Set `drive_backup_allow_same_filesystem="yes"` to override
the second check if you are deliberately backing up to the same disk.

A feed removed from Emoncms is left in place on the backup and reported as an
orphan rather than deleted.
