#!/bin/bash

backup_source_path="/home/pi/data/uploads"
data_path="/home/pi/data"

echo "Emoncms import...from $backup_source_path"
echo "...to $data_path"
date


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
    echo "Non OpenEnergyMonitor offical emonSD image, no gurantees this import will work :-/"
    read -p "Press any key to continue...or CTRL+C to exit " -n1 -s
fi
#-----------------------------------------------------------------------------------------------



# Get latest backup filename
backup_filename=$((cd $backup_source_path && ls -t *.gz) | grep emoncms-backup | head -1)
cd ~/
if [[ -z "$backup_filename" ]] #if backup does not exist (empty filename string)
then
    echo "backup does not exit..stoppping import"
    exit 1
else # if backup exists
  echo "backup found: $backup_filename starting import.."

  rpi-rw
  sudo service emonhub stop
  sudo service emoncms-nodes-service stop
  sudo service feedwriter stop

  # Uncompress backup
  tar xvfz $backup_source_path/$backup_filename -C /

  # Restore Emoncms MYSQL database
  if [[ $image == "old" ]]
  then
    mysql -u root -praspberry emoncms < $data_path/emoncms.sql
  else
    mysql -u emoncms -pemonpiemoncmsmysql2016 emoncms <$data_path/emoncms.sql
  fi

fi


# Restore settings saving as old.xxxxx
echo "backup settings emonhub.conf > $data_path/old.emohub.conf"
mv $data_path/emonhub.conf $data_path/old.emonhub.conf
mv $data_path/emoncms.conf $data_path/old.emoncms.conf


# Start with blank emonhub.conf
if [[ $image == "old" ]]
then    # Legacy image use emonhub.conf without MQTT authenitication
   echo "Start with fresh config: copy LEGACY default emonhub.conf"
   echo "/home/pi/emonhub/conf/old.default.emonhub.conf /home/pi/data/emonhub.conf"
   cp /home/pi/emonhub/conf/old.default.emonhub.conf $data_path/emonhub.conf
else    # Newer Feb15+ image use latest emonhub.conf with MQTT node variable topic structure and MQTT authentication enabled
   echo "Start with fresh config: copy NEW default emonpi emonhub.conf"
   echo "cp /home/pi/emonhub/conf/emonpi.default.emonhub.conf /home/pi/data/emonhub.conf"
   cp /home/pi/emonhub/conf/emonpi.default.emonhub.conf $data_path/emonhub.conf
fi

# Create blank emoncms.conf and ensure permissions are correct
sudo touch $data_path/emoncms.conf
sudo chown pi:www-data $data_path/emoncms.conf
sudo chmod 664 $data_path/emoncms.conf

redis-cli "flushall"

sudo service emonhub start
sudo service emoncms-nodes-service start
sudo service feedwriter start

echo "=== Emoncms import complete! ===" # This string is identified in the interface to stop ongoing AJAX calls, please ammend in interface if changed here
date
rpi-rw
