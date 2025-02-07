#!/bin/bash

script_location="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
config_location=${script_location}/config.cfg

echo "=== Emoncms import start ==="
date +"%Y-%m-%d-%T"
echo "Backup module version:"
grep version "${script_location}/module.json"
echo "EUID: $EUID"
echo "Reading ${config_location}...."
if [ -f "${config_location}" ]
then
    source "${config_location}"
    echo "Location of data databases: $database_path"
    echo "Location of emonhub.conf: $emonhub_config_path"
    echo "Location of Emoncms: $emoncms_location"
    echo "Backup destination: $backup_location"
    echo "Backup source path: $backup_source_path"
else
    echo "ERROR: Backup config file ${config_location} does not exist"
    exit 1
fi

echo "Starting import from $backup_source_path to $backup_location..."

if [ ! -f "/.dockerenv" ]; then
    emonhub=$(systemctl show emonhub | grep LoadState | cut -d"=" -f2)
    feedwriter=$(systemctl show feedwriter | grep LoadState | cut -d"=" -f2)
    mqtt_input=$(systemctl show mqtt_input | grep LoadState | cut -d"=" -f2)
    emoncms_mqtt=$(systemctl show emoncms_mqtt | grep LoadState | cut -d"=" -f2)
fi

#-----------------------------------------------------------------------------------------------
# Check emonPi / emonBase image version
#-----------------------------------------------------------------------------------------------
if [ -f "/.dockerenv" ]; then
    image_version="container"
else
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
fi
#-----------------------------------------------------------------------------------------------


# Get latest backup filename
if [ ! -d "${backup_source_path}" ]; then
    echo "Error: ${backup_source_path} does not exist, nothing to import"
    exit 1
fi

