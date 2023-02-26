#!/bin/bash
script_location="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
config_location=${script_location}/config.cfg

date=$(date +"%Y-%m-%d")

echo "=== Emoncms export start ==="
date
echo "Backup module version:"
grep version ${script_location}/module.json
echo "EUID: $EUID"
echo "Reading ${config_location}...."
if [ -f "${config_location}" ]
then
    source "${config_location}"
    echo "Location of databases: $database_path"
    echo "Location of emonhub.conf: $emonhub_config_path"
    echo "Location of Emoncms: $emoncms_location"
    echo "Backup destination: $backup_location"
else
    echo "ERROR: Backup config file ${config_location} does not exist"
    exit 1
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
sudo systemctl stop feedwriter

# Get MYSQL authentication details from settings.php
if [ -f $script_location/get_emoncms_mysql_auth.php ]; then
    auth=$(echo $emoncms_location | php $script_location/get_emoncms_mysql_auth.php php)
    IFS=":" read username password database <<< "$auth"
else
    echo "Error: cannot read MYSQL authentication details from Emoncms $script_location/get_emoncms_mysql_auth.php php & settings.php"
    echo "$PWD"
    sudo systemctl start feedwriter > /dev/null
    exit 1
fi

# MYSQL Dump Emoncms database
if [ -n "$username" ]; then # if username string is not empty
    mysqldump -u$username -p$password $database > $backup_location/emoncms.sql
    if [ $? -ne 0 ]; then
        echo "Error: failed to export mysql data"
        echo "emoncms export failed"
        sudo systemctl start feedwriter > /dev/null
        exit 1
    fi
else
    echo "Error: Cannot read MYSQL authentication details from Emoncms settings.php"
    sudo systemctl start feedwriter > /dev/null
    exit 1
fi

if [ -f $backup_location/emoncms.sql ]
then
  echo "-- adding $backup_location/emoncms.sql to archive --"
  tar -c --file=$backup_location/emoncms-backup-$date.tar $backup_location/emoncms.sql --transform 's?.*/??g' 2>&1
else
    echo "no file $backup_location/emoncms.sql"
fi

if [ -f $emonhub_config_path/emonhub.conf ]
then
  echo "-- adding $emonhub_config_path/emonhub.conf to archive --"
  tar -vr --file=$backup_location/emoncms-backup-$date.tar $emonhub_config_path/emonhub.conf --transform 's?.*/??g' 2>&1
else
    echo "no file $emonhub_config_path/emonhub.conf"
fi

if [ -f $emoncms_location/settings.ini ]
then
  echo "-- adding $emoncms_location/settings.ini to archive --"
  tar -vr --file=$backup_location/emoncms-backup-$date.tar $emoncms_location/settings.ini --transform 's?.*/??g' 2>&1
else
    echo "no file $emoncms_location/settings.ini"
fi

if [ -f $emoncms_location/settings.php ]
then
  echo "-- adding $emoncms_location/settings.php to archive --"
  tar -vr --file=$backup_location/emoncms-backup-$date.tar $emoncms_location/settings.php --transform 's?.*/??g' 2>&1
else
    echo "no file $emoncms_location/settings.php"
fi

# Append database folder to the archive with absolute path
if [ -d $database_path/phpfina ]
then
  echo "-- adding $database_path/phpfina to archive --"
  tar -vr --file=$backup_location/emoncms-backup-$date.tar -C $database_path phpfina 2>&1
  if [ $? -ne 0 ]; then
    echo "Error: failed to tar phpfina"
  fi
else
    echo "no phpfina directory"
fi

if [ -d $database_path/phpfiwa ]
then
  echo "-- adding $database_path/phpfiwa to archive --"
  tar -vr --file=$backup_location/emoncms-backup-$date.tar -C $database_path phpfiwa 2>&1
  if [ $? -ne 0 ]; then
    echo "Error: failed to tar phpfiwa"
  fi
else
    echo "no phpfiwa directory"
fi

if [ -d $database_path/phptimeseries ]
then
  echo "-- adding $database_path/phptimeseries to archive --"
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
    sudo systemctl start feedwriter > /dev/null
    exit 1
fi

sudo systemctl start feedwriter > /dev/null

echo "Backup saved: $backup_location/emoncms-backup-$date.tar.gz"
date
echo "Export finished...refresh page to view download link"
echo "=== Emoncms export complete! ===" # This string is identified in the interface to stop ongoing AJAX calls, please ammend in interface if changed here
