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
    sudo service feedwriter start > /dev/null
fi

#-----------------------------------------------------------------------------------------------
# Remove Old backup files
#-----------------------------------------------------------------------------------------------
if [ -f $backup_location/emoncms.sql ]
then
    sudo rm $backup_location/emoncms.sql
fi

if [ -f $backup_location/emoncms-backup-$date.tar ]
then
    sudo rm $backup_location/emoncms-backup-$date.tar
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

# Very old images (the ones shipped with kickstarter campaign) have "emonpi-28May2015"
if [[ -z $image_version ]] || [[ "$image_date" == "emonSD-17Jun2015" ]]
then
  image="old"
  echo "$image image"
else
  image="new"
  echo "$image image"
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
    sudo service feedwriter start > /dev/null
    exit 1
fi

# MYSQL Dump Emoncms database
if [ -n "$username" ]; then # if username string is not empty
    mysqldump -u$username -p$password emoncms > $backup_location/emoncms.sql
    if [ $? -ne 0 ]; then
        echo "Error: failed to export mysql data"
        echo "emoncms export failed"
        exit 1
    fi

else
    echo "Error: Cannot read MYSQL authentication details from Emoncms settings.php"
    sudo service feedwriter start > /dev/null
    exit 1
fi

echo "Emoncms MYSQL database dump complete, adding files to archive..."

if [ $image="old" ]; then
  # Create backup archive and add config files stripping out the path
  # Old image  = don't backup nodeRED config (since nodeRED doesnot exist)
  tar -cf $backup_location/emoncms-backup-$date.tar $backup_location/emoncms.sql $emonhub_config_path/emonhub.conf $emoncms_config_path/emoncms.conf $emoncms_location/settings.php --transform 's?.*/??g' 2>&1
  if [ $? -ne 0 ]; then
      echo "Error: failed to tar config data"
      echo "emoncms export failed"
      exit 1
  fi
fi

if [ $image="new" ]; then
  # Create backup archive and add config files stripping out the path
  # New image = backup NodeRED
  tar -cf $backup_location/emoncms-backup-$date.tar $backup_location/emoncms.sql $emonhub_config_path/emonhub.conf $emoncms_config_path/emoncms.conf $emoncms_location/settings.php /home/pi/data/node-red/flows_emonpi.json /home/pi/data/node-red/flows_emonpi_cred.json /home/pi/data/node-red/settings.js --transform 's?.*/??g' 2>&1
  if [ $? -ne 0 ]; then
      echo "Error: failed to tar config data"
      echo "emoncms export failed"
      exit 1
  fi
fi

# Append database folder to the archive with absolute path
tar --append --file=$backup_location/emoncms-backup-$date.tar -C $mysql_path phpfina phptimeseries 2>&1
if [ $? -ne 0 ]; then
    echo "Error: failed to tar mysql dump and data"
    echo "emoncms export failed"
    exit 1
fi

# Compress backup
echo "Compressing archive..."
gzip -fv $backup_location/emoncms-backup-$date.tar 2>&1
if [ $? -ne 0 ]; then
    echo "Error: failed to compress tar file"
    echo "emoncms export failed"
    exit 1
fi

sudo service feedwriter start > /dev/null

echo "Backup saved: $backup_location/emoncms-backup-$date.tar.gz"
date
echo "Export finished...refresh page to view download link"
echo "=== Emoncms export complete! ===" # This string is identified in the interface to stop ongoing AJAX calls, please ammend in interface if changed here
