#!/bin/bash

script_location="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
config_location=${script_location}/config.cfg

echo "=== USB Emoncms import start ==="
date +"%Y-%m-%d-%T"
echo "Backup module version:"
grep version ${script_location}/module.json
echo "EUID: $EUID"
echo "Reading ${config_location}...."
if [ -f "${config_location}" ]
then
    source "${config_location}"
    echo "Location of data databases: $database_path"
    echo "Location of emonhub.conf: $emonhub_config_path"
    echo "Location of Emoncms: $emoncms_location"
else
    echo "ERROR: Backup ${config_location} file does not exist"
    exit 1
fi

emonhub=$(systemctl show emonhub | grep LoadState | cut -d"=" -f2)
feedwriter=$(systemctl show feedwriter | grep LoadState | cut -d"=" -f2)
emoncms_mqtt=$(systemctl show emoncms_mqtt | grep LoadState | cut -d"=" -f2)

echo

# ---------------------------------------------------
# Create mount points
# ---------------------------------------------------
if [ ! -d /media/old_sd_boot ]; then
    echo "creating mount point /media/old_sd_boot"
    sudo mkdir /media/old_sd_boot
fi

if [ ! -d /media/old_sd_root ]; then
    echo "creating mount point /media/old_sd_root"
    sudo mkdir /media/old_sd_root
fi

if [ ! -d /media/old_sd_data ]; then
    echo "creating mount point /media/old_sd_data"
    sudo mkdir /media/old_sd_data
fi

disk=false

echo "Scanning for USB card reader:"
for diskname in 'sda' 'sdb' 'sdc'
  do
  if [ $disk == false ]; then
    disk_id=$(find /dev/disk/by-id/ -lname "*$diskname")
    if [ $disk_id ]; then
        mount_check=$(mount | grep /dev/$diskname)
        if [ "$mount_check" == "" ]; then
            echo "- Unmounted disk: $disk_id at /dev/$diskname"
            
            partprobe=$(sudo partprobe -d -s /dev/$diskname)
            if [ "$partprobe" == "/dev/$diskname: msdos partitions 1 2 3" ]; then
                echo "-- Unmounted disk has correct number of partitions"
                          
                echo "-- Mounting old SD card boot partition"
                sudo mount -r /dev/$diskname'1' /media/old_sd_boot
                echo "-- Mounting old SD card root partition"
                sudo mount -r /dev/$diskname'2' /media/old_sd_root
                echo "-- Mounting old SD card data partition"
                sudo mount -r /dev/$diskname'3' /media/old_sd_data
                
                valid_disk=true
                
                # Check for image verion file
                image_version=$(ls /media/old_sd_boot/emonSD*  | cut -d"/" -f4)
                if [ "$image_version" ]; then
                    echo "-- image version: $image_version"
                else
                    echo "-- Error: Image version file not present"
                    valid_disk=false
                fi
                
                # Check for emoncms database location
                if sudo test -d "/media/old_sd_data/mysql/emoncms"; then
                    echo "-- Emoncms mysql database found (old location)"
                # New structure
                elif sudo test -d "/media/old_sd_root/var/lib/mysql/emoncms"; then
                    echo "-- Emoncms mysql database found (new location)"
                else
                    echo "-- Error: Could not find mysql database"
                    valid_disk=false
                fi 
                
                # PHPFina check
                if sudo test -d "/media/old_sd_data/phpfina"; then
                    echo "-- Emoncms phptimeseries data directory found"
                else
                    echo "-- Error: Emoncms phpfina data directory not found"
                    valid_disk=false
                fi
                
                # PHPTimeseries check
                if sudo test -d "/media/old_sd_data/phptimeseries"; then
                    echo "-- Emoncms phptimeseries data directory found"
                else
                    echo "-- Error: Emoncms phptimeseries data directory not found"
                    valid_disk=false
                fi
                
                if [ $valid_disk != false ]; then
                    echo "-- Disk appears to be valid, continuing with import"
                    disk="$diskname"
                else 
                    echo "-- Invalid disk"
                    sudo umount /dev/$diskname'1'
                    sudo umount /dev/$diskname'2'
                    sudo umount /dev/$diskname'3'
                fi 
                
            else
                echo "- Error: Unmounted disk has incorrect number of partitions"
            fi 
        else
            echo "- Mounted disk: $disk_id at /dev/$diskname"
        fi
    else
        echo "- No card reader found on $diskname"
    fi
  fi
done

if [ $disk == false ]; then
    echo "USB drive not found"
    exit 1
fi

echo

# ---------------------------------------------------
# Stopping services
# ---------------------------------------------------
echo "Stopping services.."
if [[ $emonhub == "loaded" ]]; then
    sudo systemctl stop emonhub
