#!/bin/bash
data_path="/home/pi/data"

date=$(date +"%Y-%m-%d")

echo "Emoncms export...from $data_path"
echo $date

#-----------------------------------------------------------------------------------------------
# Check emonPi / emonBase image version
#-----------------------------------------------------------------------------------------------
image_version=$(ls /boot | grep emonSD)
# Check first 16 characters of filename
image_date=${image_version:0:16}
if [[ "$image_date" == "emonSD-17Jun2015" ]]
then
  image="old"
  echo "$image image"
else
  image="new"
  echo "$image image"
fi

if [[ "${image_version:0:6}" == "emonSD" ]]
then
    echo "Image version: $image_version"
else
    echo "Non OpenEnergyMonitor offical emonSD image, no gurantees this script will work :-/"
    read -p "Press any key to continue...or CTRL+C to exit " -n1 -s
fi
#-----------------------------------------------------------------------------------------------

cd $data_path

sudo service feedwriter stop

# MYSQL Dump Emoncms database
auth=$(php get_emoncms_mysql_auth.php)
IFS=":" read username password <<< "$auth"
mysqldump -u $username -p$password emoncms > $data_path/emoncms.sql

# Compress backup with database and config files
tar -cvzf backup-$date.tar.gz emoncms.sql phpfina phptimeseries emonhub.conf emoncms.conf

sudo service feedwriter start

echo "backup saved $data_path/backup-$date.tar.gz"
echo "done"
date
