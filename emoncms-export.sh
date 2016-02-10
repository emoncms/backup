#!/bin/bash

date=$(date +"%Y-%m-%d")

echo "=== Emoncms export start ==="
date

echo "Reading config.cfg...." >&2
if [ -f $PWD/config.cfg ]
then
    source $PWD/config.cfg
    echo "Location of mysql database: $mysql_path" >&2
    echo "Location of emonhub.conf: $emonhub_config_path" >&2
    echo "Location of emoncms.conf: $emoncms_config_path" >&2
    echo "Location of Emoncms: $emoncms_location" >&2
    echo "Backup destination: $backup_location" >&2
else
    echo "ERROR: Backup config.cfg file does not exist"
    exit 1
fi

#-----------------------------------------------------------------------------------------------
# Check emonPi / emonBase image version
#-----------------------------------------------------------------------------------------------
image_version=$(ls /boot | grep emonSD)
# Check first 16 characters of filename
image_date=${image_version:0:16}

if [[ "${image_version:0:6}" == "emonSD" ]]
then
    echo "Image version: $image_version"
fi

# Detect if SD card image verion, used to restore the correct emonhub.conf
if [[ "$image_date" == "emonSD-17Jun2015" ]]
then
  image="old"
else
  image="new"
fi
#-----------------------------------------------------------------------------------------------



sudo service feedwriter stop

# MYSQL Dump Emoncms database
auth=$(php $PWD/get_emoncms_mysql_auth.php)
IFS=":" read username password <<< "$auth"


# if username sring is not empty
if [ -n "$username" ]; then
    mysqldump -u$username -p$password emoncms > $backup_location/emoncms.sql
else
    echo "Cannot read MYSQL authentication details from Emoncms settings.php..STOPPING EXPORT"
    exit 1
fi

echo "MYSQL Emoncms database dump complete, starting compressing backupgit .."

# Compress backup with database and config files
tar -cvzf $backup_location/emoncms-backup-$date.tar.gz $mysql_path/emoncms.sql $mysql_path/phpfina $mysql_path/phptimeseries $emonhub_config_path/emonhub.conf $emoncms_config_path/emoncms.conf

sudo service feedwriter start

echo "backup saved $backup_location/emoncms-backup-$date.tar.gz"
date
echo "done..refresh page to view download link"
echo "=== Emoncms export complete! ===" # This string is identified in the interface to stop ongoing AJAX calls, please ammend in interface if changed here