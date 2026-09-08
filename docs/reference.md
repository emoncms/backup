# Reference

Every option of the drive backup, the timers, what the Emoncms interface does behind each button, how the scripts get root, the layout on the drive and the safety checks. For getting started see the [USB drive guide](usb-drive.md) or the [NAS guide](nas.md).

## Command line

    ./drive-backup.sh              # append new data only, for daily use
    ./drive-backup.sh --verify     # full checksum check and repair
    ./drive-backup.sh --dry-run    # report what would be written, write nothing
    ./drive-backup.sh --if-mounted # skip quietly if the drive is unavailable
    ./drive-backup.sh --discover   # list mounted drives that could hold a backup
    ./drive-backup.sh --set-path <mountpoint>   # select one and prepare it

    ./drive-backup.sh --discover-devices        # list drives that are not mounted
    ./drive-backup.sh --mount <id>              # mount one, add it to fstab, use it
    ./drive-backup.sh --format-mount <id> --confirm-erase   # ERASES the whole disk, formats btrfs

    ./drive-backup.sh --enable-schedule    # turn the daily and weekly timers on
    ./drive-backup.sh --disable-schedule   # and off again

`<id>` is the first column of `--discover-devices`, normally a `/dev/disk/by-id/` path. Kernel names such as `/dev/sda` are handed out in the order drives appear, so the drive scanned as `/dev/sda` can be a different drive by the time the user confirms.

The first run copies the whole dataset. Later runs append new data only.

Run `--verify` weekly or monthly. `--append-verify` skips any file whose size on the destination matches the source, so a same size rewrite in place (PHPFina back filling padding, or the postprocess module rewriting history) is invisible to the default mode. Verify compares every file by checksum and rewrites only the blocks that differ.

The restore options are in [Restoring](restore.md).

## Configuration

The drive backup settings in `config.cfg`, with their defaults. `default.config.cfg` documents each one.

