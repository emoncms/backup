#!/bin/bash

date=$(date +"%Y-%m-%d")

echo "=== Emoncms export start ==="
date
echo "EUID: $EUID"
echo "Reading /home/pi/backup/config.cfg...."
if [ -f /home/pi/backup/config.cfg ]
then
    source /home/pi/backup/config.cfg
    echo "Location of mysql database: $mysql_path"
    echo "Location of emonhub.conf: $emonhub_config_path"
    echo "Location of emoncms.conf: $emoncms_config_path"
    echo "Location of Emoncms: $emoncms_location"
    echo "Backup destination: $backup_location"
else
    echo "ERROR: Backup /home/pi/backup/config.cfg file does not exist"
    exit 1
fi

backup_location="/home/pi/usbdisk/backup"

#-----------------------------------------------------------------------------------------------
# Remove Old backup files
#-----------------------------------------------------------------------------------------------
#if [ -f $backup_location/emoncms.sql ]
#then
#    sudo rm $backup_location/emoncms.sql
#fi


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
if [ -f /home/pi/backup/get_emoncms_mysql_auth.php ]; then
    auth=$(echo $emoncms_location | php /home/pi/backup/get_emoncms_mysql_auth.php php)
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

echo "Emoncms MYSQL database dump complete, adding files to archive .."

cp $emonhub_config_path/emonhub.conf $backup_location
cp $emoncms_config_path/emoncms.conf $backup_location
cp $emoncms_location/settings.php $backup_location
cp /home/pi/data/node-red/flows_emonpi.json $backup_location
cp /home/pi/data/node-red/settings.js $backup_location

# Append database folder to the archive with absolute path
#cp --verbose -r /home/pi/$mysql_path $backup_location
cp --verbose -r /home/pi/data/phpfina/. $backup_location/phpfina
cp --verbose -r /home/pi/data/phptimeseries/. $backup_location/phptimeseries

sudo service feedwriter start > /dev/null

date
echo "=== Emoncms export complete! ===" # This string is identified in the interface to stop ongoing AJAX calls, please ammend in interface if changed here
