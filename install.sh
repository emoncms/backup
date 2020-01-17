#!/bin/bash
backup_module_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd $backup_module_dir
echo "--------------------------------------------"
echo "Backup module installation and update script"
echo "--------------------------------------------"
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
if [ -f $openenergymonitor_dir/EmonScripts/install/load_config.sh ]; then
    echo "- Loading EmonScripts config.ini"
    cd $openenergymonitor_dir/EmonScripts/install
    source load_config.sh
    cd $backup_module_dir
else 
    echo "- EmonScripts load_config.sh not found"
    exit 0
fi

# Creating backup module config.cfg file
echo "- Copying default.config.cfg to config.cfg"
cp default.config.cfg config.cfg
echo "- Setting config.cfg settings"
sed -i "s~USER~$user~" config.cfg
sed -i "s~BACKUP_SCRIPT_LOCATION~$backup_module_dir~" config.cfg
sed -i "s~EMONCMS_LOCATION~$emoncms_www~" config.cfg
sed -i "s~BACKUP_LOCATION~$emoncms_datadir/backup~" config.cfg
sed -i "s~DATABASE_PATH~$emoncms_datadir~" config.cfg
sed -i "s~EMONHUB_CONFIG_PATH~/etc/emonhub~" config.cfg
sed -i "s~EMONHUB_SPECIMEN_CONFIG~$openenergymonitor_dir/emonhub/conf~" config.cfg
sed -i "s~BACKUP_SOURCE_PATH~$emoncms_datadir/backup/uploads~" config.cfg
source config.cfg

# Load backup module configuration file
upload_location=$backup_location/uploads

# Symlink emoncms UI (if not done so already)
if [ ! -L $emoncms_www/Modules/backup ]; then
    echo "- Symlinking backup module"
    ln -s $backup_module_dir/backup-module $emoncms_www/Modules/backup
else
    echo "- Backup module symlink already exists"
fi

# php_ini=/etc/php5/apache2/php.ini
PHP_VER=$(php -v | head -n 1 | cut -d " " -f 2 | cut -f1-2 -d"." )
php_ini=/etc/php/$PHP_VER/apache2/php.ini
echo "- PHP Version: $PHP_VER"

echo "- Creating /etc/php/$PHP_VER/mods-available/emoncmsbackup.ini"
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
    sudo chown pi:pi $backup_location -R
else
    echo "- $backup_location already exists"
fi

if [ ! -d $backup_location/uploads ]; then
    echo "- creating $backup_location/uploads directory"
    sudo mkdir $backup_location/uploads
    sudo chown www-data:pi $backup_location/uploads -R
else
    echo "- $backup_location/uploads already exists"
fi

echo "- restarting apache"
sudo service apache2 restart
