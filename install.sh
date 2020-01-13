#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
echo "Backup module installation script"

# Load backup module configuration file
source $DIR/config.cfg
upload_location=$backup_location/uploads

# Symlink emoncms UI (if not done so already)
# emoncms_www=/var/www/emoncms
# if [ ! -L $emoncms_www/Modules/backup ]; then
#     ln -s $usrdir/modules/backup/backup-module $emoncms_www/Modules/backup
# fi

# php_ini=/etc/php5/apache2/php.ini
PHP_VER=$(php -v | head -n 1 | cut -d " " -f 2 | cut -f1-2 -d"." )
php_ini=/etc/php/$PHP_VER/apache2/php.ini

# Modify php.ini
# echo "- applying php.ini modifications"
# sudo sed -i "s/^post_max_size.*/post_max_size = 3G/" $php_ini
# sudo sed -i "s/^upload_max_filesize.*/upload_max_filesize = 3G/" $php_ini
# sudo sed -i "s~^;upload_tmp_dir.*~upload_tmp_dir = $upload_dir~" $php_ini
# sudo sed -i "s~^upload_tmp_dir.*~upload_tmp_dir = $upload_dir~" $php_ini

cat << EOF |
post_max_size = 3G
upload_max_filesize = 3G
upload_tmp_dir = ${upload_location}
EOF
sudo tee /etc/php/$PHP_VER/mods-available/emoncmsbackup.ini

sudo phpenmod emoncmsbackup

# Create uploads folder
if [ ! -d $backup_location ]; then
    echo "- creating $backup_location directory"
    sudo mkdir $backup_location
    sudo chown pi:pi $backup_location -R
fi

if [ ! -d $backup_location/uploads ]; then
    echo "- creating $backup_location/uploads directory"
    sudo mkdir $backup_location/uploads
    sudo chown www-data:pi $backup_location/uploads -R
fi

echo "- restarting apache"
sudo service apache2 restart
