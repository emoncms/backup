#!/bin/bash
backup_module_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd $backup_module_dir
openenergymonitor_dir=$1

# Try default openenergymonitor directory if not specified
if [ ! $openenergymonitor_dir ]; then
    if [ ! -d /opt/openenergymonitor ]; then
        echo "- Missing openenergymonitor directory parameter and default: /opt/openenergymonitor not found"
        exit 0
    else
        # If directory exists: use default
        openenergymonitor_dir=/opt/openenergymonitor
    fi
fi

# Load EmonScripts installation config.ini
if [ -f $openenergymonitor_dir/EmonScripts/install/config.ini ]; then
    cd $openenergymonitor_dir/EmonScripts/install
    source load_config.sh
    cd $backup_module_dir
    emonhub_directory=$openenergymonitor_dir/emonhub
else
    echo "- EmonScripts config.ini not found, starting manual process"
    read -p "- Please enter system user (e.g pi): " user
    echo "  $user"
    read -p "- Please enter emoncms directory (e.g /var/www/emoncms): " emoncms_www
    if [ -d $emoncms_www ]; then echo "  $emoncms_www valid"; else echo "  $emoncms_www invalid"; exit 0; fi
    read -p "- Please enter emoncms data directory (e.g /var/opt/emoncms): " emoncms_datadir
    if [ -d $emoncms_datadir ]; then echo "  $emoncms_datadir valid"; else echo "  $emoncms_datadir invalid"; exit 0; fi
    read -p "- Please enter emonhub directory (e.g /opt/openenergymonitor/emonhub): " emonhub_directory
    if [ -d $emonhub_directory ]; then echo "  $emonhub_directory valid"; else echo "  $emonhub_directory invalid"; exit 0; fi
fi

# Backing up to an attached drive runs as root and can mount and format drives,
# so it is only switched on where a USB backup drive is the normal case: a
# Raspberry Pi. Anywhere else it is a deliberate choice, made by hand in
# config.cfg, see default.config.cfg.
if grep -qi "raspberry pi" /proc/device-tree/model 2>/dev/null; then
    drive_backup_default="yes"
else
    drive_backup_default="no"
fi

# Creating backup module config.cfg file
if [ ! -f config.cfg ]; then
    echo "- Copying default.config.cfg to config.cfg"
    cp default.config.cfg config.cfg
    echo "- Setting config.cfg settings"
    sed -i "s~USER~$user~" config.cfg
    sed -i "s~BACKUP_SCRIPT_LOCATION~$backup_module_dir~" config.cfg
    sed -i "s~EMONCMS_LOCATION~$emoncms_www~" config.cfg
    sed -i "s~BACKUP_LOCATION~$emoncms_datadir/backup~" config.cfg
    sed -i "s~DATABASE_PATH~$emoncms_datadir~" config.cfg
    sed -i "s~EMONHUB_CONFIG_PATH~/etc/emonhub~" config.cfg
    sed -i "s~EMONHUB_SPECIMEN_CONFIG~$emonhub_directory/conf~" config.cfg
    sed -i "s~BACKUP_SOURCE_PATH~$emoncms_datadir/backup/uploads~" config.cfg
    sed -i "s~^drive_backup_enabled=.*~drive_backup_enabled=\"$drive_backup_default\"~" config.cfg
    echo "- drive_backup_enabled set to \"$drive_backup_default\""
else 
    echo "- config.cfg already exists, left as it is"
    # An install from before the switch existed. Add it with the default a fresh
    # install would get, so that a Raspberry Pi already backing up to a drive
    # carries on doing so after the update.
    if ! grep -q "^drive_backup_enabled=" config.cfg; then
        echo "- adding drive_backup_enabled=\"$drive_backup_default\" to config.cfg"
        printf '\n# Whether backing up to an attached drive can be used, see default.config.cfg\ndrive_backup_enabled="%s"\n' \
            "$drive_backup_default" >> config.cfg
    fi
fi
source config.cfg

# Load backup module configuration file
upload_location=$backup_location/uploads

# Symlink emoncms UI (if not done so already)
if [ ! -L $emoncms_www/Modules/backup ]; then
    echo "- symlinking backup module"
    ln -s $backup_module_dir/backup-module $emoncms_www/Modules/backup
