#!/bin/bash

script_location="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

echo "=== USB Emoncms import start ==="
date +"%Y-%m-%d-%T"
echo "Backup module version:"
cat $script_location/backup-module/module.json | grep version
echo "EUID: $EUID"
echo "Reading $script_location/config.cfg...."
if [ -f "$script_location/config.cfg" ]
then
    source "$script_location/config.cfg"
    echo "Location of data databases: $database_path"
    echo "Location of emonhub.conf: $emonhub_config_path"
    echo "Location of Emoncms: $emoncms_location"
    echo "Backup destination: $backup_location"
    echo "Backup source path: $backup_source_path"
else
    echo "ERROR: Backup $script_location/backup/config.cfg file does not exist"
    exit 1
fi

emonhub=$(systemctl show emonhub | grep LoadState | cut -d"=" -f2)
feedwriter=$(systemctl show feedwriter | grep LoadState | cut -d"=" -f2)
emoncms_mqtt=$(systemctl show emoncms_mqtt | grep LoadState | cut -d"=" -f2)

echo

disk=$(find /dev/disk/by-id/ -lname '*sda')

if [ $disk ]; then
    echo "Found: $disk"

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
    
    # ---------------------------------------------------
    # Mount partitions
    # ---------------------------------------------------
    echo "Mounting old SD card boot partition"
    sudo mount -r /dev/sda1 /media/old_sd_boot
    echo "Mounting old SD card root partition"
    sudo mount -r /dev/sda2 /media/old_sd_root
    echo "Mounting old SD card data partition"
    sudo mount -r /dev/sda3 /media/old_sd_data

    echo

    # ---------------------------------------------------
    # Stopping services
    # ---------------------------------------------------
    echo "Stopping services.."
    if [[ $emonhub == "loaded" ]]; then
        sudo service emonhub stop
    fi
    if [[ $feedwriter == "loaded" ]]; then
        sudo service feedwriter stop
    fi
    if [[ $emoncms_mqtt == "loaded" ]]; then
        sudo service emoncms_mqtt stop
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
        echo "Manually deleting old mysql emoncms database"
        sudo rm -rf /var/lib/mysql/emoncms
    fi
    
    echo "Manual install of emoncms database"
    sudo cp -r /media/old_sd_root/var/lib/mysql/emoncms /var/lib/mysql/emoncms
    
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
    echo "Clearning data folders"
    sudo rm -rf $database_path/{phpfina,phptimeseries} 2> /dev/null
    
    echo "Copying PHPFina feed data"
    sudo cp -rfv /media/old_sd_data/phpfina $database_path/phpfina
    sudo chown -R www-data:root $database_path/phpfina
    
    echo "Copying PHPTimeSeries feed data"
    sudo cp -rfv /media/old_sd_data/phptimeseries $database_path/phptimeseries
    sudo chown -R www-data:root $database_path/phptimeseries

    # ---------------------------------------------------------------
    # Copy emonhub conf
    # --------------------------------------------------------------- 
    sudo cp -fv /media/old_sd_root/etc/emonhub/emonhub.conf /etc/emonhub/emonhub.conf
    
    # ---------------------------------------------------------------
    # Clear redis and restart services
    # --------------------------------------------------------------- 
    echo "Flushing redis"
    redis-cli "flushall" 2>&1
    
    # Restart services
    if [[ $emonhub == "loaded" ]]; then
        echo "Restarting emonhub..."
        sudo service emonhub start
    fi
    if [[ $feedwriter == "loaded" ]]; then
        echo "Restarting feedwriter..."
        sudo service feedwriter start
    fi
    if [[ $emoncms_mqtt == "loaded" ]]; then
        echo "Restarting emoncms MQTT..."
        sudo service emoncms_mqtt start
    fi

    # ---------------------------------------------------
    # Unmount partitions
    # ---------------------------------------------------
    sudo umount /dev/sda1
    sudo umount /dev/sda2
    sudo umount /dev/sda3
    
    date +"%Y-%m-%d-%T"
    # This string is identified in the interface to stop ongoing AJAX calls in logger window, please ammend in interface if changed here
    echo "=== Emoncms import complete! ==="
    sudo service apache2 restart
fi

