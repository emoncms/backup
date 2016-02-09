#!/bin/bash
data_path="/home/pi/data"

date=$(date +"%Y-%m-%d")

echo "=== Emoncms export start ==="
date
echo "backup from $data_path"


#-----------------------------------------------------------------------------------------------
# Check emonPi / emonBase image version
#-----------------------------------------------------------------------------------------------
image_version=$(ls /boot | grep emonSD)
# Check first 16 characters of filename
image_date=${image_version:0:16}

if [[ "${image_version:0:6}" == "emonSD" ]]
then
    echo "Image version: $image_version"
else
    echo "Non OpenEnergyMonitor offical emonSD image, no gurantees this script will work :-/"
    read -p "Press any key to continue...or CTRL+C to exit " -n1 -s
fi

if [[ "$image_date" == "emonSD-17Jun2015" ]]
then
  image="old"
  echo "$image image"
else
  image="new"
  echo "$image image"
fi
#-----------------------------------------------------------------------------------------------

cd $data_path

sudo service feedwriter stop

# MYSQL Dump Emoncms database
auth=$(php get_emoncms_mysql_auth.php)
IFS=":" read username password <<< "$auth"
mysqldump -u $username -p$password emoncms > $data_path/emoncms.sql

# Compress backup with database and config files
tar -cvzf emoncms-backup-$date.tar.gz emoncms.sql phpfina phptimeseries emonhub.conf emoncms.conf

sudo service feedwriter start

echo "backup saved $data_path/emoncms-backup-$date.tar.gz"
date
echo "done..refresh page to view download link"
echo "=== Emoncms export complete! ===" # This string is identified in the interface to stop ongoing AJAX calls, please ammend in interface if changed here
