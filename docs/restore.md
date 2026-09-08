# Restoring

Restoring from the backup drive, from the shell or from the **Restore** tab in Emoncms. The tab gathers the three recovery paths: the backup drive, an uploaded `.tar.gz` archive, and an old emonSD card in a USB reader. Restoring from the drive or the SD card needs a confirmation box ticked.

## From the drive

`emoncms-import.sh` reads a `.tar.gz` archive and cannot read the drive mirror. Restoring uses `drive-restore.sh`:

    ./drive-restore.sh --list        # show the snapshots on the drive
    ./drive-restore.sh               # restore the newest, asks you to confirm
    ./drive-restore.sh --sql <name>  # restore a specific snapshot
    ./drive-restore.sh --dry-run     # report what would be done, change nothing
    ./drive-restore.sh --delete      # also remove feed files not in the backup

It stops the Emoncms services, imports the chosen MYSQL snapshot, copies the feed data back, restores `emonhub.conf`, flushes redis and restarts everything.

The **Restore points** card on the Backup tab lists the same snapshots, and **Restore from drive** on the Restore tab restores the newest.

## Undoing a restore

Before overwriting anything it dumps the current database to `backup_location` as `pre-restore-<date>.sql.gz`. A restore started by mistake can be undone with:

    gunzip -c <backup_location>/pre-restore-<date>.sql.gz | mysql -u<user> -p <database>

Feed data is overwritten in place and is not covered by that safety net.

## What is and is not restored

`settings.ini` and `settings.php` are held in the backup for reference and are **not** restored. They hold the database credentials and paths of the system the backup was taken from.

Feed files present on this system but absent from the backup are left alone by default. Pass `--delete` to make this system an exact mirror of the backup. `--delete` acts on this system only. Nothing is removed from the drive.

## Safeguards

The restore refuses to run without `--yes` when it is not attached to a terminal, so a cron job or a stray script cannot destroy data. The Emoncms interface passes `--yes` after its own confirmation.

The lock file is shared with `drive-backup.sh`, so a backup and a restore never run at the same time.

## From a portable archive

Upload the `.tar.gz` on the **Restore** tab. The browser upload can fail for a large archive. In that case copy the file to the `backup_source_path` directory named in `config.cfg` and run:

    ./emoncms-import.sh
