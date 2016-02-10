#!/bin/bash

date=$(date +"%Y-%m-%d")

echo "=== Emoncms export start ==="
date
echo "Reading ~/backup/config.cfg...."
if [ -f ~/backup/config.cfg ]
then
    source ~/backup/config.cfg
    echo "Location of mysql database: $mysql_path"
    echo "Location of emonhub.conf: $emonhub_config_path"
    echo "Location of emoncms.conf: $emoncms_config_path"
    echo "Location of Emoncms: $emoncms_location"
    echo "Backup destination: $backup_location"
else
    echo "ERROR: Backup ~/backup/config.cfg file does not exist"
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

# Get MYSQL authentication details from settings.php
if [ -f ~/backup/get_emoncms_mysql_auth.php ]; then
    auth=$(echo $emoncms_location | php ~/backup/get_emoncms_mysql_auth.php php)
    IFS=":" read username password <<< "$auth"
else
    echo "Error: cannot read MYSQL authentication details from Emoncms settings.php"
    echo "$PWD"
    exit 1
fi

# MYSQL Dump Emoncms database
if [ -n "$username" ]; then # if username sring is not empty
    mysqldump -u$username -p$password emoncms > $backup_location/emoncms.sql
else
    echo "Error: Cannot read MYSQL authentication details from Emoncms settings.php"
    exit 1
fi

echo "Emoncms MYSQL database dump complete, starting compressing backup .."

# Compress backup with database and config files
tar -cvzf $backup_location/emoncms-backup-$date.tar.gz $mysql_path/emoncms.sql $mysql_path/phpfina $mysql_path/phptimeseries $emonhub_config_path/emonhub.conf $emoncms_config_path/emoncms.conf

sudo service feedwriter start

echo "backup saved $backup_location/emoncms-backup-$date.tar.gz"
date
echo "done..refresh page to view download link"
echo "=== Emoncms export complete! ===" # This string is identified in the interface to stop ongoing AJAX calls, please ammend in interface if changed here