backup_filename=$(ls -t "${backup_source_path}"/*.tar.gz | head -1)
if [[ -z "${backup_filename}" ]] #if backup does not exist (empty filename string)
then
    echo "Error: cannot find backup, stopping import"
    exit 1
fi

# if backup exists
echo "Backup found: ${backup_filename} starting import.."

echo "Read MYSQL authentication details from settings.php"
if [ -f "${script_location}/get_emoncms_mysql_auth.php" ]; then
    auth=$(echo "${emoncms_location}" | php "${script_location}/get_emoncms_mysql_auth.php" php)
    IFS=":" read username password database <<< "$auth"
else
    echo "Error: cannot read MYSQL authentication details from Emoncms settings.php"
    echo "$PWD"
    exit 1
fi


echo "Decompressing backup.."
import_location="${backup_location}/import"
if [ -d "${import_location}" ]; then
    if [ -f "/.dockerenv" ]; then
        rm -rf "${import_location}"
    else
        sudo rm -rf "${import_location}"
    fi
    # Belt and braces cleanup in case any '.' prefixed files exist
fi

mkdir "${import_location}"
if [ ! -f "/.dockerenv" ]; then
    sudo chown "${user}" "${import_location}"
fi

tar xfzv "${backup_filename}" -C "${import_location}" 2>&1
if [ $? -ne 0 ]; then
	echo "Error: failed to decompress backup"
	echo "${backup_filename} has not been removed for diagnotics"
	echo "Removing files in ${import_location}"
    if [ -f "/.dockerenv" ]; then
        rm -Rf "${import_location}/*"
    else
        sudo rm -Rf "${import_location}/*"
    fi
    echo "Import failed"
    exit 1
fi

echo "Removing compressed backup to save disk space.."
if [ -f "/.dockerenv" ]; then
    rm "${backup_filename}"
else
    sudo rm "${backup_filename}"
fi

if [ -n "$password" ]
then # if username sring is not empty
    if [ -f "${import_location}/emoncms.sql" ]; then
        if [ ! -f "/.dockerenv" ]; then
            echo "Stopping services.."
            if [[ $emonhub == "loaded" ]]; then
                sudo systemctl stop emonhub
            fi
            if [[ $feedwriter == "loaded" ]]; then
                sudo systemctl stop feedwriter
            fi
            if [[ $mqtt_input == "loaded" ]]; then
                sudo systemctl stop mqtt_input
            fi
            if [[ $emoncms_mqtt == "loaded" ]]; then
                sudo systemctl stop emoncms_mqtt
            fi
        fi
        echo "Emoncms MYSQL database import..."
        mysql -u"${username}" -p"${password}" "${database}" < "${import_location}/emoncms.sql"
    if [ $? -ne 0 ]; then
        echo "Error: failed to import mysql data"
        echo "Import failed"
        exit 1
    fi
    else
        "Error: cannot find emoncms.sql database to import"
        exit 1
    fi
else
    echo "Error: cannot read MYSQL authentication details from Emoncms settings.php"
    exit 1
fi

echo "Import feed meta data.."
if [ -f "/.dockerenv" ]; then
    rm -rf "${database_path}"/{phpfina,phptimeseries} 2> /dev/null
else
    sudo rm -rf "${database_path}"/{phpfina,phptimeseries} 2> /dev/null
fi

echo "Restore phpfina and phptimeseries data folders..."
if [ -d "${import_location}/phpfina" ]; then
    if [ -f "/.dockerenv" ]; then
        mv "${import_location}/phpfina" "${database_path}"
    else
        sudo mv "${import_location}/phpfina" "${database_path}"
        sudo chown -R www-data:root "${database_path}/phpfina"
    fi
fi

if [ -d "${import_location}/phptimeseries" ]; then
    if [ -f "/.dockerenv" ]; then
        mv "${import_location}/phptimeseries" "${database_path}"
    else
        sudo mv "${import_location}/phptimeseries" "${database_path}"
        sudo chown -R www-data:root "${database_path}/phptimeseries"
    fi
fi

# cleanup
if [ -f "/.dockerenv" ]; then
    rm "${import_location}/emoncms.sql"
else
    sudo rm "${import_location}/emoncms.sql"
fi

# Save previous config settings as old.emonhub.conf
if [ -f "${import_location}/emonhub.conf" ]; then
    if [ -d "${emonhub_config_path}" ]; then
        echo "Import emonhub.conf > ${emonhub_config_path}/emohub.conf"
        if [ -f "/.dockerenv" ]; then
            mv "${import_location}/emonhub.conf" "${emonhub_config_path}/emonhub.conf"
            chmod 666 "${emonhub_config_path}/emonhub.conf"
        else
            sudo mv "${import_location}/emonhub.conf" "${emonhub_config_path}/emonhub.conf"
            sudo chmod 666 "${emonhub_config_path}/emonhub.conf"
        fi
    else
        echo "WARNING: emonhub.conf found in backup, but no emonHub directory (${emonhub_config_path}) found"
    fi
fi
 
# Start with blank emonhub.conf
# if [[ $image == "old" ]]
# then    # Legacy image use emonhub.conf without MQTT authenitication
#    echo "Start with fresh config: copy LEGACY default.emonhub.conf:"
#    echo "cp $emonhub_specimen_config/old.default.emonhub.conf $emonhub_config_path/emonhub.conf"
#    cp $emonhub_specimen_config/old.default.emonhub.conf $emonhub_config_path/emonhub.conf
# else    # Newer Feb15+ image use latest emonhub.conf with MQTT node variable topic structure and MQTT authentication enabled
#    echo "Start with fresh config: copy NEW default emonpi.emonhub.conf:"
#    echo "cp $emonhub_specimen_config/emonpi.default.emonhub.conf $emonhub_config_path/emonhub.conf"
#    cp $emonhub_specimen_config/emonpi.default.emonhub.conf $emonhub_config_path/emonhub.conf
# fi

redis-cli "flushall" 2>&1

if [ -f /opt/openenergymonitor/EmonScripts/common/emoncmsdbupdate.php ]; then
    echo "Updating Emoncms Database.."
    php /opt/openenergymonitor/EmonScripts/common/emoncmsdbupdate.php
fi

# Restart services
if [ ! -f "/.dockerenv" ]; then
    if [[ $emonhub == "loaded" ]]; then
        echo "Restarting emonhub..."
        sudo systemctl start emonhub
    fi
    if [[ $feedwriter == "loaded" ]]; then
        echo "Restarting feedwriter..."
        sudo systemctl start feedwriter
    fi
    if [[ $mqtt_input == "loaded" ]]; then
        echo "Restarting mqtt_input..."
        sudo systemctl start mqtt_input
    fi
    if [[ $emoncms_mqtt == "loaded" ]]; then
        echo "Restarting emoncms_mqtt..."
        sudo systemctl start emoncms_mqtt
    fi
fi

date +"%Y-%m-%d-%T"
# This string is identified in the interface to stop ongoing AJAX calls in logger window, please ammend in interface if changed here
echo "=== Emoncms import complete! ==="
if [ ! -f "/.dockerenv" ]; then
    sudo systemctl restart apache2
fi