| Setting | Default | Meaning |
|---|---|---|
| `drive_backup_enabled` | `no`, `yes` on a Raspberry Pi | the master switch, see [Enabling it](../readme.md#enabling-it) |
| `drive_backup_path` | empty | destination directory on the mounted drive |
| `drive_backup_retain_daily_sql` | `7` | daily MYSQL dumps to keep |
| `drive_backup_retain_weekly_sql` | `4` | weekly MYSQL dumps to keep |
| `drive_backup_weekly_day` | `1` | day of week to keep a weekly dump, 1 is Monday |
| `drive_backup_min_free_mb` | `256` | refuse to run if less than this would be left free |
| `drive_backup_allow_same_filesystem` | `no` | allow a destination on the root filesystem |
| `drive_backup_preserve_permissions` | `auto` | keep unix ownership on the backup, see [Ownership](nas.md#differences-from-a-local-disk) |
| `drive_backup_probe_seconds` | `20` | how long to wait for a network share before skipping |

The destination chosen in the interface, or with `--set-path`, is written to `drive-backup-path.conf` and takes precedence over `drive_backup_path` in `config.cfg`.

## Scheduling

`install.sh` installs two systemd timers when the drive backup is enabled. Choosing a destination, in the interface or with `--set-path`, turns them on. They can also be turned on and off from the **Backup drive** card in the interface, or from a shell:

    ./drive-backup.sh --enable-schedule
    ./drive-backup.sh --disable-schedule

which is equivalent to:

    sudo systemctl enable --now emoncms-drive-backup.timer emoncms-drive-backup-verify.timer

| Timer | Schedule | Runs |
|---|---|---|
| `emoncms-drive-backup.timer` | daily | append new feed data |
| `emoncms-drive-backup-verify.timer` | Sundays 04:00 | full checksum verify and repair |

Both use `Persistent=true`, so a backup missed while the system was off runs at the next boot, and `RandomizedDelaySec=1h`, so several systems on one site do not wake together.

The timers run the script with `--if-mounted`. An absent drive, an unreachable share or a run already in progress counts as a skipped run, not a failure. The next run after the drive returns catches up.

Check status:

    systemctl list-timers 'emoncms-drive-backup*'
    systemctl status emoncms-drive-backup
    journalctl -u emoncms-drive-backup -o cat

Each run also writes `/var/log/emoncms/drivebackup.log` (`drivebackup-verify.log` for verify), overwritten each time.

Run one now:

    sudo systemctl start emoncms-drive-backup

## The Emoncms interface

The module has two tabs, **Backup** and **Restore**.

Backup opens with one line saying whether the data is protected.

| Colour | Meaning |
|---|---|
| green | a recent backup exists and the daily timer is on |
| amber | the drive is disconnected, no backup has been taken yet, the last backup is more than two days old, or the timer is off |
| red | the last run failed, the last backup is more than a week old, or the drive is mounted but not answering |

Below that the tab has two sections.

**Automatic backup.** The **Backup drive** card shows where the copy goes, how full the drive is, when it last ran and what it wrote, and when it runs next. Its buttons back up, verify, and turn the daily schedule on and off. Explanations sit inside the card as disclosures. **Change drive** opens the list of drives. A second card, **Restore points**, lists the database snapshots held on the drive.

When there is no working destination, or **Change drive** is pressed, one card lists every drive that could be used. Mounted drives sit alongside drives that still need setting up. **Scan for drives** looks again.

**Portable copy.** Build an archive and download it.

Each run reports Complete, Failed or Nothing to do in the header of its log.

Restore gathers the three recovery paths: the backup drive, an uploaded `.tar.gz` archive, and an old emonSD card in a USB reader. Restoring from the drive or the SD card needs a confirmation box ticked.

### What the interface does

**Scan for drives** runs `--discover-devices`. A device is offered if it is not on a disk carrying a mounted filesystem or active swap, is not read only, is at least 512 MB, and holds either a mountable filesystem or nothing at all. Swap, LVM and RAID members and encrypted volumes are never listed. A card reader with no card in it is listed as such and cannot be used.

Confirming a drive runs `--mount <id>`, which:

1. checks the identifier against its own `--discover-devices` output, as `--set-path` checks a mountpoint. The interface cannot name a device of its own choosing.
2. picks the name for `/etc/fstab`: the filesystem UUID, else its `PARTUUID`, else the `/dev/disk/by-id/` path it was chosen by. FAT has only a short volume serial and some drives report none. If that name is already in `/etc/fstab`, the mountpoint in that entry is used.
3. otherwise picks the first free of `/media/emoncms-backup`, `-2`, `-3` and so on, and adds an entry with `noatime,nofail,x-systemd.device-timeout=10`. btrfs also gets `compress=zstd`. FAT, exFAT and NTFS get `uid=root,gid=root,umask=0022`, since they cannot store unix ownership.
4. copies `/etc/fstab` to `/etc/fstab.emoncms-backup.<timestamp>.bak` first, and restores it if the drive fails to mount.
5. hands over to `--set-path`.

`--format-mount <id> --confirm-erase` first erases the **whole disk** the device sits on and writes a GPT label, one partition and a btrfs filesystem labelled `emoncms-backup`. The whole disk, because a used SD card carries a boot partition and a root partition and formatting one of them leaves a mixed card. `--discover-devices` reports the disk and its contents in its last three columns and the interface shows them in the confirmation. Before writing, the script checks again that nothing on the disk is mounted or in use as swap. `/etc/fstab` entries naming the old filesystems are removed, with the same backup. The interface asks for `ERASE` to be typed and sends it with the request. The module checks it before queueing anything.

Formatting needs `parted` and `btrfs-progs`, which `install.sh` installs.

### Running as root

Everything past the read only queries needs root. The systemd timers run the script as root. From the Emoncms interface it runs as the `service-runner` user and re-execs itself under `sudo -n`. Without passwordless sudo it stops with a message.

`--discover` and `--discover-devices` run before that point, directly as the web server user, which has no sudo rights and needs none. So does the `drive_backup_enabled` check.

This relies on the `service-runner` user having passwordless sudo for everything. The Raspberry Pi OS default user has it and the EmonScripts install guides set it up elsewhere. A sudoers rule naming just these two scripts would be no tighter, since the same user owns them and could edit them. Tightening it means making the scripts root owned and read only to that user, then granting sudo for exactly those paths.

Every drive action that changes something must be requested with POST. The session cookie is `SameSite=Strict`, so another site cannot make the browser send it, and a link or an image tag cannot start an action.

The destination chosen in the interface is written to `drive-backup-path.conf`, which takes precedence over `config.cfg`. `config.cfg` is sourced as shell by scripts running as root, so it is not writable from the web interface. The interface can only select a mountpoint that `--discover` reported, and `--set-path` checks the mountpoint against that list again.

The tab needs `service-runner` running with `backup-drive-sync`, `backup-drive-verify`, `backup-drive-setpath`, `backup-drive-mount`, `backup-drive-schedule` and `backup-drive-restore` on its whitelist. They are in Emoncms core from the `backup_support` branch onwards. `service-runner` reads the whitelist at startup, so restart it after updating Emoncms. An action missing from the whitelist is rejected without output. The interface reports an action as not started when the log has not changed 15 seconds after the request.

## Layout on the drive

    /media/backup/emoncms/
        .emoncms-backup-target      marker, the script refuses to write without it
        phpfina/  phpfiwa/  phptimeseries/
        config/                     settings.ini (or settings.php), emonhub.conf
        sql/daily/                  last 7 MYSQL dumps
        sql/weekly/                 last 4, hard linked so they cost no extra space
        status.json                 result of the last run

## Safety

The script refuses to run if the destination is missing its marker file or is on the root filesystem, which is what happens when the USB drive is not mounted. Both checks stop an unmounted drive filling the system disk with a copy of the feed data. Set `drive_backup_allow_same_filesystem="yes"` to override the second check when deliberately backing up to the same disk.

A feed removed from Emoncms is left in place on the backup and reported as an orphan.

Nothing outside the destination directory is ever deleted. The backup does not use `rsync --delete`. It removes only its own expired MYSQL dumps and a mirrored feed file whose feed has been recreated. See [What the backup does on the share](nas.md#what-the-backup-does-on-the-share).
