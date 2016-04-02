    #!/bin/bash
backup_source_path="/home/pi/data/uploads"
data_path="/home/pi/data"

echo "=== Emoncms import start ==="

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
    echo "Backup source path: $backup_source_path"
else
    echo "ERROR: Backup ~/backup/config.cfg file does not exist"
    exit 1
fi

echo "Starting import from $backup_source_path to $backup_location..."


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

if [[ "$image_date" == "emonSD-17Jun2015" ]]
then
  image="old"
  echo "$image image"
else
  image="new"
  echo "$image image"
fi
#-----------------------------------------------------------------------------------------------


# Get latest backup filename
backup_filename=$((cd $backup_source_path && ls -t *tar.gz) | head -1)
if [[ -z "$backup_filename" ]] #if backup does not exist (empty filename string)
then
    echo "Error: cannot find backup..stopping import"
    exit 1
fi
# if backup exists
echo "Backup found: $backup_filename starting import.."


sudo service emonhub stop
sudo service feedwriter stop
if [ -f "/etc/init.d/emoncms-nodes-service" ]; then
    sudo service emoncms-nodes-service stop
fi

# Uncompress backup
echo "Decompressing backup.."
mkdir $backup_location/import
tar xfz $backup_source_path/$backup_filename -C $backup_location/import

echo "Removing compressed backup to save disk space.."
rm $backup_source_path/$backup_filename

echo "Wipe any current data from account.."
sudo rm -rf $mysql_path/{phpfina,phptimeseries}

echo "Restore phpfina and phptimeseries data folders..."
sudo mv $backup_location/import/phpfina $mysql_path
sudo mv $backup_location/import/phptimeseries $mysql_path
sudo chown www-data:root $mysql_path/{phpfina,phptimeseries}
sudo chown -R www-data:root $mysql_path/{phpfina,phptimeseries}


# Get MYSQL authentication details from settings.php
if [ -f ~/backup/get_emoncms_mysql_auth.php ]; then
    auth=$(echo $emoncms_location | php ~/backup/get_emoncms_mysql_auth.php php)
    IFS=":" read username password <<< "$auth"
else
    echo "Error: cannot read MYSQL authentication details from Emoncms settings.php"
    echo "$PWD"
    exit 1
fi

echo "Emoncms MYSQL database import..."
if [ -n "$password" ]
then # if username sring is not empty
    if [ -f $backup_location/import/emoncms.sql ]; then
        mysql -u$username -p$password emoncms < $backup_location/import/emoncms.sql
    else
        "Error: cannot find emoncms.sql database to import"
        exit 1
    fi
    
else
    echo "Error: cannot read MYSQL authentication details from Emoncms settings.php"
    exit 1
fi

# cleanup
sudo rm $backup_location/import/emoncms.sql

# Save previous config settings as old.emonhub.conf and old.emoncms.conf
echo "Import emonhub.conf > $emonhub_config_path/old.emohub.conf"
mv $backup_location/import/emonhub.conf $emonhub_config_path/old.emonhub.conf
echo "Import emoncms.conf > $emonhub_config_path/old.emoncms.conf"
mv $backup_location/import/emoncms.conf $emoncms_config_path/old.emoncms.conf


# Start with blank emonhub.conf
if [[ $image == "old" ]]
then    # Legacy image use emonhub.conf without MQTT authenitication
   echo "Start with fresh config: copy LEGACY default.emonhub.conf:"
   echo "cp $emonhub_specimen_config/old.default.emonhub.conf $emonhub_config_path/emonhub.conf"
   cp $emonhub_specimen_config/old.default.emonhub.conf $emonhub_config_path/emonhub.conf
else    # Newer Feb15+ image use latest emonhub.conf with MQTT node variable topic structure and MQTT authentication enabled
   echo "Start with fresh config: copy NEW default emonpi.emonhub.conf:"
   echo "cp $emonhub_specimen_config/emonpi.default.emonhub.conf $emonhub_config_path/emonhub.conf"
   cp $emonhub_specimen_config/emonpi.default.emonhub.conf $emonhub_config_path/emonhub.conf
fi

# Create blank emoncms.conf and ensure permissions are correct
sudo touch $emoncms_config_path/emoncms.conf
sudo chown pi:www-data $emoncms_config_path/emoncms.conf
sudo chmod 664 $emoncms_config_path/emoncms.conf

redis-cli "flushall" 2>&1

if [ -f /home/pi/emonpi/emoncmsdbupdate.php ]; then
    echo "Update Emoncms Database"
    php /home/pi/emonpi/emoncmsdbupdate.php
fi

echo "Restarting emonhub..."
sudo service emonhub start
echo "Restarting feedwriter..."
sudo service feedwriter start
if [ -f "/etc/init.d/emoncms-nodes-service" ]; then
    echo "Restarting emoncms-nodes-service..."
    sudo service emoncms-nodes-service start
fi

date
# This string is identified in the interface to stop ongoing AJAX calls in logger window, please ammend in interface if changed here
echo "=== Emoncms import complete! ==="
sudo service apache2 restart
