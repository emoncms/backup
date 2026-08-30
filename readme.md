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
    ./drive-backup.sh --discover   # list drives that could hold a backup
    ./drive-backup.sh --set-path <mountpoint>   # select one and prepare it

The first run copies the whole dataset; later runs append only new data.

Run `--verify` periodically, weekly or monthly. It is needed because
`--append-verify` skips any file whose size on the destination already matches
the source, so a same size in place rewrite (PHPFina back filling padding, or the
postprocess module rewriting history) is invisible to the default mode. Verify
compares every file by checksum and rewrites only the blocks that differ, so it
is thorough without being wasteful.

### Scheduling

`install.sh` installs two systemd timers. They are enabled automatically if
`drive_backup_path` is already set when you run it, otherwise enable them once you
have configured and initialised the drive:

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

The backup module's **Drive Backup** tab lists the drives it found, lets you pick
one as the backup destination, and then shows the state of that drive, the result
of the last run, how much was written and the database snapshots held, with
buttons to back up, verify and restore. Restoring requires ticking a
confirmation box.

The destination chosen in the interface is written to `drive-backup-path.conf`
rather than to `config.cfg`, and it takes precedence over `config.cfg`.
`config.cfg` is sourced as shell by scripts running as root, so it is
deliberately not writable from the web interface. The interface can only select
a mountpoint that `drive-backup.sh --discover` reported, and `--set-path`
re-checks that the mountpoint is in that list before accepting it, so choosing a
destination can never point a root process at an arbitrary directory. The tab needs `service-runner` to be running, and the
`backup-drive-sync`, `backup-drive-verify` and `backup-drive-restore` actions to be
present in its whitelist (they are in Emoncms core).

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

### Safety

The script refuses to run if the destination is missing its marker file or is on
the root filesystem, which is what happens when the USB drive is not mounted. Both
checks exist to stop an unmounted drive quietly filling the system disk with a
copy of the feed data. Set `drive_backup_allow_same_filesystem="yes"` to override
the second check if you are deliberately backing up to the same disk.

A feed removed from Emoncms is left in place on the backup and reported as an
orphan rather than deleted.