fi
if [[ $feedwriter == "loaded" ]]; then
    sudo systemctl stop feedwriter
fi
if [[ $emoncms_mqtt == "loaded" ]]; then
    sudo systemctl stop emoncms_mqtt
fi

# ---------------------------------------------------------------
# Mysql import (direct file copy method as we cant run mysqldump)
# --------------------------------------------------------------- 
echo "Read MYSQL authentication details from settings.php"
if [ -f $script_location/get_emoncms_mysql_auth.php ]; then
    auth=$(echo $emoncms_location | php $script_location/get_emoncms_mysql_auth.php php)
    IFS=":" read username password database <<< "$auth"
else
    echo "Error: cannot read MYSQL authentication details from Emoncms settings.php"
    echo "$PWD"
    exit 1
fi

echo "stopping mysql"
sudo systemctl stop mariadb 
   
if [ -d /var/lib/mysql/emoncms ]; then
    # Old structure
    if sudo test -d "/media/old_sd_data/mysql/emoncms"; then
        echo "Copying over mysql database from SD card (old structure)"
        sudo rm -rf /var/lib/mysql/emoncms
        sudo cp -rv /media/old_sd_data/mysql/emoncms /var/lib/mysql/emoncms
    # New structure
    elif sudo test -d "/media/old_sd_root/var/lib/mysql/emoncms"; then
        echo "Copying over mysql database from SD card (new structure)"
        sudo rm -rf /var/lib/mysql/emoncms
        sudo cp -rv /media/old_sd_root/var/lib/mysql/emoncms /var/lib/mysql/emoncms
    else
        echo "could not find mysql database"
        exit 1
    fi
fi
    
echo "Setting database ownership"
sudo chown mysql:mysql /var/lib/mysql/emoncms
sudo chown -R mysql:mysql /var/lib/mysql/emoncms

echo "starting mysql"
sudo systemctl start mariadb    

echo "checking database"
mysqlcheck -A --auto-repair -u$username -p$password

if [ -f /opt/openenergymonitor/EmonScripts/common/emoncmsdbupdate.php ]; then
    echo "Updating Emoncms Database.."
    php /opt/openenergymonitor/EmonScripts/common/emoncmsdbupdate.php
fi

# ---------------------------------------------------------------
# Copy over phpfina files
# --------------------------------------------------------------- 
echo "Archive old data folders"
sudo mv $database_path/phpfina $database_path/phpfina_old
sudo mv $database_path/phptimeseries $database_path/phptimeseries_old

echo "Copying PHPFina feed data"
if sudo test -d "/media/old_sd_data/phpfina"; then
    sudo cp -rfv /media/old_sd_data/phpfina $database_path/phpfina
    sudo chown -R www-data:root $database_path/phpfina
fi

echo "Copying PHPTimeSeries feed data"
if sudo test -d "/media/old_sd_data/phptimeseries"; then
    sudo cp -rfv /media/old_sd_data/phptimeseries $database_path/phptimeseries
    sudo chown -R www-data:root $database_path/phptimeseries
fi
# ---------------------------------------------------------------
# Copy emonhub conf
# ---------------------------------------------------------------
# New structure
if [ -f /media/old_sd_root/etc/emonhub/emonhub.conf ]; then
    sudo cp -fv /media/old_sd_root/etc/emonhub/emonhub.conf $emonhub_config_path/emonhub.conf
fi
# Old structure
if [ -f /media/old_sd_data/emonhub.conf ]; then
    sudo cp -fv /media/old_sd_data/emonhub.conf $emonhub_config_path/emonhub.conf
fi
# ---------------------------------------------------------------
# Clear redis and restart services
# --------------------------------------------------------------- 
echo "Flushing redis"
redis-cli "flushall" 2>&1

# Restart services
if [[ $emonhub == "loaded" ]]; then
    echo "Restarting emonhub..."
    sudo systemctl start emonhub
fi
if [[ $feedwriter == "loaded" ]]; then
    echo "Restarting feedwriter..."
    sudo systemctl start feedwriter
fi
if [[ $emoncms_mqtt == "loaded" ]]; then
    echo "Restarting emoncms MQTT..."
    sudo systemctl start emoncms_mqtt
fi

# ---------------------------------------------------
# Unmount partitions
# ---------------------------------------------------
sudo umount /dev/$disk'1'
sudo umount /dev/$disk'2'
sudo umount /dev/$disk'3'

date +"%Y-%m-%d-%T"
# This string is identified in the interface to stop ongoing AJAX calls in logger window, please ammend in interface if changed here
echo "=== Emoncms import complete! ==="
sudo service apache2 restart
