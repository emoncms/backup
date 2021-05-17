#!/bin/bash
backup_module_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd $backup_module_dir
openenergymonitor_dir=$1

# Try default openenergymonitor directory if not specified
if [ ! $openenergymonitor_dir ]; then
    if [ ! -d /opt/openenergymonitor ]; then
        echo "- Missing openenergymonitor directory parameter and default: /opt/openenergymonitor not found"
        exit 0
    else
        # If directory exists: use default
        openenergymonitor_dir=/opt/openenergymonitor
    fi
fi

# Load EmonScripts installation config.ini
if [ -f $openenergymonitor_dir/EmonScripts/install/config.ini ]; then
    cd $openenergymonitor_dir/EmonScripts/install
    source load_config.sh
    cd $backup_module_dir
    emonhub_directory=$openenergymonitor_dir/emonhub
else
    echo "- EmonScripts config.ini not found, starting manual process"
    read -p "- Please enter system user (e.g pi): " user
    echo "  $user"
    read -p "- Please enter emoncms directory (e.g /var/www/emoncms): " emoncms_www
    if [ -d $emoncms_www ]; then echo "  $emoncms_www valid"; else echo "  $emoncms_www invalid"; exit 0; fi
    read -p "- Please enter emoncms data directory (e.g /var/opt/emoncms): " emoncms_datadir
    if [ -d $emoncms_datadir ]; then echo "  $emoncms_datadir valid"; else echo "  $emoncms_datadir invalid"; exit 0; fi
    read -p "- Please enter emonhub directory (e.g /opt/openenergymonitor/emonhub): " emonhub_directory
    if [ -d $emonhub_directory ]; then echo "  $emonhub_directory valid"; else echo "  $emonhub_directory invalid"; exit 0; fi
fi

# Creating backup module config.cfg file
echo "- copying default.config.cfg to config.cfg"
cp default.config.cfg config.cfg
echo "- setting config.cfg settings"
sed -i "s~USER~$user~" config.cfg
sed -i "s~BACKUP_SCRIPT_LOCATION~$backup_module_dir~" config.cfg
sed -i "s~EMONCMS_LOCATION~$emoncms_www~" config.cfg
sed -i "s~BACKUP_LOCATION~$emoncms_datadir/backup~" config.cfg
sed -i "s~DATABASE_PATH~$emoncms_datadir~" config.cfg
sed -i "s~EMONHUB_CONFIG_PATH~/etc/emonhub~" config.cfg
sed -i "s~EMONHUB_SPECIMEN_CONFIG~$emonhub_directory/conf~" config.cfg
sed -i "s~BACKUP_SOURCE_PATH~$emoncms_datadir/backup/uploads~" config.cfg
source config.cfg

# Load backup module configuration file
upload_location=$backup_location/uploads

# Symlink emoncms UI (if not done so already)
if [ ! -L $emoncms_www/Modules/backup ]; then
    echo "- symlinking backup module"
    ln -s $backup_module_dir/backup-module $emoncms_www/Modules/backup
fi

# php_ini=/etc/php5/apache2/php.ini
PHP_VER=$(php -v | head -n 1 | cut -d " " -f 2 | cut -f1-2 -d"." )
php_ini=/etc/php/$PHP_VER/apache2/php.ini
# echo "- PHP Version: $PHP_VER"

echo "- creating /etc/php/$PHP_VER/mods-available/emoncmsbackup.ini"
cat << EOF |
post_max_size = 3G
upload_max_filesize = 3G
upload_tmp_dir = ${upload_location}
EOF
sudo tee /etc/php/$PHP_VER/mods-available/emoncmsbackup.ini

echo "- phpenmod emoncmsbackup"
sudo phpenmod emoncmsbackup

# Create uploads folder
if [ ! -d $backup_location ]; then
    echo "- creating $backup_location directory"
    sudo mkdir $backup_location
    sudo chown $user:$user $backup_location -R
fi

if [ ! -d $backup_location/uploads ]; then
    echo "- creating $backup_location/uploads directory"
    sudo mkdir $backup_location/uploads
    sudo chown www-data:$user $backup_location/uploads -R
fi

echo "- restarting apache"
sudo service apache2 restart
