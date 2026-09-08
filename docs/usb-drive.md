# Backing up to a USB drive

How to set up a USB drive as the destination for the daily backup. The [readme](../readme.md) explains what the drive backup is and how to turn it on. The [reference](reference.md) lists every option.

## From the interface

Plug the drive in, open the **Backup** tab and press **Scan for drives**. The tab lists drives that are already mounted alongside drives that are plugged in and not yet mounted, and offers each whatever it needs next.

**Mount and use this drive** mounts it, adds it to `/etc/fstab`, selects it as the backup destination and prepares it. Any drive can instead be erased and formatted as btrfs, behind a typed confirmation that lists everything currently on the disk. A drive with no filesystem is offered that way only.

btrfs is the recommended format. It checksums every block, so damage on the drive is detected. Mounted with `compress=zstd` it compresses feed data by about 80%, and it can snapshot the feed data as well as the database.

Only drives that are not on a disk the running system uses are offered, so the SD card cannot be picked by mistake. See [What the interface does](reference.md#what-the-interface-does).

Choosing a drive turns on the daily backup and the weekly verify. Press **Back up now** to take the first copy without waiting for the timer. The first run copies the whole dataset. Later runs append new data only.

## By hand

**1. Mount the drive.**

Use `noatime` and `nofail`. `noatime` avoids a metadata write per file on each run. `nofail` lets the system boot when the drive is missing.

    UUID=xxxx  /media/backup  ext4  defaults,noatime,nofail,x-systemd.device-timeout=10  0  2

For a NAS share see [Backing up to a NAS](nas.md).

**2. Choose it as the backup destination.**

From the **Backup** tab, or from a shell:

    ./drive-backup.sh --discover              # list what is available
    ./drive-backup.sh --set-path /media/backup

Or set it in `config.cfg` and prepare it yourself:

    drive_backup_path="/media/backup/emoncms"
    ./drive-backup.sh --init

**3. Take the first backup.**

    ./drive-backup.sh

`--set-path` turns the timers on. `--init` on its own does not, so after that route run:

    ./drive-backup.sh --enable-schedule

## Keeping it healthy

Run `--verify` weekly or monthly. The interface's **Verify and repair** button does the same. `--append-verify` skips any file whose size on the destination matches the source, so a same size rewrite in place (PHPFina back filling padding, or the postprocess module rewriting history) is invisible to the default mode. Verify compares every file by checksum and rewrites only the blocks that differ. The weekly timer does this on Sundays at 04:00, see [Scheduling](reference.md#scheduling).

The line at the top of the **Backup** tab says whether the data is protected. Amber means the drive is disconnected, the last backup is more than two days old, or the timer is off. Red means the last run failed, the last backup is more than a week old, or the drive is mounted but not answering.

## A drive that was unplugged and plugged back in

Unplugging a USB drive and plugging it back in does not restore the mount. The drive comes back as a new device and the old mount is left behind. It is still listed by `findmnt` and still answers reads from the kernel's caches, and every write fails with `Input/output error`.

The marker file check can be satisfied from cache, so before writing anything the script writes a few bytes to the destination, forces them to the device with `sync -f`, reads them back and removes them. If that fails it stops and prints the two commands that fix it:

    sudo umount -l /media/emoncms-backup
    sudo mount /media/emoncms-backup

This is reported as a failed run, even under `--if-mounted`. A drive that is plugged in and not working would never back up again, and nobody would be told.

The interface reports this state separately from a disconnected drive, since reconnecting the drive is the wrong advice here.
