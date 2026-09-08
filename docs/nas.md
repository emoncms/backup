# Backing up to a NAS

Everything in the [USB drive guide](usb-drive.md) works with an NFS or SMB share as the destination. This guide starts from nothing: creating the share on the NAS, mounting it on the Emoncms system and choosing it in the interface. It then covers the four things that differ from a local disk.

## What the backup does on the share

The first question from anyone with existing data on a NAS is what the backup can touch. The answer is one folder.

- **It only writes inside one folder.** When a mounted share is chosen, the destination is `<mountpoint>/emoncms`. The feed mirror, config copy, MYSQL dumps, `status.json` and the marker file all live in there. See [Layout on the drive](reference.md#layout-on-the-drive).
- **It never deletes outside that folder.** The daily backup does not use `rsync --delete`. The only files it removes are its own expired MYSQL dumps in `emoncms/sql/`, which are named after this system's hostname, and a feed file inside the mirror when that feed has been recreated on the Emoncms side.
- **It cannot format a share.** The erase and format action only accepts a local block device, and a network mount is not one. A share appears in the scan as a network drive and is offered for use as it is.
- **A restore only reads the share.** `drive-restore.sh --delete` removes feed files on the Emoncms system that are not in the backup. It does not delete on the share.
- **The NAS user is the second line of defence.** Give the Emoncms system a NAS user that can see one dedicated shared folder and nothing else. Then nothing on the Emoncms side, including a bug, can reach the rest of the NAS.

Do not point it at a share that already has an `emoncms` folder holding something else. The backup would mix into that folder. A fresh shared folder is the clean answer.

## Setting up a share

### On the NAS

Menus differ between Synology, QNAP, TrueNAS and the rest, but the steps are the same.

1. Create a new shared folder called `emoncms-backup`. Do not reuse an existing one.
2. Create a NAS user called `emoncms` with a password. Give it read and write access to `emoncms-backup` only, and no access to any other shared folder.
3. Turn on SMB, sometimes called CIFS or "Windows file service". SMB is the simplest option and the backup handles its ownership limitation automatically. NFS works too, see [NFS instead of SMB](#nfs-instead-of-smb).
4. Give the NAS a fixed IP address, either as a reservation in the router or as a static address on the NAS. The mount names the NAS by address, and a changed address means a missing backup drive.

### On the Emoncms system, SMB

Install the SMB client and create a mountpoint:

    sudo apt-get install -y cifs-utils
    sudo mkdir -p /media/nas-backup

Put the NAS user's password in a file only root can read:

    sudo tee /etc/emoncms-nas.cred > /dev/null <<'CRED'
    username=emoncms
    password=YOUR_PASSWORD_HERE
    CRED
    sudo chmod 600 /etc/emoncms-nas.cred

Add one line to the end of `/etc/fstab` with `sudo nano /etc/fstab`, replacing the address with the NAS's:

    //192.168.1.50/emoncms-backup  /media/nas-backup  cifs  credentials=/etc/emoncms-nas.cred,uid=root,gid=root,nofail,_netdev,noatime,x-systemd.device-timeout=10  0  0

`nofail` lets the system boot when the NAS is off. `_netdev` waits for the network before trying. `uid=root,gid=root` fixes the ownership of every file, which SMB cannot store anyway.

Mount it and check it accepts a write:

    sudo systemctl daemon-reload
    sudo mount /media/nas-backup
    findmnt /media/nas-backup
    sudo touch /media/nas-backup/test && sudo rm /media/nas-backup/test

If the mount fails, the usual causes are a wrong password, a share name that does not match exactly, or an SMB version the NAS does not offer. Adding `vers=3.0` to the options fixes the last one on most NAS models.

### NFS instead of SMB

Install the NFS client:

    sudo apt-get install -y nfs-common
    sudo mkdir -p /media/nas-backup

On the NAS, add an NFS permission rule on the shared folder for the Emoncms system's IP address with read and write access. The backup runs as root, and NFS servers map root to an unprivileged user by default, so every write would be refused. Either turn that mapping off for this rule (`no_root_squash` on a Linux server, "no mapping" on Synology) or map root to a user that owns the folder ("map root to admin" on Synology) and set this in `config.cfg`, since a mapped root cannot set file ownership:

    drive_backup_preserve_permissions="no"

Then the `/etc/fstab` line. Use `soft`, so an unreachable server returns an error instead of blocking, and `nofail`:

    192.168.1.50:/volume1/emoncms-backup  /media/nas-backup  nfs  defaults,soft,timeo=50,retrans=2,nofail,_netdev,noatime  0  0

The exported path is shown on the NAS next to the NFS settings. Mount and check it as for SMB above.

### In Emoncms

Open the **Backup** tab and press **Scan for drives**. The share is listed as a network drive. Confirm it. That records `/media/nas-backup/emoncms` as the destination, creates the folders in it and turns on the daily backup and weekly verify. Press **Back up now** to take the first copy.

From a shell instead:

    ./drive-backup.sh --discover
    ./drive-backup.sh --set-path /media/nas-backup
    ./drive-backup.sh

The first run copies everything. Over gigabit ethernet a few GB takes a minute or two. Over wifi it can take a while. Later daily runs write only the new readings, a few megabytes.

## Differences from a local disk

**Ownership.** `rsync -a` preserves unix ownership and permissions. A CIFS share mounted with a fixed `uid`, `gid` or `file_mode`, and any FAT, exFAT or NTFS filesystem, cannot store them, and rsync then reports a failure for every file. `drive_backup_preserve_permissions="auto"` (the default) detects those filesystems and syncs without ownership. Nothing is lost. `drive-restore.sh` sets ownership on the way back in regardless. Set it to `yes` or `no` to force the behaviour. NFS is not detected automatically, so on an NFS export that maps root to another user set it to `no` by hand.

**Reachability.** A share can be mounted and unreachable. On a hard NFS mount any access then blocks in uninterruptible IO indefinitely and the systemd unit hangs. Both scripts probe a network destination first and give up after `drive_backup_probe_seconds` (default 20). Under the timer this counts as a skipped run, like an unplugged USB drive, and the next run after the NAS returns catches up. Mount NFS shares with `soft` as well, so that reads during the run fail instead of hanging.

**Compression and restore points come from the filesystem.** Compressing a feed file, or hard linking it into a dated snapshot directory, means rewriting the whole file on every run, which is the cost this design avoids. A copy on write filesystem gives both for free. Compression happens per extent below the append and a snapshot costs only the delta. On a local drive that means formatting it as btrfs and mounting it with `compress=zstd`, which is what the interface's erase and format action does. On a NAS it depends on the filesystem the NAS uses for the shared folder. Many NAS models use btrfs and offer compression and snapshots per shared folder in their own settings. Measured on real PHPFina data, feed files compress by about 80%.

**Verify cost.** Verify reads every byte on both sides. Over gigabit ethernet a 3 GB dataset is about half a minute of transfer. Over wifi or 100 Mbit it is minutes. For a network destination consider running it monthly:

    sudo systemctl edit emoncms-drive-backup-verify.timer

    [Timer]
    OnCalendar=
    OnCalendar=monthly

## One share per system

MYSQL dumps are named after the hostname, so one folder can hold the dumps of several systems without them pruning each other. The feed mirrors are not, so two systems backing up into the same `emoncms` folder would overwrite each other's feed files. Give each Emoncms system its own shared folder.
