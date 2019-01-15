#!/bin/bash
script_location="`dirname $0`"

date=$(date +"%Y-%m-%d")

echo "=== Emoncms export start ==="
date
echo "Backup module version:"
cat /home/pi/backup/backup/module.json | grep version
echo "EUID: $EUID"
echo "Reading $script_location/config.cfg...."
if [ -f "$script_location/config.cfg" ]
then
    source "$script_location/config.cfg"
    echo "Location of databases: $database_path"
    echo "Location of emonhub.conf: $emonhub_config_path"
    echo "Location of Emoncms: $emoncms_location"
    echo "Backup destination: $backup_location"
else
    echo "ERROR: Backup $script_location/backup/config.cfg file does not exist"
    exit 1
    sudo service feedwriter start > /dev/null
fi

module_location="${emoncms_location}/Modules/backup"
echo "emoncms backup module location $module_location"

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
else
  image="new"
fi
#-----------------------------------------------------------------------------------------------

# Disabled in @borphin commit?
sudo service feedwriter stop

# Get MYSQL authentication details from settings.php
if [ -f $script_location/get_emoncms_mysql_auth.php ]; then
    auth=$(echo $emoncms_location | php $script_location/get_emoncms_mysql_auth.php php)
    IFS=":" read username password <<< "$auth"
else
    echo "Error: cannot read MYSQL authentication details from Emoncms $script_location/get_emoncms_mysql_auth.php php & settings.php"
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
        sudo service feedwriter start > /dev/null
        exit 1
    fi
else
    echo "Error: Cannot read MYSQL authentication details from Emoncms settings.php"
    sudo service feedwriter start > /dev/null
    exit 1
fi

echo "Emoncms MYSQL database dump complete, adding files to archive .."

if [ -f $backup_location/emoncms.sql ]
then
  tar -c --file=$backup_location/emoncms-backup-$date.tar $backup_location/emoncms.sql --transform 's?.*/??g' 2>&1
else
    echo "no file $backup_location/emoncms.sql"
fi

if [ -f $emonhub_config_path/emonhub.conf ]
then
  tar -vr --file=$backup_location/emoncms-backup-$date.tar $emonhub_config_path/emonhub.conf --transform 's?.*/??g' 2>&1
else
    echo "no file $emonhub_config_path/emonhub.conf"
fi

if [ -f $emoncms_location/settings.php ]
then
  tar -vr --file=$backup_location/emoncms-backup-$date.tar $emoncms_location/settings.php --transform 's?.*/??g' 2>&1
else
    echo "no file $emoncms_location/settings.php"
fi

# Append database folder to the archive with absolute path
if [ -d $database_path/phpfina ]
then
  tar -vr --file=$backup_location/emoncms-backup-$date.tar -C $database_path phpfina 2>&1
  if [ $? -ne 0 ]; then
    echo "Error: failed to tar phpfina"
  fi
else
    echo "no phpfina directory"
fi

if [ -d $database_path/phpfiwa ]
then
  tar -vr --file=$backup_location/emoncms-backup-$date.tar -C $database_path phpfiwa 2>&1
  if [ $? -ne 0 ]; then
    echo "Error: failed to tar phpfiwa"
  fi
else
    echo "no phpfiwa directory"
fi

if [ -d $database_path/phptimeseries ]
then
  tar -vr --file=$backup_location/emoncms-backup-$date.tar -C $database_path phptimeseries 2>&1
  if [ $? -ne 0 ]; then
    echo "Error: failed to tar phptimeseries"
  fi
else
    echo "no phptimeseries directory $database_path/phptimeseries"
fi

# Compress backup
echo "Compressing archive..."
gzip -fv $backup_location/emoncms-backup-$date.tar 2>&1
if [ $? -ne 0 ]; then
    echo "Error: failed to compress tar file"
    echo "emoncms export failed"
    sudo service feedwriter start > /dev/null
    exit 1
fi

sudo service feedwriter start > /dev/null

echo "Backup saved: $backup_location/emoncms-backup-$date.tar.gz"
date
echo "Export finished...refresh page to view download link"
echo "=== Emoncms export complete! ===" # This string is identified in the interface to stop ongoing AJAX calls, please ammend in interface if changed here