fi

# php_ini=/etc/php5/apache2/php.ini
PHP_VER=$(php -v | head -n 1 | cut -d " " -f 2 | cut -f1-2 -d"." )
php_ini=/etc/php/$PHP_VER/apache2/php.ini
# echo "- PHP Version: $PHP_VER"

echo "- creating /etc/php/$PHP_VER/mods-available/emoncmsbackup.ini"
cat << EOF |
post_max_size = 3G
upload_max_filesize = 3G
upload_tmp_dir = ${upload_location}
EOF
sudo tee /etc/php/$PHP_VER/mods-available/emoncmsbackup.ini

echo "- phpenmod emoncmsbackup"
sudo phpenmod emoncmsbackup

# Create uploads folder
if [ ! -d $backup_location ]; then
    echo "- creating $backup_location directory"
    sudo mkdir $backup_location
    sudo chown $user:$user $backup_location -R
fi

if [ ! -d $backup_location/uploads ]; then
    echo "- creating $backup_location/uploads directory"
    sudo mkdir $backup_location/uploads
    sudo chown www-data:$user $backup_location/uploads -R
fi

# ---------------------------------------------------------------
# Backup to an attached drive
#
# Nothing below is installed unless it is switched on in config.cfg: no packages
# it alone needs, and no systemd units that would run drive-backup.sh as root.
# ---------------------------------------------------------------
if [ "$drive_backup_enabled" != "yes" ]; then
    echo "- backup to an attached drive is not enabled (drive_backup_enabled=\"no\" in config.cfg)"
    echo "  Its timers and packages are not installed. To use it, set drive_backup_enabled=\"yes\""
    echo "  in $backup_module_dir/config.cfg and run this script again."
else

# drive-backup.sh requires rsync
if ! command -v rsync > /dev/null; then
    echo "- installing rsync (required by drive-backup.sh)"
    sudo apt-get install -y rsync
fi

# drive-backup.sh --format-mount partitions a drive with parted and formats it
# as btrfs, which needs btrfs-progs
if ! command -v parted > /dev/null; then
    echo "- installing parted (required to format a backup drive)"
    sudo apt-get install -y parted
fi
if ! command -v mkfs.btrfs > /dev/null; then
    echo "- installing btrfs-progs (required to format a backup drive as btrfs)"
    sudo apt-get install -y btrfs-progs
fi

# ---------------------------------------------------------------
# Install the drive-backup.sh systemd timers
#
# The timers are only enabled once drive_backup_path has been set in config.cfg,
# so that a fresh install does not schedule a backup to nowhere. Re-run this
# script after setting it, or enable them by hand with the commands printed below.
# ---------------------------------------------------------------
echo "- installing drive-backup systemd units"
for unit in emoncms-drive-backup.service emoncms-drive-backup.timer \
            emoncms-drive-backup-verify.service emoncms-drive-backup-verify.timer; do
    sed "s~BACKUP_SCRIPT_LOCATION~$backup_module_dir~" "$backup_module_dir/systemd/$unit" \
        | sudo tee /etc/systemd/system/$unit > /dev/null
done
sudo systemctl daemon-reload

if [ -n "$drive_backup_path" ]; then
    echo "- drive_backup_path is set to $drive_backup_path, enabling timers"
    sudo systemctl enable --now emoncms-drive-backup.timer
    sudo systemctl enable --now emoncms-drive-backup-verify.timer
    sudo systemctl list-timers 'emoncms-drive-backup*' --no-pager
else
    echo "- drive_backup_path is not set in config.cfg, timers installed but not enabled"
    echo "  To enable daily drive backup, mount a USB drive or NAS share, then either"
    echo "  choose it on the Drive Backup tab of the backup module in Emoncms, or:"
    echo "    1. $backup_module_dir/drive-backup.sh --discover"
    echo "    2. $backup_module_dir/drive-backup.sh --set-path <mountpoint>"
    echo "    3. sudo systemctl enable --now emoncms-drive-backup.timer emoncms-drive-backup-verify.timer"
fi

fi # drive_backup_enabled

echo "- restarting apache"
sudo service apache2 restart
