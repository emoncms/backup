# Emoncms backup

Backup and restore for Emoncms. There are two kinds of backup.

- **A portable archive.** One `.tar.gz` file holding the MYSQL database, the phpfina, phpfiwa and phptimeseries feed data, `emonhub.conf` and `settings.ini` (or `settings.php`). `emoncms-export.sh` builds it and `emoncms-import.sh` reads it. Use it to move to another system or to keep a copy off site.
- **A daily backup to an attached drive.** A mirror on a USB drive or NAS share that writes only what has changed. `drive-backup.sh` maintains it and `drive-restore.sh` restores from it.

Both are available from the **Backup** module in Emoncms and from a shell.

![The Backup tab of the Emoncms backup module](backup_module.png)

## Guides

- [Backing up to a USB drive](docs/usb-drive.md): setting up a drive from the interface or by hand, and what to do when a drive stops answering
- [Backing up to a NAS](docs/nas.md): a step by step walkthrough for an SMB or NFS share, and what the backup does and does not touch on the share
- [Restoring](docs/restore.md): restoring from the drive, and undoing a restore
- [Reference](docs/reference.md): every command line option, the timers, the interface, running as root, the layout on the drive and the safety checks

## Install

Requirements:

- Emoncms master or stable, installed in `/var/www/emoncms`
- Redis enabled
- The service-runner service running ([install instructions](https://github.com/emoncms/emoncms/blob/master/scripts/services/install-service-runner-update.md))

Install the EmonScripts repository if it is not already present:

    cd /opt/openenergymonitor
    git clone https://github.com/openenergymonitor/EmonScripts.git

Install this module:

    cd /opt/emoncms/modules
    git clone https://github.com/emoncms/backup.git
    cd backup
    ./install.sh

`install.sh` creates `config.cfg` from `default.config.cfg`, symlinks the module into Emoncms, raises the PHP upload limits and creates the uploads folder. On a Raspberry Pi it also installs the packages and systemd timers for the drive backup, see [Enabling it](#enabling-it).

## Portable archive

Export from a shell:

    ./emoncms-export.sh

The export stops `feedwriter` while it runs and writes the whole dataset each time.

The browser upload can fail for a large archive. In that case:

1. Copy the `.tar.gz` file to the `backup_source_path` directory named in `config.cfg`
2. Run `./emoncms-import.sh`

## Backup to an attached drive

`emoncms-export.sh` rebuilds and recompresses a complete archive on every run, writing about twice the size of the dataset. That is too slow for a daily backup and wears out a flash drive.

`drive-backup.sh` keeps a directory mirror on the drive and writes only what has changed. The destination can be a USB disk or a NAS share. PHPFina and PHPTimeSeries are append only stores with fixed record sizes (4 and 9 bytes), so from one day to the next the only new feed data is at the end of each file. `rsync --append-verify` writes just that tail.

Measured on a system with 83 feeds and 738 MB of PHPFina data:

| | written per run |
|---|---|
| `emoncms-export.sh` (tar + gzip) | ~1.5 GB |
| `drive-backup.sh` feed data | 1.8 MB |
| `drive-backup.sh` MYSQL dump | 1.1 MB |

The MYSQL dump uses `--single-transaction`, so `feedwriter` keeps running.

### Enabling it

Backing up to a drive runs as root. It reads every feed file, mounts drives, writes `/etc/fstab` and can format a disk. It is behind a switch in `config.cfg`:

    drive_backup_enabled="yes"

`install.sh` sets it to `yes` on a Raspberry Pi and to `no` anywhere else. To use it on a virtual machine or a server, set it to `yes` by hand and run `install.sh` again. That installs the timers and the `rsync`, `parted` and `btrfs-progs` packages.

With the switch at `no`, `drive-backup.sh` and `drive-restore.sh` refuse everything except listing drives and turning the timers off. This applies from the interface and from a shell alike. The interface says how to turn it on.

The scripts check the switch themselves. `config.cfg` cannot be written from the web interface, so a compromised web tier cannot flip it, and the `backup-drive-*` entries in the `service-runner` whitelist do nothing on a system where the feature is off.

### Setting it up

The quickest route is the **Backup** tab. Plug the drive in, press **Scan for drives** and confirm the drive. That mounts it, selects it as the destination and turns on the daily backup and weekly verify. Press **Back up now** once to take the first full copy.

The [USB drive guide](docs/usb-drive.md) and the [NAS guide](docs/nas.md) cover each case in detail, including doing it by hand.
