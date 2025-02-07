#!/bin/bash

# Set the shell to trigger errors when commands within a pipe have a non-zero return code
set -o pipefail

# The errors variable is set when error_handler() is called, the variable is used by the finish() function for success or failure messages
errors=false

# This error handler function display information of what happened and where, but does NOT stop the script execution
error_handler() {
    echo "Error: RC=$1 occurred on line $2"
    errors=true
}

# Set trap for ERR to pass the return code and line number to error_handler()
trap 'error_handler $? $LINENO' ERR

# Exit handler used to ensure the exit message AJAX expects is found, whilst summarising if errors were found
# This also picks up the natural exit when reaching end of script

function finish() {
    if [[ "${errors}" == "false" && $? == 0 ]]; then
        echo "=== Emoncms export complete! ==="
# The strings output are identified in the interface to stop ongoing AJAX calls, please ammend in interface if changed here
    else
        echo "=== Emoncms export completed with ERRORS! ==="
# The strings output are identified in the interface to stop ongoing AJAX calls, please ammend in interface if changed here
    fi
}

# Set trap for whenever EXIT is called to call finish()
trap finish EXIT

declare -a included not_found
script_location="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
config_location=${script_location}/config.cfg

echo "=== Emoncms export start ==="
date
echo "Backup module version:"
grep version "${script_location}/module.json"
echo "EUID: $EUID"
echo "Reading ${config_location}...."

if [ ! -f "${config_location}" ]
then
    echo "ERROR: Backup config file ${config_location} does not exist"
    exit 1
fi

source "${config_location}"
echo "Location of databases: $database_path"
echo "Location of emonhub.conf: $emonhub_config_path"
echo "Location of Emoncms: $emoncms_location"
echo "Backup destination: $backup_location"

tar_filename="${backup_location}/emoncms-backup-$(hostname)-$(date +"%Y-%m-%d").tar"

module_location="${emoncms_location}/Modules/backup"
echo "emoncms backup module location $module_location"

#-----------------------------------------------------------------------------------------------
# Remove Old backup files
#-----------------------------------------------------------------------------------------------
for file in "${backup_location}/emoncms.sql" "${tar_filename}"
do
    if [ -f "${file}" ]
    then
        if [ -f "/.dockerenv" ]; then
            rm "${file}"
        else
            sudo rm "${file}"
        fi
    fi
done

#-----------------------------------------------------------------------------------------------
# Check emonPi / emonBase image version
#-----------------------------------------------------------------------------------------------
image_version=$(cd /boot && echo *emonSD* )
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
if [ ! -f "/.dockerenv" ]; then
    sudo systemctl stop feedwriter
fi

# Get MYSQL authentication details from settings.php
if [ -f "${script_location}/get_emoncms_mysql_auth.php" ]; then
    auth=$(echo "${emoncms_location}" | php "${script_location}/get_emoncms_mysql_auth.php" php)
    IFS=":" read username password database <<< "$auth"
else
    echo "Error: cannot read MYSQL authentication details from Emoncms $script_location/get_emoncms_mysql_auth.php php & settings.php"
    echo "$PWD"
    if [ ! -f "/.dockerenv" ]; then
        sudo systemctl start feedwriter > /dev/null
    fi
    exit 1
fi

# MYSQL Dump Emoncms database
if [ -n "$username" ]; then # if username string is not empty
    mysqldump -u"${username}" -p"${password}" "${database}" > "${backup_location}/emoncms.sql"
    if [ $? -ne 0 ]; then
        echo "Error: failed to export mysql data"
        echo "emoncms export failed"
        if [ ! -f "/.dockerenv" ]; then
            sudo systemctl start feedwriter > /dev/null
        fi
        exit 1
    fi
else
    echo "Error: Cannot read MYSQL authentication details from Emoncms settings.php"
    if [ ! -f "/.dockerenv" ]; then
        sudo systemctl start feedwriter > /dev/null
    fi
    exit 1
fi

# 
for file in "${backup_location}/emoncms.sql" "${emonhub_config_path}/emonhub.conf" "${emoncms_location}/settings.ini" "${emoncms_location}/settings.php"
do
    if [ -f "${file}" ]
    then
        echo "-- adding ${file} to archive --"
        tar -vr --file="${tar_filename}" "${file}" --transform 's?.*/??g' 2>&1
        included+=("${file}")
    else
        echo "no ${file} to backup"
        not_found+=("${file}")
    fi
done

# Append database folder to the archive with absolute path
for dir in phpfina phpfiwa phptimeseries
do
    if [ -d "${database_path}/${dir}" ]
    then
        echo "-- adding ${database_path}/${dir} to archive --"
        tar -vr --file="${tar_filename}" -C "${database_path}" "${dir}" 2>&1
        if [ $? -ne 0 ]; then
            echo "Error: failed to tar ${dir}"
        fi
        included+=("${dir}")
    else
        echo "no ${database_path}/${dir} directory to backup"
        not_found+=("${dir}")
    fi
done

if [ ! -f "/.dockerenv" ]; then
    sudo systemctl start feedwriter > /dev/null
fi

# Compress backup
echo "Compressing archive..."
gzip -fv "${tar_filename}" 2>&1
if [ $? -ne 0 ]; then
    echo "Error: failed to compress tar file"
    echo "emoncms export failed"
    exit 1
fi

echo "Backup saved: ${tar_filename}.gz"
date
echo -e "\nBackup included components: ${included[*]}"
echo -e "INFO: These components couldn't be found to backup: ${not_found[*]}\n"

echo "Export finished...refresh page to view download link"

# The exit trap will pickup the natural exit and display the string to stop ongoing AJAX calls
